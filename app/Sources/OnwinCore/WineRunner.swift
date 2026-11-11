import Foundation

/// Builds the Wine environment for a space and starts Windows programs in it.
public struct WineRunner: Sendable {
    public let space: Space
    public let engine: Engine

    /// drive_c once the prefix exists, the space folder before wineboot has created it.
    var defaultDirectory: URL { OnwinPaths.isDirectory(space.driveC) ? space.driveC : space.url }

    public init(space: Space, engine: Engine? = nil) throws {
        self.space = space
        self.engine = try engine ?? EngineManager.engine(for: space.config)
    }

    // MARK: Environment

    /// Variables from the parent environment that must not leak into Wine.
    /// ROSETTA_: a ROSETTA_ADVERTISE_AVX inherited by onwin would turn AVX on in spaces that disable it.
    private static let scrubbedPrefixes = ["WINE", "DYLD_", "ONWIN_DLL", "ONWIN_BACKEND", "ONWIN_COMPAT_RULES",
                                           "ONWIN_COMPAT_ORIG", "CX_", "DXVK_", "D3DM_", "DXMT_", "MTL_HUD",
                                           "ROSETTA_", "PYTHONPATH"]

    public func environment(extraOverrides: [String: String] = [:], extraEnvironment: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !WineRunner.scrubbedPrefixes.contains(where: { key.hasPrefix($0) })
        }
        let config = space.config

        env["WINEPREFIX"] = space.url.path
        env["WINESERVER"] = engine.wineserver.path
        env["WINELOADER"] = engine.wine.path
        // With WINEDLLPATH set, CW HACK 22144 (dlls/ntdll/unix/loader.c) runs each
        // program through a link named after it, so the Dock shows the program instead of "wine".
        let wineLib = engine.wineLib.path
        env["WINEDLLPATH"] = ["\(wineLib)/x86_64-windows", "\(wineLib)/i386-windows", wineLib].joined(separator: ":")
        // onwin's patch to that hack (engine/patches/wine/0001-onwin-dock-names.patch): readable names
        // plus the space, "Steam (onwin꞉Игры)". U+A789 instead of ':' — macOS shows ':' in file names as '/'.
        env["ONWIN_DOCK_LABEL_SUFFIX"] = " (onwin\u{A789}" + space.name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "\u{A789}") + ")"
        env["ONWIN_DOCK_NAMES"] = WineRunner.dockNames
        // onwin's tools dir first: CW winemenubuilder runs `wineshelllink` through PATH (StartMenuHook).
        env["PATH"] = ([StartMenuHook.installIfNeeded()?.path, engine.bin.path].compactMap { $0 }
                       + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")

        // Libraries Wine dlopen()s by name: freetype, gnutls, MoltenVK, SDL, gstreamer...
        var dyld = [engine.externalLib.path, engine.lib.path]
        if OnwinPaths.exists(GraphicsSupport.d3dmetalExternalDir) { dyld.append(GraphicsSupport.d3dmetalExternalDir.path) }
        dyld += ["/usr/lib", "/usr/local/lib"]
        env["DYLD_FALLBACK_LIBRARY_PATH"] = dyld.joined(separator: ":")
        // GPTK's unix libs (d3d11.so, d3d12.so, dxgi.so...) link `@rpath/D3DMetal.framework/D3DMetal` with
        // only `@loader_path` as rpath, so the framework has to be found through the framework fallback path.
        if OnwinPaths.exists(GraphicsSupport.d3dmetalExternalDir) {
            env["DYLD_FALLBACK_FRAMEWORK_PATH"] = [GraphicsSupport.d3dmetalExternalDir.path,
                                                   "/Library/Frameworks", "/System/Library/Frameworks"].joined(separator: ":")
        }

        let gst = engine.lib.appendingPathComponent("gstreamer-1.0")
        if OnwinPaths.isDirectory(gst) {
            env["GST_PLUGIN_SYSTEM_PATH"] = gst.path
            env["GST_REGISTRY"] = OnwinPaths.cache.appendingPathComponent("gstreamer-1.0-registry.x86_64.bin").path
        }

        // Even without debug logging keep the few error channels DependencyAdvisor reads from the run
        // log (missing DLLs, .NET / Gecko not installed); they print only when something is wrong.
        env["WINEDEBUG"] = config.debugLogging ? config.wineDebugChannels : WineRunner.quietDebugChannels
        // MoltenVK prints its whole extension list (150+ lines) at info level for every Vulkan instance;
        // keep only errors unless debug logging is on.
        if env["MVK_CONFIG_LOG_LEVEL"] == nil { env["MVK_CONFIG_LOG_LEVEL"] = config.debugLogging ? "2" : "1" }
        // CW Wine 11 has only MSync (server/msync.c); there is no ESync on macOS any more.
        if config.msync { env["WINEMSYNC"] = "1" }
        if config.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        // .NET 7+ W^X mapping breaks under Rosetta; Microsoft's documented switch turns it off.
        env["DOTNET_EnableWriteXorExecute"] = "0"
        // No CX_WINDOWS_VERSION here: ntdll (version.c) would let it override the registry, including
        // per-application versions from winecfg. The space version is stored with `winecfg -v`.

        for (k, v) in GraphicsSupport.environment(for: config, engine: engine) { env[k] = v }
        // Per-exe backend choice inside Wine (onwincompat rules file + backend directories).
        for (k, v) in CompatRules.environment(for: space, engine: engine, base: env) { env[k] = v }

        var overrides = config.dllOverrides
        for (k, v) in extraOverrides { overrides[k] = v }
        if !overrides.isEmpty {
            env["WINEDLLOVERRIDES"] = overrides.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }

        // The user's own variables win.
        for (k, v) in config.environment { env[k] = v }
        for (k, v) in extraEnvironment { env[k] = v }
        // Rosetta treats *any* value of ROSETTA_ADVERTISE_AVX as "on", so "off" must mean "absent"
        // ("0" or "" → delete). This is how a space or a program
        // (ROSETTA_ADVERTISE_AVX=0 in its own variables) disables AVX.
        if let avx = env["ROSETTA_ADVERTISE_AVX"], avx == "0" || avx.isEmpty {
            env.removeValue(forKey: "ROSETTA_ADVERTISE_AVX")
        }
        return env
    }

    /// WINEDEBUG when the space's debug logging is off.
    /// Display names for helper processes that own the visible window (exe base name → name in the Dock).
    /// Format of ONWIN_DOCK_NAMES: "exe=Name;…", so ';' and '=' are dropped from the localized names.
    static let dockNames = ([
        "steam=Steam", "steamwebhelper=Steam", "epicgameslauncher=Epic Games", "epicwebhelper=Epic Games",
        "galaxyclient=GOG Galaxy", "galaxyclient helper=GOG Galaxy", "battle.net=Battle.net",
        "battle.net launcher=Battle.net", "eadesktop=EA app", "upc=Ubisoft Connect",
        "ubisoftconnect=Ubisoft Connect",
    ] + [
        ("explorer", String(localized: "Проводник", bundle: .onwinCore, comment: "Dock name of Wine's file manager (explorer.exe)")),
        ("notepad", String(localized: "Блокнот", bundle: .onwinCore, comment: "Dock name of notepad.exe")),
        ("winecfg", String(localized: "Настройки Wine", bundle: .onwinCore, comment: "Dock name of winecfg.exe")),
        ("regedit", String(localized: "Редактор реестра", bundle: .onwinCore, comment: "Dock name of regedit.exe")),
        ("taskmgr", String(localized: "Диспетчер задач", bundle: .onwinCore, comment: "Dock name of taskmgr.exe")),
        ("cmd", String(localized: "Командная строка", bundle: .onwinCore, comment: "Dock name of cmd.exe")),
    ].map { "\($0.0)=\($0.1.filter { $0 != ";" && $0 != "=" })" }).joined(separator: ";")

    public static let quietDebugChannels = "-all,err+module,err+mscoree,err+mshtml"

    // MARK: Commands

    /// What to run for a given file, like double-clicking it on Windows.
    public static func command(for file: URL, arguments: [String] = []) -> [String] {
        switch file.pathExtension.lowercased() {
        // msiexec and cmd do not understand Unix paths: "/Users/..." would be resolved against the
        // current drive, which is C: whenever the working directory is inside the space.
        case "msi": return ["msiexec", "/i", dosPath(file)] + arguments
        case "bat", "cmd": return ["cmd", "/c", dosPath(file)] + arguments
        case "lnk", "url": return ["start", "/unix", file.path] + arguments
        case "exe", "com", "scr": return [file.path] + arguments
        default: return ["start", "/unix", file.path] + arguments
        }
    }

    /// Windows path of a Unix file through the Z: drive, which Wine creates in every prefix
    /// (`dosdevices/z:` → `/`, see dlls/ntdll/unix/server.c). For Windows programs that take a file name.
    public static func dosPath(_ file: URL) -> String {
        "Z:" + file.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Wine hands the Windows exit code to exit(), so the parent only sees its low 8 bits
    /// (3010 → 194, 1638 → 102, 1602 → 66). True when `status` is what `windowsCode` becomes.
    public static func exitStatus(_ status: Int32, matches windowsCode: Int32) -> Bool {
        if status == windowsCode { return true }
        let low = windowsCode & 0xff
        return low != 0 && status == low
    }

    /// Runs a Wine command to completion (used for setup steps: wineboot, regedit, winecfg -v...).
    @discardableResult
    public func runAndWait(_ wineArguments: [String],
                           extraOverrides: [String: String] = [:],
                           currentDirectory: URL? = nil,
                           onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ProcessRunner.Result {
        prepareProfileFolders()
        // A pending prefix update would open the Wine Mono / Gecko installers (+PrefixUpdate).
        try await updatePrefixIfNeeded(onOutput: onOutput)
        return try await ProcessRunner.run(engine.wine, arguments: wineArguments,
                                    environment: environment(extraOverrides: extraOverrides),
                                    currentDirectory: currentDirectory ?? defaultDirectory,
                                    onOutput: onOutput)
    }

    /// Waits until every process of the space has exited (`wineserver -w`).
    public func waitForServer() async throws {
        _ = try await ProcessRunner.run(engine.wineserver, arguments: ["-w"], environment: environment())
    }

    /// Kills every process in the space (`wineserver -k`), «Принудительно завершить».
    public func killAll() async throws {
        _ = try await ProcessRunner.run(engine.wineserver, arguments: ["-k"], environment: environment())
    }

    /// Starts a program and returns immediately; output goes to a log file.
    @MainActor
    public func launch(_ file: URL, arguments: [String] = [], title: String? = nil,
                       extraEnvironment: [String: String] = [:]) throws -> RunningProgram {
        try launch(wineArguments: WineRunner.command(for: file, arguments: arguments),
                   title: title ?? file.deletingPathExtension().lastPathComponent,
                   workingDirectory: file.deletingLastPathComponent(), extraEnvironment: extraEnvironment)
    }

    /// Starts an arbitrary Wine command (e.g. ["winecfg"], ["regedit"], ["taskmgr"]).
    @MainActor
    public func launch(wineArguments: [String], title: String, workingDirectory: URL? = nil,
                       extraEnvironment: [String: String] = [:]) throws -> RunningProgram {
        let logDir = OnwinPaths.logs.appendingPathComponent(SpaceManager.directoryName(for: space.name), isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = WineRunner.logDateFormatter.string(from: Date())
        let safeTitle = SpaceManager.directoryName(for: title)
        let logURL = logDir.appendingPathComponent("\(stamp) \(safeTitle).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let env = environment(extraEnvironment: extraEnvironment)
        let header = """
        onwin \(OnwinVersion.string) — \(title)
        space: \(space.name) (\(space.url.path))
        engine: \(engine.info.displayName) [\(engine.info.wineVersion)]
        graphics: \(space.config.graphicsBackend.rawValue) → \(GraphicsSupport.resolve(space.config.graphicsBackend, engine: engine).rawValue)
        command: wine \(wineArguments.joined(separator: " "))
        env: \(env.filter { $0.key.hasPrefix("WINE") || $0.key.hasPrefix("ONWIN") || $0.key.hasPrefix("D3DM") || $0.key.hasPrefix("DXVK") || $0.key.hasPrefix("DXMT") || $0.key.hasPrefix("MTL") || $0.key.hasPrefix("ROSETTA") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        ----------------------------------------------------------------

        """
        logHandle.write(Data(header.utf8))

        prepareProfileFolders()
        let process = Process()
        // Pending prefix update (new engine): run it without the Mono/Gecko dialogs first (+PrefixUpdate).
        configureLaunch(process, wineArguments: wineArguments, environment: env)
        if let wd = workingDirectory, OnwinPaths.isDirectory(wd) {
            process.currentDirectoryURL = wd
        } else {
            process.currentDirectoryURL = defaultDirectory
        }
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        let program = RunningProgram(spaceID: space.id, spaceName: space.name, title: title,
                                     command: wineArguments, logURL: logURL)
        process.terminationHandler = { p in
            try? logHandle.close()
            let status = p.terminationStatus
            Task { @MainActor in program.finish(status: status) }
        }
        try process.run()
        program.pid = process.processIdentifier
        ProcessTracker.shared.add(program)
        return program
    }

    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

public enum OnwinVersion {
    public static let string = "0.1.2"
}
