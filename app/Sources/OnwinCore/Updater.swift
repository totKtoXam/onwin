import CryptoKit
import Foundation

// Built-in updater: the same release format the website installer uses (site/install.sh,
// scripts/release.sh). Every app release `v<version>` carries onwin-release.json:
//
//     { "schema": 1, "version", "build", "minimumMacOS",
//       "app":        { url, sha256, size }   Onwin-<v>-app.zip, Onwin.app without the engine
//       "dmg":        { url, sha256, size }   Onwin-<v>.dmg, the same app (the engine comes at first launch);
//                                             not used here
//       "dmgOffline": { url, sha256, size }   Onwin-<v>-offline.dmg, the app with the full engine inside;
//                                             not used here
//       "engine":     { id, built, url, sha256, size }   tar.xz of the folder <id>/, without Wine Mono / Gecko
//                                             (EngineAddons.swift downloads them when a program needs them) }
// Readers ignore keys they do not know (JSONDecoder here, plutil -extract in install.sh): new keys are fine,
// changing or removing one needs `schema` + 1.
//
// Order of an update: download (into ~/Library/Caches/onwin/Updates), check SHA-256, install the engine
// into Engines/<id> (atomic swap, like install.sh; refused while Wine of that engine runs), then the app:
// unpack next to the installed Onwin.app and hand the swap to a small /bin/sh helper that waits for onwin
// to quit, swaps the bundle and starts it again. Files downloaded by onwin itself get no quarantine flag,
// so Gatekeeper does not stop the new (not notarized) build. Never uses sudo.
//
// Testing without GitHub and without touching the real install:
//   ONWIN_MANIFEST_URL=<url of an onwin-release.json>   (http only for localhost)
//   ONWIN_APP_DIR=<folder holding the Onwin.app to update>   ONWIN_HOME=<temporary onwin data folder>

extension OnwinLinks {
    /// All releases on GitHub.
    public static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// The page of release `v<version>` (what is new, the DMG).
    public static func releasePage(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// onwin-release.json of the latest release.
    public static var latestReleaseManifest: URL {
        URL(string: "https://github.com/\(repository)/releases/latest/download/onwin-release.json")!
    }

    /// onwin-release.json of release `v<version>` (downgrades, the site's releases page).
    public static func releaseManifest(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/onwin-release.json")!
    }
}

extension OnwinVersion {
    /// How a version is shown to people: every version below 1.0 is a beta, «0.1.1 (бета)».
    public static func display(_ version: String) -> String {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        return major < 1 ? String(localized: "\(version) (бета)", bundle: .onwinCore) : version
    }

    /// True for every version below 1.0 (beta test).
    public static var isBeta: Bool { (Int(string.split(separator: ".").first ?? "") ?? 0) < 1 }

    /// The running onwin, «0.1.0 (бета)».
    public static var displayString: String { display(string) }
}

/// onwin-release.json, schema 1.
public struct ReleaseManifest: Codable, Sendable, Equatable {
    public struct Asset: Codable, Sendable, Equatable {
        public var url: URL
        public var sha256: String
        public var size: Int64
    }

    public struct EngineAsset: Codable, Sendable, Equatable {
        public var id: String
        /// ISO 8601 time of the engine build (`built` of its onwin-engine.json).
        public var built: String
        public var url: URL
        public var sha256: String
        public var size: Int64

        public var builtDate: Date? { ISO8601DateFormatter().date(from: built) }
    }

    public var schema: Int
    public var version: String
    /// CFBundleVersion of the app in this release (yyyyMMddHHmm).
    public var build: String
    public var minimumMacOS: String?
    public var site: URL?
    public var app: Asset
    public var dmg: Asset?
    public var dmgOffline: Asset?
    public var engine: EngineAsset

    public static let supportedSchema = 1

    /// Release page on GitHub (what is new).
    public var releasePage: URL { OnwinLinks.releasePage(version: version) }

    /// The running macOS is new enough for this release.
    public var supportsThisMac: Bool {
        guard let minimum = minimumMacOS else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let wanted = OperatingSystemVersion(majorVersion: parts.first ?? 0,
                                            minorVersion: parts.count > 1 ? parts[1] : 0,
                                            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(wanted)
    }
}

/// An Onwin.app on disk.
public struct InstalledApp: Sendable {
    public var url: URL
    public var version: String?
    public var build: String?
    public var bundleIdentifier: String?

    public static let bundleIdentifier = "app.onwin.Onwin"

    public init?(url: URL) {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info) else { return nil }
        self.url = url
        version = plist["CFBundleShortVersionString"] as? String
        build = plist["CFBundleVersion"] as? String
        bundleIdentifier = plist["CFBundleIdentifier"] as? String
    }

    /// The engine inside the app (the DMG build): Contents/SharedSupport/Engine.
    public var bundledEngine: Engine? {
        try? Engine(root: url.appendingPathComponent("Contents/SharedSupport/Engine", isDirectory: true))
    }

    public var displayVersion: String { version.map(OnwinVersion.display) ?? "?" }
}

/// What an update would change.
public struct UpdatePlan: Sendable {
    public enum EngineAction: Sendable, Equatable {
        /// The installed engine is current.
        case none
        /// Download the engine of the release.
        case download
        /// The engine inside the running app is current, but the new app comes without one: copy it to
        /// Engines/<id> before the app is replaced (nothing to download).
        case copyFromApp(URL)
    }

    public var manifest: ReleaseManifest
    /// The app that would be replaced; nil when none is installed (onwinctl only).
    public var app: InstalledApp?
    public var appNeedsUpdate: Bool
    public var engine: EngineAction

    public var hasUpdate: Bool { appNeedsUpdate || engine != .none }
    public var appDownloadSize: Int64 { appNeedsUpdate ? manifest.app.size : 0 }
    public var engineDownloadSize: Int64 { engine == .download ? manifest.engine.size : 0 }
}

public enum UpdateError: LocalizedError, Sendable {
    /// The folder of Onwin.app cannot be written without administrator rights (or the app runs from a
    /// disk image / a translocated copy).
    case notWritable(URL)
    /// Wine programs of the engine that has to be replaced still run.
    case engineInUse(String)
    case unsupportedMac(String)
    case badRelease(String)

    public var errorDescription: String? {
        switch self {
        case .notWritable(let url):
            let folder = url.deletingLastPathComponent().path
            return String(localized: "onwin не может обновить себя сам: нет прав на запись в папку «\(folder)». Скачайте новую версию со страницы выпуска и перетащите её в «Программы».",
                          bundle: .onwinCore)
        case .engineInUse(let id):
            return String(localized: "Движок Wine (\(id)) нужно обновить, но в onwin работают Windows-программы. Закройте их и попробуйте ещё раз.",
                          bundle: .onwinCore)
        case .unsupportedMac(let minimum):
            return String(localized: "Новой версии onwin нужна macOS \(minimum) или новее.", bundle: .onwinCore)
        case .badRelease(let message):
            return message
        }
    }
}

public enum Updater {
    // MARK: Manifest

    /// onwin-release.json of the latest release (`ONWIN_MANIFEST_URL` overrides, for tests).
    public static func latestManifest() async throws -> ReleaseManifest {
        if let custom = ProcessInfo.processInfo.environment["ONWIN_MANIFEST_URL"], !custom.isEmpty,
           let url = URL(string: custom) {
            return try await fetchManifest(from: url)
        }
        do {
            return try await fetchManifest(from: OnwinLinks.latestReleaseManifest)
        } catch let error as HTTPStatusError where error.status == 404 {
            throw OnwinError(String(localized: "Выпусков onwin с обновлением из приложения пока нет.", bundle: .onwinCore))
        }
    }

    /// onwin-release.json of release `v<version>` — to go back to an older version or pick a specific one.
    public static func manifest(forVersion version: String) async throws -> ReleaseManifest {
        let clean = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw OnwinError(String(localized: "Неверный номер версии: \(version)", bundle: .onwinCore))
        }
        do {
            return try await fetchManifest(from: OnwinLinks.releaseManifest(version: clean))
        } catch let error as HTTPStatusError where error.status == 404 {
            throw OnwinError(String(localized: "Выпуска onwin \(clean) нет (или он вышел раньше, чем появились обновления из приложения).",
                                    bundle: .onwinCore))
        }
    }

    public static func fetchManifest(from url: URL) async throws -> ReleaseManifest {
        try checkAllowed(url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("onwin/\(OnwinVersion.string)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OnwinError(String(localized: "Не удалось проверить обновления — нет связи с GitHub. Проверьте подключение к интернету.",
                                    bundle: .onwinCore))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 { throw HTTPStatusError(status: 404) }
            throw OnwinError(String(localized: "Не удалось проверить обновления: сервер ответил \(http.statusCode).", bundle: .onwinCore))
        }
        if let final = response.url { try checkAllowed(final) }
        return try decodeManifest(data)
    }

    public static func decodeManifest(_ data: Data) throws -> ReleaseManifest {
        let manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch {
            throw UpdateError.badRelease(String(localized: "Описание выпуска onwin повреждено — попробуйте позже.", bundle: .onwinCore))
        }
        guard manifest.schema <= ReleaseManifest.supportedSchema else {
            throw UpdateError.badRelease(String(localized: "Новый выпуск onwin устроен иначе, чем умеет эта версия. Скачайте его со страницы выпуска: \(manifest.releasePage.absoluteString)",
                                                bundle: .onwinCore))
        }
        guard isSafeName(manifest.engine.id) else {
            throw UpdateError.badRelease(String(localized: "В описании выпуска неверное имя движка.", bundle: .onwinCore))
        }
        return manifest
    }

    struct HTTPStatusError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            String(localized: "Описание выпуска не найдено (сервер ответил \(status)).", bundle: .onwinCore)
        }
    }

    /// https everywhere; plain http only for a local test server.
    static func checkAllowed(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return }
        if scheme == "http", let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host) { return }
        throw OnwinError(String(localized: "Небезопасный адрес загрузки: \(url.absoluteString)", bundle: .onwinCore))
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/")
    }

    // MARK: Installed state

    /// The Onwin.app to update: `ONWIN_APP_DIR/Onwin.app` (tests), the running app, the app around
    /// onwinctl (Contents/MacOS/onwinctl, also through a symlink), then /Applications, ~/Applications.
    public static func installedApp() -> InstalledApp? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ONWIN_APP_DIR"], !dir.isEmpty {
            return InstalledApp(url: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("Onwin.app", isDirectory: true))
        }
        if Bundle.main.bundleURL.pathExtension == "app", let app = InstalledApp(url: Bundle.main.bundleURL) {
            return app
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        while dir.path != "/" && !dir.path.isEmpty {
            if dir.pathExtension == "app" { if let app = InstalledApp(url: dir) { return app }; break }
            dir.deleteLastPathComponent()
        }
        for candidate in defaultAppLocations {
            if let app = InstalledApp(url: candidate) { return app }
        }
        return nil
    }

    /// Where a fresh install goes (install.sh: /Applications when writable, otherwise ~/Applications).
    public static var defaultAppLocations: [URL] {
        if let dir = ProcessInfo.processInfo.environment["ONWIN_APP_DIR"], !dir.isEmpty {
            return [URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("Onwin.app")]
        }
        return [URL(fileURLWithPath: "/Applications/Onwin.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Onwin.app")]
    }

    /// The engine installed in Engines/<id> (not the one inside the app, not ONWIN_ENGINE).
    public static func installedEngine(id: String) -> Engine? {
        try? Engine(root: OnwinPaths.engines.appendingPathComponent(id, isDirectory: true))
    }

    /// Compares a release with what is installed.
    /// - Parameter exact: the user asked for this very version: anything different counts (downgrades too).
    ///   Otherwise only newer builds count.
    public static func plan(for manifest: ReleaseManifest, app: InstalledApp?, exact: Bool = false) -> UpdatePlan {
        let appNeedsUpdate: Bool
        if let build = app?.build {
            appNeedsUpdate = exact ? build != manifest.build : isNewer(manifest.build, than: build)
        } else {
            appNeedsUpdate = true
        }

        func isCurrent(_ engine: Engine?) -> Bool {
            guard let engine, engine.id == manifest.engine.id else { return false }
            guard let have = engine.info.built, let want = manifest.engine.builtDate else { return false }
            return exact ? abs(have.timeIntervalSince(want)) < 1 : have.timeIntervalSince(want) > -1
        }
        let engine: UpdatePlan.EngineAction
        if isCurrent(installedEngine(id: manifest.engine.id)) {
            engine = .none
        } else if let bundled = app?.bundledEngine, isCurrent(bundled) {
            // The new app.zip has no engine inside: keep the current one by copying it out first.
            engine = appNeedsUpdate ? .copyFromApp(bundled.root) : .none
        } else {
            engine = .download
        }
        return UpdatePlan(manifest: manifest, app: app, appNeedsUpdate: appNeedsUpdate, engine: engine)
    }

    /// Build numbers are yyyyMMddHHmm; compared as numbers when they are numbers.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        if let a = Int64(candidate), let b = Int64(installed) { return a > b }
        return candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    /// «~5 МБ», «~1,2 ГБ» (at least 1 MB; the unit and number format follow the interface language).
    public static func sizeText(_ bytes: Int64) -> String {
        "~" + max(bytes, 1_000_000).formatted(.byteCount(style: .file))
    }

    // MARK: Wine processes

    /// Paths of the wineserver processes started from onwin's engines (Engines/<id> or an engine inside
    /// an Onwin.app). wineserver lives as long as any Wine program of its space runs.
    public static func runningWineServers() async -> [String] {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                   arguments: ["-axww", "-o", "command="]) else { return [] }
        let engines = canonicalPath(OnwinPaths.engines) + "/"
        return r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { line in
            guard let range = line.range(of: "/bin/wineserver") else { return nil }
            let path = canonicalPath(URL(fileURLWithPath: String(line[..<range.upperBound])))
            guard path.hasPrefix(engines) || path.contains(".app/Contents/SharedSupport/Engine/")
                    || path.contains("/onwin/Engines/") else { return nil }
            return path
        }
    }

    /// One spelling per file: symlinks resolved, and /private/tmp, /private/var as /tmp, /var (Foundation
    /// drops /private only for paths that exist, ps always shows it).
    static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") {
            let rest = String(path.dropFirst("/private".count))
            if ["/tmp/", "/var/", "/etc/"].contains(where: { rest.hasPrefix($0) }) { path = rest }
        }
        return path
    }

    /// Wine programs of the engine at `root` run (its wineserver is up).
    public static func isEngineInUse(_ root: URL, servers: [String]? = nil) async -> Bool {
        let list: [String]
        if let servers { list = servers } else { list = await runningWineServers() }
        let wanted = canonicalPath(root.appendingPathComponent("bin/wineserver"))
        return list.contains { canonicalPath(URL(fileURLWithPath: $0)) == wanted }
    }

    /// An onwin process runs from the app at `url` (its Contents/MacOS/Onwin).
    public static func isAppRunning(at url: URL) async -> Bool {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                   arguments: ["-axww", "-o", "command="]) else { return false }
        let executable = url.standardizedFileURL.path + "/Contents/MacOS/Onwin"
        return r.output.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text == executable || text.hasPrefix(executable + " ")
        }
    }

    // MARK: Download

    /// ~/Library/Caches/onwin/Updates/<version>-<build>
    public static func workDirectory(for manifest: ReleaseManifest) -> URL {
        OnwinPaths.cache.appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("\(manifest.version)-\(manifest.build)", isDirectory: true)
    }

    /// Downloads `asset` into `directory/name` and checks its SHA-256. A complete earlier download with the
    /// right checksum is reused (an update cancelled after the download starts again quickly).
    public static func download(_ url: URL, sha256 expected: String, title: String, name: String,
                                into directory: URL, progress: @escaping ProgressHandler) async throws -> URL {
        try checkAllowed(url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? await sha256(of: destination)) == expected.lowercased() {
                progress(InstallProgress(message: String(localized: "\(title) уже скачан", bundle: .onwinCore), fraction: 1))
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }
        progress(InstallProgress(message: String(localized: "Скачиваю \(title)…", bundle: .onwinCore), fraction: 0))
        // A download broken off by the network continues where it stopped (slow connections: the engine
        // takes many minutes). URLSession hands out "resume data" with the error; it is kept next to the file.
        let resumeFile = directory.appendingPathComponent(name + ".resume")
        let resumeData = try? Data(contentsOf: resumeFile)
        try? FileManager.default.removeItem(at: resumeFile)
        let delegate = Downloader.DownloadDelegate(name: title, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("onwin/\(OnwinVersion.string)", forHTTPHeaderField: "User-Agent")
        let temp: URL
        let response: URLResponse
        do {
            if let resumeData {
                do {
                    (temp, response) = try await session.download(resumeFrom: resumeData)
                } catch let error as URLError where error.code != .cancelled && error.downloadTaskResumeData == nil {
                    (temp, response) = try await session.download(for: request)   // stale resume data: start over
                }
            } else {
                (temp, response) = try await session.download(for: request)
            }
        } catch let error as URLError where error.code == .cancelled {
            if let data = error.downloadTaskResumeData { try? data.write(to: resumeFile) }
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let data = (error as? URLError)?.downloadTaskResumeData { try? data.write(to: resumeFile) }
            if Task.isCancelled { throw CancellationError() }
            throw OnwinError(String(localized: "Не удалось скачать \(title): \(error.localizedDescription)", bundle: .onwinCore))
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OnwinError(String(localized: "Не удалось скачать \(title): сервер ответил \(http.statusCode).", bundle: .onwinCore))
        }
        if let final = response.url { try checkAllowed(final) }
        try Task.checkCancellation()
        progress(InstallProgress(message: String(localized: "Проверяю \(title)…", bundle: .onwinCore), fraction: nil))
        let actual = try await sha256(of: temp)
        guard actual == expected.lowercased() else {
            throw OnwinError(String(localized: "Загрузка «\(title)» повреждена (не совпала контрольная сумма). Попробуйте ещё раз.",
                                    bundle: .onwinCore))
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// SHA-256 of a file, read in 4 MB pieces (the engine is ~200 MB).
    public static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: First launch

    /// onwin-release.json whose engine the app installs when it has none (the light DMG / app.zip come
    /// without one): the release of this very version, so the engine matches the app; the latest release
    /// for a build that was never published (development). `ONWIN_MANIFEST_URL` overrides, for tests.
    public static func manifestForEngineSetup() async throws -> ReleaseManifest {
        if let custom = ProcessInfo.processInfo.environment["ONWIN_MANIFEST_URL"], !custom.isEmpty {
            return try await latestManifest()
        }
        do {
            return try await fetchManifest(from: OnwinLinks.releaseManifest(version: OnwinVersion.string))
        } catch let error as HTTPStatusError where error.status == 404 {
            return try await latestManifest()
        }
    }

    /// What the first launch would download: the release, and the engine already installed if it is current.
    public static func engineSetupPlan() async throws -> UpdatePlan {
        let manifest: ReleaseManifest
        do {
            manifest = try await manifestForEngineSetup()
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OnwinError(String(localized: "Нет связи с GitHub: не удалось узнать, какой движок Wine скачать. Проверьте подключение к интернету.", bundle: .onwinCore))
        }
        return plan(for: manifest, app: nil)
    }

    /// Downloads and installs the engine of `plan` into Engines/<id> (the same path as an update:
    /// SHA-256 check, /usr/bin/tar, atomic swap). Returns the installed engine.
    public static func installEngineForSetup(_ plan: UpdatePlan, progress: @escaping ProgressHandler) async throws -> Engine {
        if plan.engine == .none, let engine = installedEngine(id: plan.manifest.engine.id) { return engine }
        var download = plan
        download.engine = .download
        guard let engine = try await installEngine(download, progress: progress) else {
            throw OnwinError(String(localized: "Движок Wine не установился.", bundle: .onwinCore))
        }
        cleanUpDownloads()
        return engine
    }

    // MARK: Engine

    /// Downloads (or copies out of the running app) and installs the engine of the release.
    @discardableResult
    public static func installEngine(_ plan: UpdatePlan, progress: @escaping ProgressHandler) async throws -> Engine? {
        let asset = plan.manifest.engine
        switch plan.engine {
        case .none:
            return nil
        case .download:
            if await isEngineInUse(OnwinPaths.engines.appendingPathComponent(asset.id)) {
                throw UpdateError.engineInUse(asset.id)
            }
            let title = String(localized: "движок Wine", bundle: .onwinCore,
                               comment: "Download title inside sentences like “Downloading %@…”, “%@ is already downloaded”")
            let archive = try await download(asset.url, sha256: asset.sha256, title: title,
                                             name: "onwin-engine-\(asset.id).tar.xz",
                                             into: workDirectory(for: plan.manifest), progress: progress)
            return try await installEngine(archive: archive, id: asset.id, built: asset.builtDate, progress: progress)
        case .copyFromApp(let source):
            progress(InstallProgress(message: String(localized: "Переношу движок Wine из приложения…", bundle: .onwinCore),
                                     fraction: nil))
            let staging = try makeEngineStaging(id: asset.id)
            let copy = staging.appendingPathComponent(asset.id, isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                // APFS clones the files: fast and takes no extra space until one of them changes.
                try FileManager.default.copyItem(at: source, to: copy)
            }.value
            return try await finishEngineInstall(staged: copy, staging: staging, id: asset.id, built: nil)
        }
    }

    /// Unpacks an engine archive (the folder <id>/) and swaps it into Engines/<id>.
    @discardableResult
    /// - Parameter built: expected `built` of the engine (from the release); nil = any.
    public static func installEngine(archive: URL, id: String, built: Date? = nil,
                                     progress: @escaping ProgressHandler) async throws -> Engine {
        guard isSafeName(id) else { throw UpdateError.badRelease(String(localized: "Неверное имя движка: \(id)", bundle: .onwinCore)) }
        progress(InstallProgress(message: String(localized: "Распаковываю движок Wine (это займёт минуту)…", bundle: .onwinCore),
                                 fraction: nil))
        let staging = try makeEngineStaging(id: id)
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                            arguments: ["-xf", archive.path, "-C", staging.path])
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: staging)
            let output = String(r.output.suffix(500))
            throw OnwinError(String(localized: "Не удалось распаковать движок Wine: \(output)", bundle: .onwinCore))
        }
        return try await finishEngineInstall(staged: staging.appendingPathComponent(id, isDirectory: true),
                                             staging: staging, id: id, built: built)
    }

    /// Engines/.install-<id> (hidden: EngineManager skips it), empty.
    static func makeEngineStaging(id: String) throws -> URL {
        try OnwinPaths.ensureLayout()
        let staging = OnwinPaths.engines.appendingPathComponent(".install-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    static func finishEngineInstall(staged: URL, staging: URL, id: String, built: Date?) async throws -> Engine {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        guard let engine = try? Engine(root: staged), engine.id == id else {
            throw UpdateError.badRelease(String(localized: "В архиве нет движка Wine \(id) (bin/wine).", bundle: .onwinCore))
        }
        if let built, abs((engine.info.built ?? .distantPast).timeIntervalSince(built)) >= 1 {
            throw UpdateError.badRelease(String(localized: "Скачанный движок Wine не совпадает с описанием выпуска — обновление отменено.",
                                                bundle: .onwinCore))
        }
        let destination = OnwinPaths.engines.appendingPathComponent(id, isDirectory: true)
        // Checked again right before the swap: a program could have been started during the download.
        if await isEngineInUse(destination) { throw UpdateError.engineInUse(id) }
        let old = OnwinPaths.engines.appendingPathComponent(".old-\(id)", isDirectory: true)
        try? fm.removeItem(at: old)
        // Wine Mono / Gecko downloaded on demand into the old engine stay (when Wine wants the same versions).
        EngineAddons.carryOver(from: destination, to: staged)
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: old) }
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            if fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: destination)
                EngineAddons.carryOver(from: staged, to: destination)
            }
            throw error
        }
        try? fm.removeItem(at: old)
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                         arguments: ["-dr", "com.apple.quarantine", destination.path])
        return try Engine(root: destination)
    }

    // MARK: App

    /// The new app unpacked next to the one it replaces, ready for `replaceApp`.
    public struct PreparedApp: Sendable {
        /// <folder of the app>/.onwin-update-<build>/Onwin.app
        public var staged: URL
        /// The Onwin.app to replace (or to create).
        public var target: URL
    }

    /// Onwin.app at `target` can be replaced without administrator rights.
    public static func canReplaceApp(at target: URL) -> Bool {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent().path
        if target.path.contains("/AppTranslocation/") { return false }
        if fm.fileExists(atPath: target.path) {
            return fm.isWritableFile(atPath: parent) && fm.isWritableFile(atPath: target.path)
                && fm.isWritableFile(atPath: target.appendingPathComponent("Contents").path)
        }
        var dir = target.deletingLastPathComponent()
        while !fm.fileExists(atPath: dir.path) && dir.path != "/" { dir.deleteLastPathComponent() }
        return fm.isWritableFile(atPath: dir.path)
    }

    /// Downloads the app of the release, checks it and unpacks it next to `target`.
    public static func prepareApp(_ plan: UpdatePlan, target: URL, progress: @escaping ProgressHandler) async throws -> PreparedApp {
        let manifest = plan.manifest
        guard manifest.supportsThisMac else { throw UpdateError.unsupportedMac(manifest.minimumMacOS ?? "?") }
        guard canReplaceApp(at: target) else { throw UpdateError.notWritable(target) }
        let work = workDirectory(for: manifest)
        let zip = try await download(manifest.app.url, sha256: manifest.app.sha256, title: "onwin \(manifest.version)",
                                     name: "Onwin-\(manifest.version)-app.zip", into: work, progress: progress)
        progress(InstallProgress(message: String(localized: "Распаковываю onwin \(manifest.version)…", bundle: .onwinCore), fraction: nil))
        let unpacked = work.appendingPathComponent("app", isDirectory: true)
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, unpacked.path])
        guard r.status == 0 else {
            let output = String(r.output.suffix(500))
            throw OnwinError(String(localized: "Не удалось распаковать onwin \(manifest.version): \(output)", bundle: .onwinCore))
        }
        let app = unpacked.appendingPathComponent("Onwin.app", isDirectory: true)
        guard let info = InstalledApp(url: app) else {
            throw UpdateError.badRelease(String(localized: "В архиве нет Onwin.app.", bundle: .onwinCore))
        }
        guard info.bundleIdentifier == InstalledApp.bundleIdentifier, info.build == manifest.build else {
            throw UpdateError.badRelease(String(localized: "Скачанный onwin не совпадает с описанием выпуска.", bundle: .onwinCore))
        }
        try await verifySignature(of: app, against: plan.app?.url)
        try Task.checkCancellation()

        // Staged in the same folder as the target, so the final swap is a rename on one disk.
        let stage = target.deletingLastPathComponent().appendingPathComponent(".onwin-update-\(manifest.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let staged = stage.appendingPathComponent("Onwin.app", isDirectory: true)
        let copy = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [app.path, staged.path])
        try? FileManager.default.removeItem(at: unpacked)
        guard copy.status == 0 else {
            try? FileManager.default.removeItem(at: stage)
            let output = String(copy.output.suffix(500))
            throw OnwinError(String(localized: "Не удалось подготовить новую версию: \(output)", bundle: .onwinCore))
        }
        return PreparedApp(staged: staged, target: target)
    }

    /// The new app must have an intact signature, and when the installed app is signed with a certificate
    /// (onwin Code Signing, releases), the new one must be signed with the same one: then macOS keeps the
    /// permissions given to onwin, and a tampered download is refused. Ad-hoc development builds skip the
    /// second check (their designated requirement is a hash of that very build).
    static func verifySignature(of app: URL, against current: URL?) async throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let verify = try await ProcessRunner.run(codesign, arguments: ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw UpdateError.badRelease(String(localized: "У скачанного onwin повреждена подпись — обновление отменено.",
                                                bundle: .onwinCore))
        }
        guard let current else { return }
        let info = try await ProcessRunner.run(codesign, arguments: ["-d", "-r-", current.path])
        guard let line = info.output.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") }),
              line.contains("certificate") else { return }
        let requirement = String(line.dropFirst("designated => ".count))
        let check = try await ProcessRunner.run(codesign, arguments: ["--verify", "-R=" + requirement, app.path])
        guard check.status == 0 else {
            throw UpdateError.badRelease(String(localized: "Скачанный onwin подписан не тем сертификатом, что установленный — обновление отменено.",
                                                bundle: .onwinCore))
        }
    }

    /// Swaps the prepared app in: right away when `waitingFor` is nil (onwinctl, onwin not running), or
    /// after process `waitingFor` (the running onwin) has quit — then the helper runs detached and this
    /// returns at once; quit onwin next. `relaunch` opens the new app afterwards.
    /// Returns the helper's log file.
    @discardableResult
    public static func replaceApp(_ prepared: PreparedApp, waitingFor pid: Int32?, relaunch: Bool) async throws -> URL {
        try FileManager.default.createDirectory(at: OnwinPaths.logs, withIntermediateDirectories: true)
        let log = OnwinPaths.logs.appendingPathComponent("update.log")
        let dir = OnwinPaths.cache.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("replace-app.sh")
        try replaceScript.write(to: script, atomically: true, encoding: .utf8)
        // onwin's own overrides (a test copy with ONWIN_HOME…) survive the restart; `-n`: a second copy of onwin
        // may be open from another folder, and `open` alone would just bring that one forward.
        let env = ProcessInfo.processInfo.environment
        let kept = ["ONWIN_HOME", "ONWIN_APP_DIR", "ONWIN_MANIFEST_URL", "ONWIN_ENGINE"].compactMap { key in
            env[key].flatMap { $0.isEmpty ? nil : "\(key)=\($0)" }
        }
        let openOptions = kept.isEmpty ? [] : ["-n"] + kept.flatMap { ["--env", $0] }
        let args = [script.path, String(pid ?? 0), prepared.target.path, prepared.staged.path, relaunch ? "1" : "0"] + openOptions
        if pid == nil {
            let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: args,
                                                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            try? (r.output).appendLine(to: log)
            guard r.status == 0, InstalledApp(url: prepared.target)?.build != nil else {
                let output = String(r.output.suffix(500))
                throw OnwinError(String(localized: "Не удалось заменить приложение: \(output)", bundle: .onwinCore))
            }
            return log
        }
        // nohup + '&': the helper outlives onwin (it is re-parented to launchd when onwin quits).
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "/usr/bin/nohup /bin/sh \"$@\" >> \"$ONWIN_UPDATE_LOG\" 2>&1 < /dev/null &", "sh"] + args
        launcher.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ONWIN_UPDATE_LOG": log.path]
        try launcher.run()
        launcher.waitUntilExit()
        guard launcher.terminationStatus == 0 else {
            throw OnwinError(String(localized: "Не удалось запустить установку новой версии.", bundle: .onwinCore))
        }

        return log
    }

    /// Removes downloads of earlier updates (keeps the current one's folder).
    public static func cleanUpDownloads(keeping manifest: ReleaseManifest? = nil) {
        let dir = OnwinPaths.cache.appendingPathComponent("Updates", isDirectory: true)
        let keep = manifest.map { workDirectory(for: $0).lastPathComponent }
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where entry != keep {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry).path, isDirectory: &isDir), isDir.boolValue {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry))
            }
        }
    }

    /// Helper for the final swap:
    /// replace-app.sh <pid|0> <target Onwin.app> <staged Onwin.app> <relaunch 1|0> [options for open...].
    static let replaceScript = #"""
    #!/bin/sh
    # onwin updater: waits for onwin to quit, puts the new Onwin.app in place of the old one, opens it.
    pid="$1"; target="$2"; staged="$3"; relaunch="$4"
    shift 4
    stage_dir="$(dirname "$staged")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') обновление: $target"
    if [ "$pid" != 0 ]; then
        n=0
        while kill -0 "$pid" 2>/dev/null; do
            n=$((n + 1))
            if [ "$n" -gt 1200 ]; then
                echo "onwin не закрылся за 2 минуты — обновление отменено"
                rm -rf "$stage_dir"
                exit 1
            fi
            sleep 0.1
        done
    fi
    if [ ! -d "$staged" ]; then echo "нет новой версии: $staged"; exit 1; fi
    old="$(dirname "$target")/.Onwin.app.old-$$"
    if [ -e "$target" ]; then
        if ! mv "$target" "$old"; then
            echo "не удалось убрать старую версию"
            rm -rf "$stage_dir"
            [ "$relaunch" = 1 ] && /usr/bin/open "$@" "$target"
            exit 1
        fi
    fi
    if mv "$staged" "$target"; then
        rm -rf "$old"
        status=0
    else
        echo "не удалось поставить новую версию — возвращаю старую"
        [ -e "$old" ] && mv "$old" "$target"
        status=1
    fi
    rm -rf "$stage_dir"
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1
    [ "$status" = 0 ] && echo "готово"
    [ "$relaunch" = 1 ] && /usr/bin/open "$@" "$target"
    exit "$status"
    """#
}

private extension String {
    func appendLine(to file: URL) throws {
        let data = Data((hasSuffix("\n") ? self : self + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: file)
        }
    }
}
