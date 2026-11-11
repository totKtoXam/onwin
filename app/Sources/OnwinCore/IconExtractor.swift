import AppKit
import Foundation

/// Extracts the application icon embedded in a Windows PE file (.exe / .dll).
///
/// The icon resources are read straight from the PE image:
/// DOS header → PE signature → COFF header → optional header (PE32 / PE32+) → resource data
/// directory → `RT_GROUP_ICON` (14, first entry, like Explorer does) → its `GRPICONDIRENTRY`
/// list → the referenced `RT_ICON` (3) images. They are reassembled into a regular .ico file in
/// memory (ICONDIR + ICONDIRENTRY with file offsets, largest image first) and decoded by AppKit.
/// PNG-compressed (Vista-style 256×256) icons are supported. Every read is bounds-checked, so
/// malformed or truncated files simply yield `nil`.
///
/// Results (including misses) are cached in an `NSCache` keyed by path + mtime + size, so it is
/// cheap to call this from view code. `.lnk` files are not resolved here: resolve the shortcut
/// with `ShellLink.parse` + `Space.unixPath(forWindowsPath:)` first and pass the target exe.
public enum IconExtractor {
    /// Icon of a PE executable, or `nil` if the file has none / is not a PE file.
    /// A `.ico` file is accepted as well and loaded directly.
    public static func icon(for exe: URL) -> NSImage? {
        let url = exe.standardizedFileURL.resolvingSymlinksInPath()
        let key = cacheKey(for: url) as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let image = loadIcon(url)
        cache.setObject(CacheEntry(image), forKey: key)
        return image
    }

    /// The icon of a PE executable as the bytes of a standalone .ico file (all images, largest first).
    public static func icoData(for exe: URL) -> Data? {
        let url = exe.standardizedFileURL.resolvingSymlinksInPath()
        guard isRegularFile(url),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let reader = PEIconReader(data: data) else { return nil }
        return reader.icoFiles()?.full
    }

    /// Forgets all cached icons (e.g. after a program was reinstalled in place).
    public static func removeAllCachedIcons() {
        cache.removeAllObjects()
    }

    // MARK: - Cache

    private final class CacheEntry {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private static let cache: NSCache<NSString, CacheEntry> = {
        let c = NSCache<NSString, CacheEntry>()
        c.countLimit = 512
        return c
    }()

    private static func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(url.path)|\(mtime)|\(size)"
    }

    // MARK: - Loading

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func loadIcon(_ url: URL) -> NSImage? {
        guard isRegularFile(url) else { return nil }
        if url.pathExtension.lowercased() == "ico" {
            return validImage(NSImage(contentsOf: url))
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let reader = PEIconReader(data: data),
              let ico = reader.icoFiles() else { return nil }
        if let image = validImage(NSImage(data: ico.full)) { return image }
        // Some odd image in the set may make the whole .ico undecodable: retry with the best one only.
        if let single = ico.largestOnly, let image = validImage(NSImage(data: single)) { return image }
        return nil
    }

    /// Accepts only images that actually decoded; sizes the image to its largest representation.
    private static func validImage(_ image: NSImage?) -> NSImage? {
        guard let image, image.isValid, !image.representations.isEmpty else { return nil }
        var bestPixels = 0
        var bestSize = NSSize.zero
        for rep in image.representations {
            let pixels = rep.pixelsWide * rep.pixelsHigh
            if pixels > bestPixels {
                bestPixels = pixels
                bestSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
        if bestPixels > 0 { image.size = bestSize }
        return image
    }
}

// MARK: - Bounds-checked little/big-endian reader

private struct ByteReader {
    let data: Data

    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    func u32BigEndian(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return nil }
        let base = data.startIndex + offset
        return data.subdata(in: base..<(base + length))
    }
}

// MARK: - Image header inspection (BMP DIB / PNG)

private struct IconImageInfo {
    let width: Int
    let height: Int
    let bitCount: Int
    let isPNG: Bool

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    init?(_ data: Data) {
        let r = ByteReader(data: data)
        var w = 0, h = 0, bits = 0
        if let signature = r.slice(0, 8), signature == IconImageInfo.pngSignature {
            // IHDR chunk: length(4) "IHDR"(4) width(4, BE) height(4, BE) depth(1) colour type(1)
            guard let pw = r.u32BigEndian(16), let ph = r.u32BigEndian(20) else { return nil }
            w = Int(pw)
            h = Int(ph)
            let depth = Int(r.u8(24) ?? 8)
            switch r.u8(25) ?? 6 {
            case 6: bits = depth * 4   // RGBA
            case 2: bits = depth * 3   // RGB
            case 4: bits = depth * 2   // grey + alpha
            default: bits = depth      // grey / palette
            }
            isPNG = true
        } else {
            guard let headerSize = r.u32(0) else { return nil }
            if headerSize == 12 {
                // BITMAPCOREHEADER
                guard let cw = r.u16(4), let ch = r.u16(6), let cb = r.u16(10) else { return nil }
                w = Int(cw)
                h = Int(ch)
                bits = Int(cb)
            } else if headerSize >= 40 && headerSize <= 1024 {
                // BITMAPINFOHEADER and later versions
                guard let iw = r.u32(4), let ih = r.u32(8), let ib = r.u16(14) else { return nil }
                w = abs(Int(Int32(bitPattern: iw)))
                h = abs(Int(Int32(bitPattern: ih)))
                bits = Int(ib)
            } else {
                return nil
            }
            // Icon DIBs store XOR + AND masks: the height is doubled.
            if h >= 2 && h % 2 == 0 { h /= 2 }
            isPNG = false
        }
        guard (1...4096).contains(w), (1...4096).contains(h) else { return nil }
        width = w
        height = h
        bitCount = bits
    }
}

// MARK: - PE resource reader

private struct PEIconReader {
    struct Section {
        let virtualAddress: Int
        let virtualSize: Int
        let rawPointer: Int
        let rawSize: Int
    }

    struct ResourceEntry {
        /// Integer ID, or nil for a named entry.
        let id: UInt16?
        let isDirectory: Bool
        /// RVA of the subdirectory or of the IMAGE_RESOURCE_DATA_ENTRY.
        let target: Int
    }

    struct IconImage {
        let data: Data
        let info: IconImageInfo
        let colorCount: UInt8
        let planes: UInt16
        let bitCount: UInt16

        var score: Int { info.width * info.height * 64 + info.bitCount }
    }

    static let rtIcon: UInt16 = 3
    static let rtGroupIcon: UInt16 = 14
    static let maxEntriesPerDirectory = 4096
    static let maxIconBytes = 8 * 1024 * 1024
    static let maxIcoFileBytes = 32 * 1024 * 1024
    static let maxImagesPerIcon = 256

    let bytes: ByteReader
    let sections: [Section]
    let resourceRVA: Int

    init?(data: Data) {
        let r = ByteReader(data: data)
        guard r.u16(0) == 0x5A4D, let lfanew = r.u32(0x3C) else { return nil }   // "MZ"
        let pe = Int(lfanew)
        guard r.u32(pe) == 0x0000_4550,                                          // "PE\0\0"
              let sectionCount = r.u16(pe + 6),
              let optionalHeaderSize = r.u16(pe + 20) else { return nil }
        let optional = pe + 24
        guard let magic = r.u16(optional) else { return nil }
        let rvaCountOffset: Int
        let directories: Int
        switch magic {
        case 0x10B:   // PE32
            rvaCountOffset = optional + 92
            directories = optional + 96
        case 0x20B:   // PE32+
            rvaCountOffset = optional + 108
            directories = optional + 112
        default:
            return nil
        }
        // Data directory #2 is IMAGE_DIRECTORY_ENTRY_RESOURCE.
        let resourceDirectory = directories + 2 * 8
        guard let rvaCount = r.u32(rvaCountOffset), rvaCount > 2,
              resourceDirectory + 8 <= optional + Int(optionalHeaderSize),
              let rva = r.u32(resourceDirectory), rva != 0 else { return nil }

        var list: [Section] = []
        let table = optional + Int(optionalHeaderSize)
        for index in 0..<Int(sectionCount) {
            let s = table + index * 40
            guard let virtualSize = r.u32(s + 8), let virtualAddress = r.u32(s + 12),
                  let rawSize = r.u32(s + 16), let rawPointer = r.u32(s + 20) else { break }
            list.append(Section(virtualAddress: Int(virtualAddress), virtualSize: Int(virtualSize),
                                rawPointer: Int(rawPointer), rawSize: Int(rawSize)))
        }
        guard !list.isEmpty else { return nil }

        bytes = r
        sections = list
        resourceRVA = Int(rva)
        guard offset(forRVA: resourceRVA) != nil else { return nil }
    }

    /// File offset of an RVA, or nil if it is not backed by file data.
    func offset(forRVA rva: Int) -> Int? {
        guard rva >= 0 else { return nil }
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress, rva - section.virtualAddress < span else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.rawSize else { return nil }
            let fileOffset = section.rawPointer + delta
            return fileOffset < bytes.count ? fileOffset : nil
        }
        return nil
    }

    // MARK: Resource tree

    func entries(ofDirectory rva: Int) -> [ResourceEntry] {
        guard let base = offset(forRVA: rva),
              let named = bytes.u16(base + 12),
              let ids = bytes.u16(base + 14) else { return [] }
        let total = min(Int(named) + Int(ids), PEIconReader.maxEntriesPerDirectory)
        var result: [ResourceEntry] = []
        result.reserveCapacity(total)
        for index in 0..<total {
            let e = base + 16 + index * 8
            guard let name = bytes.u32(e), let target = bytes.u32(e + 4) else { break }
            let isNamed = name & 0x8000_0000 != 0
            result.append(ResourceEntry(id: isNamed ? nil : UInt16(truncatingIfNeeded: name),
                                        isDirectory: target & 0x8000_0000 != 0,
                                        target: resourceRVA + Int(target & 0x7FFF_FFFF)))
        }
        return result
    }

    func typeDirectory(_ type: UInt16) -> Int? {
        entries(ofDirectory: resourceRVA).first { $0.id == type && $0.isDirectory }?.target
    }

    /// Descends (at most a few levels, so loops in a hostile file cannot hang us) to the first data entry.
    func dataEntry(for entry: ResourceEntry) -> Int? {
        var current = entry
        for _ in 0..<3 {
            if !current.isDirectory { return current.target }
            let children = entries(ofDirectory: current.target)
            guard let next = children.first(where: { !$0.isDirectory }) ?? children.first else { return nil }
            current = next
        }
        return nil
    }

    /// Bytes described by an IMAGE_RESOURCE_DATA_ENTRY (its OffsetToData is an RVA).
    func resourceData(dataEntry rva: Int, limit: Int) -> Data? {
        guard let base = offset(forRVA: rva),
              let dataRVA = bytes.u32(base),
              let size = bytes.u32(base + 4),
              size > 0, Int(size) <= limit,
              let dataOffset = offset(forRVA: Int(dataRVA)) else { return nil }
        return bytes.slice(dataOffset, Int(size))
    }

    // MARK: Icons

    /// Images of the first RT_GROUP_ICON, or nil when the file has no usable group icon.
    func groupIconImages() -> [IconImage]? {
        guard let groupType = typeDirectory(PEIconReader.rtGroupIcon),
              let firstGroup = entries(ofDirectory: groupType).first,
              let groupEntry = dataEntry(for: firstGroup),
              let groupData = resourceData(dataEntry: groupEntry, limit: 64 * 1024),
              let iconType = typeDirectory(PEIconReader.rtIcon) else { return nil }
        let g = ByteReader(data: groupData)
        // GRPICONDIR: idReserved(2) idType(2) idCount(2)
        guard g.u16(2) == 1, let count = g.u16(4), count > 0 else { return nil }
        let icons = entries(ofDirectory: iconType)
        var result: [IconImage] = []
        for index in 0..<min(Int(count), PEIconReader.maxImagesPerIcon) {
            // GRPICONDIRENTRY: bWidth bHeight bColorCount bReserved wPlanes wBitCount dwBytesInRes nId
            let e = 6 + index * 14
            guard let colors = g.u8(e + 2), let planes = g.u16(e + 4), let bits = g.u16(e + 6),
                  let iconID = g.u16(e + 12) else { break }
            guard let iconEntry = icons.first(where: { $0.id == iconID }),
                  let dataRVA = dataEntry(for: iconEntry),
                  let data = resourceData(dataEntry: dataRVA, limit: PEIconReader.maxIconBytes),
                  let info = IconImageInfo(data) else { continue }
            result.append(IconImage(data: data, info: info, colorCount: colors, planes: planes, bitCount: bits))
        }
        return result.isEmpty ? nil : result
    }

    /// Fallback for files that carry RT_ICON images without a group directory.
    func looseIconImages() -> [IconImage] {
        guard let iconType = typeDirectory(PEIconReader.rtIcon) else { return [] }
        var result: [IconImage] = []
        for entry in entries(ofDirectory: iconType).prefix(64) {
            guard let dataRVA = dataEntry(for: entry),
                  let data = resourceData(dataEntry: dataRVA, limit: PEIconReader.maxIconBytes),
                  let info = IconImageInfo(data) else { continue }
            result.append(IconImage(data: data, info: info, colorCount: 0, planes: 1, bitCount: 0))
        }
        return result
    }

    /// A complete .ico (all images, largest first) and, if there is more than one image,
    /// an .ico with only the largest image.
    func icoFiles() -> (full: Data, largestOnly: Data?)? {
        let images = groupIconImages() ?? looseIconImages()
        guard !images.isEmpty else { return nil }
        let sorted = images.sorted { $0.score > $1.score }
        let full = PEIconReader.buildICO(sorted)
        let single = sorted.count > 1 ? PEIconReader.buildICO([sorted[0]]) : nil
        return (full, single)
    }

    /// ICONDIR + ICONDIRENTRY[n] (16 bytes each, dwImageOffset instead of nId) + image data.
    static func buildICO(_ candidates: [IconImage]) -> Data {
        var images: [IconImage] = []
        var total = 6
        for image in candidates.prefix(maxImagesPerIcon) {
            let size = 16 + image.data.count
            if !images.isEmpty && total + size > maxIcoFileBytes { break }
            images.append(image)
            total += size
        }

        var out: [UInt8] = []
        out.reserveCapacity(total)
        func put8(_ value: Int) { out.append(UInt8(truncatingIfNeeded: value)) }
        func put16(_ value: Int) {
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func put32(_ value: Int) {
            put16(value & 0xFFFF)
            put16((value >> 16) & 0xFFFF)
        }

        put16(0)              // idReserved
        put16(1)              // idType: icon
        put16(images.count)   // idCount
        var dataOffset = 6 + 16 * images.count
        for image in images {
            let info = image.info
            put8(info.width >= 256 ? 0 : info.width)
            put8(info.height >= 256 ? 0 : info.height)
            put8(info.bitCount <= 8 && !info.isPNG ? Int(image.colorCount) : 0)
            put8(0)
            put16(image.planes == 0 ? 1 : Int(image.planes))
            put16(image.bitCount != 0 ? Int(image.bitCount) : info.bitCount)
            put32(image.data.count)
            put32(dataOffset)
            dataOffset += image.data.count
        }
        for image in images {
            out.append(contentsOf: image.data)
        }
        return Data(out)
    }
}
