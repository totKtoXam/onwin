import Foundation

/// Progress reporting for long operations (downloads, installers).
public struct InstallProgress: Sendable {
    public var message: String
    /// 0...1, or nil when unknown.
    public var fraction: Double?
}

public typealias ProgressHandler = @Sendable (InstallProgress) -> Void

/// Downloads files into ~/Library/Caches/onwin, reusing what is already there.
public enum Downloader {
    /// `~/Library/Caches/onwin/Downloads`: every downloaded installer / component file, by its file name.
    public static var downloadsDirectory: URL {
        OnwinPaths.cache.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The already downloaded file `fileName`, or nil when it is not in the cache (or empty).
    public static func cachedFile(named fileName: String) -> URL? {
        let file = downloadsDirectory.appendingPathComponent(fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        return (size?.intValue ?? 0) > 0 ? file : nil
    }

    public static func fetch(_ url: URL, fileName: String, progress: @escaping ProgressHandler) async throws -> URL {
        let downloads = downloadsDirectory
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = downloads.appendingPathComponent(fileName)
        if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber,
           size.intValue > 0 {
            progress(InstallProgress(message: String(localized: "\(fileName) уже скачан", bundle: .onwinCore), fraction: 1))
            return destination
        }
        progress(InstallProgress(message: String(localized: "Скачиваю \(fileName)…", bundle: .onwinCore), fraction: 0))
        let delegate = DownloadDelegate(name: fileName, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("onwin/\(OnwinVersion.string)", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OnwinError(String(localized: "Не удалось скачать \(url.absoluteString): HTTP \(http.statusCode)", bundle: .onwinCore))
        }
        // An https download must not end on a plain-http redirect target.
        if url.scheme?.lowercased() == "https", let final = response.url, final.scheme?.lowercased() != "https" {
            try? FileManager.default.removeItem(at: temp)
            throw OnwinError(String(localized: "Не удалось скачать \(url.absoluteString): перенаправление на незащищённый адрес \(final.absoluteString)", bundle: .onwinCore))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        progress(InstallProgress(message: String(localized: "\(fileName) скачан", bundle: .onwinCore), fraction: 1))
        return destination
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let name: String
        let progress: ProgressHandler
        var lastReport = Date.distantPast
        init(name: String, progress: @escaping ProgressHandler) { self.name = name; self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.2 else { return }
            lastReport = now
            let written = totalBytesWritten.formatted(.byteCount(style: .file))
            if totalBytesExpectedToWrite > 0 {
                let total = totalBytesExpectedToWrite.formatted(.byteCount(style: .file))
                progress(InstallProgress(message: String(localized: "Скачиваю \(name): \(written) из \(total)", bundle: .onwinCore),
                                         fraction: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            } else {
                progress(InstallProgress(message: String(localized: "Скачиваю \(name): \(written)", bundle: .onwinCore), fraction: nil))
            }
        }
    }
}

/// Installs components and application recipes into spaces.
public enum Installer {
    /// Installs a catalog component (and the components it requires); see `ComponentInstaller`.
    public static func install(component: Component, into space: Space,
                               progress: @escaping ProgressHandler) async throws -> Space {
        try await ComponentInstaller.install(component, into: space, progress: progress)
    }

    /// Full CrossTie-style install: create (or reuse) a space, add components, run the installer,
    /// register the program in the space's launcher list.
    public static func install(recipe: AppRecipe, into existing: Space? = nil,
                               progress: @escaping ProgressHandler) async throws -> Space {
        var space: Space
        if let existing {
            space = existing
        } else if let found = SpaceManager.find(recipe.spaceName) {
            space = found
        } else {
            progress(InstallProgress(message: String(localized: "Создаю пространство «\(recipe.spaceName)»…", bundle: .onwinCore), fraction: nil))
            space = try await SpaceManager.create(name: recipe.spaceName, windowsVersion: recipe.windowsVersion,
                                                    backend: recipe.backend,
                                                    log: { line in progress(InstallProgress(message: line.trimmingCharacters(in: .whitespacesAndNewlines), fraction: nil)) })
        }
        for id in recipe.components {
            guard let component = Catalog.component(id), !component.isInstalled(in: space.config) else { continue }
            space = try await install(component: component, into: space, progress: progress)
        }
        // A Steam game needs the Steam client first.
        let installer = recipe.installer ?? (recipe.steamAppID != nil && Steam.installation(in: space) == nil
                                             ? Catalog.app("steam")?.installer : nil)
        if let step = installer {
            // Local file of a user recipe, or a (SHA-256 checked) download: UserRecipes.swift.
            let file = try await UserRecipes.installerFile(for: step, recipe: recipe, progress: progress)
            progress(InstallProgress(message: String(localized: "Запускаю установщик \(recipe.name)…", bundle: .onwinCore), fraction: nil))
            let runner = try WineRunner(space: space)
            let r = try await runner.runAndWait(WineRunner.command(for: file, arguments: step.arguments),
                                                currentDirectory: file.deletingLastPathComponent())
            try await runner.waitForServer()
            if !([0, 3010, 1638] as [Int32]).contains(where: { WineRunner.exitStatus(r.status, matches: $0) }) {
                throw OnwinError(String(localized: "Установщик \(recipe.name) завершился с кодом \(Int(r.status))\n\(String(r.output.suffix(1500)))", bundle: .onwinCore))
            }
        }
        if let path = recipe.launchPath, !space.config.programs.contains(where: { $0.windowsPath == path }) {
            space.config.programs.append(ProgramEntry(name: recipe.name, windowsPath: path, arguments: recipe.launchArguments,
                                                       environment: recipe.launchEnvironment))
            try space.save()
        }
        if let appID = recipe.steamAppID {
            try await Steam.requestInstall(appID: appID, name: recipe.name, in: space, progress: progress)
            return space
        }
        progress(InstallProgress(message: String(localized: "\(recipe.name) установлен", bundle: .onwinCore), fraction: 1))
        return space
    }
}
