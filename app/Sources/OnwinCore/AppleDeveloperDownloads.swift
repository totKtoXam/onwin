import Foundation

/// Downloads from Apple's developer download area (download.developer.apple.com) with the cookies
/// of a developer.apple.com web session — the same protocol the open-source `xcodes` tool uses
/// (XcodesKit `XcodeListService`, XcodesLoginKit `DeveloperPortalSessionService`):
///
///   1. `POST https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action`
///      → JSON `{resultCode, resultString, downloads: [{name, dateModified "MM/dd/yy HH:mm",
///      files: [{remotePath, fileSize}]}]}`; resultCode ≠ 0 is an error (1100 = not signed in).
///      xcodes also calls it right before downloading "because the cookies from its response are needed".
///   2. `GET https://developerservices2.apple.com/services/download?path=<remotePath>` — sets the
///      `ADCDownloadAuth` cookie; only HTTP 401 means "not authorized" (xcodes `validateADCSession`).
///   3. `GET https://download.developer.apple.com<remotePath>` with the cookies (redirects followed);
///      a redirect to `…/unauthorized` (xcodes `validateDeveloperDownloadResponse`) or an HTML page
///      means the session is not good enough.
///
/// The cookies come from the app's WKWebsiteDataStore (the user signs in on Apple's own page inside
/// onwin); here they only live in an ephemeral, in-memory URLSession. Nothing is written to disk
/// and cookie values are never logged.
public enum AppleDeveloperDownloads {
    /// Where the in-app sign-in starts: Apple's account page (redirects to the Apple ID sign-in).
    public static let signInURL = URL(string: "https://developer.apple.com/account")!
    /// The downloads page filtered to the Game Porting Toolkit (browser fallback).
    public static var gptkPageURL: URL { Catalog.gameportingToolkitURL }

    static let listDownloadsURL = URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!
    static let downloadAuthURL = URL(string: "https://developerservices2.apple.com/services/download")!
    static let fileHost = "https://download.developer.apple.com"

    // MARK: Errors

    public enum Failure: Error, LocalizedError, Equatable {
        /// No (or an expired) developer.apple.com session.
        case notSignedIn
        /// Signed in, but Apple wants the developer agreement accepted first (message from Apple).
        case agreementRequired(String)
        /// Any other answer of Apple's service.
        case service(String)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return String(localized: "Вход в Apple ID не выполнен или устарел. Войдите ещё раз в окне onwin.", bundle: .onwinCore)
            case .agreementRequired(let text):
                return String(localized: "Apple просит принять соглашение Apple Developer: откройте developer.apple.com/account и примите его. (\(text))", bundle: .onwinCore)
            case .service(let text):
                return String(localized: "Сервис загрузок Apple ответил ошибкой: \(text)", bundle: .onwinCore)
            }
        }
    }

    // MARK: Model (listDownloads.action)

    public struct File: Decodable, Sendable, Equatable {
        public var remotePath: String
        public var fileSize: Int64?
        public var filename: String?

        public init(remotePath: String, fileSize: Int64? = nil, filename: String? = nil) {
            self.remotePath = remotePath
            self.fileSize = fileSize
            self.filename = filename
        }
    }

    public struct Download: Decodable, Sendable, Equatable {
        public var name: String
        public var files: [File]
        public var dateModified: Date?
        /// Apple's flag, informational only: like xcodes, stable vs beta is decided by the name.
        public var isReleased: Int?

        public init(name: String, files: [File], dateModified: Date? = nil, isReleased: Int? = nil) {
            self.name = name
            self.files = files
            self.dateModified = dateModified
            self.isReleased = isReleased
        }

        enum CodingKeys: String, CodingKey { case name, files, dateModified, isReleased }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            files = (try? c.decode([File].self, forKey: .files)) ?? []
            dateModified = (try? c.decode(String.self, forKey: .dateModified)).flatMap(AppleDeveloperDownloads.parseDate)
            if let i = try? c.decode(Int.self, forKey: .isReleased) {
                isReleased = i
            } else if let b = try? c.decode(Bool.self, forKey: .isReleased) {
                isReleased = b ? 1 : 0
            } else {
                isReleased = nil
            }
        }
    }

    struct ListResponse: Decodable {
        var resultCode: Int?
        var resultString: String?
        var userString: String?
        var downloads: [Download]?
    }

    /// "MM/dd/yy HH:mm" (what xcodes decodes), with a four-digit-year variant for safety.
    static func parseDate(_ text: String) -> Date? {
        for format in ["MM/dd/yy HH:mm", "MM/dd/yyyy HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "America/Los_Angeles")
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// Parses a listDownloads.action response (throws `Failure` for Apple's error answers).
    public static func parseDownloadList(_ data: Data) throws -> [Download] {
        let head = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<") { throw Failure.notSignedIn }   // an HTML sign-in page instead of JSON
        let response: ListResponse
        do {
            response = try JSONDecoder().decode(ListResponse.self, from: data)
        } catch {
            throw Failure.service(String(localized: "непонятный ответ (\(data.count) байт)", bundle: .onwinCore))
        }
        let code = response.resultCode ?? 0
        if code != 0 {
            let text = response.userString ?? response.resultString ?? String(localized: "код \(code)", bundle: .onwinCore)
            let lower = text.lowercased()
            if code == 1100 || lower.contains("log in") || lower.contains("sign in") || lower.contains("session has expired") {
                throw Failure.notSignedIn
            }
            if lower.contains("agree") || lower.contains("agreement") || lower.contains("terms") {
                throw Failure.agreementRequired(text)
            }
            throw Failure.service(String(localized: "\(text) (код \(code))", bundle: .onwinCore))
        }
        guard let downloads = response.downloads else { throw Failure.service(String(localized: "в ответе нет списка загрузок", bundle: .onwinCore)) }
        return downloads
    }

    // MARK: Picking the Game Porting Toolkit

    public struct Release: Sendable, Equatable {
        public var name: String
        /// Numeric version components ("3.0" → [3, 0]).
        public var version: [Int]
        public var isPrerelease: Bool
        public var remotePath: String
        public var fileSize: Int64?
        public var dateModified: Date?

        public var fileName: String { (remotePath as NSString).lastPathComponent }
        public var url: URL { URL(string: AppleDeveloperDownloads.fileHost + remotePath)! }
        public var versionString: String { version.map(String.init).joined(separator: ".") }
    }

    static let prereleaseMarkers = ["beta", "seed", "release candidate", "rc", "preview", "developer preview"]

    /// "Game Porting Toolkit 3.0" → ([3, 0], stable); "Game Porting Toolkit 3.0 beta 2" → prerelease.
    static func parseGPTKName(_ name: String) -> (version: [Int], prerelease: Bool)? {
        let pattern = #"^\s*game\s+porting\s+toolkit\s+v?(\d+(?:\.\d+)*)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let vr = Range(m.range(at: 1), in: name) else { return nil }
        let version = name[vr].split(separator: ".").compactMap { Int($0) }
        let rest = Range(m.range(at: 2), in: name).map { String(name[$0]).lowercased() } ?? ""
        let words = rest.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let prerelease = prereleaseMarkers.contains { marker in
            marker.contains(" ") ? rest.contains(marker) : words.contains(marker)
        }
        return (version, prerelease)
    }

    /// The newest stable Game Porting Toolkit (a beta only when there is no stable one).
    public static func latestGamePortingToolkit(in downloads: [Download]) -> Release? {
        var releases: [Release] = []
        for d in downloads {
            guard let parsed = parseGPTKName(d.name) else { continue }
            let dmgs = d.files.filter { ($0.remotePath as NSString).pathExtension.lowercased() == "dmg" }
            guard let file = dmgs.first(where: { $0.remotePath.lowercased().contains("game_porting_toolkit") }) ?? dmgs.first
            else { continue }
            releases.append(Release(name: d.name, version: parsed.version,
                                    isPrerelease: parsed.prerelease,
                                    remotePath: file.remotePath, fileSize: file.fileSize, dateModified: d.dateModified))
        }
        func newer(_ a: Release, _ b: Release) -> Bool {   // a < b
            if a.version != b.version { return a.version.lexicographicallyPrecedes(b.version) }
            return (a.dateModified ?? .distantPast) < (b.dateModified ?? .distantPast)
        }
        let stable = releases.filter { !$0.isPrerelease }
        return (stable.isEmpty ? releases : stable).max(by: newer)
    }

    // MARK: Network

    /// An ephemeral (in-memory) session carrying the given Apple cookies.
    public static func makeSession(cookies: [HTTPCookie]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        let storage = config.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies where isAppleCookie(cookie) { storage.setCookie(cookie) }
        config.httpCookieStorage = storage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }

    /// Redirects are followed only to https URLs (the session carries Apple ID cookies).
    static func isAllowedRedirect(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }

    public static func isAppleCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "apple.com" || domain.hasSuffix(".apple.com")
    }

    /// True when the cookies contain an unexpired Apple ID web session (`myacinfo`, set by
    /// idmsa.apple.com for .apple.com after sign-in, plus the developer site's DSESSIONID if present).
    public static func hasSessionCookie(_ cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        cookies.contains { c in
            isAppleCookie(c) && c.name == "myacinfo" && !c.value.isEmpty && (c.expiresDate.map { $0 > now } ?? true)
        }
    }

    /// Fetches and parses the developer download list.
    public static func listDownloads(session: URLSession) async throws -> [Download] {
        var request = URLRequest(url: listDownloadsURL)
        request.httpMethod = "POST"
        request.setValue("application/json, text/javascript, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw Failure.notSignedIn
        }
        return try parseDownloadList(data)
    }

    /// The ADCDownloadAuth step (xcodes `validateADCSession`): only 401 is fatal.
    public static func authorizeDownload(path: String, session: URLSession) async throws {
        var components = URLComponents(url: downloadAuthURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await session.data(for: request) else { return }
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw Failure.notSignedIn }
    }

    /// Downloads `release` into `directory` (resumable: a `<file>.part` is continued with a Range
    /// request). Verifies the size against Apple's listing / the server. Returns the finished file.
    public static func download(_ release: Release, session: URLSession, into directory: URL,
                                progress: @escaping ProgressHandler) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(release.fileName)
        let part = directory.appendingPathComponent(release.fileName + ".part")
        if let expected = release.fileSize, fileSize(destination) == expected {
            progress(.status(String(localized: "\(release.fileName) уже скачан", bundle: .onwinCore), fraction: 1))
            return destination
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        var offset = fileSize(part)
        if let expected = release.fileSize, offset > expected { try Data().write(to: part); offset = 0 }

        var request = URLRequest(url: release.url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            progress(.status(String(localized: "Продолжаю загрузку \(release.fileName) с \(megabytes(offset))…", bundle: .onwinCore)))
        } else {
            progress(.status(String(localized: "Скачиваю \(release.fileName)…", bundle: .onwinCore), fraction: 0))
        }
        let receiver = try PartFileReceiver(part: part, offset: offset, expected: release.fileSize,
                                            name: release.fileName, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    receiver.start(task, continuation: continuation)
                }
            } onCancel: {
                task.cancel()
            }
        } catch let error as URLError {
            let downloaded = megabytes(fileSize(part))
            throw OnwinError(String(localized: "Загрузка \(release.fileName) прервалась (\(downloaded) скачано): \(error.localizedDescription) Запустите установку ещё раз — загрузка продолжится с этого места.", bundle: .onwinCore))
        }

        let size = fileSize(part)
        let expected = release.fileSize ?? receiver.totalSize
        if let expected, size != expected {
            throw OnwinError(String(localized: "Загрузка \(release.fileName) оборвалась: \(megabytes(size)) из \(megabytes(expected)). Запустите установку ещё раз — загрузка продолжится с этого места.", bundle: .onwinCore))
        }
        if looksLikeHTML(part) {
            try? fm.removeItem(at: part)
            throw Failure.notSignedIn
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
        progress(.status(String(localized: "\(release.fileName) скачан (\(megabytes(size)))", bundle: .onwinCore), fraction: 1))
        return destination
    }

    // MARK: Helpers

    public static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func looksLikeHTML(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 64)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html")
    }

    /// "bytes 100-999/1000" → 1000.
    static func totalFromContentRange(_ value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Session delegate of `AppleDeveloperDownloads.makeSession`: refuses redirects to anything but https.
final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(AppleDeveloperDownloads.isAllowedRedirect(request.url) ? request : nil)
    }
}

/// Streams a data task into a `.part` file (append for 206, truncate for 200).
final class PartFileReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let part: URL
    private let name: String
    private let progress: ProgressHandler
    private let expected: Int64?
    private var handle: FileHandle
    private var written: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport = Date.distantPast
    private(set) var totalSize: Int64?

    init(part: URL, offset: Int64, expected: Int64?, name: String, progress: @escaping ProgressHandler) throws {
        self.part = part
        self.name = name
        self.progress = progress
        self.expected = expected
        self.handle = try FileHandle(forWritingTo: part)
        self.written = offset
        self.totalSize = expected
        super.init()
        try handle.seekToEnd()
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard AppleDeveloperDownloads.isAllowedRedirect(request.url) else {
            fail(OnwinError(String(localized: "Сервер Apple перенаправил загрузку \(name) на небезопасный адрес — загрузка остановлена", bundle: .onwinCore)))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(OnwinError(String(localized: "Сервер Apple прислал не HTTP-ответ на загрузку \(name)", bundle: .onwinCore))); completionHandler(.cancel); return
        }
        if http.url?.lastPathComponent == "unauthorized" || (http.mimeType ?? "").lowercased().contains("html") {
            fail(AppleDeveloperDownloads.Failure.notSignedIn); completionHandler(.cancel); return
        }
        switch http.statusCode {
        case 206:
            if let total = AppleDeveloperDownloads.totalFromContentRange(http.value(forHTTPHeaderField: "Content-Range")) {
                totalSize = expected ?? total
            }
        case 200:
            // The server ignored the Range: start over.
            do {
                try handle.truncate(atOffset: 0)
                written = 0
            } catch { fail(error); completionHandler(.cancel); return }
            if http.expectedContentLength > 0 { totalSize = expected ?? http.expectedContentLength }
        case 416:
            // Range not satisfiable: the .part is already complete (checked by the caller).
            completionHandler(.cancel); return
        case 401, 403:
            fail(AppleDeveloperDownloads.Failure.notSignedIn); completionHandler(.cancel); return
        default:
            fail(OnwinError(String(localized: "Сервер Apple ответил HTTP \(http.statusCode) на загрузку \(name)", bundle: .onwinCore))); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(error); dataTask.cancel(); return
        }
        written += Int64(data.count)
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        if let total = totalSize, total > 0 {
            progress(.status(String(localized: "Скачиваю \(name): \(AppleDeveloperDownloads.megabytes(written)) из \(AppleDeveloperDownloads.megabytes(total))", bundle: .onwinCore),
                             fraction: min(Double(written) / Double(total), 1)))
        } else {
            progress(.status(String(localized: "Скачиваю \(name): \(AppleDeveloperDownloads.megabytes(written))", bundle: .onwinCore)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.synchronize()
        try? handle.close()
        lock.lock()
        let c = continuation
        continuation = nil
        let stored = failure
        lock.unlock()
        if let stored {
            c?.resume(throwing: stored)
        } else if let error, (error as? URLError)?.code != .cancelled {
            c?.resume(throwing: error)
        } else if let error, (error as? URLError)?.code == .cancelled, (task.response as? HTTPURLResponse)?.statusCode != 416 {
            c?.resume(throwing: CancellationError())
        } else {
            c?.resume()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }
}
