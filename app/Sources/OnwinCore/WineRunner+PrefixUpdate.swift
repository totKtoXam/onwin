import Foundation

/// Prefix updates without the Wine Mono / Gecko installer windows.
///
/// wineboot updates a prefix whenever `<prefix>/.update-timestamp` differs from the mtime of the
/// engine's `share/wine/wine.inf` (programs/wineboot/wineboot.c `update_timestamp`): after every
/// engine install or rebuild, after a space copy without the file, after restoring an archive made
/// with another engine. The update re-registers DLLs, and mscoree's / mshtml's DllRegisterServer then
/// open "Wine Mono Installer" / "Wine Gecko Installer" dialogs that wait for a click. Any first Wine
/// process of a session triggers that update, so onwin runs it itself first, with mscoree and mshtml
/// disabled (the same overrides SpaceSetup uses for `wineboot --init`; Mono and Gecko are
/// installed as components instead), and only then starts the requested program with its own,
/// unchanged environment.
extension WineRunner {
    /// Overrides for the update run only (never for the user's program: .NET apps need mscoree).
    static let prefixUpdateOverrides = ["mscoree": "", "mshtml": ""]

    /// The file whose mtime wineboot stores in `.update-timestamp`.
    var wineInf: URL { engine.root.appendingPathComponent("share/wine/wine.inf") }

    /// True when the next Wine process would make wineboot update the prefix.
    public var prefixUpdatePending: Bool {
        guard space.isInitialized else { return false }   // wineboot --init (SpaceSetup) handles new prefixes
        var st = stat()
        guard stat(wineInf.path, &st) == 0 else { return false }
        let stampURL = space.url.appendingPathComponent(".update-timestamp")
        guard let text = try? String(contentsOf: stampURL, encoding: .utf8) else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("disable") { return false }
        return UInt64(trimmed.prefix(while: \.isNumber)) != UInt64(st.st_mtimespec.tv_sec)
    }

    /// Runs the pending prefix update (`wineboot -u` with mscoree/mshtml disabled) and waits until
    /// that Wine session has ended, so no system process keeps the update's overrides. Does nothing
    /// when no update is pending or the space is running (the running session already did it).
    /// Returns true when an update ran.
    @discardableResult
    public func updatePrefixIfNeeded(onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Bool {
        guard prefixUpdatePending, !isServerRunning else { return false }
        prepareProfileFolders()
        onOutput?(WineRunner.prefixUpdateMessage + "\n")
        _ = try await ProcessRunner.run(engine.wine, arguments: ["wineboot", "-u"],
                                        environment: environment(extraOverrides: engine.addonInstallOverrides),
                                        currentDirectory: defaultDirectory, onOutput: onOutput)
        try await waitForServer()
        return true
    }

    static let prefixUpdateMessage = "onwin: движок изменился — обновляю окружение Windows (wineboot -u, без установщиков Wine Mono/Gecko)…"

    /// For the synchronous `launch`: when an update is pending, runs the program through /bin/sh,
    /// which performs the update first and then `exec`s wine (same PID, so tracking is unaffected).
    func configureLaunch(_ process: Process, wineArguments: [String], environment env: [String: String]) {
        guard prefixUpdatePending, !isServerRunning else {
            process.executableURL = engine.wine
            process.arguments = wineArguments
            process.environment = env
            return
        }
        var overrides = space.config.dllOverrides
        for (k, v) in engine.addonInstallOverrides { overrides[k] = v }
        var shellEnv = env
        shellEnv["ONWIN_UPDATE_DLLOVERRIDES"] = overrides.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        shellEnv["ONWIN_UPDATE_MESSAGE"] = WineRunner.prefixUpdateMessage
        // /bin/sh is protected by SIP, and macOS strips every DYLD_* variable from it and from what it
        // starts. Without DYLD_FALLBACK_LIBRARY_PATH Wine cannot dlopen the engine's FreeType, gnutls,
        // MoltenVK, SDL… (fonts break, games don't start). Hand them over under other names and restore.
        var restore = ""
        for (key, value) in env where key.hasPrefix("DYLD_") {
            shellEnv["ONWIN_KEEP_" + key] = value
            restore += "export \(key)=\"$ONWIN_KEEP_\(key)\"; unset ONWIN_KEEP_\(key)\n"
        }
        let script = restore + """
        printf '%s\\n' "$ONWIN_UPDATE_MESSAGE"
        WINEDLLOVERRIDES="$ONWIN_UPDATE_DLLOVERRIDES" "$0" wineboot -u
        "$WINESERVER" -w
        unset ONWIN_UPDATE_DLLOVERRIDES ONWIN_UPDATE_MESSAGE
        exec "$0" "$@"
        """
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, engine.wine.path] + wineArguments
        process.environment = shellEnv
    }
}
