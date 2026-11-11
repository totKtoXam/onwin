import CryptoKit
import Foundation

// MARK: - User recipes ("Мои приложения")
//
// A recipe the user wrote for a program that is not in the built-in catalog. Stored one JSON file per recipe:
//
//     ~/Library/Application Support/onwin/Recipes/<id>.json      the recipe (UserRecipe, schemaVersion 1)
//     ~/Library/Application Support/onwin/Recipes/Files/<id>/    its local installer (copied there on save,
//                                                                so the recipe keeps working when the
//                                                                original file moves) and icon.png
//
// `Catalog.apps` = built-in recipes + `UserRecipes.appRecipes()` (category `.user`); a user recipe whose id
// collides with a built-in one is never listed. Import/export use one `.onwinrecipe` file: the same JSON.
// Exported recipes never embed the installer: for a local installer the file name is kept and the user must
// put the file next to the .onwinrecipe (import copies it from there) or choose it again in the editor.
// Importing NEVER runs anything; installing is always a separate, explicit step.
//
//   UserRecipes.all() / recipe(_:) / save(_:installerFile:) / remove(_:) / export(_:to:) / importFile(_:)
//   UserRecipes.decode(_:) (tolerant) / validate(_:) / makeID(for:) / installerFile(for:recipe:progress:)
// Detection of what an installer added: InstallDetection.swift.

/// A recipe written by the user. Tolerant to missing / unknown fields: older or hand-written files load.
public struct UserRecipe: Codable, Hashable, Identifiable, Sendable {
    public static let schemaVersion = 1
    public static let categoryName = AppRecipe.Category.user.rawValue
    public static let fileExtension = "onwinrecipe"
    public static let defaultSymbol = "app.fill"

    /// Where the installer comes from.
    public struct InstallerSource: Codable, Hashable, Sendable {
        /// https download.
        public var url: String?
        /// Optional pinned SHA-256 of the downloaded file (lower-case hex).
        public var sha256: String?
        /// Local installer: a file name inside Recipes/Files/<id>/ (an absolute path before saving).
        public var file: String?
        /// Name to save the download under (default: last URL path component).
        public var fileName: String?
        /// Silent-install flags (/S, /VERYSILENT, /qn...).
        public var arguments: [String]

        public init(url: String? = nil, sha256: String? = nil, file: String? = nil, fileName: String? = nil,
                    arguments: [String] = []) {
            self.url = url; self.sha256 = sha256; self.file = file; self.fileName = fileName; self.arguments = arguments
        }

        public var isLocalFile: Bool { url == nil && file != nil }

        /// File name the installer runs under: always one plain path component (a recipe file may say
        /// `"fileName": "../../x"`; that must never reach `Downloader` or the Recipes folder as a path).
        public var effectiveFileName: String {
            if let file, let name = UserRecipe.safeFileName(file) { return name }
            if let fileName, let name = UserRecipe.safeFileName(fileName) { return name }
            if let url, let parsed = URL(string: url), !parsed.pathExtension.isEmpty,
               let name = UserRecipe.safeFileName(parsed.lastPathComponent) {
                return name
            }
            return "setup.exe"
        }

        /// The https download URL (nil for anything else: http, file:, a typo).
        public var httpsURL: URL? {
            guard let url, let parsed = URL(string: url), parsed.scheme?.lowercased() == "https",
                  parsed.host?.isEmpty == false else { return nil }
            return parsed
        }

        enum CodingKeys: String, CodingKey { case url, sha256, file, fileName, arguments }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .url))
            sha256 = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .sha256))?.lowercased()
            file = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .file))
            fileName = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .fileName))
            arguments = UserRecipe.decodeArguments(c, .arguments)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(sha256, forKey: .sha256)
            try c.encodeIfPresent(file, forKey: .file)
            try c.encodeIfPresent(fileName, forKey: .fileName)
            try c.encode(arguments, forKey: .arguments)
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var summary: String
    public var installer: InstallerSource?
    /// Space to install into: created with `windowsVersion` / `backend` when it does not exist.
    public var spaceName: String
    public var windowsVersion: WindowsVersion
    public var backend: GraphicsBackend
    /// Catalog component ids installed before the installer runs.
    public var components: [String]
    /// Windows path of the program to launch (pinned in the space after installing).
    public var launchPath: String?
    public var launchArguments: [String]
    /// Per-program environment of the launched program.
    public var environment: [String: String]
    public var notes: String
    /// SF Symbol shown when there is no extracted icon.
    public var symbol: String
    public var created: Date?
    public var modified: Date?

    public init(id: String = "", name: String, summary: String = "", installer: InstallerSource? = nil,
                spaceName: String = "", windowsVersion: WindowsVersion = .win10, backend: GraphicsBackend = .auto,
                components: [String] = [], launchPath: String? = nil, launchArguments: [String] = [],
                environment: [String: String] = [:], notes: String = "", symbol: String = UserRecipe.defaultSymbol) {
        self.schemaVersion = UserRecipe.schemaVersion
        self.id = id
        self.name = name
        self.summary = summary
        self.installer = installer
        self.spaceName = spaceName
        self.windowsVersion = windowsVersion
        self.backend = backend
        self.components = components
        self.launchPath = launchPath
        self.launchArguments = launchArguments
        self.environment = environment
        self.notes = notes
        self.symbol = symbol
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, summary, category, installer, spaceName, windowsVersion, backend, components
        case legacySpaceName = "bottleName"   // recipes written before spaces were called "bottles"
        case launchPath, launchArguments, environment, notes, symbol, created, modified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? UserRecipe.schemaVersion
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        installer = (try? c.decodeIfPresent(InstallerSource.self, forKey: .installer)) ?? nil
        spaceName = ((try? c.decodeIfPresent(String.self, forKey: .spaceName))
                     ?? (try? c.decodeIfPresent(String.self, forKey: .legacySpaceName)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Unknown values (a newer onwin, a typo) fall back to the defaults instead of failing the whole file.
        windowsVersion = ((try? c.decodeIfPresent(String.self, forKey: .windowsVersion)) ?? nil)
            .flatMap { WindowsVersion(rawValue: $0.lowercased()) } ?? .win10
        backend = ((try? c.decodeIfPresent(String.self, forKey: .backend)) ?? nil)
            .flatMap { GraphicsBackend(rawValue: $0.lowercased()) } ?? .auto
        components = ((try? c.decodeIfPresent([String].self, forKey: .components)) ?? nil) ?? []
        launchPath = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .launchPath))
        launchArguments = UserRecipe.decodeArguments(c, .launchArguments)
        environment = ((try? c.decodeIfPresent([String: String].self, forKey: .environment)) ?? nil) ?? [:]
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        symbol = UserRecipe.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? UserRecipe.defaultSymbol
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil
        modified = (try? c.decodeIfPresent(Date.self, forKey: .modified)) ?? nil
        if spaceName.isEmpty { spaceName = name }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encode(UserRecipe.categoryName, forKey: .category)
        try c.encodeIfPresent(installer, forKey: .installer)
        try c.encode(spaceName, forKey: .spaceName)
        try c.encode(windowsVersion.rawValue, forKey: .windowsVersion)
        try c.encode(backend.rawValue, forKey: .backend)
        try c.encode(components, forKey: .components)
        try c.encodeIfPresent(launchPath, forKey: .launchPath)
        try c.encode(launchArguments, forKey: .launchArguments)
        try c.encode(environment, forKey: .environment)
        try c.encode(notes, forKey: .notes)
        try c.encode(symbol, forKey: .symbol)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(modified, forKey: .modified)
    }

    /// The last path component of `path` when it is a usable file name (not empty, ".", ".." or hidden).
    public static func safeFileName(_ path: String) -> String? {
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        return name
    }

    static func nonEmpty(_ s: String??) -> String? {
        guard let value = s ?? nil else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Arguments as a JSON array, or as one command-line string ("/S /D=C:\\X").
    static func decodeArguments<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        if let list = try? c.decodeIfPresent([String].self, forKey: key) { return list }
        if let line = try? c.decodeIfPresent(String.self, forKey: key) { return WindowsCommandLine.split(line) }
        return []
    }

    // MARK: Derived

    /// The local installer inside Recipes/Files/<id>/ (nil for downloads).
    public var localInstallerURL: URL? {
        guard let installer, installer.isLocalFile, let file = installer.file else { return nil }
        if file.hasPrefix("/") { return URL(fileURLWithPath: file) }
        guard let name = UserRecipe.safeFileName(file) else { return nil }
        return UserRecipes.filesDirectory(for: id).appendingPathComponent(name)
    }

    /// True when the recipe has a local installer that is not on disk (e.g. after importing on another Mac).
    public var isMissingInstallerFile: Bool {
        guard let url = localInstallerURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Icon extracted from the installed program when the recipe was saved (Files/<id>/icon.png).
    public var iconURL: URL? {
        let url = UserRecipes.filesDirectory(for: id).appendingPathComponent("icon.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The catalog form (`Catalog.apps`).
    public var appRecipe: AppRecipe {
        var step: Component.Step?
        if let installer {
            if let local = localInstallerURL {
                step = Component.Step(local.absoluteString, fileName: local.lastPathComponent, arguments: installer.arguments)
            } else if let url = installer.httpsURL {
                // Only https downloads become an install step (never http:// or file:// from a recipe file).
                step = Component.Step(url.absoluteString, fileName: installer.effectiveFileName, arguments: installer.arguments)
            }
        }
        return AppRecipe(id: id, name: name, summary: summary.isEmpty ? "Моё приложение" : summary, category: .user,
                         installer: step, windowsVersion: windowsVersion, backend: backend, components: components,
                         launchPath: launchPath, launchArguments: launchArguments,
                         spaceName: spaceName.isEmpty ? name : spaceName, notes: notes, symbol: symbol,
                         launchEnvironment: environment)
    }
}

/// Storage, validation, import / export of user recipes.
public enum UserRecipes {
    public static var directory: URL { OnwinPaths.root.appendingPathComponent("Recipes", isDirectory: true) }
    public static var filesRoot: URL { directory.appendingPathComponent("Files", isDirectory: true) }
    public static func filesDirectory(for id: String) -> URL { filesRoot.appendingPathComponent(id, isDirectory: true) }
    static func fileURL(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    // MARK: Reading

    /// Cache keyed by the directory's modification date: saving (atomic rename) or removing a recipe
    /// changes it, so `Catalog.apps` stays cheap enough for view code.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var stamp: Date?
        var path = ""
        var recipes: [UserRecipe] = []
    }
    private static let cache = Cache()

    /// All valid user recipes, sorted by name.
    public static func all() -> [UserRecipe] {
        let dir = directory
        let stamp = (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        cache.lock.lock()
        if let stamp, cache.stamp == stamp, cache.path == dir.path {
            let hit = cache.recipes
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        let loaded = loadAll()
        cache.lock.lock()
        cache.stamp = stamp
        cache.path = dir.path
        cache.recipes = loaded
        cache.lock.unlock()
        return loaded
    }

    /// Forgets the cache (after writing files with another tool).
    public static func invalidateCache() {
        cache.lock.lock()
        cache.stamp = nil
        cache.lock.unlock()
    }

    private static func loadAll() -> [UserRecipe] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var result: [UserRecipe] = []
        var seen = Set<String>()
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file), var recipe = try? decode(data) else { continue }
            // The file name is the id (a hand-edited file may say otherwise).
            recipe.id = file.deletingPathExtension().lastPathComponent
            // The id names the Files/<id>/ folder that `remove` deletes: never "..", "." or other odd names.
            guard isValidID(recipe.id), !recipe.name.isEmpty, seen.insert(recipe.id.lowercased()).inserted else { continue }
            result.append(recipe)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func recipe(_ id: String) -> UserRecipe? {
        all().first { $0.id == id } ?? all().first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public static func isUserRecipe(_ id: String) -> Bool {
        !builtinIDs.contains(id.lowercased()) && recipe(id) != nil
    }

    /// Recipes for `Catalog.apps` (never shadowing a built-in id).
    public static func appRecipes() -> [AppRecipe] {
        all().filter { !builtinIDs.contains($0.id.lowercased()) }.map(\.appRecipe)
    }

    static var builtinIDs: Set<String> { Set(Catalog.builtinApps.map { $0.id.lowercased() }) }

    // MARK: Decoding / encoding

    public static func decode(_ data: Data) throws -> UserRecipe {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(UserRecipe.self, from: data)
        } catch {
            throw OnwinError("Файл рецепта повреждён или это не рецепт onwin: \(error.localizedDescription)")
        }
    }

    public static func encode(_ recipe: UserRecipe) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(recipe)
    }

    // MARK: Validation

    /// Problems that prevent saving or installing (empty = valid). `checkFiles` also requires the local
    /// installer to exist (off for drafts whose file is chosen but not copied yet).
    public static func validate(_ recipe: UserRecipe, checkFiles: Bool = true) -> [String] {
        var problems: [String] = []
        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Укажите название программы") }
        if !recipe.id.isEmpty {
            if !isValidID(recipe.id) {
                problems.append("Идентификатор «\(recipe.id)»: только латинские буквы, цифры, «-», «_» и «.»")
            } else if builtinIDs.contains(recipe.id.lowercased()) {
                problems.append("Идентификатор «\(recipe.id)» занят встроенным рецептом каталога")
            }
        }
        if let installer = recipe.installer {
            if let url = installer.url {
                if let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host?.isEmpty == false {
                    // ok
                } else {
                    problems.append("Ссылка на установщик должна начинаться с https://")
                }
                if let sha = installer.sha256, !isSHA256(sha) {
                    problems.append("SHA-256 — это 64 шестнадцатеричных символа")
                }
                if let name = installer.fileName, UserRecipe.safeFileName(name) != name {
                    problems.append("Имя файла установщика «\(name)» — только имя файла, без папок")
                }
            } else if let file = installer.file {
                if !file.hasPrefix("/"), UserRecipe.safeFileName(file) == nil {
                    problems.append("Неверное имя файла установщика «\(file)»")
                }
                let ext = (file as NSString).pathExtension.lowercased()
                if !["exe", "msi", "bat", "cmd"].contains(ext) {
                    problems.append("Установщик должен быть файлом .exe или .msi")
                }
                if checkFiles, recipe.isMissingInstallerFile {
                    problems.append("Нет файла установщика \((file as NSString).lastPathComponent) — выберите его заново")
                }
            } else {
                problems.append("Укажите ссылку на установщик или выберите файл")
            }
        } else {
            problems.append("Укажите установщик: ссылку https:// или файл на Mac")
        }
        let space = recipe.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if space.isEmpty { problems.append("Укажите пространство") }
        if space.contains("/") || space.contains(":") { problems.append("В имени пространства нельзя использовать «/» и «:»") }
        for id in recipe.components where Catalog.component(id) == nil {
            problems.append("Неизвестный компонент «\(id)»")
        }
        if let path = recipe.launchPath {
            if !isWindowsPath(path) {
                problems.append("Путь запуска — путь Windows, например C:\\Program Files\\Программа\\app.exe")
            } else if !["exe", "lnk", "bat", "cmd", "com"].contains((path.replacingOccurrences(of: "\\", with: "/") as NSString).pathExtension.lowercased()) {
                problems.append("Путь запуска должен указывать на .exe (или .lnk, .bat)")
            }
        }
        for key in recipe.environment.keys where key.isEmpty || key.contains("=") || key.contains(" ") {
            problems.append("Неверное имя переменной окружения «\(key)»")
        }
        return problems
    }

    public static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.count), let first = id.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    public static func isWindowsPath(_ s: String) -> Bool {
        let chars = Array(s)
        return chars.count > 3 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    /// "Моя Программа 2" → "moa-programma-2"; unique among built-in and user recipes (except `keeping`).
    public static func makeID(for name: String, keeping: String? = nil) -> String {
        let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name)
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        var slug = ""
        var lastDash = false
        for scalar in latin.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar); lastDash = false
            } else if !lastDash && !slug.isEmpty {
                slug.append("-"); lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "app" }
        slug = String(slug.prefix(48))
        let taken = builtinIDs.union(all().map { $0.id.lowercased() }).subtracting([keeping?.lowercased()].compactMap { $0 })
        if !taken.contains(slug) { return slug }
        var n = 2
        while taken.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }

    // MARK: Writing

    /// Saves a recipe. An empty id gets one from the name. `installerFile` (or an absolute `installer.file`)
    /// is copied into Recipes/Files/<id>/ and the recipe then refers to it by name.
    @discardableResult
    public static func save(_ recipe: UserRecipe, installerFile: URL? = nil) throws -> UserRecipe {
        var r = recipe
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.spaceName = r.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.spaceName.isEmpty { r.spaceName = r.name }
        if r.id.isEmpty { r.id = makeID(for: r.name) }
        r.schemaVersion = UserRecipe.schemaVersion
        guard isValidID(r.id) else { throw OnwinError("Неверный идентификатор рецепта «\(r.id)»") }
        guard !builtinIDs.contains(r.id.lowercased()) else {
            throw OnwinError("Идентификатор «\(r.id)» занят встроенным рецептом каталога")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var source = installerFile
        if source == nil, let file = r.installer?.file, file.hasPrefix("/") { source = URL(fileURLWithPath: file) }
        if let source {
            guard OnwinPaths.exists(source), !OnwinPaths.isDirectory(source), UserRecipe.safeFileName(source.path) != nil else {
                throw OnwinError("Нет файла \(source.path)")
            }
            let dir = filesDirectory(for: r.id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(source.lastPathComponent)
            if source.standardizedFileURL.path != destination.standardizedFileURL.path {
                // Only one installer per recipe: drop an older one with another name.
                for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent != "icon.png" {
                    try? fm.removeItem(at: old)
                }
                try fm.copyItem(at: source, to: destination)
            }
            var installer = r.installer ?? UserRecipe.InstallerSource()
            installer.url = nil
            installer.sha256 = nil
            installer.file = source.lastPathComponent
            installer.fileName = nil
            r.installer = installer
        } else if let installer = r.installer, installer.url != nil {
            // Switched to a download: the copied local installer is no longer needed.
            r.installer?.file = nil
            let dir = filesDirectory(for: r.id)
            for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != "icon.png" {
                try? fm.removeItem(at: old)
            }
        }

        let previous = recipe.id.isEmpty ? nil : self.recipe(r.id)
        r.created = previous?.created ?? r.created ?? Date()
        r.modified = Date()
        try encode(r).write(to: fileURL(for: r.id), options: .atomic)
        invalidateCache()
        return r
    }

    /// Deletes the recipe and its copied files. Spaces installed from it stay.
    public static func remove(_ id: String) throws {
        guard let r = recipe(id) else { throw OnwinError("Нет рецепта «\(id)». Список: onwinctl recipe list") }
        let fm = FileManager.default
        try fm.removeItem(at: fileURL(for: r.id))
        try? fm.removeItem(at: filesDirectory(for: r.id))
        invalidateCache()
    }

    /// Stores an icon (PNG) shown on the recipe's card.
    public static func saveIcon(_ png: Data, for id: String) throws {
        let dir = filesDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("icon.png"), options: .atomic)
    }

    // MARK: Import / export

    /// Writes the recipe as a .onwinrecipe file (JSON). The installer is never embedded: a local installer
    /// is referenced by its file name only (`exportNote` says what the receiver must do).
    public static func export(_ id: String, to destination: URL) throws {
        guard var r = recipe(id) else { throw OnwinError("Нет рецепта «\(id)»") }
        if var installer = r.installer, installer.isLocalFile, let file = installer.file {
            installer.file = (file as NSString).lastPathComponent
            r.installer = installer
        }
        try encode(r).write(to: destination, options: .atomic)
    }

    /// Text for the user after exporting (nil when the recipe is self-contained).
    public static func exportNote(for recipe: UserRecipe) -> String? {
        guard let file = recipe.installer?.file, recipe.installer?.isLocalFile == true else { return nil }
        return "Установщик не встроен в рецепт: передайте вместе с файлом рецепта и «\((file as NSString).lastPathComponent)» " +
            "(положите их в одну папку — при импорте onwin заберёт установщик оттуда)."
    }

    /// Reads a .onwinrecipe file without saving it. A local installer lying next to the file is
    /// returned as `installerFile` (the caller copies it by saving).
    public static func read(_ file: URL) throws -> (recipe: UserRecipe, installerFile: URL?) {
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw OnwinError("Не удалось прочитать \(file.lastPathComponent): \(error.localizedDescription)")
        }
        var r = try decode(data)
        guard !r.name.isEmpty else { throw OnwinError("В рецепте \(file.lastPathComponent) нет названия программы") }
        var sibling: URL?
        if let installer = r.installer, installer.isLocalFile, let name = installer.file {
            // Only the file name counts, looked up next to the recipe file: an absolute path or "../x" in a
            // received recipe must not make onwin copy (and later run) some other file of this Mac.
            if let plain = UserRecipe.safeFileName(name) {
                let candidate = file.deletingLastPathComponent().appendingPathComponent(plain)
                if OnwinPaths.exists(candidate), !OnwinPaths.isDirectory(candidate),
                   ["exe", "msi", "bat", "cmd"].contains(candidate.pathExtension.lowercased()) {
                    sibling = candidate
                }
                r.installer?.file = plain
            } else {
                r.installer?.file = nil
            }
        }
        return (r, sibling)
    }

    /// Imports a .onwinrecipe (or recipe JSON) file: never installs or runs anything. The id is kept when
    /// free, otherwise a new one is made (a built-in id is never taken over).
    @discardableResult
    public static func importFile(_ file: URL, replace: Bool = false) throws -> UserRecipe {
        var (r, installerFile) = try read(file)
        let free = isValidID(r.id) && !builtinIDs.contains(r.id.lowercased()) && (replace || recipe(r.id) == nil)
        if !free { r.id = makeID(for: r.name) }
        return try save(r, installerFile: installerFile)
    }

    // MARK: Installer files

    /// The installer file a recipe runs: a local file as is; a user recipe's download goes to the cache under a
    /// name unique to the recipe and URL and is checked against its SHA-256; built-in recipes use `Downloader`.
    public static func installerFile(for step: Component.Step, recipe: AppRecipe,
                                     progress: @escaping ProgressHandler) async throws -> URL {
        if step.url.isFileURL {
            guard FileManager.default.fileExists(atPath: step.url.path) else {
                throw OnwinError("Нет файла установщика \(step.url.lastPathComponent). Откройте рецепт «\(recipe.name)» " +
                                 "в каталоге («Мои приложения» → «Изменить») и выберите файл заново.")
            }
            return step.url
        }
        guard recipe.category == .user, let user = self.recipe(recipe.id), step == recipe.installer else {
            return try await Downloader.fetch(step.url, fileName: step.fileName, progress: progress)
        }
        guard step.url.scheme?.lowercased() == "https" else {
            throw OnwinError("Установщик рецепта «\(recipe.name)» можно скачивать только по https://")
        }
        let digest = SHA256.hash(data: Data(step.url.absoluteString.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let cacheName = "user-\(user.id)-\(digest)-\(step.fileName)"
        let expected = user.installer?.sha256
        var file = try await Downloader.fetch(step.url, fileName: cacheName, progress: progress)
        if let expected {
            var actual = try sha256(of: file)
            if actual != expected {
                // A stale or broken cached copy: download once more before giving up.
                try? FileManager.default.removeItem(at: file)
                file = try await Downloader.fetch(step.url, fileName: cacheName, progress: progress)
                actual = try sha256(of: file)
            }
            guard actual == expected else {
                try? FileManager.default.removeItem(at: file)
                throw OnwinError("Контрольная сумма \(step.fileName) не совпадает с рецептом.\nОжидалось: \(expected)\nПолучено: \(actual)\n" +
                                 "Издатель мог обновить файл — проверьте ссылку и обновите SHA-256 в рецепте.")
            }
            progress(InstallProgress(message: "SHA-256 \(step.fileName) совпадает", fraction: nil))
        }
        return file
    }

    /// SHA-256 of a file, lower-case hex.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension Catalog {
    /// Built-in recipes followed by the user's own ("Мои приложения").
    public static var apps: [AppRecipe] { builtinApps + UserRecipes.appRecipes() }
}
