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

        progress(.status("Шаг 2 из \(stepCount): ищу последнюю версию Game Porting Toolkit на developer.apple.com…"))
        let downloads = try await AppleDeveloperDownloads.listDownloads(session: session)
        guard let release = AppleDeveloperDownloads.latestGamePortingToolkit(in: downloads) else {
            throw OnwinError("В загрузках Apple Developer не нашлось Game Porting Toolkit. Скачайте его вручную на " +
                             "\(Catalog.gameportingToolkitURL.absoluteString) — onwin подхватит .dmg из «Загрузок».")
        }
        let kind = release.isPrerelease ? " (бета: стабильной версии нет)" : ""
        progress(.status("Шаг 2 из \(stepCount): \(release.name)\(kind) — \(release.fileName)"))
        try Task.checkCancellation()
        try await AppleDeveloperDownloads.authorizeDownload(path: release.remotePath, session: session)
        let image = try await AppleDeveloperDownloads.download(release, session: session,
                                                               into: Downloader.downloadsDirectory, progress: progress)
        try Task.checkCancellation()
        progress(.status("Шаг 3 из \(stepCount): устанавливаю D3DMetal из \(release.fileName)…"))
        try await importFound(.diskImage(image), progress: progress)
        if deleteImageAfterImport {
            try? FileManager.default.removeItem(at: image)
            progress(.status("Образ \(release.fileName) удалён из кэша"))
        }
        progress(InstallProgress(message: "D3DMetal (\(release.name)) установлен", fraction: 1))
        return image
    }
}
