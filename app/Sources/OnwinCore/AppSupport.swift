import Foundation

// Small additions the SwiftUI app needs from the core. Kept in a separate file so the
// original core files stay untouched.

/// File kinds onwin can hand to Wine (double-click semantics, see `WineRunner.command(for:)`).
public enum WineFileTypes {
    public static let runnableExtensions: Set<String> = ["exe", "msi", "lnk", "bat", "cmd", "com"]

    public static func isRunnable(_ url: URL) -> Bool {
        runnableExtensions.contains(url.pathExtension.lowercased())
    }
}

extension Space {
    /// Directory where `WineRunner.launch` writes this space's run logs
    /// (`~/Library/Logs/onwin/<space name>/`).
    public var logDirectory: URL {
        OnwinPaths.logs.appendingPathComponent(SpaceManager.directoryName(for: name), isDirectory: true)
    }

    /// Run logs of this space, newest first.
    public func logFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: logDirectory,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "log" }.sorted { date($0) > date($1) }
    }
}

extension SpaceManager {
    /// A space name that is not taken yet: `base`, `base 2`, `base 3`...
    public static func availableName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Пространство" : trimmed
        if find(root) == nil { return root }
        var n = 2
        while find("\(root) \(n)") != nil { n += 1 }
        return "\(root) \(n)"
    }
}

extension InstallProgress {
    /// Public constructor (the memberwise initialiser of `InstallProgress` is internal).
    public static func status(_ message: String, fraction: Double? = nil) -> InstallProgress {
        InstallProgress(message: message, fraction: fraction)
    }
}
