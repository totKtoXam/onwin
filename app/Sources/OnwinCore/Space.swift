import Foundation

/// A space is a Wine prefix (a self-contained fake Windows installation) plus its onwin settings.
/// The space directory *is* the WINEPREFIX: it holds `drive_c`, `system.reg`,
/// `user.reg`, `dosdevices` and our `onwin-space.json`.
public struct Space: Identifiable, Hashable, Sendable {
    public let url: URL
    public var config: SpaceConfig

    public var id: UUID { config.id }
    public var name: String { config.name }
    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    public var system32: URL { driveC.appendingPathComponent("windows/system32", isDirectory: true) }
    public var syswow64: URL { driveC.appendingPathComponent("windows/syswow64", isDirectory: true) }
    public var isInitialized: Bool { OnwinPaths.exists(url.appendingPathComponent("system.reg")) }

    public init(url: URL) throws {
        self.url = url
        self.config = try SpaceConfig.load(from: url)
    }

    init(url: URL, config: SpaceConfig) {
        self.url = url
        self.config = config
    }

    public static func == (lhs: Space, rhs: Space) -> Bool { lhs.url == rhs.url && lhs.config == rhs.config }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    public func save() throws { try config.save(to: url) }

    /// Converts a Windows path (C:\Program Files\...) into the Unix path inside this space.
    public func unixPath(forWindowsPath windowsPath: String) -> URL? {
        var path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 2, path[path.index(after: path.startIndex)] == ":" else { return nil }
        let drive = path.prefix(1).lowercased()
        path.removeFirst(2)
        let base = url.appendingPathComponent("dosdevices/\(drive):", isDirectory: true).resolvingSymlinksInPath()
        let components = path.split(separator: "/").map(String.init)
        // Case-insensitive walk, as Windows paths are case-insensitive.
        var current = base
        for component in components {
            let exact = current.appendingPathComponent(component)
            if OnwinPaths.exists(exact) { current = exact; continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            if let match = entries.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                current = current.appendingPathComponent(match)
            } else {
                current = exact
            }
        }
        return current
    }

    /// Converts a Unix path into the Windows path Wine would show (Z:\... for paths outside the space).
    public func windowsPath(forUnixPath unix: URL) -> String {
        let p = unix.standardizedFileURL.resolvingSymlinksInPath().path
        let c = driveC.standardizedFileURL.resolvingSymlinksInPath().path
        if p == c || p.hasPrefix(c + "/") {
            return "C:" + String(p.dropFirst(c.count)).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + p.replacingOccurrences(of: "/", with: "\\")
    }
}

/// Creates, lists, deletes, duplicates, archives and restores spaces.
public enum SpaceManager {
    public static func list() -> [Space] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: OnwinPaths.spaces,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { try? Space(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func find(_ nameOrID: String) -> Space? {
        let all = list()
        return all.first(where: { $0.name == nameOrID })
            ?? all.first(where: { $0.id.uuidString.lowercased() == nameOrID.lowercased() })
            ?? all.first(where: { $0.name.localizedCaseInsensitiveCompare(nameOrID) == .orderedSame })
    }

    /// Directory name for a space name: keep it readable but file-system safe.
    static func directoryName(for name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Space" : cleaned
    }

    static func uniqueDirectory(for name: String) -> URL {
        let base = directoryName(for: name)
        var candidate = OnwinPaths.spaces.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while OnwinPaths.exists(candidate) {
            candidate = OnwinPaths.spaces.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Creates a new space: makes the directory, runs `wineboot --init`, sets the Windows
    /// version and applies onwin's defaults (SpaceSetup).
    @discardableResult
    public static func create(name: String,
                              windowsVersion: WindowsVersion = .win10,
                              backend: GraphicsBackend = .auto,
                              engine: Engine? = nil,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Space {
        try OnwinPaths.ensureLayout()
        if find(name) != nil { throw OnwinError("Пространство «\(name)» уже существует") }
        let dir = uniqueDirectory(for: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = SpaceConfig(name: name, windowsVersion: windowsVersion, graphicsBackend: backend)
        let engine = try engine ?? EngineManager.engine(for: nil)
        config.engineID = nil
        let space = Space(url: dir, config: config)
        try space.save()
        do {
            try await SpaceSetup.initialize(space, engine: engine, log: log)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return space
    }

    public static func delete(_ space: Space) async throws {
        try? await WineRunner(space: space).killAll()
        try FileManager.default.trashItem(at: space.url, resultingItemURL: nil)
    }

    public static func rename(_ space: Space, to newName: String) throws -> Space {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnwinError("Имя пространства не может быть пустым") }
        if let other = find(trimmed), other.id != space.id { throw OnwinError("Пространство «\(trimmed)» уже существует") }
        var b = space
        b.config.name = trimmed
        // Same folder name (or only a case change, which the case-insensitive volume treats as the
        // same name): keep the folder. uniqueDirectory would see it as taken and move to "<name> 2".
        if directoryName(for: trimmed).caseInsensitiveCompare(space.url.lastPathComponent) == .orderedSame {
            try b.save()
            return b
        }
        let newDir = uniqueDirectory(for: trimmed)
        try FileManager.default.moveItem(at: space.url, to: newDir)
        b = Space(url: newDir, config: b.config)
        try b.save()
        return b
    }

    public static func duplicate(_ space: Space, as newName: String) throws -> Space {
        if find(newName) != nil { throw OnwinError("Пространство «\(newName)» уже существует") }
        let dir = uniqueDirectory(for: newName)
        try FileManager.default.copyItem(at: space.url, to: dir)
        var config = space.config
        config.id = UUID()
        config.name = newName
        config.created = Date()
        let b = Space(url: dir, config: config)
        // Keep .update-timestamp: without it the copy's first start would run a prefix update.
        try b.save()
        return b
    }

    /// Exports a space into a compressed archive (`.onwinspace`, a tar.gz; `.onwinbottle` from older builds opens too).
    public static func archive(_ space: Space, to destination: URL) async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                                 arguments: ["-czf", destination.path,
                                                             "--exclude", ".wineserver*",
                                                             "-C", space.url.deletingLastPathComponent().path,
                                                             space.url.lastPathComponent])
        guard result.status == 0 else { throw OnwinError("Не удалось упаковать пространство: \(result.output)") }
    }

    /// Restores a space from an archive made by `archive(_:to:)`.
    public static func restore(from archive: URL, name: String? = nil) async throws -> Space {
        try OnwinPaths.ensureLayout()
        let staging = OnwinPaths.spaces.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                                 arguments: ["-xzf", archive.path, "-C", staging.path])
        guard result.status == 0 else { throw OnwinError("Не удалось распаковать архив: \(result.output)") }
        let contents = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
        guard let extracted = contents.first(where: { SpaceConfig.exists(in: $0) }) else {
            throw OnwinError("В архиве нет пространства onwin")
        }
        var config = try SpaceConfig.load(from: extracted)
        let finalName = name ?? (find(config.name) == nil ? config.name : config.name + " (копия)")
        config.name = finalName
        config.id = UUID()
        let dir = uniqueDirectory(for: finalName)
        try FileManager.default.moveItem(at: extracted, to: dir)
        let space = Space(url: dir, config: config)
        try space.save()
        return space
    }
}
