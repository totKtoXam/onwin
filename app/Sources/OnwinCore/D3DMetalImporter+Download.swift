import Foundation

/// In-app download of the Game Porting Toolkit with the cookies of the user's developer.apple.com
/// session (see `AppleDeveloperDownloads`), followed by the usual import.
extension D3DMetalImporter {
    /// Steps of the flow: 1 sign-in, 2 download, 3 install.
    public static let stepCount = 3

    /// Why Apple does not accept the session (nil = usable: listDownloads answers with a list).
    public static func sessionProblem(cookies: [HTTPCookie]) async -> AppleDeveloperDownloads.Failure? {
        guard AppleDeveloperDownloads.hasSessionCookie(cookies) else { return .notSignedIn }
        let session = AppleDeveloperDownloads.makeSession(cookies: cookies)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AppleDeveloperDownloads.listDownloads(session: session)
            return nil
        } catch let failure as AppleDeveloperDownloads.Failure {
            return failure
        } catch {
            return .service(error.localizedDescription)
        }
    }

    /// Finds the newest stable Game Porting Toolkit, downloads it into onwin's cache (continuing a
    /// partial download), imports D3DMetal and, if asked, deletes the image. Returns the image URL.
    @discardableResult
    public static func downloadAndImport(cookies: [HTTPCookie], deleteImageAfterImport: Bool = false,
                                         progress: @escaping ProgressHandler) async throws -> URL {
        let session = AppleDeveloperDownloads.makeSession(cookies: cookies)
        defer { session.finishTasksAndInvalidate() }

        progress(.status(String(localized: "Шаг 2 из \(stepCount): ищу последнюю версию Game Porting Toolkit на developer.apple.com…", bundle: .onwinCore)))
        let downloads = try await AppleDeveloperDownloads.listDownloads(session: session)
        guard let release = AppleDeveloperDownloads.latestGamePortingToolkit(in: downloads) else {
            let page = Catalog.gameportingToolkitURL.absoluteString
            throw OnwinError(String(localized: "В загрузках Apple Developer не нашлось Game Porting Toolkit. Скачайте его вручную на \(page) — onwin подхватит .dmg из «Загрузок».", bundle: .onwinCore))
        }
        progress(.status(release.isPrerelease
            ? String(localized: "Шаг 2 из \(stepCount): \(release.name) (бета: стабильной версии нет) — \(release.fileName)", bundle: .onwinCore)
            : String(localized: "Шаг 2 из \(stepCount): \(release.name) — \(release.fileName)", bundle: .onwinCore)))
        try Task.checkCancellation()
        try await AppleDeveloperDownloads.authorizeDownload(path: release.remotePath, session: session)
        let image = try await AppleDeveloperDownloads.download(release, session: session,
                                                               into: Downloader.downloadsDirectory, progress: progress)
        try Task.checkCancellation()
        progress(.status(String(localized: "Шаг 3 из \(stepCount): устанавливаю D3DMetal из \(release.fileName)…", bundle: .onwinCore)))
        try await importFound(.diskImage(image), progress: progress)
        if deleteImageAfterImport {
            try? FileManager.default.removeItem(at: image)
            progress(.status(String(localized: "Образ \(release.fileName) удалён из кэша", bundle: .onwinCore)))
        }
        progress(InstallProgress(message: String(localized: "D3DMetal (\(release.name)) установлен", bundle: .onwinCore), fraction: 1))
        return image
    }
}
