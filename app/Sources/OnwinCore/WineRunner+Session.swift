import Foundation

/// Space session control: "is the space running", soft shutdown with a fallback to a hard kill.
/// Built on Wine's own tools: `wineboot --end-session --shutdown`, `wineserver -k` and `wineserver -k0`.
extension WineRunner {
    /// How a shutdown ended.
    public enum ShutdownOutcome: Sendable, Equatable {
        /// No wineserver was running for the space; nothing was started.
        case notRunning
        /// Every program closed after WM_QUERYENDSESSION / WM_ENDSESSION and the server exited.
        case clean
        /// Something kept running past the timeout; `wineserver -k` finished it.
        case forced
        /// A program refused to end the session (the user pressed "Cancel" in its "Save changes?"
        /// dialog). Nothing was killed; offer "Принудительно" (`killAll`) instead.
        case refused
    }

    // MARK: Server state

    /// Directory of the space's wineserver: `/tmp/.wine-<uid>/server-<dev>-<inode>` of the prefix
    /// (dlls/ntdll/unix/server.c `init_server_dir`, server/request.c `create_server_dir`).
    public var serverDirectory: URL? {
        var st = stat()
        guard stat(space.url.path, &st) == 0 else { return nil }
        let dev = UInt64(bitPattern: Int64(st.st_dev))   // C: (unsigned long long)dev
        let ino = UInt64(st.st_ino)
        return URL(fileURLWithPath: "/tmp/.wine-\(getuid())/server-\(String(dev, radix: 16))-\(String(ino, radix: 16))",
                   isDirectory: true)
    }

    /// PID of the space's running wineserver, nil when none runs. Same test as `wineserver -k0`:
    /// the server keeps a write lock on `<server dir>/lock` (server/request.c `kill_lock_owner`).
    /// Starts no process, so it is cheap enough to call from the UI.
    public var serverPID: pid_t? {
        guard let dir = serverDirectory else { return nil }
        let fd = open(dir.appendingPathComponent("lock").path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 1
        guard fcntl(fd, F_GETLK, &fl) != -1, fl.l_type == Int16(F_WRLCK), fl.l_pid > 0 else { return nil }
        return fl.l_pid
    }

    /// True while any process of the space (or its wineserver) runs, including programs that were
    /// not started from this onwin instance (onwinctl, another copy of the app, a Dock launcher).
    public var isServerRunning: Bool { serverPID != nil }

    // MARK: Shutdown

    /// Soft shutdown («Завершить все программы»):
    /// `wine wineboot --end-session --shutdown --kill --force` sends WM_QUERYENDSESSION/WM_ENDSESSION
    /// to the windows on every desktop (programs may save, or refuse), and only when all agreed
    /// terminates every process of the space, the desktop last. `--kill` is required with the CW
    /// tree: its wineboot no longer terminates a process after WM_ENDSESSION ("CODEWEAVERS HACK" in
    /// programs/wineboot/shutdown.c, `send_end_session_messages`), so without it Notepad & co. stay
    /// alive. `--force` = SMTO_ABORTIFHUNG for hung windows.
    ///
    /// Then waits up to `timeout` seconds in total for the wineserver to exit; if it is still alive
    /// (wineboot stuck behind a dialog or a hung program) falls back to `wineserver -k`. A refusal
    /// (wineboot exit code 1) is returned as `.refused` without killing anything.
    ///
    /// Never starts Wine when the space is not running: a fresh `wine` would boot the prefix and could
    /// run its update, i.e. the Wine Mono / Gecko installer dialogs. mscoree/mshtml are disabled for
    /// the wineboot process for the same reason.
    ///
    /// Note: Wine's wineboot shows its own "program is not responding" (End Task) window when a
    /// program does not answer for 5 s; the timeout here kills the space anyway, so it needs no click.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 10, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ShutdownOutcome {
        guard isServerRunning else { return .notRunning }
        let deadline = Date().addingTimeInterval(timeout)

        let process = Process()
        process.executableURL = engine.wine
        process.arguments = ["wineboot", "--end-session", "--shutdown", "--kill", "--force"]
        process.environment = environment(extraOverrides: engine.addonInstallOverrides)
        process.currentDirectoryURL = defaultDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        onOutput?("wine wineboot --end-session --shutdown --kill --force\n")
        try process.run()

        while Date() < deadline {
            if !isServerRunning { break }
            if !process.isRunning && process.terminationStatus != 0 {
                onOutput?(String(localized: "Программа отказалась завершаться (wineboot: \(Int(process.terminationStatus))).", bundle: .onwinCore) + "\n")
                return .refused
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning { process.terminate() }
        guard isServerRunning else {
            onOutput?(String(localized: "Все программы пространства закрылись сами.", bundle: .onwinCore) + "\n")
            return .clean
        }

        onOutput?(String(localized: "Не все программы закрылись за \(Int(timeout)) с — wineserver -k", bundle: .onwinCore) + "\n")
        try await killAll()
        // wineserver -k returns once the server got SIGINT/SIGKILL; give it a moment to release the lock.
        for _ in 0..<20 where isServerRunning {
            try? await Task.sleep(for: .milliseconds(150))
        }
        return .forced
    }

    /// Shutdown, then `apply` (skipped when a program refused), for settings a running wineserver does
    /// not pick up: WINEMSYNC is read by the server and every process at start, so switching it with
    /// the space running would mix sync modes.
    public func restart(timeout: TimeInterval = 10,
                        onOutput: (@Sendable (String) -> Void)? = nil,
                        apply: @Sendable () async throws -> Void) async throws -> ShutdownOutcome {
        let outcome = try await shutdown(timeout: timeout, onOutput: onOutput)
        if outcome != .refused { try await apply() }
        return outcome
    }
}
