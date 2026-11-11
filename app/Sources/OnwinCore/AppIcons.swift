import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One place an icon can come from.
public enum AppIconSource: Hashable, Sendable {
    /// A Windows PE file (.exe / .dll) whose icon resource is used, or an .ico file (largest image).
    case executable(URL)
    /// A ready image file on disk (Steam library art, winemenubuilder PNG): used as is.
    case image(URL)
    /// An official icon on the vendor's own site (`AppRecipe.iconURL`), downloaded once.
    case remote(URL)
}

/// Which Steam artwork a game should show.
public enum SteamArtStyle: Hashable, Sendable {
    /// Portrait library cover first (program grid / game cards).
    case cover
    /// Square icon first (lists, Launchpad).
    case icon
}

/// What an icon is wanted for; `AppIcons.sources(for:)` turns it into sources, best first.
public enum AppIconSubject: Hashable, Sendable {
    /// A catalog recipe: its program installed in any of `spaces`, its cached installer, its vendor icon.
    case recipe(AppRecipe, spaces: [Space])
    /// A catalog component: the icon of its cached installer.
    case component(Component)
    /// A program of a space (exe icon, Start Menu icon, Steam art for Steam games).
    case program(SpaceProgram, space: Space)
    /// A game of the space's Steam client.
    case steamGame(appID: Int, space: Space, style: SteamArtStyle)
    /// The space itself: the icon of its main (recipe / pinned) program.
    case space(Space, programs: [SpaceProgram])
    /// A started Wine command (`RunningProgram.command`).
    case command([String], space: Space?)
    /// Explicit sources.
    case sources([AppIconSource])
}

/// The original application logos, everywhere in onwin.
///
/// Resolution walks the sources of a subject in order and returns the first one that yields an image:
///
///  1. the installed program's exe icon (`IconExtractor`, the PE `RT_GROUP_ICON` resource);
///  2. the icon of the recipe's / component's installer when it is already in the download cache;
///  3. Steam's own art for Steam games (`SteamGameArt`: shortcut .ico, library cover, icon);
///  4. an official high-resolution icon from the vendor's domain (`AppRecipe.iconURL`);
///
/// and the caller draws its SF Symbol tile when nothing is found. Executable and remote icons are
/// converted to PNG once and kept in `~/Library/Caches/onwin/Icons/<sha256 of the source>.png`
/// (the key of a file includes its size and mtime, so a reinstalled program gets its new icon);
/// image files are used in place. On top of that there is a memory cache of resolutions and of
/// decoded `NSImage`s, so views can ask synchronously first (`cachedImage(for:)`) and only go async
/// (`resolve(_:)`, off the main thread) when the answer is not known yet. Misses of remote icons
/// (offline, HTTP error) are retried after 10 minutes, misses of files when the file changes.
public enum AppIcons {
    public static var cacheDirectory: URL {
        OnwinPaths.cache.appendingPathComponent("Icons", isDirectory: true)
    }

    // MARK: Public API

    /// The cached icon file of a subject (PNG in the icon cache, or an image file on disk), resolving it
    /// off the calling thread. nil when no source yields an image.
    public static func resolve(_ subject: AppIconSubject) async -> URL? {
        if let known = state.withLock({ $0.resolved[subject] }), OnwinPaths.exists(known) { return known }
        let url = await Task.detached(priority: .utility) { () -> URL? in
            await resolve(sources: sources(for: subject))
        }.value
        if let url {
            state.withLock { s in
                if s.resolved.count > 2048 { s.resolved.removeAll() }
                s.resolved[subject] = url
            }
        }
        return url
    }

    /// The first source of the list that yields an image (see the type documentation).
    public static func resolve(sources: [AppIconSource]) async -> URL? {
        for source in sources {
            if let url = await file(for: source) { return url }
        }
        return nil
    }

    /// Decoded image of an already resolved subject, from memory only (no file or network I/O except
    /// decoding a cached file once). For the first frame of a view; then call `resolve(_:)`.
    public static func cachedImage(for subject: AppIconSubject) -> NSImage? {
        guard let url = state.withLock({ $0.resolved[subject] }) else { return nil }
        return image(at: url)
    }

    /// The icon of a subject as an image (resolves, then decodes with a memory cache).
    public static func image(for subject: AppIconSubject) async -> NSImage? {
        guard let url = await resolve(subject) else { return nil }
        return image(at: url)
    }

    /// Decodes an image file with a memory cache keyed by path + mtime.
    public static func image(at url: URL) -> NSImage? {
        let key = fileKey(url) as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        // Size the image to its pixels so `resizable()` scales from the real resolution.
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        images.setObject(image, forKey: key)
        return image
    }

    /// PNG bytes of the resolved icon (for `onwinctl icon` and tests).
    public static func pngData(for subject: AppIconSubject) async -> Data? {
        guard let url = await resolve(subject), let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "png" { return data }
        return bestPNG(fromImageData: data)
    }

    /// Forgets the memory caches (the disk cache stays; it is keyed by file version anyway).
    public static func removeAllCachedIcons() {
        state.withLock { $0 = State() }
        images.removeAllObjects()
        IconExtractor.removeAllCachedIcons()
    }

    /// True when the image fills its square: the four corners are opaque (a cover, a store icon on a
    /// solid background). Such images are clipped to the tile; transparent Windows icons are drawn inside it.
    public static func isOpaqueTile(_ image: NSImage) -> Bool {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        let corners = [0, side - 1, side * (side - 1), side * side - 1]
        return corners.allSatisfy { pixels[$0 * 4 + 3] > 230 }
    }

    // MARK: Sources

    /// Sources of a subject, best first. Does file-system work: call it off the main thread.
    public static func sources(for subject: AppIconSubject) -> [AppIconSource] {
        var list: [AppIconSource] = []
        switch subject {
        case .sources(let explicit):
            list = explicit

        case .recipe(let recipe, let spaces):
            // Spaces made for the recipe first (a stable partition: `sorted` needs a strict ordering).
            let isOwn = { (b: Space) in b.name.caseInsensitiveCompare(recipe.spaceName) == .orderedSame }
            let ordered = spaces.filter(isOwn) + spaces.filter { !isOwn($0) }
            if let path = recipe.launchPath {
                for space in ordered {
                    if let unix = space.unixPath(forWindowsPath: path), isFile(unix) { list.append(.executable(unix)) }
                }
            }
            if let appID = recipe.steamAppID {
                for space in ordered {
                    guard let steam = Steam.installation(in: space) else { continue }
                    list += steamSources(Steam.art(for: appID, steam: steam, space: space), style: .icon)
                }
            }
            // A user recipe's icon saved from its installed program («Сохранить в каталог?»).
            if recipe.category == .user, let saved = UserRecipes.recipe(recipe.id)?.iconURL { list.append(.image(saved)) }
            if let step = recipe.installer, isPE(step.fileName) {
                // A user recipe's local installer lives in Recipes/Files/<id>/, downloads in the cache.
                if step.url.isFileURL {
                    if isFile(step.url) { list.append(.executable(step.url)) }
                } else if let file = Downloader.cachedFile(named: step.fileName) {
                    list.append(.executable(file))
                }
            }
            if let url = recipe.iconURL { list.append(.remote(url)) }

        case .component(let component):
            for download in component.downloads where isPE(download.fileName) {
                if let file = Downloader.cachedFile(named: download.fileName) { list.append(.executable(file)) }
            }

        case .program(let program, let space):
            list = programSources(program, in: space)

        case .steamGame(let appID, let space, let style):
            guard let steam = Steam.installation(in: space) else { break }
            list = steamSources(Steam.art(for: appID, steam: steam, space: space), style: style)
            if let game = Steam.games(of: steam, in: space).first(where: { $0.appID == appID }),
               let exe = Steam.mainExecutable(of: game) {
                list.append(.executable(exe))
            }

        case .space(let space, let programs):
            var exes: [URL] = []
            if let recipe = Catalog.apps.first(where: { $0.spaceName.caseInsensitiveCompare(space.name) == .orderedSame }),
               let path = recipe.launchPath, let unix = space.unixPath(forWindowsPath: path), isFile(unix) {
                exes.append(unix)
            }
            let pinned = programs.filter { if case .pinned = $0.source { return true } else { return false } }
            let main = pinned.isEmpty && programs.count == 1 ? programs : pinned
            for program in main.prefix(3) {
                for source in programSources(program, in: space) where !list.contains(source) { list.append(source) }
            }
            list = exes.map { .executable($0) } + list.filter { source in
                if case .executable(let url) = source { return !exes.contains(url) }
                return true
            }

        case .command(let command, let space):
            list = commandSources(command, space: space)
        }
        return list
    }

    static func programSources(_ program: SpaceProgram, in space: Space) -> [AppIconSource] {
        var list: [AppIconSource] = []
        var steamArt: SteamGameArt?
        if let exe = program.executable, let found = Steam.game(containing: exe, in: space) {
            steamArt = Steam.art(for: found.game.appID, steam: found.steam, space: space)
        }
        // Steam's square shortcut icon is the game's official icon in all sizes.
        if let icon = steamArt?.clientIcon { list.append(.executable(icon)) }
        if let exe = program.executable, isFile(exe), isPE(exe.lastPathComponent) || exe.pathExtension.lowercased() == "ico" {
            list.append(.executable(exe))
        }
        let ext = program.launchFile.pathExtension.lowercased()
        if ext == "lnk",
           let entry = StartMenuHook.entry(forLink: program.launchFile, in: space),
           let name = entry.icon, let png = StartMenuHook.iconFile(named: name, in: space) {
            list.append(.image(png))
        } else if ["exe", "dll", "ico"].contains(ext), program.launchFile != program.executable {
            list.append(.executable(program.launchFile))
        }
        if let art = steamArt {
            for url in [art.cover, art.header, art.icon].compactMap({ $0 }) { list.append(.image(url)) }
        }
        return list
    }

    static func steamSources(_ art: SteamGameArt, style: SteamArtStyle) -> [AppIconSource] {
        var list: [AppIconSource] = []
        switch style {
        case .cover:
            list += [art.cover, art.header, art.hero].compactMap { $0 }.map { .image($0) }
            if let icon = art.clientIcon { list.append(.executable(icon)) }
            list += [art.icon, art.logo].compactMap { $0 }.map { .image($0) }
        case .icon:
            if let icon = art.clientIcon { list.append(.executable(icon)) }
            list += [art.icon, art.logo, art.cover, art.header].compactMap { $0 }.map { .image($0) }
        }
        return list
    }

    /// `[exe, args…]`, `["start", "/unix", file.lnk]`, `[steam.exe, "-applaunch", id]`…
    static func commandSources(_ command: [String], space: Space?) -> [AppIconSource] {
        if let space, let flag = command.firstIndex(where: { $0.lowercased() == "-applaunch" }),
           flag + 1 < command.count, let appID = Int(command[flag + 1]) {
            return sources(for: .steamGame(appID: appID, space: space, style: .icon))
        }
        for argument in command {
            var path = argument
            if path.count > 2, path.hasPrefix("Z:\\") || path.hasPrefix("z:\\") {
                path = String(path.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
            } else if path.count > 2, path.dropFirst().hasPrefix(":\\"), let space,
                      let unix = space.unixPath(forWindowsPath: path) {
                path = unix.path
            }
            guard path.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: path)
            switch url.pathExtension.lowercased() {
            case "exe", "dll", "ico":
                if isFile(url) { return [.executable(url)] }
            case "lnk":
                if let space {
                    let target = ShellLink.parse(url)?.targetPath.flatMap { space.unixPath(forWindowsPath: $0) }
                    let program = SpaceProgram(id: url.path, name: url.deletingPathExtension().lastPathComponent,
                                                source: .startMenu(url), executable: target, launchFile: url,
                                                arguments: [], environment: [:])
                    return programSources(program, in: space)
                }
            default:
                continue
            }
        }
        return []
    }

    // MARK: Resolving one source

    private static func file(for source: AppIconSource) async -> URL? {
        switch source {
        case .image(let url):
            return isDecodableImage(url) ? url : nil
        case .executable(let url):
            guard isFile(url) else { return nil }
            let key = "exe|" + fileKey(url)
            return await produce(key: key, retryAfter: nil) { pngFromExecutable(url) }
        case .remote(let url):
            guard url.scheme == "https" else { return nil }
            return await produce(key: "url|" + url.absoluteString, retryAfter: 600) { await download(url) }
        }
    }

    /// Returns the cached PNG of `key`, or runs `make` once (concurrent callers wait for the same work).
    private static func produce(key: String, retryAfter: TimeInterval?,
                                make: @escaping @Sendable () async -> Data?) async -> URL? {
        let target = cacheDirectory.appendingPathComponent(sha256(key) + ".png")
        if isFile(target) { return target }
        if let missed = state.withLock({ $0.misses[key] }) {
            guard let retryAfter, Date().timeIntervalSince(missed) > retryAfter else { return nil }
        }
        let task: Task<URL?, Never> = state.withLock { s in
            if let running = s.inFlight[key] { return running }
            let created = Task<URL?, Never>.detached(priority: .utility) {
                guard let png = await make() else { return nil }
                do {
                    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                    try png.write(to: target, options: .atomic)
                    return target
                } catch {
                    return nil
                }
            }
            s.inFlight[key] = created
            return created
        }
        let result = await task.value
        state.withLock { s in
            s.inFlight[key] = nil
            if result == nil { s.misses[key] = Date() } else { s.misses[key] = nil }
        }
        return result
    }

    static func pngFromExecutable(_ url: URL) -> Data? {
        let ico: Data? = url.pathExtension.lowercased() == "ico"
            ? (try? Data(contentsOf: url)) : IconExtractor.icoData(for: url)
        if let ico, let png = bestPNG(fromImageData: ico) { return png }
        // Some icon sets only AppKit's decoder understands.
        if let image = IconExtractor.icon(for: url) {
            var rect = NSRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return png(cg) }
        }
        return nil
    }

    /// Largest vendor icon accepted (bytes); the body is streamed and dropped as soon as it is bigger.
    static let maxDownloadBytes = 4 * 1024 * 1024

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("onwin/\(OnwinVersion.string)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              // Redirects must stay on https.
              http.url?.scheme?.lowercased() == "https",
              // Only images: no Content-Type or another type (an HTML error / bot-check page) is a miss.
              let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.hasPrefix("image/"),
              http.expectedContentLength <= Int64(maxDownloadBytes) else {
            return nil
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxDownloadBytes { return nil }
            }
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }
        return bestPNG(fromImageData: data)
    }

    // MARK: Image helpers

    /// Largest icon side decoded (px); bigger frames are skipped so a crafted file cannot make onwin
    /// allocate gigabytes ("decompression bomb").
    static let maxIconSide = 4096

    /// The largest image of a PNG / JPEG / ICO / ICNS as PNG bytes. Frames are chosen by their header
    /// (pixel size) and only the chosen one is decoded.
    static func bestPNG(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var bestIndex: Int?
        var bestArea = 0
        for index in 0..<min(CGImageSourceGetCount(source), 64) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maxIconSide, height <= maxIconSide else { continue }
            if width * height > bestArea { bestArea = width * height; bestIndex = index }
        }
        guard let bestIndex, let image = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else { return nil }
        return png(image)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func isDecodableImage(_ url: URL) -> Bool {
        guard isFile(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: Small helpers

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func isPE(_ fileName: String) -> Bool {
        ["exe", "dll"].contains((fileName as NSString).pathExtension.lowercased())
    }

    private static func fileKey(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(url.standardizedFileURL.path)|\(mtime)|\(size)"
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: State

    private struct State {
        var resolved: [AppIconSubject: URL] = [:]
        var misses: [String: Date] = [:]
        var inFlight: [String: Task<URL?, Never>] = [:]
    }

    private static let state = LockedValue(State())

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
}

extension Steam {
    /// The game's main executable, for its icon when Steam has no art cached: the largest .exe in the
    /// install folder or one level below (bin/, Binaries/Win64…), skipping installers, crash reporters
    /// and redistributables.
    public static func mainExecutable(of game: SteamGame) -> URL? {
        let fm = FileManager.default
        let skip = ["unins", "setup", "crash", "redist", "vcredist", "dxsetup", "dotnet", "report", "helper", "ue4prereq",
                    "easyanticheat", "battleye"]
        var candidates: [(URL, Int64)] = []
        func scan(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if depth < 3 { scan(entry, depth: depth + 1) }
                } else if entry.pathExtension.lowercased() == "exe" {
                    let name = entry.lastPathComponent.lowercased()
                    if skip.contains(where: { name.contains($0) }) { continue }
                    candidates.append((entry, Int64(values?.fileSize ?? 0)))
                }
            }
        }
        scan(game.installDirectory, depth: 0)
        return candidates.max { $0.1 < $1.1 }?.0
    }
}
