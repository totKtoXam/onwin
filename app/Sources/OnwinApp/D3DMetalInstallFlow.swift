import AppKit
import Foundation
import Observation
import OnwinCore
import SwiftUI
import WebKit

// MARK: - «Установить D3DMetal»: the one in-app flow (AppModel API, part D3DMetal)
//
//   func installD3DMetal() async -> Bool      what every «Установить D3DMetal» button calls
//                                              (fetchD3DMetal() forwards here)
//   func forgetAppleSignIn() async            removes the apple.com session from the web data store
//   D3DMetalInstallFlow.deleteImageKey        UserDefaults Bool: delete the GPTK .dmg after import
//                                              (default false = keep it in ~/Library/Caches/onwin/Downloads)
//
// Steps:
//   0. a Game_Porting_Toolkit_*.dmg in ~/Downloads / the download cache, or a mounted GPTK volume
//      → straight to the import, no Apple ID needed;
//   1. the apple.com session stored in WKWebsiteDataStore.default() (the app's persistent store) is
//      checked with Apple's listDownloads; if it is missing or expired, AppleSignInWindow shows
//      Apple's own sign-in page (Apple ID, password, 2FA happen on Apple's page, onwin never sees
//      or stores the password). Success = Apple's session cookie + listDownloads answering;
//   2. download of the newest stable GPTK into the cache (resumable, size verified),
//   3. hdiutil attach of the outer and the nested image, import, detach (TaskProgressSheet).
// Cookies are only read from the web data store and handed to an in-memory URLSession; they are
// never written elsewhere or logged.

/// Where the Game Porting Toolkit for an install comes from.
enum D3DMetalSource {
    case found(D3DMetalImporter.Found)
    case session([HTTPCookie])
}

enum D3DMetalInstallFlow {
    static let deleteImageKey = "onwin.d3dmetal.deleteImageAfterImport"

    static var deleteImageAfterImport: Bool { UserDefaults.standard.bool(forKey: deleteImageKey) }

    /// The apple.com cookies of the app's web data store.
    @MainActor
    static func storedAppleCookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter(AppleDeveloperDownloads.isAppleCookie)
    }
}

extension AppModel {
    @discardableResult
    func installD3DMetal() async -> Bool {
        if let current = activeTask, !current.isFinished {
            report("Дождитесь окончания операции «\(current.title)».")
            return false
        }
        let source: D3DMetalSource
        if let found = D3DMetalImporter.find() {
            source = .found(found)
        } else {
            backgroundActivity = "Проверяю вход в Apple ID…"
            let cookies = await D3DMetalInstallFlow.storedAppleCookies()
            let problem = await D3DMetalImporter.sessionProblem(cookies: cookies)
            backgroundActivity = nil
            if problem == nil {
                source = .session(cookies)
            } else {
                guard let obtained = await AppleSignInWindow.shared.run(initialProblem: problem) else { return false }
                source = obtained
                // Let the sign-in window go away before the progress sheet appears.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let deleteImage = D3DMetalInstallFlow.deleteImageAfterImport
        let ok = await performTask("Установка D3DMetal", autoClose: false) { (context: TaskContext) async throws -> Bool in
            switch source {
            case .found(let found):
                context.status("Нашёл \(found.url.lastPathComponent) — вход в Apple ID не нужен")
                try await D3DMetalImporter.importFound(found, progress: context.progress)
            case .session(let cookies):
                context.status("Шаг 1 из \(D3DMetalImporter.stepCount): вход в Apple ID выполнен")
                try await D3DMetalImporter.downloadAndImport(cookies: cookies, deleteImageAfterImport: deleteImage,
                                                             progress: context.progress)
            }
            return true
        }
        isD3DMetalInstalled = GraphicsSupport.isD3DMetalInstalled
        for space in spaces { analyzeDependencies(of: space.id) }
        return ok ?? false
    }

    /// Signs onwin out of developer.apple.com (removes the apple.com website data of the web store).
    func forgetAppleSignIn() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { record in
            let name = record.displayName.lowercased()
            return name == "apple.com" || name.hasSuffix(".apple.com")
        }
        await store.removeData(ofTypes: types, for: records)
        for cookie in await D3DMetalInstallFlow.storedAppleCookies() {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }
}

// MARK: - Sign-in window

/// State of the sign-in window (observed by `AppleSignInView`).
@MainActor
@Observable
final class AppleSignInState {
    var message = "Войдите со своим Apple ID — бесплатной учётной записи разработчика достаточно."
    var isChecking = false
    var isWarning = false
    var deleteImageAfterImport = D3DMetalInstallFlow.deleteImageAfterImport {
        didSet { UserDefaults.standard.set(deleteImageAfterImport, forKey: D3DMetalInstallFlow.deleteImageKey) }
    }
    var openedInBrowser = false
}

/// A standalone window with Apple's sign-in page (works from the main window and from Preferences).
@MainActor
final class AppleSignInWindow: NSObject, NSWindowDelegate, WKHTTPCookieStoreObserver {
    static let shared = AppleSignInWindow()

    private var window: NSWindow?
    private var continuation: CheckedContinuation<D3DMetalSource?, Never>?
    private var state = AppleSignInState()
    private var pollTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var lastCheckedSession: String?

    /// Shows the window and waits until the user signed in (or a GPTK image turned up), or closed it.
    func run(initialProblem: AppleDeveloperDownloads.Failure?) async -> D3DMetalSource? {
        if let window {   // already open: bring it to the front, the first caller gets the result
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return nil
        }
        state = AppleSignInState()
        if case .agreementRequired? = initialProblem {
            state.message = "Apple просит принять соглашение Apple Developer — примите его на странице ниже."
            state.isWarning = true
        }
        lastCheckedSession = nil
        return await withCheckedContinuation { (c: CheckedContinuation<D3DMetalSource?, Never>) in
            continuation = c
            open()
        }
    }

    private func open() {
        let view = AppleSignInView(state: state,
                                   onPageLoaded: { [weak self] in self?.scheduleCheck(force: false) },
                                   onOpenInBrowser: { [weak self] in self?.openInBrowser() },
                                   onCancel: { [weak self] in self?.finish(nil) })
        let hosting = NSHostingView(rootView: view.tint(OnwinTheme.accent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Установка D3DMetal — вход в Apple ID"
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 720, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        WKWebsiteDataStore.default().httpCookieStore.add(self)
        // Fallback path (browser download) and a periodic session check in case no cookie event comes.
        pollTask = Task { @MainActor [weak self] in
            var lastImage: (URL, Int64)?
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.window != nil else { return }
                tick += 1
                if let found = D3DMetalImporter.find() {
                    if case .diskImage(let url) = found {
                        let size = AppleDeveloperDownloads.fileSize(url)
                        defer { lastImage = (url, size) }
                        guard size > 0, lastImage?.0 == url, lastImage?.1 == size else {
                            self.state.message = "Вижу \(url.lastPathComponent) — жду окончания загрузки…"
                            continue
                        }
                    }
                    self.finish(.found(found))
                    return
                }
                if tick % 4 == 0 { self.scheduleCheck(force: true) }
            }
        }
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(AppleDeveloperDownloads.gptkPageURL)
        state.openedInBrowser = true
        state.isWarning = false
        state.message = "Скачайте «Game Porting Toolkit» (.dmg) в браузере в папку «Загрузки» — onwin заметит файл и установит D3DMetal сам. Это окно можно не закрывать."
    }

    // MARK: Session detection

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.scheduleCheck(force: false) }
    }

    /// Called on cookie changes, finished page loads and periodically; debounced, one check at a time.
    func scheduleCheck(force: Bool) {
        guard window != nil, checkTask == nil else { return }
        checkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            defer { self.checkTask = nil }
            let cookies = await D3DMetalInstallFlow.storedAppleCookies()
            guard AppleDeveloperDownloads.hasSessionCookie(cookies) else { return }
            // Same session already rejected: only re-ask Apple on the periodic check.
            let key = cookies.filter { ["myacinfo", "DSESSIONID"].contains($0.name) }.map(\.value).sorted().joined().hashValue.description
            if !force, key == self.lastCheckedSession { return }
            self.lastCheckedSession = key
            self.state.isChecking = true
            let problem = await D3DMetalImporter.sessionProblem(cookies: cookies)
            self.state.isChecking = false
            guard self.window != nil else { return }
            switch problem {
            case nil:
                self.state.message = "Вход выполнен — начинаю загрузку."
                self.finish(.session(cookies))
            case .agreementRequired?:
                self.state.isWarning = true
                self.state.message = "Вход выполнен, но Apple просит принять соглашение Apple Developer — примите его на странице, onwin продолжит сам."
            case .notSignedIn?:
                break
            case .service(let text)?:
                self.state.isWarning = true
                self.state.message = "Apple пока не отдаёт список загрузок: \(text). Завершите вход на странице — onwin проверит ещё раз."
            }
        }
    }

    // MARK: Closing

    private func finish(_ result: D3DMetalSource?, closeWindow: Bool = true) {
        pollTask?.cancel(); pollTask = nil
        checkTask?.cancel(); checkTask = nil
        WKWebsiteDataStore.default().httpCookieStore.remove(self)
        let c = continuation
        continuation = nil
        if let window {
            self.window = nil
            window.delegate = nil
            if closeWindow { window.close() }
        }
        c?.resume(returning: result)
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        finish(nil, closeWindow: false)
    }
}
