import Foundation

/// File-system layout used by onwin.
///
///     ~/Library/Application Support/onwin/
///         Spaces/<name>/           one Wine prefix per space (drive_c, *.reg, onwin-space.json);
///                                  `Bottles/` of older builds is moved here (see `migrateLegacySpaces`)
///         Engines/<id>/            Wine engines (bin/wine, lib/wine, lib/dxvk, lib/dxmt, ...)
///         Graphics/D3DMetal/       D3DMetal imported from Apple's Game Porting Toolkit
///     ~/Library/Caches/onwin/      downloaded installers and components
///     ~/Library/Logs/onwin/        per-space run logs
///
/// `ONWIN_HOME` overrides the root (handy for tests).
public enum OnwinPaths {
    public static let fileManager = FileManager.default

    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["ONWIN_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("onwin", isDirectory: true)
    }

    public static var spaces: URL {
        _ = migrateLegacySpaces
        return root.appendingPathComponent("Spaces", isDirectory: true)
    }

    /// Folder used before spaces were called "bottles" (onwin ≤ 0.1.0 development builds).
    static var legacySpaces: URL { root.appendingPathComponent("Bottles", isDirectory: true) }

    /// One-time move of `Bottles/` to `Spaces/`. A `Bottles` symlink to the new folder stays, so Wine
    /// processes that were started from the old path (and older onwin builds) keep working.
    /// Lazy static: runs once per process, thread-safe.
    private static let migrateLegacySpaces: Void = {
        let fm = FileManager.default
        let old = legacySpaces
        let new = root.appendingPathComponent("Spaces", isDirectory: true)
        guard let attrs = try? fm.attributesOfItem(atPath: old.path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: "Spaces")
        } catch {
            // Leave everything where it is; the next start tries again.
        }
    }()
    public static var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public static var graphics: URL { root.appendingPathComponent("Graphics", isDirectory: true) }
    public static var d3dmetal: URL { graphics.appendingPathComponent("D3DMetal", isDirectory: true) }
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    public static var cache: URL {
        if let custom = ProcessInfo.processInfo.environment["ONWIN_HOME"], !custom.isEmpty {
            return root.appendingPathComponent("Cache", isDirectory: true)
        }
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("onwin", isDirectory: true)
    }

    public static var logs: URL {
        if let custom = ProcessInfo.processInfo.environment["ONWIN_HOME"], !custom.isEmpty {
            return root.appendingPathComponent("Logs", isDirectory: true)
        }
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("Logs/onwin", isDirectory: true)
    }

    /// Creates the standard directories if they are missing.
    public static func ensureLayout() throws {
        for dir in [root, spaces, engines, graphics, cache, logs] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

public struct OnwinError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
