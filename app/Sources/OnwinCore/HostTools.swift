import Foundation

/// Native (arm64) helper programs onwin runs on the Mac side.
///
/// cabextract is bundled into `Onwin.app/Contents/MacOS/cabextract` by scripts/build-app.sh
/// (built by scripts/build-cabextract.sh from the upstream 1.11 release). Lookup order:
///   1. `$ONWIN_CABEXTRACT`
///   2. next to the running executable (Onwin.app/Contents/MacOS, also through the onwinctl symlink)
///   3. `build/tools/cabextract` of a source checkout above the executable (swift run / .build/debug)
///   4. `PATH`, /opt/homebrew/bin, /usr/local/bin
public enum HostTools {
    public static var cabextract: URL? {
        find("cabextract", environmentKey: "ONWIN_CABEXTRACT")
    }

    public static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    public static func requireCabextract() throws -> URL {
        if let tool = cabextract { return tool }
        throw OnwinError("Не найден cabextract — он нужен, чтобы достать DLL из архивов Microsoft. " +
                         "Соберите его: scripts/build-cabextract.sh (или пересоберите Onwin.app скриптом scripts/build-app.sh).")
    }

    static func find(_ name: String, environmentKey: String) -> URL? {
        let fm = FileManager.default
        func usable(_ url: URL) -> URL? { fm.isExecutableFile(atPath: url.path) ? url : nil }

        let env = ProcessInfo.processInfo.environment
        if let custom = env[environmentKey], !custom.isEmpty,
           let hit = usable(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)) {
            return hit
        }

        var executableDirs: [URL] = []
        if let exe = Bundle.main.executableURL {
            executableDirs.append(exe.deletingLastPathComponent())
            executableDirs.append(exe.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        executableDirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true))
        for dir in executableDirs {
            if let hit = usable(dir.appendingPathComponent(name)) { return hit }
        }

        // Source checkout: <root>/app/.build/<triple>/debug/onwinctl → <root>/build/tools/<name>
        for dir in executableDirs {
            var current = dir
            for _ in 0..<7 {
                if let hit = usable(current.appendingPathComponent("build/tools/\(name)")) { return hit }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }

        var searchPath = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        searchPath += ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in searchPath where !dir.isEmpty {
            if let hit = usable(URL(fileURLWithPath: dir).appendingPathComponent(name)) { return hit }
        }
        return nil
    }
}
