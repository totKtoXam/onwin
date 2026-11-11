import Foundation

/// The Windows profile folders of a space («Документы», «Загрузки», «Музыка», «Изображения», «Видео»
/// and the «My Mac Desktop» link on the Windows desktop) and whether they lead to the Mac's folders.
///
/// How Wine makes the links (CW Wine tree, dlls/shell32/shellpath.c): `SHGetFolderPathAndSubDirW` with
/// `CSIDL_FLAG_CREATE` calls `_SHCreateSymbolicLink` only when the folder does not exist yet, and
/// mountmgr (dlls/mountmgr.sys/unixlib.c `set_shell_folder`) then puts a symlink to `$HOME/Documents`,
/// `$HOME/Downloads`, `$HOME/Music`, `$HOME/Pictures`, `$HOME/Movies` there. The Desktop becomes a
/// real folder with a `My Mac Desktop` → `$HOME/Desktop` link inside (CrossOver Hack 12791,
/// `_SHCreateDesktopSymbolicLink`). `wineboot --init` and `wineboot -u` create them through
/// `_SHRegisterUserShellFolders`; an existing real folder is left alone (the only code that replaces
/// one, `wine_update_symbolic_links`, is never called by onwin).
///
/// Those Mac folders are protected by macOS privacy (TCC), so a Windows program looking into them
/// (Steam, games writing to «Мои документы») makes macOS ask «onwin would like to access…». An
/// isolated space therefore gets real folders before Wine first starts (`ensureIsolated`, called from
/// WineRunner before every Wine start while the space is stopped), and Wine never links them.
///
/// Nothing here reads or changes anything inside the Mac folders: links are looked at with `lstat`
/// and removed with `unlink`, which never follow them.
public enum MacFolders {
    /// One profile folder that Wine links to a Mac folder.
    public struct Folder: Sendable {
        /// Path inside the profile, `drive_c/users/crossover/<path>`.
        public let path: String
        /// Folder in the Mac home directory the link points to.
        public let macName: String
        /// Name shown to the user.
        public let title: String
    }

    /// Wine's user name in the CW tree is always "crossover" (CrossOver Hack 12735,
    /// dlls/advapi32/advapi.c `GetUserNameW`), so the profile is `C:\users\crossover`.
    static let userName = "crossover"

    public static let folders: [Folder] = [
        Folder(path: "Documents", macName: "Documents", title: "Документы"),
        Folder(path: "Downloads", macName: "Downloads", title: "Загрузки"),
        Folder(path: "Music", macName: "Music", title: "Музыка"),
        Folder(path: "Pictures", macName: "Pictures", title: "Изображения"),
        Folder(path: "Videos", macName: "Movies", title: "Видео"),
        Folder(path: "Desktop/My Mac Desktop", macName: "Desktop", title: "Рабочий стол Mac"),
    ]

    /// The Desktop link lives inside a real Desktop folder and is only a shortcut: in an isolated space it
    /// is removed, not replaced with a folder.
    static func isDesktopLink(_ folder: Folder) -> Bool { folder.path.hasPrefix("Desktop/") }

    public static func profile(of space: Space) -> URL {
        space.driveC.appendingPathComponent("users/\(userName)", isDirectory: true)
    }

    static func macFolder(_ folder: Folder) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder.macName, isDirectory: true)
    }

    // MARK: State

    enum Kind { case missing, link, directory, other }

    /// What is at `url` itself (a symlink is not followed).
    static func kind(of url: URL) -> Kind {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    /// Profile folders that are links now (to the Mac or anywhere else).
    public static func linkedFolders(in space: Space) -> [Folder] {
        let profile = profile(of: space)
        return folders.filter { kind(of: profile.appendingPathComponent($0.path)) == .link }
    }

    // MARK: Isolated

    /// Makes the space isolated: every link is removed (the Mac folder itself is not touched) and the
    /// five folders become real, empty folders, or get back what `link` set aside as «<имя> (onwin)».
    /// Missing folders are created, so Wine never links them later. Also run before the very first
    /// `wineboot --init`: Wine then finds the folders and makes no links at all.
    /// Returns the folders that were links before.
    @discardableResult
    public static func ensureIsolated(_ space: Space) throws -> [Folder] {
        let fm = FileManager.default
        let profile = profile(of: space)
        var unlinked: [Folder] = []
        for folder in folders {
            let url = profile.appendingPathComponent(folder.path)
            let isDesktop = isDesktopLink(folder)
            switch kind(of: url) {
            case .directory, .other:
                continue
            case .link:
                guard unlink(url.path) == 0 else {
                    throw OnwinError("Не удалось убрать ссылку «\(folder.title)» (\(url.path)): \(String(cString: strerror(errno)))")
                }
                unlinked.append(folder)
            case .missing:
                break
            }
            if isDesktop { continue }
            // A folder kept aside while the space was linked comes back in its place.
            if let kept = keptFolder(for: folder, in: profile) {
                try fm.moveItem(at: kept, to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        // The Windows desktop itself is a real folder; create it so Wine does not add the Mac link.
        let desktop = profile.appendingPathComponent("Desktop", isDirectory: true)
        if kind(of: desktop) == .missing { try fm.createDirectory(at: desktop, withIntermediateDirectories: true) }
        return unlinked
    }

    // MARK: Linked

    /// What `link` did with a folder that already had files in the space.
    public struct KeptFolder: Sendable {
        public let folder: Folder
        /// Where its contents are now, «Documents (onwin)» next to the new link.
        public let keptAt: URL
    }

    /// Links the profile folders to the Mac folders again. A folder of the space that has files is not
    /// merged or moved into the Mac: it is renamed to «<имя> (onwin)» and stays in the space. Empty
    /// folders are replaced. A Mac folder that does not exist is skipped (Wine does the same).
    @discardableResult
    public static func link(_ space: Space) throws -> [KeptFolder] {
        let fm = FileManager.default
        let profile = profile(of: space)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        var kept: [KeptFolder] = []
        for folder in folders {
            let url = profile.appendingPathComponent(folder.path)
            let target = macFolder(folder)
            var st = stat()
            guard stat(target.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            switch kind(of: url) {
            case .link:
                // Already a link: leave it, wherever it points (a user's own choice stays).
                continue
            case .other:
                continue
            case .directory:
                if !hasFiles(url) {
                    try fm.removeItem(at: url)
                } else {
                    let destination = uniqueKeptURL(for: folder, in: profile)
                    try fm.moveItem(at: url, to: destination)
                    kept.append(KeptFolder(folder: folder, keptAt: destination))
                }
            case .missing:
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        }
        return kept
    }

    /// True when the folder holds anything but empty folders and `.DS_Store` (Wine itself puts an empty
    /// `Pictures\Screenshots` there). Symlinks inside count as content and are not followed.
    static func hasFiles(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        for name in entries where name != ".DS_Store" {
            let child = url.appendingPathComponent(name)
            if kind(of: child) != .directory || hasFiles(child) { return true }
        }
        return false
    }

    /// «Documents (onwin)», «Documents (onwin 2)»… next to the folder.
    static func keptName(for folder: Folder, number: Int) -> String {
        let name = (folder.path as NSString).lastPathComponent
        return number == 1 ? "\(name) (onwin)" : "\(name) (onwin \(number))"
    }

    static func uniqueKeptURL(for folder: Folder, in profile: URL) -> URL {
        let parent = profile.appendingPathComponent(folder.path).deletingLastPathComponent()
        var number = 1
        while true {
            let url = parent.appendingPathComponent(keptName(for: folder, number: number), isDirectory: true)
            if kind(of: url) == .missing { return url }
            number += 1
        }
    }

    /// The first «<имя> (onwin)» folder, if `link` set one aside.
    static func keptFolder(for folder: Folder, in profile: URL) -> URL? {
        let url = profile.appendingPathComponent(folder.path).deletingLastPathComponent()
            .appendingPathComponent(keptName(for: folder, number: 1), isDirectory: true)
        return kind(of: url) == .directory ? url : nil
    }

    // MARK: Switching

    /// Result of `apply`, for the message shown to the user.
    public struct Outcome: Sendable {
        public var unlinked: [Folder] = []
        public var kept: [KeptFolder] = []

        /// Russian explanation of the folders set aside, nil when there were none.
        public var keptMessage: String? {
            guard !kept.isEmpty else { return nil }
            let list = kept.map { "«\($0.folder.title)» → C:\\users\\crossover\\\($0.keptAt.lastPathComponent)" }
            return "В пространстве уже были файлы в этих папках. Они не удалены и не перенесены в папки Mac, а сохранены рядом под новым именем:\n"
                + list.joined(separator: "\n")
        }
    }

    /// Switches the space's folders to `linked` (the config is not changed or saved here). The space must
    /// not be running: a running program could be writing into a folder that is being replaced.
    public static func apply(linked: Bool, to space: Space) throws -> Outcome {
        if let runner = try? WineRunner(space: space), runner.isServerRunning {
            throw OnwinError("Пространство «\(space.name)» запущено. Закройте его программы, чтобы изменить папки.")
        }
        var outcome = Outcome()
        if linked {
            outcome.kept = try link(space)
        } else {
            outcome.unlinked = try ensureIsolated(space)
        }
        return outcome
    }
}

extension SpaceManager {
    /// Changes whether the space's «Документы», «Загрузки»… lead to the Mac folders, and saves it.
    /// Throws while the space runs.
    public static func setMacFoldersLinked(_ space: Space, _ linked: Bool) throws -> (Space, MacFolders.Outcome) {
        let outcome = try MacFolders.apply(linked: linked, to: space)
        var updated = space
        updated.config.linkMacFolders = linked
        try updated.save()
        return (updated, outcome)
    }
}

extension WineRunner {
    /// Before a Wine start in an isolated space: real profile folders, so Wine does not link a missing
    /// one to the Mac (it would, see MacFolders). Skipped while the space runs (its folders are in use)
    /// and for linked spaces, where Wine's own behaviour is kept. Never throws: a failure here must not
    /// stop the program, Wine then simply behaves as before.
    public func prepareProfileFolders() {
        guard !space.config.linkMacFolders, !isServerRunning else { return }
        try? MacFolders.ensureIsolated(space)
    }
}
