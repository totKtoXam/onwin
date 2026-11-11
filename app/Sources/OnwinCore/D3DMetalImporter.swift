import Foundation

/// D3DMetal import from Apple's Game Porting Toolkit (GPTK).
///
/// Apple serves the GPTK only to signed-in Apple developer accounts (a free account is enough).
/// The app does everything itself (AppModel.fetchD3DMetal, D3DMetalInstallFlow.swift):
///   1. an already downloaded `Game_Porting_Toolkit_*.dmg` (~/Downloads or onwin's download cache)
///      or a mounted GPTK volume is used directly (`find`) — no sign-in at all;
///   2. otherwise the user signs in on Apple's own page inside onwin (WKWebView) and
///      `downloadAndImport(cookies:)` lists the downloads, picks the newest stable GPTK
///      (`AppleDeveloperDownloads`), downloads it resumably into the cache and imports it;
///   3. import (`importFound`): `hdiutil attach -nobrowse -readonly` the outer image, then the nested
///      `Evaluation environment for Windows games *.dmg`, `GraphicsSupport.importD3DMetal(from:)`,
///      detach what we mounted.
/// `run(options:)` is the CLI's variant: use what is on disk, optionally wait for a manual download.
public enum D3DMetalImporter {
    public struct Options: Sendable {
        /// Open Apple's download page in the browser while waiting (manual fallback; off by default).
        public var openBrowser = false
        /// Seconds to wait for the download.
        public var timeout: TimeInterval = 3600
        public var pollInterval: TimeInterval = 2
        /// ~/Downloads and onwin's own download cache (where the in-app download puts the image).
        public var downloadDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                                                 Downloader.downloadsDirectory]
        public var volumesDirectory = URL(fileURLWithPath: "/Volumes")
        public init() {}
    }

    public enum Found: Sendable, Equatable {
        /// A downloaded disk image (outer GPTK or the inner evaluation environment).
        case diskImage(URL)
        /// A volume that is already mounted (by the user); we do not detach it.
        case mountedVolume(URL)

        public var url: URL {
            switch self {
            case .diskImage(let u), .mountedVolume(let u): return u
            }
        }
    }

    static let imagePatterns = ["game_porting_toolkit*.dmg", "evaluation environment for windows games*.dmg"]
    static let volumePatterns = ["evaluation environment for windows games*", "game porting toolkit*"]

    /// Runs the whole guided flow. Returns where D3DMetal came from.
    @discardableResult
    public static func run(options: Options = Options(), progress: @escaping ProgressHandler) async throws -> Found {
        if let found = find(options: options) {
            progress(.status(String(localized: "Нашёл \(found.url.lastPathComponent) — импортирую", bundle: .onwinCore)))
            try await importFound(found, progress: progress)
            return found
        }
        if options.openBrowser {
            progress(.status(String(localized: "Открываю страницу загрузки Apple: войдите с Apple ID и скачайте Game Porting Toolkit (.dmg)", bundle: .onwinCore)))
            openInBrowser(Catalog.gameportingToolkitURL)
        } else {
            progress(.status(String(localized: "Жду Game_Porting_Toolkit_*.dmg в «Загрузках». Проще всего: onwin → Каталог → D3DMetal → «Установить D3DMetal».", bundle: .onwinCore)))
        }
        let deadline = Date().addingTimeInterval(options.timeout)
        var lastSizes: [URL: Int64] = [:]
        var lastNotice = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            if let found = find(options: options) {
                // A disk image must stop growing before we touch it.
                if case .diskImage(let url) = found {
                    let size = fileSize(url)
                    defer { lastSizes[url] = size }
                    guard size > 0, lastSizes[url] == size else {
                        progress(.status(String(localized: "Вижу \(url.lastPathComponent), жду окончания загрузки…", bundle: .onwinCore)))
                        try await Task.sleep(nanoseconds: UInt64(options.pollInterval * 1_000_000_000))
                        continue
                    }
                }
                progress(.status(String(localized: "Нашёл \(found.url.lastPathComponent)", bundle: .onwinCore)))
                try await importFound(found, progress: progress)
                return found
            }
            if Date().timeIntervalSince(lastNotice) > 30 {
                let left = Int(deadline.timeIntervalSinceNow / 60)
                progress(.status(String(localized: "Жду файл Game_Porting_Toolkit_*.dmg в «Загрузках» (ещё до \(max(left, 1)) мин)…", bundle: .onwinCore)))
                lastNotice = Date()
            }
            try await Task.sleep(nanoseconds: UInt64(options.pollInterval * 1_000_000_000))
        }
        throw OnwinError(String(localized: "Не дождался загрузки Game Porting Toolkit. Скачайте .dmg с developer.apple.com и запустите импорт ещё раз (или укажите том вручную: onwinctl d3dmetal-import <путь>).", bundle: .onwinCore))
    }

    /// The newest GPTK disk image in the download folders, or a mounted GPTK volume.
    public static func find(options: Options = Options()) -> Found? {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: options.volumesDirectory, includingPropertiesForKeys: nil) {
            for volume in entries where volumePatterns.contains(where: { Glob.matches($0, volume.lastPathComponent) }) {
                if GraphicsSupport.findItem(named: "D3DMetal.framework", under: volume, maxDepth: 6) != nil
                    || innerImage(in: volume) != nil {
                    return .mountedVolume(volume)
                }
            }
        }
        var images: [(URL, Date)] = []
        for dir in options.downloadDirectories {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for file in entries where imagePatterns.contains(where: { Glob.matches($0, file.lastPathComponent) }) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                images.append((file, date))
            }
        }
        return images.max { $0.1 < $1.1 }.map { .diskImage($0.0) }
    }

    /// Imports from a disk image or a volume (mounting and detaching what is needed).
    public static func importFound(_ found: Found, progress: @escaping ProgressHandler) async throws {
        var mounted: [URL] = []
        do {
            var root: URL
            switch found {
            case .mountedVolume(let volume):
                root = volume
            case .diskImage(let image):
                progress(.status(String(localized: "Подключаю \(image.lastPathComponent)…", bundle: .onwinCore)))
                root = try await attach(image)
                mounted.append(root)
            }
            if GraphicsSupport.findItem(named: "D3DMetal.framework", under: root, maxDepth: 6) == nil,
               let inner = innerImage(in: root) {
                progress(.status(String(localized: "Подключаю вложенный образ \(inner.lastPathComponent)…", bundle: .onwinCore)))
                root = try await attach(inner)
                mounted.append(root)
            }
            try Task.checkCancellation()
            progress(.status(String(localized: "Копирую D3DMetal из «\(root.lastPathComponent)»…", bundle: .onwinCore)))
            let source = root
            try await Task.detached { try GraphicsSupport.importD3DMetal(from: source) }.value
        } catch {
            for volume in mounted.reversed() { await detach(volume) }
            throw error
        }
        for volume in mounted.reversed() {
            progress(.status(String(localized: "Отключаю \(volume.lastPathComponent)…", bundle: .onwinCore)))
            await detach(volume)
        }
        guard GraphicsSupport.isD3DMetalInstalled else {
            throw OnwinError(String(localized: "Копирование закончилось, но D3DMetal не найден в \(OnwinPaths.d3dmetal.path)", bundle: .onwinCore))
        }
        progress(InstallProgress(message: String(localized: "D3DMetal импортирован в \(OnwinPaths.d3dmetal.path)", bundle: .onwinCore), fraction: 1))
    }

    /// "Evaluation environment for Windows games 3.0.dmg" inside the outer GPTK volume.
    static func innerImage(in volume: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let images = entries.filter { $0.pathExtension.lowercased() == "dmg" }
        return images.first { Glob.matches("evaluation environment for windows games*", $0.lastPathComponent) } ?? images.first
    }

    // MARK: hdiutil

    /// `hdiutil attach -nobrowse -readonly`, returns the mount point. Answers "Y" to a license prompt.
    public static func attach(_ image: URL) async throws -> URL {
        let r = try await hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", image.path], input: "Y\n")
        guard r.status == 0 else {
            throw OnwinError(String(localized: "hdiutil не смог подключить \(image.lastPathComponent) (код \(Int(r.status))): \(String(r.errors.suffix(400)))", bundle: .onwinCore))
        }
        guard let start = r.output.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(r.output[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            // Attached but no mount point reported: do not leave the image attached.
            if let start = r.output.range(of: "<?xml"),
               let plist = try? PropertyListSerialization.propertyList(from: Data(r.output[start.lowerBound...].utf8), format: nil) as? [String: Any],
               let entities = plist["system-entities"] as? [[String: Any]],
               let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) {
                await detach(URL(fileURLWithPath: device))
            }
            throw OnwinError(String(localized: "hdiutil подключил \(image.lastPathComponent), но не сообщил точку монтирования", bundle: .onwinCore))
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    public static func detach(_ volume: URL) async {
        if let r = try? await hdiutil(["detach", volume.path, "-quiet"], input: nil), r.status == 0 { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try? await hdiutil(["detach", volume.path, "-force", "-quiet"], input: nil)
    }

    static func hdiutil(_ arguments: [String], input: String?) async throws -> (status: Int32, output: String, errors: String) {
        try await Task.detached { try hdiutilSync(arguments, input: input) }.value
    }

    /// Blocking; called off the main actor only.
    private static func hdiutilSync(_ arguments: [String], input: String?) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = HostTools.hdiutil
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inp
        // If hdiutil exits before reading stdin, writing the answer must fail with EPIPE instead of
        // killing onwin with SIGPIPE.
        _ = fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        if let input {
            try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inp.fileHandleForWriting.close()
        }
        // hdiutil does not daemonize: both pipes reach EOF when it exits. Read stderr concurrently
        // so neither pipe can fill up and block it.
        let errCollector = OutputCollector()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errCollector.append(err.fileHandleForReading.readDataToEndOfFile())
            errDone.signal()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errDone.wait()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), errCollector.text)
    }

    // MARK: Helpers

    static func openInBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
