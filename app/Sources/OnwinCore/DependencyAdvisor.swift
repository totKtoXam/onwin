import Foundation

/// "This game may need …": a component (or a hint without one) with the reason and the evidence.
public struct Suggestion: Identifiable, Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// From the import tables of the game's files, before it ever ran.
        case imports
        /// From the Wine log of a run that failed.
        case log
    }

    /// Catalog component id; nil for a hint that has no installable component.
    public var componentID: String?
    public var title: String
    /// Russian, one sentence.
    public var reason: String
    /// What we saw: "Game.exe → d3dx9_43.dll", a log line...
    public var evidence: [String]
    public var source: Source
    /// Higher first. 3 = the program cannot start without it, 2 = likely needed, 1 = may help.
    public var priority: Int

    public var id: String { componentID ?? "hint:\(title)" }
    public var component: Component? { componentID.flatMap(Catalog.component) }

    public init(componentID: String?, title: String, reason: String, evidence: [String], source: Source, priority: Int) {
        self.componentID = componentID; self.title = title; self.reason = reason
        self.evidence = evidence; self.source = source; self.priority = priority
    }
}

/// Finds which catalog components a Windows program needs.
///
/// Static analysis reads the PE import tables (regular + delay-load) of the program and, shallowly,
/// of the other .exe/.dll files in its folder, and maps imported DLL names to components
/// (`Component.satisfiesImports`). DLLs the game ships next to itself and native (non-Wine) copies
/// already in the space are ignored. Dynamic analysis reads the Wine log of a finished run.
/// Components already installed in the space (`config.installedComponents`) are skipped.
public enum DependencyAdvisor {
    public struct Limits: Sendable {
        public var maxFiles = 48
        public var maxDepth = 2
        public var maxFileBytes = 256 * 1024 * 1024
        public init() {}
    }

    // MARK: Static (imports)

    /// Suggestions for a program file (an .exe, or a .lnk resolved by the caller). `space` is used
    /// to skip installed components and DLLs already present; nil analyses the file on its own.
    /// `wineDLLDirectories` (Wine's builtin PE directories, e.g. `lib/wine/x86_64-windows`) enables the
    /// "unknown library" hint for imports neither the game, the space, Wine nor the catalog provide;
    /// by default they come from the space's engine.
    public static func analyze(executable: URL, space: Space?, scanFolder: Bool = true,
                               wineDLLDirectories: [URL]? = nil,
                               limits: Limits = Limits()) -> [Suggestion] {
        let exe = executable.standardizedFileURL.resolvingSymlinksInPath()
        guard let main = PEImage.read(exe) else { return [] }
        let folder = exe.deletingLastPathComponent()
        let builtinDirs = wineDLLDirectories ?? space.flatMap { try? EngineManager.engine(for: $0.config) }
            .map { [$0.wineLib.appendingPathComponent("x86_64-windows"), $0.wineLib.appendingPathComponent("i386-windows")] } ?? []
        let builtins = Set(builtinDirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { Catalog.normalizedDLLName($0) }
        })

        // DLL names present next to the game (any case), and in its subfolders when scanning.
        var files: [URL] = [exe]
        var shipped = Set<String>()
        let exePath = exe.path
        for url in listFolder(folder, depth: scanFolder ? limits.maxDepth : 0) {
            let lower = url.lastPathComponent.lowercased()
            if lower.hasSuffix(".dll") { shipped.insert(Catalog.normalizedDLLName(lower)) }
            if scanFolder, files.count < limits.maxFiles, url.standardizedFileURL.resolvingSymlinksInPath().path != exePath,
               lower.hasSuffix(".exe") || lower.hasSuffix(".dll"),
               !isInstallerOrTool(lower), fileSize(url) <= limits.maxFileBytes {
                files.append(url)
            }
        }

        var findings: [String: (dlls: Set<String>, evidence: [String])] = [:]   // component id → ...
        var hints: [String: [String]] = [:]
        var dotNetEvidence: [String] = []
        for file in files {
            guard let image = file == exe ? main : PEImage.read(file) else { continue }
            let label = relativeName(file, to: folder)
            // Only a .NET *program* (or a mixed C++/CLI DLL) needs a .NET runtime in the space: pure
            // IL DLLs next to a native exe (Unity's <Game>_Data/Managed/*.dll) run on the engine's own Mono.
            let needsCLR = image.isDotNet && (!image.isDLL || !image.isILOnly)
            if needsCLR { dotNetEvidence.append("\(label) — сборка .NET") }
            for dll in image.allImports {
                let name = Catalog.normalizedDLLName(dll)
                if name.hasPrefix("api-ms-win-") || name.hasPrefix("ext-ms-") { continue }
                if shipped.contains(name) { continue }
                if let space, hasNativeCopy(name, is64: image.is64Bit, in: space) { continue }
                let delayed = image.delayImports.contains(dll) && !image.imports.contains(dll)
                let line = "\(label) → \(name).dll" + (delayed ? " (отложенная загрузка)" : "")
                if name == "mscoree" { if needsCLR { dotNetEvidence.append(line) }; continue }
                guard let component = Catalog.components(satisfying: name).first else {
                    if let hint = staticHint(for: name) {
                        hints[hint, default: []].append(line)
                    } else if !builtins.isEmpty, !builtins.contains(name), !name.hasPrefix("steam") {
                        hints["Отсутствующие DLL", default: []].append(line)
                    }
                    continue
                }
                findings[component.id, default: ([], [])].dlls.insert(name)
                if findings[component.id]!.evidence.count < 6 { findings[component.id]!.evidence.append(line) }
            }
        }

        var result: [Suggestion] = []
        for (id, finding) in findings {
            guard let component = Catalog.component(id) else { continue }
            if let s = staticSuggestion(component, dlls: finding.dlls, evidence: finding.evidence, mainIs64: main.is64Bit) {
                result.append(s)
            }
        }
        if !dotNetEvidence.isEmpty,
           let s = dotNetSuggestion(evidence: Array(dotNetEvidence.prefix(6)), source: .imports, space: space) {
            result.append(s)
        }
        for (title, evidence) in hints {
            result.append(Suggestion(componentID: nil, title: title, reason: hintReason(title),
                                     evidence: Array(evidence.prefix(6)), source: .imports, priority: 1))
        }
        return finalize(result, space: space)
    }

    private static func staticSuggestion(_ c: Component, dlls: Set<String>, evidence: [String], mainIs64: Bool) -> Suggestion? {
        let list = dlls.sorted().map { $0 + ".dll" }.prefix(4).joined(separator: ", ")
        switch c.id {
        case Catalog.d3dmetalID:
            return Suggestion(componentID: c.id, title: c.name,
                              reason: "Игра использует DirectX 12 (\(list)) — лучше всего его переводит в Metal D3DMetal от Apple.",
                              evidence: evidence, source: .imports, priority: 2)
        case "directx-jun2010":
            return Suggestion(componentID: c.id, title: c.name,
                              reason: "Игре нужны библиотеки старого DirectX (\(list)). В Wine есть свои замены, но с оригинальными игры работают надёжнее.",
                              evidence: evidence, source: .imports, priority: 2)
        case "physx":
            return Suggestion(componentID: c.id, title: c.name,
                              reason: "Игра загружает NVIDIA PhysX (\(list)), а рядом с ней этих файлов нет.",
                              evidence: evidence, source: .imports, priority: 3)
        case "wine-gecko":
            return Suggestion(componentID: c.id, title: c.name,
                              reason: "Программа показывает веб-страницы через \(list) — без Wine Gecko эти окна будут пустыми.",
                              evidence: evidence, source: .imports, priority: 1)
        case "d3dcompiler_47":
            return Suggestion(componentID: c.id, title: c.name,
                              reason: "Игра компилирует шейдеры через \(list). Оригинальный компилятор Microsoft справляется со всеми шейдерами, встроенный в Wine — не всегда.",
                              evidence: evidence, source: .imports, priority: 1)
        default:
            let reason: String
            if c.category == .runtimes {
                reason = "Программе нужны библиотеки \(c.name): \(list). Встроенные замены Wine неполные — лучше поставить оригинальные."
            } else {
                reason = "Программа использует \(list) из пакета \(c.name)."
            }
            return Suggestion(componentID: c.id, title: c.name, reason: reason, evidence: evidence, source: .imports,
                              priority: c.category == .runtimes ? 2 : 1)
        }
    }

    /// .NET programs: Wine Mono first; after a failed run with Mono installed, the real .NET 4.8.
    /// nil when the space already has what we would suggest.
    private static func dotNetSuggestion(evidence: [String], source: Suggestion.Source, space: Space?) -> Suggestion? {
        let config = space?.config
        let hasReal = config.map { Catalog.component("dotnet48")?.isInstalled(in: $0) ?? false } ?? false
        let hasMono = config.map { Catalog.component("wine-mono")?.isInstalled(in: $0) ?? false } ?? false
        if hasReal { return nil }
        if hasMono {
            guard source == .log else { return nil }
            return Suggestion(componentID: "dotnet48", title: Catalog.component("dotnet48")?.name ?? ".NET Framework 4.8",
                              reason: "Программе на .NET не хватило Wine Mono — попробуйте настоящий .NET Framework 4.8.",
                              evidence: evidence, source: source, priority: 2)
        }
        return Suggestion(componentID: "wine-mono", title: Catalog.component("wine-mono")?.name ?? "Wine Mono",
                          reason: "Это программа на .NET: ей нужна среда .NET. Начните с Wine Mono; если не хватит — .NET Framework 4.8.",
                          evidence: evidence, source: source, priority: 3)
    }

    /// Imports without a component that are still worth telling about.
    private static func staticHint(for dll: String) -> String? {
        if dll.hasPrefix("steam_api") { return "Steam" }
        if dll == "nvapi" || dll == "nvapi64" { return "NVIDIA NVAPI" }
        if dll.hasPrefix("eossdk") { return "Epic Online Services" }
        return nil
    }

    private static func hintReason(_ title: String) -> String {
        switch title {
        case "Steam": return "Игра ищет Steam (steam_api.dll не рядом с ней): запускайте её через Steam в этом пространстве."
        case "NVIDIA NVAPI": return "Игра обращается к NVAPI видеокарт NVIDIA — в Mac его нет, обычно это не мешает (включите D3DMetal для DLSS → MetalFX)."
        case "Epic Online Services": return "Игре нужен Epic Games Launcher: установите его из каталога в это пространство."
        case "Отсутствующие DLL": return "Этих DLL нет ни рядом с игрой, ни в Wine. Проверьте, что игра установлена полностью."
        default: return title
        }
    }

    // MARK: Dynamic (Wine log)

    public static func analyze(log url: URL, space: Space?) -> [Suggestion] {
        guard let text = readTail(url, maxBytes: 4 * 1_048_576) else { return [] }
        return analyze(logText: text, space: space)
    }

    public static func analyze(logText text: String, space: Space?) -> [Suggestion] {
        var byComponent: [String: [String]] = [:]
        var missingByComponent: [String: [String]] = [:]
        var hints: [String: [String]] = [:]
        var dotNet: [String] = []
        var seenLines = Set<String>()

        func add(_ id: String, _ line: String) {
            if byComponent[id, default: []].count < 6 { byComponent[id, default: []].append(line) }
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count < 2000, seenLines.insert(line).inserted else { continue }
            let lower = line.lowercased()

            // err:module:import_dll Library d3dx9_43.dll (which is needed by L"C:\\Game\\game.exe") not found
            if lower.contains("import_dll") || lower.contains("library") && lower.contains("not found") {
                if let dll = firstDLL(in: line, after: "Library ") {
                    let name = Catalog.normalizedDLLName(dll)
                    if name == "mscoree" { dotNet.append(shorten(line)); continue }
                    if let c = Catalog.components(satisfying: name).first {
                        add(c.id, shorten(line))
                        if !missingByComponent[c.id, default: []].contains(name) { missingByComponent[c.id, default: []].append(name) }
                    }
                    else if !name.hasPrefix("api-ms-") { hints["Отсутствующие DLL", default: []].append(shorten(line)) }
                    continue
                }
            }
            // err:module:LdrInitializeThunk Importing dlls for L"..." failed — reported via the lines above.
            if lower.contains("fixup_imports_ilonly") || lower.contains("mscoree") && (lower.contains("err:") || lower.contains("not found")) ||
                lower.contains("wine mono is not installed") || lower.contains("could not load wine mono") ||
                lower.contains("cannot find .net") || lower.contains("this application requires one of the following versions of the .net framework") {
                dotNet.append(shorten(line))
                continue
            }
            if lower.contains("could not load wine-gecko") || lower.contains("could not find wine gecko") {
                add("wine-gecko", shorten(line))
                continue
            }
            if lower.contains("d3d12") && (lower.contains("failed to create") || lower.contains("not supported") ||
                                           lower.contains("d3d12createdevice") && lower.contains("fail")) {
                add(Catalog.d3dmetalID, shorten(line))
                continue
            }
            if lower.contains("err:d3dcompiler") {
                add("d3dcompiler_47", shorten(line))
                continue
            }
            if lower.contains("unhandled page fault") || lower.contains("unhandled exception") {
                if hints["Сбой программы", default: []].count < 3 { hints["Сбой программы", default: []].append(shorten(line)) }
            }
        }

        var result: [Suggestion] = []
        for (id, evidence) in byComponent {
            guard let c = Catalog.component(id) else { continue }
            let reason: String
            switch id {
            case Catalog.d3dmetalID: reason = "Игра не смогла создать устройство DirectX 12 — установите D3DMetal."
            case "wine-gecko": reason = "Программа пыталась показать веб-страницу, но Wine Gecko не установлен."
            case "d3dcompiler_47": reason = "Ошибка компиляции шейдеров — оригинальный d3dcompiler_47 часто это исправляет."
            default:
                let missing = (missingByComponent[id] ?? []).prefix(4).map { $0 + ".dll" }
                let names = missing.joined(separator: ", ")
                reason = names.isEmpty
                    ? "Программа не запустилась: не нашлась библиотека из пакета \(c.name)."
                    : "Программа не запустилась: нет \(names) — \(missing.count == 1 ? "эта библиотека входит" : "эти библиотеки входят") в \(c.name)."
            }
            result.append(Suggestion(componentID: id, title: c.name, reason: reason, evidence: evidence, source: .log, priority: 3))
        }
        if !dotNet.isEmpty, let s = dotNetSuggestion(evidence: Array(dotNet.prefix(6)), source: .log, space: space) {
            result.append(s)
        }
        for (title, evidence) in hints {
            let reason = title == "Сбой программы"
                ? "Программа упала (Unhandled page fault / exception). Попробуйте другой графический режим в настройках пространства или включите журнал отладки."
                : hintReason(title)
            result.append(Suggestion(componentID: nil, title: title, reason: reason,
                                     evidence: Array(evidence.prefix(6)), source: .log, priority: title == "Сбой программы" ? 1 : 2))
        }
        return finalize(result, space: space)
    }

    // MARK: Helpers

    /// Drops installed components and duplicates; sorts by priority, then name.
    static func finalize(_ list: [Suggestion], space: Space?) -> [Suggestion] {
        var seen = Set<String>()
        return list
            .filter { s in
                guard let c = s.component else { return true }
                if c.kind == .global { return !GraphicsSupport.isD3DMetalInstalled }
                guard let space else { return true }
                if c.isInstalled(in: space.config) { return false }
                // Real .NET installed: never suggest Mono.
                if c.id == "wine-mono", Catalog.component("dotnet48")?.isInstalled(in: space.config) == true { return false }
                return true
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.title < $1.title }
    }

    /// A non-Wine copy of the DLL already sits in the space's system directory for that bitness.
    static func hasNativeCopy(_ name: String, is64: Bool, in space: Space) -> Bool {
        guard let dir = ComponentInstaller.directory(for: is64 ? .dll64 : .dll32, in: space) else { return false }
        let file = dir.appendingPathComponent(name + ".dll")
        guard OnwinPaths.exists(file) else { return false }
        return !PEImage.isWineBuiltin(file)
    }

    static func listFolder(_ folder: URL, depth: Int) -> [URL] {
        var result: [URL] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        while let (dir, level) = queue.first, result.count < 4000 {
            queue.removeFirst()
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if level < depth { queue.append((entry, level + 1)) }
                } else {
                    result.append(entry)
                }
            }
        }
        return result
    }

    /// Redistributable installers and crash reporters next to games import all kinds of things.
    static func isInstallerOrTool(_ lowerName: String) -> Bool {
        ["unins", "setup", "vcredist", "vc_redist", "dxsetup", "dotnet", "ndp4", "crashreport", "crashpad",
         "uninstall", "redist", "installer", "updater"].contains { lowerName.contains($0) }
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func relativeName(_ file: URL, to folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
    }

    /// First "<something>.dll" token after `marker` (or anywhere in the line).
    static func firstDLL(in line: String, after marker: String) -> String? {
        let tail: Substring
        if let r = line.range(of: marker, options: .caseInsensitive) { tail = line[r.upperBound...] } else { tail = Substring(line) }
        let separators = CharacterSet(charactersIn: " \t\"'()[],;:")
        for token in tail.components(separatedBy: separators) where token.lowercased().hasSuffix(".dll") {
            let name = token.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? token
            if !name.isEmpty { return name }
        }
        return nil
    }

    static func shorten(_ line: String) -> String {
        // Drop the "0024:" thread prefix Wine puts in front of every line.
        var s = line
        if let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) == 4,
           s[..<colon].allSatisfy(\.isHexDigit) {
            s = String(s[s.index(after: colon)...])
        }
        return s.count > 220 ? String(s.prefix(220)) + "…" : s
    }

    static func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
