import Foundation

/// A program registered under `…\CurrentVersion\Uninstall` (what "Programs and Features" lists).
public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public enum Scope: String, Hashable, Sendable {
        case machine        // HKLM\Software\…            (64-bit view)
        case machine32      // HKLM\Software\Wow6432Node\… (32-bit programs)
        case user           // HKCU\Software\…

        public var displayName: String {
            switch self {
            case .machine: return "HKLM"
            case .machine32: return "HKLM (32-бит)"
            case .user: return "HKCU"
            }
        }
    }

    /// Name of the Uninstall subkey (product GUID for MSI packages).
    public var keyName: String
    public var scope: Scope
    public var displayName: String
    public var displayVersion: String?
    public var publisher: String?
    public var installLocation: String?
    public var displayIcon: String?
    public var uninstallString: String?
    public var quietUninstallString: String?
    /// `WindowsInstaller=1`: removed with `msiexec /x {GUID}`.
    public var isWindowsInstaller: Bool
    public var estimatedSizeKB: Int?

    public var id: String { "\(scope.rawValue)/\(keyName)" }
}

/// Reads the Uninstall keys of a space straight from its registry files and builds the commands
/// that remove a program. Selection follows Wine's own `uninstaller` (programs/uninstaller/main.c):
/// HKLM, HKLM 32-bit view and HKCU; `SystemComponent=1` is hidden; a key needs `DisplayName` and either
/// `WindowsInstaller=1` (→ `msiexec /x<key>`) or `UninstallString`. onwin runs the command itself instead of
/// `uninstaller --remove`, because Wine's uninstaller shows a message box when the command fails.
public enum UninstallRegistry {
    static let uninstallPath = #"Software\Microsoft\Windows\CurrentVersion\Uninstall"#
    static let uninstallPath32 = #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#

    public static func applications(in space: Space) -> [InstalledApplication] {
        let machine = WineRegistry.keys(in: WineRegistry.machineHive(of: space), under: [uninstallPath, uninstallPath32])
        let user = WineRegistry.keys(in: WineRegistry.userHive(of: space), under: [uninstallPath])
        var result: [InstalledApplication] = []
        var seen = Set<String>()
        let sources: [(InstalledApplication.Scope, String, [WineRegistry.Key])] = [
            (.machine, uninstallPath, machine), (.machine32, uninstallPath32, machine), (.user, uninstallPath, user),
        ]
        for (scope, base, keys) in sources {
            for key in keys {
                // Direct subkeys of the Uninstall key only.
                guard key.path.count > base.count + 1,
                      key.path.lowercased().hasPrefix(base.lowercased() + "\\") else { continue }
                let keyName = String(key.path.dropFirst(base.count + 1))
                guard !keyName.contains("\\"), let app = application(from: key, keyName: keyName, scope: scope) else { continue }
                // The same product registered in several views (Wine's own CXHTML is in both): list it once.
                let dedupe = "\(keyName.lowercased())|\(app.displayName.lowercased())"
                if seen.insert(dedupe).inserted { result.append(app) }
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func application(from key: WineRegistry.Key, keyName: String,
                            scope: InstalledApplication.Scope) -> InstalledApplication? {
        if key["SystemComponent"]?.integer == 1 { return nil }
        guard let name = key["DisplayName"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let msi = key["WindowsInstaller"]?.integer == 1
        let uninstall = nonEmpty(key["UninstallString"]?.text)
        guard msi || uninstall != nil else { return nil }
        return InstalledApplication(keyName: keyName, scope: scope, displayName: name,
                                    displayVersion: nonEmpty(key["DisplayVersion"]?.text),
                                    publisher: nonEmpty(key["Publisher"]?.text),
                                    installLocation: nonEmpty(key["InstallLocation"]?.text),
                                    displayIcon: nonEmpty(key["DisplayIcon"]?.text),
                                    uninstallString: uninstall,
                                    quietUninstallString: nonEmpty(key["QuietUninstallString"]?.text),
                                    isWindowsInstaller: msi,
                                    estimatedSizeKB: key["EstimatedSize"]?.integer.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Finds a program by display name or key name (exact, case-insensitive), then by a unique substring.
    public static func find(_ query: String, in apps: [InstalledApplication]) -> [InstalledApplication] {
        let exact = apps.filter {
            $0.displayName.caseInsensitiveCompare(query) == .orderedSame || $0.keyName.caseInsensitiveCompare(query) == .orderedSame
        }
        if !exact.isEmpty { return exact }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Whether a silent removal is possible (QuietUninstallString, or MSI with /qn).
    public static func canUninstallQuietly(_ app: InstalledApplication) -> Bool {
        app.isWindowsInstaller || app.quietUninstallString != nil
            || app.uninstallString.flatMap(msiProductCode(in:)) != nil
    }

    /// Product code of an `MsiExec.exe /I{GUID}` or `/X{GUID}` UninstallString: MSI packages whose key
    /// lacks `WindowsInstaller=1` (or is not named after the product code). `/I` opens the package's
    /// maintenance window, so a quiet removal uses `msiexec /x {GUID} /qn` instead.
    static func msiProductCode(in line: String) -> String? {
        let pattern = #"(?i)^\s*"?(?:[a-z]:\\[^"]*\\)?msiexec(?:\.exe)?"?\s.*?/[ix]\s*"?(\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range]).uppercased()
    }

    /// Wine arguments that remove `app`. `quiet` uses QuietUninstallString or `msiexec /x … /qn`;
    /// otherwise the program's own uninstaller window opens (as in Windows).
    public static func command(for app: InstalledApplication, quiet: Bool, in space: Space) -> [String]? {
        if app.isWindowsInstaller {
            // Same as Wine's uninstaller: the key name is the product code.
            return ["msiexec", "/x", app.keyName] + (quiet ? ["/qn"] : [])
        }
        if quiet, app.quietUninstallString == nil, let code = app.uninstallString.flatMap(msiProductCode(in:)) {
            return ["msiexec", "/x", code, "/qn"]
        }
        let line = (quiet ? app.quietUninstallString : nil) ?? app.uninstallString
        guard let line, let resolved = WindowsCommandLine.resolve(expand(line, in: space), in: space) else { return nil }
        return resolved.wineArguments
    }

    /// Expands the environment variables REG_EXPAND_SZ commands use most (%SystemRoot%, %ProgramFiles%…).
    static func expand(_ s: String, in space: Space) -> String {
        guard s.contains("%") else { return s }
        let vars: [String: String] = [
            "systemroot": #"C:\windows"#, "windir": #"C:\windows"#, "systemdrive": "C:",
            "programfiles": #"C:\Program Files"#, "programfiles(x86)": #"C:\Program Files (x86)"#,
            "programw6432": #"C:\Program Files"#, "commonprogramfiles": #"C:\Program Files\Common Files"#,
            "commonprogramfiles(x86)": #"C:\Program Files (x86)\Common Files"#, "programdata": #"C:\ProgramData"#,
            "allusersprofile": #"C:\ProgramData"#,
        ]
        var out = ""
        var rest = Substring(s)
        while let start = rest.firstIndex(of: "%") {
            out += rest[..<start]
            let after = rest.index(after: start)
            guard let end = rest[after...].firstIndex(of: "%") else { out += rest[start...]; return out }
            let name = rest[after..<end].lowercased()
            if let v = vars[name] { out += v } else { out += rest[start...end] }
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }
}
