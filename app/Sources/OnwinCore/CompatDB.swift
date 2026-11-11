import Foundation

/// onwin's own compatibility database: per-executable defaults that `engine/compat/onwincompat.c`
/// applies inside each Wine process.
///
/// Rules here come after the space's per-program settings (`ProgramEntry.graphicsBackend`), so the
/// user can always override them, and before the space's own backend.
///
/// Clean-room rule (see AGENTS.md): every entry must come from onwin's own testing or from a public
/// source, named in the comment next to the entry. Nothing may be taken from closed third-party
/// products (their compatibility databases, install profiles, binaries or wrapper scripts).
///
/// Chromium-based launchers (CEF / Electron / WebView2): under winemac a Chromium GPU *process* cannot
/// draw into a window owned by another process (win32u has no cross-process window surfaces), so the
/// windows stay black. Chromium's documented switches `--in-process-gpu` (run the GPU thread inside the
/// browser process) and `--disable-gpu` (software compositing) avoid that; see
/// https://peter.sh/experiments/chromium-command-line-switches/ and Chromium's `content_switches.cc`.
public enum CompatDB {
    static let noCrashpad = ["--type=crashpad-handler"]

    public static let launchers: [CompatRule] = [
        // Steam's web helper (CEF). Verified by onwin on Apple M5 / macOS 26.5 (11.11.2026): without these
        // switches the Steam window stays black, with them the store, library and login render.
        CompatRule(id: "steam", patterns: ["steamwebhelper.exe"],
                   appendArguments: "--no-sandbox --in-process-gpu --disable-gpu",
                   forbiddenArguments: noCrashpad, source: "db:steam"),
    ]

    /// Per-game rules. Example:
    ///     // Source: <URL of the public report or "onwin test, <date>, <Mac>">
    ///     CompatRule(id: "somegame", patterns: ["somegame.exe"], backend: .dxvk,
    ///                environment: ["DXVK_HUD": "fps"], source: "db:somegame")
    public static let games: [CompatRule] = []

    /// Every built-in rule, highest priority first.
    public static var rules: [CompatRule] { games + launchers }

    /// The built-in rule for a Windows path or exe name, if any (first match, like onwincompat).
    public static func rule(forExecutable windowsPathOrName: String) -> CompatRule? {
        rules.first { $0.matches(windowsPath: windowsPathOrName) }
    }
}
