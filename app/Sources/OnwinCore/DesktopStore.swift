import Foundation

// «Рабочий стол»: what the desktop remembers between runs, in
// ~/Library/Application Support/onwin/desktop.json (OnwinPaths.root):
//
//     { "version": 1,
//       "lastLaunched": { "<DesktopItem.id>": "2026-11-11T10:00:00Z", … },
//       "hidden": ["<DesktopItem.id>", …] }
//
// Item ids are stable across runs: "<space UUID>/program/<SpaceProgram.id>" (a pinned entry's UUID or
// a Start Menu .lnk path) and "<space UUID>/steam/<appid>" (see DesktopCatalog.swift).

/// The persisted desktop state.
public struct DesktopState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// When an item was last started (from the desktop, or seen running).
    public var lastLaunched: [String: Date]
    /// Items the user hid from the desktop («Скрыть с рабочего стола»).
    public var hidden: Set<String>

    public init(lastLaunched: [String: Date] = [:], hidden: Set<String> = []) {
        self.version = DesktopState.currentVersion
        self.lastLaunched = lastLaunched
        self.hidden = hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? DesktopState.currentVersion
        lastLaunched = try c.decodeIfPresent([String: Date].self, forKey: .lastLaunched) ?? [:]
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
    }

    /// Drops entries of deleted spaces (ids start with the space UUID). Entries of programs that are
    /// gone from an existing space stay: a program reinstalled later keeps its place and hidden flag.
    /// Returns true when something was removed.
    @discardableResult
    public mutating func prune(keepingSpaces spaceIDs: Set<UUID>) -> Bool {
        let keep = Set(spaceIDs.map(\.uuidString))
        func alive(_ id: String) -> Bool { id.split(separator: "/").first.map { keep.contains(String($0)) } ?? false }
        let before = (lastLaunched.count, hidden.count)
        lastLaunched = lastLaunched.filter { alive($0.key) }
        hidden = hidden.filter(alive)
        return before != (lastLaunched.count, hidden.count)
    }
}

/// Reads and writes desktop.json.
public enum DesktopStore {
    public static var file: URL { OnwinPaths.root.appendingPathComponent("desktop.json") }

    /// The saved state; an empty one when the file is missing or unreadable.
    public static func load(from url: URL = DesktopStore.file) -> DesktopState {
        guard let data = try? Data(contentsOf: url) else { return DesktopState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DesktopState.self, from: data)) ?? DesktopState()
    }

    public static func save(_ state: DesktopState, to url: URL = DesktopStore.file) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
