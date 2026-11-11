import Foundation

/// A program found in a space: either pinned in the config or discovered from the Start Menu.
public struct SpaceProgram: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable { case pinned(UUID), startMenu(URL), desktop(URL) }
    public var id: String
    public var name: String
    public var source: Source
    /// Unix path of the target executable when known (for icons).
    public var executable: URL?
    /// What to hand to Wine: the .lnk itself or the exe.
    public var launchFile: URL
    public var arguments: [String]
    public var environment: [String: String]
}

public enum ProgramScanner {
    /// All launchable programs of a space, pinned ones first, then Start Menu shortcuts.
    public static func programs(in space: Space) -> [SpaceProgram] {
        var result: [SpaceProgram] = []
        var seenTargets = Set<String>()

        for entry in space.config.programs {
            guard let unix = space.unixPath(forWindowsPath: entry.windowsPath) else { continue }
            seenTargets.insert(unix.standardizedFileURL.path.lowercased())
            result.append(SpaceProgram(id: entry.id.uuidString, name: entry.name, source: .pinned(entry.id),
                                        executable: unix, launchFile: unix, arguments: entry.arguments,
                                        environment: entry.environment))
        }

        let fm = FileManager.default
        var menuRoots = [space.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = space.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            menuRoots.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        var shortcuts: [(URL, SpaceProgram.Source)] = []
        for root in menuRoots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "lnk" {
                shortcuts.append((file, .startMenu(file)))
            }
        }
        for desktop in [users.appendingPathComponent("Public/Desktop")] {
            for f in (try? fm.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension.lowercased() == "lnk" {
                shortcuts.append((f, .desktop(f)))
            }
        }

        for (lnk, source) in shortcuts {
            let name = lnk.deletingPathExtension().lastPathComponent
            let lower = name.lowercased()
            // Skip uninstallers, readmes and web links: they are not programs to launch.
            if lower.contains("uninstall") || lower.contains("удалить") || lower.hasPrefix("readme") { continue }
            let info = ShellLink.parse(lnk)
            var target: URL?
            if let path = info?.targetPath, let unix = space.unixPath(forWindowsPath: path) {
                if !["exe", "bat", "cmd", "msc", "lnk"].contains(unix.pathExtension.lowercased()) { continue }
                target = unix
            }
            if let t = target {
                let key = t.standardizedFileURL.path.lowercased()
                if seenTargets.contains(key) { continue }
                seenTargets.insert(key)
            }
            result.append(SpaceProgram(id: lnk.path, name: name, source: source, executable: target,
                                        launchFile: lnk, arguments: [], environment: [:]))
        }
        return result
    }
}

/// Minimal reader for Windows .lnk files (MS-SHLLINK): enough to get the target path.
public enum ShellLink {
    public struct Info: Sendable {
        public var targetPath: String?
        public var arguments: String?
        public var workingDirectory: String?
    }

    public static func parse(_ url: URL) -> Info? {
        guard let data = try? Data(contentsOf: url), data.count >= 0x4C else { return nil }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int {
            o + 4 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 : 0
        }
        func cString(_ o: Int) -> String? {
            guard o < bytes.count else { return nil }
            var end = o
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            return String(bytes: bytes[o..<end], encoding: .windowsCP1252)
        }
        guard u32(0) == 0x4C else { return nil }
        let flags = u32(0x14)
        let hasIDList = flags & 0x1 != 0, hasLinkInfo = flags & 0x2 != 0
        let hasName = flags & 0x4 != 0, hasRelPath = flags & 0x8 != 0, hasWorkDir = flags & 0x10 != 0
        let hasArgs = flags & 0x20 != 0, isUnicode = flags & 0x80 != 0

        var offset = 0x4C
        if hasIDList { offset += 2 + u16(offset) }
        var info = Info()
        if hasLinkInfo {
            let start = offset
            let size = u32(start)
            let liFlags = u32(start + 8)
            if liFlags & 0x1 != 0 {
                let headerSize = u32(start + 4)
                var base: String?
                if headerSize >= 0x24 {
                    let uniOffset = u32(start + 0x1C)
                    if uniOffset > 0 { base = utf16String(bytes, start + uniOffset) }
                }
                if base == nil { base = cString(start + u32(start + 0x10)) }
                let suffix = cString(start + u32(start + 0x18)) ?? ""
                if let base { info.targetPath = base + suffix }
            }
            offset = start + size
        }
        func readStringData() -> String? {
            let count = u16(offset)
            offset += 2
            let length = isUnicode ? count * 2 : count
            guard offset + length <= bytes.count else { return nil }
            let slice = Array(bytes[offset..<offset + length])
            offset += length
            if isUnicode {
                let units = stride(from: 0, to: slice.count - 1, by: 2).map { UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            }
            return String(bytes: slice, encoding: .windowsCP1252)
        }
        if hasName { _ = readStringData() }
        var relative: String?
        if hasRelPath { relative = readStringData() }
        if hasWorkDir { info.workingDirectory = readStringData() }
        if hasArgs { info.arguments = readStringData() }
        if info.targetPath == nil, let relative, let wd = info.workingDirectory {
            info.targetPath = wd + "\\" + relative.replacingOccurrences(of: ".\\", with: "")
        }
        return info
    }

    private static func utf16String(_ bytes: [UInt8], _ offset: Int) -> String? {
        var units: [UInt16] = []
        var o = offset
        while o + 1 < bytes.count {
            let u = UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
            if u == 0 { break }
            units.append(u)
            o += 2
        }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }
}
