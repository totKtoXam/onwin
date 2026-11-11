import CryptoKit
import Foundation

// MARK: - Verified downloads

extension Downloader {
    /// Downloads (or reuses from the cache) a component file and verifies it. A cached file that
    /// fails verification is downloaded again once.
    public static func fetch(_ download: Component.Download, progress: @escaping ProgressHandler) async throws -> URL {
        let file = try await fetch(download.url, fileName: download.fileName, progress: progress)
        guard let problem = verify(file, download.verification) else { return file }
        progress(.status("\(download.fileName): \(problem) — скачиваю заново…"))
        try? FileManager.default.removeItem(at: file)
        let again = try await fetch(download.url, fileName: download.fileName, progress: progress)
        if let second = verify(again, download.verification) {
            try? FileManager.default.removeItem(at: again)
            throw OnwinError("Файл \(download.fileName) с \(download.url.host ?? download.url.absoluteString) не прошёл проверку: \(second)")
        }
        return again
    }

    /// nil when the file is fine, otherwise a Russian description of the problem.
    public static func verify(_ file: URL, _ verification: Component.Download.Verification) -> String? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "файл пустой" }
        switch verification {
        case .sha256(let expected):
            guard let actual = try? sha256(of: file) else { return "не удалось прочитать файл" }
            return actual == expected.lowercased() ? nil : "SHA-256 \(actual) вместо \(expected)"
        case .portableExecutable:
            return isPortableExecutable(file) ? nil : "это не программа Windows (нет заголовка PE)"
        case .cabinet:
            return header(of: file, count: 4) == Data("MSCF".utf8) ? nil : "это не архив CAB (нет заголовка MSCF)"
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func header(of file: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    static func isPortableExecutable(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 0x40), dos.count == 0x40, dos[0] == 0x4D, dos[1] == 0x5A else { return false }
        let lfanew = UInt64(dos[0x3C]) | UInt64(dos[0x3D]) << 8 | UInt64(dos[0x3E]) << 16 | UInt64(dos[0x3F]) << 24
        guard lfanew < 64 * 1024, (try? handle.seek(toOffset: lfanew)) != nil,
              let sig = try? handle.read(upToCount: 4) else { return false }
        return sig == Data([0x50, 0x45, 0, 0])
    }
}

// MARK: - Installer

/// Executes a component's actions in a space (onwin's counterpart of a winetricks verb).
public enum ComponentInstaller {
    /// Installs `component` and, first, the components it requires. Returns the updated space
    /// (config re-read from disk, then `installedComponents` and `dllOverrides` updated and saved).
    public static func install(_ component: Component, into space: Space,
                               progress: @escaping ProgressHandler) async throws -> Space {
        var chain = Set<String>()
        return try await install(component, into: space, progress: progress, chain: &chain)
    }

    private static func install(_ component: Component, into start: Space, progress: @escaping ProgressHandler,
                                chain: inout Set<String>) async throws -> Space {
        if component.kind == .global {
            throw OnwinError("\(component.name) ставится один раз для всех пространств: используйте «Установить D3DMetal» " +
                             "в каталоге onwin или onwinctl d3dmetal-fetch.")
        }
        guard start.isInitialized else { throw OnwinError("Пространство «\(start.name)» ещё не готово (нет system.reg).") }
        guard chain.insert(component.id).inserted else { return start }

        var space = start
        for requirement in component.requires {
            guard let required = Catalog.component(requirement), !required.isInstalled(in: space.config) else { continue }
            progress(.status("Для \(component.name) нужен \(required.name) — ставлю его первым"))
            space = try await install(required, into: space, progress: progress, chain: &chain)
        }

        // Wine Mono / Gecko: added once to the engine and shared by every space (EngineAddons.swift)
        // instead of the per-space .msi. The space registers them at its next start (prefix update).
        if let addons = EngineAddons.addons(forComponent: component.id),
           let engine = try? EngineManager.engine(for: space.config),
           EngineAddons.missing(addons, in: engine).isEmpty || EngineAddons.canInstall(into: engine) {
            try await EngineAddons.install(addons, into: engine, progress: progress)
            return try markInstalled(component, in: space, progress: progress)
        }

        // 1. Downloads.
        var files: [String: URL] = [:]
        for (index, download) in component.downloads.enumerated() {
            try Task.checkCancellation()
            if component.downloads.count > 1 {
                progress(.status("\(component.name): файл \(index + 1) из \(component.downloads.count)"))
            }
            files[download.fileName] = try await Downloader.fetch(download, progress: progress)
        }

        // 2. Actions.
        let runner: WineRunner? = try WineRunner(space: space)
        let work = OnwinPaths.cache.appendingPathComponent("Work/\(component.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var context = Context(component: component, space: space, runner: runner, files: files, work: work, progress: progress)
        do {
            for (index, action) in component.actions.enumerated() {
                try Task.checkCancellation()
                progress(InstallProgress(message: "", fraction: Double(index) / Double(max(component.actions.count, 1))))
                try await context.perform(action)
            }
        } catch {
            if context.changedWindowsVersion { try? await context.perform(.restoreWindowsVersion) }
            throw error
        }

        // 3. Config.
        return try markInstalled(component, in: space, progress: progress)
    }

    /// Records the component in the space's config (re-read from disk first) with its DLL overrides.
    private static func markInstalled(_ component: Component, in start: Space, progress: ProgressHandler) throws -> Space {
        var space = start
        if let fresh = try? Space(url: space.url) { space = fresh }
        for (dll, mode) in component.dllOverrides { space.config.dllOverrides[dll] = mode }
        let superseded = Set(component.replaces + component.legacyIDs)
        space.config.installedComponents.removeAll { superseded.contains($0) }
        if !space.config.installedComponents.contains(component.id) {
            space.config.installedComponents.append(component.id)
        }
        try space.save()
        progress(InstallProgress(message: "\(component.name) установлен", fraction: 1))
        return space
    }

    /// The space directory a destination maps to; nil for 64-bit files in a 32-bit space.
    public static func directory(for destination: Component.Destination, in space: Space) -> URL? {
        let is64 = OnwinPaths.isDirectory(space.syswow64)
        switch destination {
        case .dll64: return is64 ? space.system32 : nil
        case .dll32: return is64 ? space.syswow64 : space.system32
        case .fonts: return space.driveC.appendingPathComponent("windows/Fonts", isDirectory: true)
        }
    }

    // MARK: Action execution

    /// Downloads a component's files and runs only its extraction steps into `directory`
    /// (`system32/`, `syswow64/`, `Fonts/` are created there). No Wine needed: used to check a
    /// catalog entry (`onwinctl component-files`) and by tests. Returns the files written.
    public static func extractFiles(of component: Component, into directory: URL,
                                    progress: @escaping ProgressHandler) async throws -> [URL] {
        var files: [String: URL] = [:]
        for download in component.downloads {
            files[download.fileName] = try await Downloader.fetch(download, progress: progress)
        }
        let fm = FileManager.default
        let fake = directory.appendingPathComponent("prefix", isDirectory: true)
        let windows = fake.appendingPathComponent("drive_c/windows", isDirectory: true)
        for sub in ["system32", "syswow64", "Fonts"] {
            try fm.createDirectory(at: windows.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let space = Space(url: fake, config: SpaceConfig(name: "extract"))
        let work = directory.appendingPathComponent(".work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let context = Context(component: component, space: space, runner: nil, files: files, work: work, progress: progress)
        var written: [URL] = []
        for case .extract(let extraction) in component.actions {
            written += try await context.extract(extraction)
        }
        return written
    }

    private struct Context {
        let component: Component
        let space: Space
        let runnerIfAny: WineRunner?
        let files: [String: URL]
        let work: URL
        let progress: ProgressHandler
        var changedWindowsVersion = false

        init(component: Component, space: Space, runner: WineRunner?, files: [String: URL], work: URL,
             progress: @escaping ProgressHandler) {
            self.component = component; self.space = space; self.runnerIfAny = runner
            self.files = files; self.work = work; self.progress = progress
        }

        var runner: WineRunner {
            get throws {
                guard let r = runnerIfAny else { throw OnwinError("Для этого шага нужен Wine") }
                return r
            }
        }

        func file(_ name: String) throws -> URL {
            guard let url = files[name] else { throw OnwinError("Внутренняя ошибка каталога: нет файла \(name) в \(component.id)") }
            return url
        }

        mutating func perform(_ action: Component.Action) async throws {
            switch action {
            case .run(let name, let arguments, let overrides):
                let file = try file(name)
                progress(.status("Устанавливаю \(component.name): \(file.lastPathComponent)…"))
                let runner = try runner
                let r = try await runner.runAndWait(WineRunner.command(for: file, arguments: arguments),
                                                    extraOverrides: overrides,
                                                    currentDirectory: file.deletingLastPathComponent())
                try await runner.waitForServer()
                // Redistributables return 3010 ("reboot required") or 1638 ("a newer version is installed").
                if !([0, 3010, 1638] as [Int32]).contains(where: { WineRunner.exitStatus(r.status, matches: $0) }) {
                    throw OnwinError("Установщик \(file.lastPathComponent) завершился с кодом \(r.status)\n\(r.output.suffix(1500))")
                }

            case .extract(let extraction):
                let copied = try await extract(extraction)
                if !copied.isEmpty {
                    progress(.status("Скопировано: " + copied.map(\.lastPathComponent).joined(separator: ", ")))
                }

            case .registry(let values):
                var reg = RegFile()
                for v in values {
                    switch v.value {
                    case .string(let s): reg = reg.set(v.key, v.name, .string(s))
                    case .dword(let d): reg = reg.set(v.key, v.name, .dword(d))
                    }
                }
                progress(.status("Записываю настройки \(component.name) в реестр…"))
                try await Registry.importReg(reg, runner: try runner)

            case .registerFonts(let fonts):
                guard let dir = ComponentInstaller.directory(for: .fonts, in: space) else { return }
                var reg = RegFile()
                for font in fonts where OnwinPaths.exists(dir.appendingPathComponent(font.file)) {
                    let name = font.file.lowercased().hasSuffix(".ttf") || font.file.lowercased().hasSuffix(".ttc")
                        ? "\(font.name) (TrueType)" : font.name
                    reg = reg.set(#"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#, name, .string(font.file))
                    reg = reg.set(#"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Fonts"#, name, .string(font.file))
                }
                progress(.status("Регистрирую шрифты…"))
                try await Registry.importReg(reg, runner: try runner)

            case .registerServers(let patterns, let destination):
                guard let dir = ComponentInstaller.directory(for: destination, in: space) else { return }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { name in patterns.contains { Glob.matches($0, name) } }
                    .filter { !PEImage.isWineBuiltin(dir.appendingPathComponent($0)) }
                    .sorted()
                let tool = destination == .dll32 && OnwinPaths.isDirectory(space.syswow64)
                    ? #"C:\windows\syswow64\regsvr32.exe"# : "regsvr32"
                let runner = try runner
                for name in names {
                    try Task.checkCancellation()
                    progress(.status("regsvr32 \(name)"))
                    // The component's overrides reach the space config only after all actions:
                    // without them regsvr32 would load (and register) Wine's builtin instead.
                    let r = try await runner.runAndWait([tool, "/s", name], extraOverrides: component.dllOverrides)
                    if r.status != 0 { progress(.status("regsvr32 \(name) вернул \(r.status) — пропускаю")) }
                }
                try await runner.waitForServer()

            case .removeWineMono:
                try await removeWineMono()

            case .setWindowsVersion(let version):
                progress(.status("Временно включаю \(version.displayName) для установщика…"))
                let runner = try runner
                _ = try await runner.runAndWait(["winecfg", "-v", version.winecfgName])
                try await runner.waitForServer()
                changedWindowsVersion = true

            case .restoreWindowsVersion:
                let version = ((try? Space(url: space.url))?.config ?? space.config).windowsVersion
                progress(.status("Возвращаю \(version.displayName)…"))
                let runner = try runner
                _ = try await runner.runAndWait(["winecfg", "-v", version.winecfgName])
                try await runner.waitForServer()
                changedWindowsVersion = false
            }
        }

        /// cabextract stage 1 (optional): cabinets inside the archive; stage 2: the wanted files.
        func extract(_ e: Component.Extraction) async throws -> [URL] {
            let cabextract = try HostTools.requireCabextract()
            let source = try file(e.source)
            guard let destination = ComponentInstaller.directory(for: e.destination, in: space) else {
                progress(.status("32-битное пространство: 64-битные файлы из \(e.source) пропущены"))
                return []
            }
            let fm = FileManager.default
            let stage = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }

            progress(.status("Распаковываю \(e.files.joined(separator: ", ")) из \(source.lastPathComponent)…"))
            var archives = [source]
            if !e.cabinets.isEmpty {
                let outer = stage.appendingPathComponent("outer", isDirectory: true)
                for pattern in e.cabinets {
                    _ = try await ComponentInstaller.cabextract(cabextract, ["-q", "-L", "-d", outer.path, "-F", pattern, source.path])
                }
                archives = ComponentInstaller.regularFiles(under: outer)
            }
            let inner = stage.appendingPathComponent("inner", isDirectory: true)
            for (index, archive) in archives.enumerated() {
                try Task.checkCancellation()
                let out = inner.appendingPathComponent("\(index)", isDirectory: true)
                for pattern in e.files {
                    // Non-cabinet payloads simply fail here; that is expected.
                    _ = try await ComponentInstaller.cabextract(cabextract, ["-q", "-L", "-d", out.path, "-F", pattern, archive.path])
                }
            }
            let found = ComponentInstaller.regularFiles(under: inner).filter { file in
                e.files.contains { Glob.matches($0, file.lastPathComponent) }
            }
            if found.isEmpty {
                if e.optional { return [] }
                throw OnwinError("В \(source.lastPathComponent) не нашлось \(e.files.joined(separator: ", ")). " +
                                 "Возможно, Microsoft изменила содержимое архива.")
            }

            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            var copied: [URL] = []
            for file in found.sorted(by: { $0.path < $1.path }) {
                var name = file.lastPathComponent.lowercased()
                if let renamed = e.renames[name] {
                    name = renamed
                } else if let suffix = e.stripSuffixes.first(where: { name.hasSuffix($0) }) {
                    name.removeLast(suffix.count)
                }
                if e.destination != .fonts && name.hasSuffix(".dll") {
                    let expected: PEImage.Machine = e.destination == .dll64 ? .amd64 : .i386
                    guard let image = PEImage.read(file), image.machine == expected else {
                        throw OnwinError("\(name) из \(source.lastPathComponent) не того типа (ожидалась \(expected.displayName))")
                    }
                }
                let target = destination.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: file, to: target)
                copied.append(target)
            }
            return copied
        }

        /// Same as winetricks remove_mono: uninstall every "Wine Mono*" entry, drop the .NET setup keys
        /// it registered and Mono's own mscoree.dll.
        func removeWineMono() async throws {
            let runner = try runner
            let list = try await runner.runAndWait(["uninstaller", "--list"])
            var found = false
            for line in list.output.split(whereSeparator: \.isNewline) where line.contains("Wine Mono") {
                guard let guid = line.split(separator: "|").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                      guid.hasPrefix("{") else { continue }
                progress(.status("Удаляю \(line.split(separator: "|").last.map(String.init) ?? "Wine Mono")…"))
                _ = try await runner.runAndWait(["uninstaller", "--remove", guid])
                found = true
            }
            try await runner.waitForServer()
            guard found else { return }
            for key in [#"HKLM\Software\Microsoft\NET Framework Setup\NDP\v3.5"#, #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4"#] {
                _ = try await runner.runAndWait(["reg", "delete", key, "/f"])
            }
            for dir in [space.system32, space.syswow64] {
                let dll = dir.appendingPathComponent("mscoree.dll")
                if let data = try? Data(contentsOf: dll, options: .mappedIfSafe),
                   data.range(of: Data("WINE_MONO_OVERRIDES".utf8)) != nil {
                    try? FileManager.default.removeItem(at: dll)
                }
            }
            try await runner.waitForServer()
        }
    }

    static func regularFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result.append(url)
        }
        return result
    }

    /// Runs cabextract without a pipe (stderr goes to a temp file, so a chatty archive cannot block us)
    /// and without ProcessRunner's drain delay — component installs run it dozens of times.
    static func cabextract(_ tool: URL, _ arguments: [String]) async throws -> (status: Int32, errors: String) {
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("onwin-cabextract-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        let errHandle = try FileHandle(forWritingTo: errFile)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errHandle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try? errHandle.close()
        let errors = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return (status, errors)
    }
}
