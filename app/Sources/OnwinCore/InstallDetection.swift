import Foundation

// MARK: - What did the installer add?
//
// `InstallSnapshot.take(space)` records the Start Menu / desktop shortcuts (.lnk), the top-level folders of
// Program Files and Program Files (x86) and the registry Uninstall entries (UninstallRegistry). Taken before
// and after an installer, `InstallDetector.detect(before:after:in:)` proposes the program(s) to launch:
//
//   1. targets of new shortcuts (the installer's own choice, with its arguments);
//   2. DisplayIcon of new Uninstall entries when it is an .exe (Explorer shows that icon for the program);
//   3. the largest .exe in InstallLocation of a new Uninstall entry / in a new Program Files folder,
//      skipping uninstallers, updaters, crash reporters and redistributables.
//
// `RecipeInstaller.install(recipe:into:progress:)` wraps `Installer.install` with a snapshot taken right
// before the installer runs (after the space and its components exist), so only the program counts.

/// State of a space that an installer may change.
public struct InstallSnapshot: Sendable {
    /// Unix paths (lower-cased) of .lnk files in the Start Menu and on the desktops.
    public var shortcuts: Set<String>
    /// Unix paths (lower-cased) of Program Files / Program Files (x86) top-level folders.
    public var programFolders: Set<String>
    /// Uninstall entries, by `InstalledApplication.id`.
    public var applications: [String: InstalledApplication]
    public var shortcutFiles: [String: URL]
    public var programFolderURLs: [String: URL]

    public static func take(_ space: Space) -> InstallSnapshot {
        let fm = FileManager.default
        var shortcutFiles: [String: URL] = [:]
        for root in shortcutRoots(of: space) {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "lnk" {
                shortcutFiles[file.standardizedFileURL.path.lowercased()] = file
            }
        }
        var folders: [String: URL] = [:]
        for name in ["Program Files", "Program Files (x86)"] {
            let dir = space.driveC.appendingPathComponent(name, isDirectory: true)
            for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            where OnwinPaths.isDirectory(entry) {
                folders[entry.standardizedFileURL.path.lowercased()] = entry
            }
        }
        var apps: [String: InstalledApplication] = [:]
        for app in UninstallRegistry.applications(in: space) { apps[app.id] = app }
        return InstallSnapshot(shortcuts: Set(shortcutFiles.keys), programFolders: Set(folders.keys),
                               applications: apps, shortcutFiles: shortcutFiles, programFolderURLs: folders)
    }

    static func shortcutRoots(of space: Space) -> [URL] {
        let fm = FileManager.default
        var roots = [space.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = space.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            if user == "Public" {
                roots.append(users.appendingPathComponent("Public/Desktop"))
                continue
            }
            roots.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
            roots.append(users.appendingPathComponent("\(user)/Desktop"))
        }
        return roots
    }
}

/// A program the installer seems to have added: a proposal for the recipe's launch path.
public struct LaunchCandidate: Identifiable, Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case shortcut, uninstallIcon, installLocation, programFolder

        public var displayName: String {
            switch self {
            case .shortcut: return "ярлык в меню «Пуск»"
            case .uninstallIcon: return "значок в «Установке и удалении программ»"
            case .installLocation: return "папка установки программы"
            case .programFolder: return "новая папка в Program Files"
            }
        }
    }

    public var name: String
    public var windowsPath: String
    public var unixPath: URL
    public var arguments: [String]
    public var source: Source
    public var sizeBytes: Int64

    public var id: String { windowsPath.lowercased() }
}

/// Result of comparing two snapshots.
public struct InstallDetection: Sendable {
    public var newShortcuts: [URL]
    public var newProgramFolders: [URL]
    public var newApplications: [InstalledApplication]
    /// Best first.
    public var candidates: [LaunchCandidate]

    public static let empty = InstallDetection(newShortcuts: [], newProgramFolders: [], newApplications: [], candidates: [])

    public var isEmpty: Bool { newShortcuts.isEmpty && newProgramFolders.isEmpty && newApplications.isEmpty }

    /// Display name of the installed product (Uninstall DisplayName, else the best candidate's name).
    public var productName: String? {
        newApplications.first?.displayName ?? candidates.first?.name
    }
    public var publisher: String? { newApplications.first?.publisher }
    public var version: String? { newApplications.first?.displayVersion }
}

public enum InstallDetector {
    /// Names of executables that are not "the program".
    static let helperWords = ["unins", "uninst", "uninstall", "setup", "install", "update", "updater", "crash", "report",
                              "helper", "redist", "vcredist", "dxsetup", "dotnet", "elevate", "service", "bugsplat",
                              "cefsharp", "notification", "remove"]

    static func isHelper(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return helperWords.contains { lower.contains($0) }
    }

    public static func detect(before: InstallSnapshot, after: InstallSnapshot, in space: Space) -> InstallDetection {
        let newShortcuts = after.shortcuts.subtracting(before.shortcuts).compactMap { after.shortcutFiles[$0] }
            .sorted { $0.path < $1.path }
        let newFolders = after.programFolders.subtracting(before.programFolders).compactMap { after.programFolderURLs[$0] }
            .sorted { $0.path < $1.path }
        let newApps = after.applications.keys.filter { before.applications[$0] == nil }.compactMap { after.applications[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var result: [LaunchCandidate] = []
        var seen = Set<String>()
        func add(_ unix: URL, name: String, arguments: [String] = [], source: LaunchCandidate.Source) {
            let resolved = unix.standardizedFileURL
            guard resolved.pathExtension.lowercased() == "exe", OnwinPaths.exists(resolved), !OnwinPaths.isDirectory(resolved) else { return }
            let windows = space.windowsPath(forUnixPath: resolved)
            guard seen.insert(windows.lowercased()).inserted else { return }
            result.append(LaunchCandidate(name: name, windowsPath: windows, unixPath: resolved, arguments: arguments,
                                          source: source, sizeBytes: fileSize(resolved)))
        }

        // 1. Shortcuts, programs first (uninstallers and readmes are what ProgramScanner skips too).
        for lnk in newShortcuts {
            let name = lnk.deletingPathExtension().lastPathComponent
            let lower = name.lowercased()
            if lower.contains("uninstall") || lower.contains("удалить") || lower.hasPrefix("readme") { continue }
            guard let info = ShellLink.parse(lnk), let target = info.targetPath,
                  let unix = space.unixPath(forWindowsPath: target), !isHelper(unix.lastPathComponent) else { continue }
            add(unix, name: name, arguments: info.arguments.map(WindowsCommandLine.split) ?? [], source: .shortcut)
        }
        // 2. DisplayIcon of new Uninstall entries.
        for app in newApps {
            guard let icon = app.displayIcon, let path = iconPath(icon, in: space),
                  let unix = space.unixPath(forWindowsPath: path), !isHelper(unix.lastPathComponent) else { continue }
            add(unix, name: app.displayName, source: .uninstallIcon)
        }
        // 3. Largest program exe in the install location / new folders.
        for app in newApps {
            guard let location = app.installLocation,
                  let dir = space.unixPath(forWindowsPath: UninstallRegistry.expand(unquote(location), in: space)),
                  OnwinPaths.isDirectory(dir), let exe = largestExecutable(in: dir) else { continue }
            add(exe, name: app.displayName, source: .installLocation)
        }
        for folder in newFolders {
            guard let exe = largestExecutable(in: folder) else { continue }
            add(exe, name: folder.lastPathComponent, source: .programFolder)
        }
        return InstallDetection(newShortcuts: newShortcuts, newProgramFolders: newFolders, newApplications: newApps,
                                candidates: result)
    }

    /// `"C:\Program Files\App\app.exe",0` → `C:\Program Files\App\app.exe` (environment variables expanded).
    static func iconPath(_ value: String, in space: Space) -> String? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if let comma = s.lastIndex(of: ","), Int(s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)) != nil {
            s = String(s[..<comma])
        }
        s = UninstallRegistry.expand(unquote(s), in: space)
        guard UserRecipes.isWindowsPath(s), s.lowercased().hasSuffix(".exe") else { return nil }
        return s
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// The biggest .exe under `dir` (4 levels deep at most) that is not an uninstaller or helper.
    public static func largestExecutable(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (URL, Int64)?
        var fallback: (URL, Int64)?
        var visited = 0
        for case let file as URL in walker {
            visited += 1
            if visited > 20_000 { break }
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard file.pathExtension.lowercased() == "exe" else { continue }
            let size = fileSize(file)
            if isHelper(file.lastPathComponent) {
                if size > (fallback?.1 ?? -1) { fallback = (file, size) }
            } else if size > (best?.1 ?? -1) {
                best = (file, size)
            }
        }
        return (best ?? fallback)?.0
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Recipe installation with detection of what the installer added (user recipes, custom installers).
public enum RecipeInstaller {
    public struct Result: Sendable {
        public var space: Space
        public var detection: InstallDetection
    }

    /// Creates / reuses the space, installs the components, snapshots, then runs `Installer.install`.
    public static func install(recipe: AppRecipe, into existing: Space? = nil,
                               progress: @escaping ProgressHandler) async throws -> Result {
        var space: Space
        if let existing {
            space = existing
        } else if let found = SpaceManager.find(recipe.spaceName) {
            space = found
        } else {
            progress(InstallProgress(message: "Создаю пространство «\(recipe.spaceName)»…", fraction: nil))
            space = try await SpaceManager.create(name: recipe.spaceName, windowsVersion: recipe.windowsVersion,
                                                    backend: recipe.backend,
                                                    log: { line in progress(InstallProgress(message: line.trimmingCharacters(in: .whitespacesAndNewlines), fraction: nil)) })
        }
        for id in recipe.components {
            guard let component = Catalog.component(id), !component.isInstalled(in: space.config) else { continue }
            space = try await Installer.install(component: component, into: space, progress: progress)
        }
        let before = InstallSnapshot.take(space)
        space = try await Installer.install(recipe: recipe, into: space, progress: progress)
        let detection = InstallDetector.detect(before: before, after: InstallSnapshot.take(space), in: space)
        return Result(space: space, detection: detection)
    }

    /// Runs an installer file in a space and waits for it (and, when `waitForSpace`, for every process
    /// of the space, so the registry is written), then reports what it added. A non-zero exit is not an
    /// error here: the user may have cancelled; `status` tells.
    public static func runInstaller(_ file: URL, arguments: [String] = [], in space: Space, waitForSpace: Bool = true,
                                    output: (@Sendable (String) -> Void)? = nil) async throws -> (status: Int32, detection: InstallDetection) {
        let before = InstallSnapshot.take(space)
        let runner = try WineRunner(space: space)
        let r = try await runner.runAndWait(WineRunner.command(for: file, arguments: arguments),
                                            currentDirectory: file.deletingLastPathComponent(), onOutput: output)
        if waitForSpace { try await runner.waitForServer() }
        return (r.status, InstallDetector.detect(before: before, after: InstallSnapshot.take(space), in: space))
    }

    /// Whether an installer exit status means success (0, 3010 = reboot required, 1638 = already installed).
    public static func isSuccess(_ status: Int32) -> Bool {
        ([0, 3010, 1638] as [Int32]).contains { WineRunner.exitStatus(status, matches: $0) }
    }
}
