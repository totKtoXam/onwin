import AppKit
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - onwin:// URLs

/// `onwin://run?space=<uuid>&program=<program id>&file=<unix path>`: what a launcher opens.
/// The main app runs the program itself (so it shows up in «Запущенные» and gets its log);
/// `onwinctl open-url` does the same from the command line.
public struct LaunchRequest: Hashable, Sendable {
    public static let scheme = "onwin"

    /// Space UUID (or name, for hand-written URLs).
    public var space: String
    /// `SpaceProgram.id`: a pinned entry's UUID or the Unix path of a Start Menu .lnk.
    public var program: String?
    /// Fallback when the program is gone from the list: the file to run (.exe/.lnk/...).
    public var file: String?

    public init(space: String, program: String?, file: String?) {
        self.space = space
        self.program = program
        self.file = file
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == LaunchRequest.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "run" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, !value.isEmpty { values[item.name] = value }
        }
        // "bottle" = launchers made before spaces were called "bottles".
        guard let space = values["space"] ?? values["bottle"] else { return nil }
        self.init(space: space, program: values["program"], file: values["file"])
    }

    public var url: URL {
        // ASCII only (CharacterSet.alphanumerics would let Cyrillic etc. through unencoded).
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var query = "space=\(enc(space))"
        if let program { query += "&program=\(enc(program))" }
        if let file { query += "&file=\(enc(file))" }
        return URL(string: "\(LaunchRequest.scheme)://run?\(query)")!
    }

    public init(program: SpaceProgram, in space: Space) {
        self.init(space: space.id.uuidString, program: program.id, file: program.launchFile.path)
    }

    /// Finds the space and the program to run. A missing program id falls back to `file`, but only
    /// to a program the space already lists (pinned, Start Menu, Desktop).
    ///
    /// Security: any web page or app can open an `onwin://` URL, so the URL never names an arbitrary
    /// file or command to run — only something already registered in the space (with its saved
    /// arguments). An unlisted `file` is refused even when it exists.
    public func resolve(in spaces: [Space] = SpaceManager.list(),
                        programs: (Space) -> [SpaceProgram] = ProgramScanner.programs(in:)) throws -> (Space, SpaceProgram) {
        let found = spaces.first { $0.id.uuidString.caseInsensitiveCompare(space) == .orderedSame }
            ?? spaces.first { $0.name.localizedCaseInsensitiveCompare(space) == .orderedSame }
        guard let found else {
            throw OnwinError(String(localized: "Пространство ярлыка не найдено (\(space)). Возможно, его удалили — удалите и ярлык.", bundle: .onwinCore))
        }
        let list = programs(found)
        if let program, let match = list.first(where: { $0.id == program }) { return (found, match) }
        if let file {
            let url = URL(fileURLWithPath: file).standardizedFileURL
            if let match = list.first(where: { $0.launchFile.standardizedFileURL == url }) {
                return (found, match)
            }
        }
        throw OnwinError(String(localized: "Программы ярлыка больше нет в пространстве «\(found.name)». Возможно, её удалили — удалите и ярлык.", bundle: .onwinCore))
    }
}

// MARK: - Launcher .app bundles

/// A launcher found on disk.
public struct LauncherInfo: Hashable, Sendable, Identifiable {
    public var url: URL
    public var name: String
    public var spaceID: UUID
    public var programID: String
    /// Made by «Создавать ярлыки автоматически» (removed again when the shortcut disappears).
    public var isAutomatic: Bool
    public var id: URL { url }
}

/// Builds small `.app` bundles that start one Windows program,
/// so programs can live in Launchpad / «Программы», the Dock and Spotlight.
///
///     ~/Applications/onwin/<space>/<program>.app
///         Contents/Info.plist          LSUIElement, OnwinLauncher {space, program, file, url, ...}
///         Contents/MacOS/launcher      the onwin-launcher stub (Mach-O) or a sh fallback
///         Contents/Resources/AppIcon.icns   from the exe icon (winemenubuilder PNG or IconExtractor)
///
/// The stub opens `onwin://run?...` with onwin.app (found by bundle id), so the app tracks the
/// process; when onwin.app is not installed it runs `onwinctl open-url <url>` and waits.
/// Bundles are signed ad-hoc and registered with LaunchServices.
public enum LauncherBuilder {
    public static let appBundleIdentifier = "app.onwin.Onwin"
    public static let stubName = "onwin-launcher"
    static let infoKey = "OnwinLauncher"
    static let formatVersion = 1

    /// `~/Applications/onwin` (`$ONWIN_HOME/Launchers` when ONWIN_HOME is set, for tests;
    /// `ONWIN_LAUNCHERS_DIR` overrides both).
    public static var defaultRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["ONWIN_LAUNCHERS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let home = env["ONWIN_HOME"], !home.isEmpty {
            return OnwinPaths.root.appendingPathComponent("Launchers", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/onwin", isDirectory: true)
    }

    public static func directory(for space: Space, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(fileSafe(space.name, fallback: "Пространство"), isDirectory: true)
    }

    // MARK: Listing

    public static func launchers(root: URL = defaultRoot) -> [LauncherInfo] {
        let fm = FileManager.default
        var result: [LauncherInfo] = []
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            for app in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            where app.pathExtension == "app" {
                if let info = read(app) { result.append(info) }
            }
        }
        return result
    }

    public static func launchers(for spaceID: UUID, root: URL = defaultRoot) -> [LauncherInfo] {
        launchers(root: root).filter { $0.spaceID == spaceID }
    }

    public static func launcher(for program: SpaceProgram, in space: Space, root: URL = defaultRoot) -> LauncherInfo? {
        launchers(for: space.id, root: root).first { $0.programID == program.id }
    }

    static func read(_ app: URL) -> LauncherInfo? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let info = plist[infoKey] as? [String: Any],
              let space = ((info["Space"] ?? info["Bottle"]) as? String).flatMap(UUID.init(uuidString:)),
              let program = info["Program"] as? String else { return nil }
        let name = plist["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
        return LauncherInfo(url: app, name: name, spaceID: space, programID: program,
                            isAutomatic: info["Automatic"] as? Bool ?? false)
    }

    // MARK: Creating

    /// Creates (or replaces) the launcher of a program and returns the .app.
    @discardableResult
    public static func create(for program: SpaceProgram, in space: Space, root: URL = defaultRoot,
                              automatic: Bool = false, menuEntries: [String: StartMenuHook.Entry]? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = directory(for: space, root: root)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Replace this program's previous launcher (even one with another name); keep other
        // programs' launchers that happen to share the name.
        let previous = launchers(for: space.id, root: root).filter { $0.programID == program.id }
        var app = folder.appendingPathComponent(fileSafe(program.name, fallback: "Программа") + ".app", isDirectory: true)
        if OnwinPaths.exists(app), !previous.contains(where: { $0.url.standardizedFileURL == app.standardizedFileURL }) {
            app = uniqueApp(in: folder, base: fileSafe(program.name, fallback: "Программа"))
        }
        for old in previous { try? fm.removeItem(at: old.url) }

        let staging = folder.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let request = LaunchRequest(program: program, in: space)
        let executable = macos.appendingPathComponent("launcher")
        let usesStub: Bool
        if let stub = stubExecutable() {
            try fm.copyItem(at: stub, to: executable)
            usesStub = true
        } else {
            try Data(fallbackScript(request).utf8).write(to: executable)
            usesStub = false
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var hasIcon = false
        if let image = iconImage(for: program, in: space, menuEntries: menuEntries) {
            hasIcon = writeICNS(image, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        let entry = (program.launchFile.pathExtension.lowercased() == "lnk")
            ? StartMenuHook.entry(forLink: program.launchFile, in: space, entries: menuEntries) : nil
        let plist = infoPlist(name: program.name, program: program, space: space, request: request,
                              automatic: automatic, hasIcon: hasIcon, usesStub: usesStub,
                              description: entry?.description)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        sign(staging, identifier: plist["CFBundleIdentifier"] as? String)
        if OnwinPaths.exists(app) { try fm.removeItem(at: app) }
        try fm.moveItem(at: staging, to: app)
        register(app)
        return app
    }

    /// Moves a launcher to the Trash (falls back to deleting it).
    public static func remove(_ launcher: LauncherInfo) throws {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: launcher.url, resultingItemURL: nil)
        } catch {
            try fm.removeItem(at: launcher.url)
        }
        unregister(launcher.url)
        removeFolderIfEmpty(launcher.url.deletingLastPathComponent())
    }

    /// Removes every launcher of a space (when the space is deleted).
    public static func removeAll(for spaceID: UUID, root: URL = defaultRoot) {
        for launcher in launchers(for: spaceID, root: root) { try? remove(launcher) }
    }

    // MARK: Automatic launchers

    public struct SyncResult: Sendable {
        public var created: [URL] = []
        public var removed: [URL] = []
        public var moved: [URL] = []
        public var errors: [String] = []
        public var changed: Bool { !created.isEmpty || !removed.isEmpty || !moved.isEmpty }
    }

    /// Keeps the space's launchers in line with its programs:
    /// - launchers sitting in a folder of an old space name are moved to the current one;
    /// - with `space.config.autoLaunchers`, every Start Menu / Desktop program gets a launcher
    ///   and automatic launchers whose shortcut disappeared (uninstalled) are removed.
    /// Launchers made by hand are never removed here.
    @discardableResult
    public static func sync(_ space: Space, programs: [SpaceProgram]? = nil, root: URL = defaultRoot) -> SyncResult {
        var result = SyncResult()
        let fm = FileManager.default
        let folder = directory(for: space, root: root)
        var existing = launchers(for: space.id, root: root)

        for (index, launcher) in existing.enumerated()
        where launcher.url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var target = folder.appendingPathComponent(launcher.url.lastPathComponent, isDirectory: true)
                if OnwinPaths.exists(target) {
                    target = uniqueApp(in: folder, base: launcher.url.deletingPathExtension().lastPathComponent)
                }
                let oldFolder = launcher.url.deletingLastPathComponent()
                try fm.moveItem(at: launcher.url, to: target)
                unregister(launcher.url)
                register(target)
                existing[index].url = target
                result.moved.append(target)
                removeFolderIfEmpty(oldFolder)
            } catch {
                result.errors.append("\(launcher.name): \(error.localizedDescription)")
            }
        }

        guard space.config.autoLaunchers else { return result }
        let list = programs ?? ProgramScanner.programs(in: space)
        let menuPrograms = list.filter {
            switch $0.source {
            case .startMenu, .desktop: return true
            case .pinned: return false
            }
        }
        let ids = Set(list.map(\.id))
        for launcher in existing where launcher.isAutomatic && !ids.contains(launcher.programID) {
            do {
                try remove(launcher)
                result.removed.append(launcher.url)
            } catch {
                result.errors.append("\(launcher.name): \(error.localizedDescription)")
            }
        }
        let have = Set(existing.map(\.programID))
        let entries = StartMenuHook.entries(in: space)
        for program in menuPrograms where !have.contains(program.id) {
            do {
                result.created.append(try create(for: program, in: space, root: root, automatic: true, menuEntries: entries))
            } catch {
                result.errors.append("\(program.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: Pieces

    /// The compiled stub: next to the running executable (Onwin.app/Contents/MacOS, the SwiftPM
    /// bin directory, the target of an onwinctl symlink) or `ONWIN_LAUNCHER_STUB`.
    public static func stubExecutable() -> URL? {
        var candidates: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["ONWIN_LAUNCHER_STUB"], !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: custom))
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(stubName))
            candidates.append(exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(stubName))
        }
        let arg0 = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        candidates.append(arg0.deletingLastPathComponent().appendingPathComponent(stubName))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) {
            candidates.append(app.appendingPathComponent("Contents/MacOS/\(stubName)"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where onwinctl is, recorded in the launcher for the stub's fallback.
    static func onwinctlPath() -> String? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("onwinctl"))
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("onwinctl"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    static func infoPlist(name: String, program: SpaceProgram, space: Space, request: LaunchRequest,
                          automatic: Bool, hasIcon: Bool, usesStub: Bool, description: String?) -> [String: Any] {
        var launcher: [String: Any] = [
            "Version": formatVersion,
            "Space": space.id.uuidString,
            "SpaceName": space.name,
            "Program": program.id,
            "File": program.launchFile.path,
            "URL": request.url.absoluteString,
            "Automatic": automatic,
            "Created": ISO8601DateFormatter().string(from: Date()),
        ]
        if let ctl = onwinctlPath() { launcher["Onwinctl"] = ctl }
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "ru",
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": bundleIdentifier(space: space.id, program: program.id),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleShortVersionString": OnwinVersion.string,
            "CFBundleVersion": "\(formatVersion)",
            "LSMinimumSystemVersion": "14.0",
            // The stub only hands the program over to onwin; the windows come from Wine.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "LSApplicationCategoryType": "public.app-category.games",
            "NSHumanReadableCopyright": String(localized: "Ярлык onwin: «\(name)» в пространстве «\(space.name)»", bundle: .onwinCore),
            infoKey: launcher,
        ]
        if hasIcon { plist["CFBundleIconFile"] = "AppIcon" }
        if let description, !description.isEmpty { plist["NSHumanReadableDescription"] = description }
        if !usesStub { launcher["Script"] = true; plist[infoKey] = launcher }
        return plist
    }

    /// `app.onwin.launcher.<space uuid>.<hash of program id>`: stable per program.
    static func bundleIdentifier(space: UUID, program: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a 64
        for byte in program.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "app.onwin.launcher.\(space.uuidString.lowercased()).p\(String(hash, radix: 16))"
    }

    /// Used when the stub binary is not available (e.g. a core built without it).
    static func fallbackScript(_ request: LaunchRequest) -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let url = quote(request.url.absoluteString)
        let ctl = onwinctlPath().map(quote) ?? "''"
        return """
        #!/bin/sh
        # onwin launcher (generated). Opens the program through onwin.app, or through onwinctl.
        URL=\(url)
        if /usr/bin/open -b \(appBundleIdentifier) "$URL" 2>/dev/null; then exit 0; fi
        for ctl in \(ctl) /usr/local/bin/onwinctl /opt/homebrew/bin/onwinctl "$HOME/.local/bin/onwinctl"; do
            [ -n "$ctl" ] && [ -x "$ctl" ] && exec "$ctl" open-url "$URL"
        done
        /usr/bin/osascript -e 'display alert "onwin не найден" message "Установите onwin, чтобы запускать этот ярлык."' >/dev/null 2>&1
        exit 1

        """
    }

    // MARK: Icon

    static func iconImage(for program: SpaceProgram, in space: Space,
                          menuEntries: [String: StartMenuHook.Entry]?) -> NSImage? {
        // 0. A Steam game: Steam's own art (AppIcons / SteamArt.swift) — its square shortcut icon, or the
        //    library cover when the exe only carries a small icon.
        if let image = steamLauncherImage(for: program, in: space) { return image }
        // 1. What winemenubuilder extracted for the shortcut (honours the .lnk's icon location).
        if program.launchFile.pathExtension.lowercased() == "lnk",
           let entry = StartMenuHook.entry(forLink: program.launchFile, in: space, entries: menuEntries),
           let name = entry.icon, let png = StartMenuHook.iconFile(named: name, in: space),
           let image = NSImage(contentsOf: png), image.isValid {
            return image
        }
        // 2. The icon resource of the target exe.
        if let exe = program.executable, let image = IconExtractor.icon(for: exe) { return image }
        return nil
    }

    /// Writes an .icns with ImageIO (16…1024 px); falls back to iconutil with an .iconset.
    @discardableResult
    static func writeICNS(_ image: NSImage, to url: URL) -> Bool {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let images = sizes.compactMap { render(image, pixels: $0) }
        guard images.count == sizes.count else { return false }
        // ICNS slots: 16, 32, 128, 256, 512 pt at 1x (72 dpi) and 2x (144 dpi); ImageIO picks the
        // slot from pixel size + DPI.
        let byPixels = Dictionary(uniqueKeysWithValues: zip(sizes, images))
        let slots: [(pixels: Int, dpi: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 72), ($0 * 2, 144)] }
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString,
                                                             slots.count, nil) {
            for slot in slots {
                guard let cg = byPixels[slot.pixels] else { continue }
                let properties = [kCGImagePropertyDPIWidth: slot.dpi, kCGImagePropertyDPIHeight: slot.dpi] as CFDictionary
                CGImageDestinationAddImage(destination, cg, properties)
            }
            if CGImageDestinationFinalize(destination), OnwinPaths.exists(url) { return true }
        }
        return writeICNSWithIconutil(images: byPixels, to: url)
    }

    private static func writeICNSWithIconutil(images: [Int: CGImage], to url: URL) -> Bool {
        let iconutil = URL(fileURLWithPath: "/usr/bin/iconutil")
        guard FileManager.default.isExecutableFile(atPath: iconutil.path) else { return false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("onwin-icon-\(UUID().uuidString)")
        let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            for base in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    guard let cg = images[base * scale] else { continue }
                    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                    let rep = NSBitmapImageRep(cgImage: cg)
                    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                    try png.write(to: iconset.appendingPathComponent(name))
                }
            }
        } catch {
            return false
        }
        let process = Process()
        process.executableURL = iconutil
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && OnwinPaths.exists(url)
    }

    /// Draws the Windows icon into a square canvas with the margin macOS icons have
    /// (the artwork takes ~80% of the canvas), keeping its aspect ratio.
    static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let side = CGFloat(pixels)
        let box = (side * 0.8).rounded()
        let source = image.size
        let scale = source.width > 0 && source.height > 0 ? min(box / source.width, box / source.height) : 1
        let drawn = NSSize(width: source.width * scale, height: source.height * scale)
        let rect = NSRect(x: ((side - drawn.width) / 2).rounded(), y: ((side - drawn.height) / 2).rounded(),
                          width: drawn.width, height: drawn.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        context.flushGraphics()
        return rep.cgImage
    }

    // MARK: Signing, LaunchServices, names

    /// Ad-hoc signature (`codesign` is part of macOS). Unsigned bundles still open, so failures are ignored.
    static func sign(_ app: URL, identifier: String?) {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else { return }
        let process = Process()
        process.executableURL = codesign
        var arguments = ["--force", "--sign", "-"]
        if let identifier { arguments += ["--identifier", identifier] }
        process.arguments = arguments + [app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        process.waitUntilExit()
    }

    /// Tells LaunchServices about the new bundle so it shows up in Launchpad / Spotlight right away.
    static func register(_ app: URL) {
        _ = LSRegisterURL(app as CFURL, true)
    }

    static func unregister(_ app: URL) {
        let lsregister = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        guard FileManager.default.isExecutableFile(atPath: lsregister.path) else { return }
        let process = Process()
        process.executableURL = lsregister
        process.arguments = ["-u", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func removeFolderIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
        if items.isEmpty { try? fm.removeItem(at: folder) }
    }

    static func uniqueApp(in folder: URL, base: String) -> URL {
        var n = 2
        var candidate = folder.appendingPathComponent("\(base) \(n).app", isDirectory: true)
        while OnwinPaths.exists(candidate) {
            n += 1
            candidate = folder.appendingPathComponent("\(base) \(n).app", isDirectory: true)
        }
        return candidate
    }

    /// A Finder-safe file name: no "/" or ":", no leading dot, at most 120 characters.
    static func fileSafe(_ name: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        var cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        return cleaned.isEmpty ? fallback : cleaned
    }
}
