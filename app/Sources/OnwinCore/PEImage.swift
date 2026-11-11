import Foundation

/// The parts of a Windows PE image (.exe / .dll) the dependency advisor needs: architecture,
/// imported DLLs (regular and delay-loaded) and whether it is a .NET assembly.
///
/// Parsed the same way as `IconExtractor`: DOS header → "PE\0\0" → COFF header → optional header
/// (PE32 / PE32+) → data directories → section table for RVA → file offset. Every read is
/// bounds-checked; malformed files yield `nil` or empty lists, never a crash.
public struct PEImage: Sendable {
    public enum Machine: Sendable, Equatable {
        case i386, amd64, arm64, other(UInt16)

        public var displayName: String {
            switch self {
            case .i386: return "32-бит (x86)"
            case .amd64: return "64-бит (x64)"
            case .arm64: return "ARM64"
            case .other(let v): return String(format: "0x%04x", v)
            }
        }
    }

    public var machine: Machine
    public var is64Bit: Bool
    public var isDLL: Bool
    /// Lower-case DLL names as written in the import table ("kernel32.dll").
    public var imports: [String]
    public var delayImports: [String]
    /// Has a CLR (COM descriptor) header: a .NET assembly.
    public var isDotNet: Bool
    /// .NET image flagged COMIMAGE_FLAGS_ILONLY (pure managed code, no native C++/CLI parts).
    public var isILOnly: Bool = false

    public var allImports: [String] {
        var seen = Set<String>()
        return (imports + delayImports).filter { seen.insert($0).inserted }
    }

    static let maxDescriptors = 2048
    static let maxReadBytes = 512 * 1024 * 1024

    public static func read(_ url: URL) -> PEImage? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue >= 0x40, size.intValue <= maxReadBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> PEImage? {
        let r = PEBytes(data: data)
        guard r.u16(0) == 0x5A4D, let lfanew = r.u32(0x3C) else { return nil }        // "MZ"
        let pe = Int(lfanew)
        guard r.u32(pe) == 0x0000_4550,                                                // "PE\0\0"
              let machineRaw = r.u16(pe + 4),
              let sectionCount = r.u16(pe + 6),
              let optionalSize = r.u16(pe + 20),
              let characteristics = r.u16(pe + 22) else { return nil }
        let optional = pe + 24
        guard let magic = r.u16(optional) else { return nil }
        let is64: Bool
        let imageBase: UInt64
        let countOffset: Int, directories: Int
        switch magic {
        case 0x10B:
            is64 = false
            imageBase = UInt64(r.u32(optional + 28) ?? 0)
            countOffset = optional + 92; directories = optional + 96
        case 0x20B:
            is64 = true
            imageBase = r.u64(optional + 24) ?? 0
            countOffset = optional + 108; directories = optional + 112
        default:
            return nil
        }
        let directoryCount = Int(r.u32(countOffset) ?? 0)
        let optionalEnd = optional + Int(optionalSize)
        func directory(_ index: Int) -> (rva: Int, size: Int)? {
            let entry = directories + index * 8
            guard index < directoryCount, entry + 8 <= optionalEnd,
                  let rva = r.u32(entry), let size = r.u32(entry + 4), rva != 0 else { return nil }
            return (Int(rva), Int(size))
        }

        var sections: [PESection] = []
        for index in 0..<min(Int(sectionCount), 96) {
            let s = optionalEnd + index * 40
            guard let vsize = r.u32(s + 8), let vaddr = r.u32(s + 12),
                  let rsize = r.u32(s + 16), let rptr = r.u32(s + 20) else { break }
            sections.append(PESection(virtualAddress: Int(vaddr), virtualSize: Int(vsize),
                                      rawPointer: Int(rptr), rawSize: Int(rsize)))
        }
        func offset(_ rva: Int) -> Int? {
            guard rva > 0 else { return nil }
            for s in sections {
                let span = max(s.virtualSize, s.rawSize)
                guard rva >= s.virtualAddress, rva - s.virtualAddress < span else { continue }
                let delta = rva - s.virtualAddress
                guard delta < s.rawSize else { return nil }
                let o = s.rawPointer + delta
                return o < r.count ? o : nil
            }
            // Headers are mapped 1:1 (tiny images put the import table there).
            let firstSection = sections.map(\.virtualAddress).min() ?? Int.max
            return rva < firstSection && rva < r.count ? rva : nil
        }
        func name(atRVA rva: Int) -> String? {
            guard let o = offset(rva), let s = r.cString(o, limit: 256), !s.isEmpty else { return nil }
            return s.lowercased()
        }

        var imports: [String] = []
        if let dir = directory(1), let base = offset(dir.rva) {
            for i in 0..<maxDescriptors {
                let d = base + i * 20
                guard let nameRVA = r.u32(d + 12), let thunk = r.u32(d + 16), let original = r.u32(d) else { break }
                if nameRVA == 0 && thunk == 0 && original == 0 { break }
                if let n = name(atRVA: Int(nameRVA)) { imports.append(n) }
            }
        }

        var delay: [String] = []
        if let dir = directory(13), let base = offset(dir.rva) {
            for i in 0..<maxDescriptors {
                let d = base + i * 32
                guard let attributes = r.u32(d), let nameField = r.u32(d + 4) else { break }
                if nameField == 0 { break }
                // Attribute bit 0 clear: old (VC6) descriptors hold virtual addresses, not RVAs.
                var rva = Int(nameField)
                if attributes & 1 == 0, UInt64(nameField) > imageBase, imageBase <= UInt64(UInt32.max) {
                    rva = Int(UInt64(nameField) - imageBase)
                }
                if let n = name(atRVA: rva) { delay.append(n) }
            }
        }

        let machine: Machine
        switch machineRaw {
        case 0x014C: machine = .i386
        case 0x8664: machine = .amd64
        case 0xAA64: machine = .arm64
        default: machine = .other(machineRaw)
        }
        // IMAGE_COR20_HEADER: cb, runtime version (2 × u16), MetaData (8 bytes), Flags at +16.
        let clr = directory(14)
        let ilOnly = clr.flatMap { offset($0.rva) }.flatMap { r.u32($0 + 16) }.map { $0 & 1 != 0 } ?? false
        return PEImage(machine: machine, is64Bit: is64, isDLL: characteristics & 0x2000 != 0,
                       imports: imports, delayImports: delay, isDotNet: clr != nil, isILOnly: ilOnly)
    }

    /// True for Wine's builtin / placeholder DLLs (the files Wine puts into system32, marked at
    /// offset 0x40 with "Wine builtin DLL" or "Wine placeholder DLL").
    public static func isWineBuiltin(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x60), head.count >= 0x58 else { return false }
        let marker = head.subdata(in: 0x40..<0x58)
        return String(decoding: marker, as: UTF8.self).hasPrefix("Wine ")
    }
}

private struct PESection {
    let virtualAddress: Int
    let virtualSize: Int
    let rawPointer: Int
    let rawSize: Int
}

/// Bounds-checked little-endian reader.
private struct PEBytes {
    let data: Data
    var count: Int { data.count }

    func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o <= data.count - 2 else { return nil }
        let b = data.startIndex + o
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }

    func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o <= data.count - 4 else { return nil }
        let b = data.startIndex + o
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }

    func u64(_ o: Int) -> UInt64? {
        guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }

    func cString(_ o: Int, limit: Int) -> String? {
        guard o >= 0, o < data.count else { return nil }
        var bytes: [UInt8] = []
        var i = o
        while i < data.count, bytes.count < limit {
            let c = data[data.startIndex + i]
            if c == 0 { break }
            // DLL names are plain ASCII; anything else means we are reading garbage.
            guard c >= 0x20, c < 0x7F else { return nil }
            bytes.append(c)
            i += 1
        }
        return String(bytes: bytes, encoding: .ascii)
    }
}
