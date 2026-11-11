import Foundation

/// Settings that replace the space's own ones for one run ("Запустить с параметрами…") or for one
/// pinned program (`ProgramEntry.overrides`): Metal HUD, "не сообщать AVX", logging channels.
/// nil fields keep the space setting.
public struct RunOverrides: Codable, Hashable, Sendable {
    public var graphicsBackend: GraphicsBackend?
    public var metalHUD: Bool?
    public var advertiseAVX: Bool?
    /// WINEDEBUG for the run; "" means the quiet default even if the space logs.
    public var wineDebug: String?

    public init(graphicsBackend: GraphicsBackend? = nil, metalHUD: Bool? = nil,
                advertiseAVX: Bool? = nil, wineDebug: String? = nil) {
        self.graphicsBackend = graphicsBackend
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.wineDebug = wineDebug
    }

    public var isEmpty: Bool { graphicsBackend == nil && metalHUD == nil && advertiseAVX == nil && wineDebug == nil }

    /// Only the fields that differ from `config` (so a saved program follows later space changes
    /// of everything the user did not set explicitly).
    public func differences(from config: SpaceConfig) -> RunOverrides {
        var o = RunOverrides()
        if let b = graphicsBackend, b != config.graphicsBackend { o.graphicsBackend = b }
        if let h = metalHUD, h != config.metalHUD { o.metalHUD = h }
        if let a = advertiseAVX, a != config.advertiseAVX { o.advertiseAVX = a }
        if let d = wineDebug {
            let current = config.debugLogging ? config.wineDebugChannels : ""
            if d != current { o.wineDebug = d }
        }
        return o
    }

    private enum CodingKeys: String, CodingKey { case graphicsBackend, metalHUD, advertiseAVX, wineDebug }

    // Never fails: a damaged field must not make the space's program list unreadable.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        graphicsBackend = try? c.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend)
        metalHUD = try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)
        advertiseAVX = try? c.decodeIfPresent(Bool.self, forKey: .advertiseAVX)
        wineDebug = try? c.decodeIfPresent(String.self, forKey: .wineDebug)
    }
}

extension SpaceConfig {
    /// The config with `overrides` applied (for building one run's environment).
    public func applying(_ overrides: RunOverrides?) -> SpaceConfig {
        guard let o = overrides, !o.isEmpty else { return self }
        var c = self
        if let b = o.graphicsBackend { c.graphicsBackend = b }
        if let h = o.metalHUD { c.metalHUD = h }
        if let a = o.advertiseAVX {
            c.advertiseAVX = a
            // Rosetta enables AVX for *any* value of the variable, so "off" means removing it.
            if !a { c.environment.removeValue(forKey: "ROSETTA_ADVERTISE_AVX") }
        }
        if let d = o.wineDebug {
            let channels = d.trimmingCharacters(in: .whitespaces)
            c.debugLogging = !channels.isEmpty
            if !channels.isEmpty { c.wineDebugChannels = channels }
            c.environment.removeValue(forKey: "WINEDEBUG")
        }
        return c
    }
}

extension Space {
    /// A copy whose config has `overrides` applied; hand it to `WineRunner` for one launch.
    public func applying(_ overrides: RunOverrides?) -> Space {
        guard let o = overrides, !o.isEmpty else { return self }
        return Space(url: url, config: config.applying(o))
    }

    /// The overrides saved with a pinned program, if any.
    public func overrides(for program: SpaceProgram) -> RunOverrides? {
        guard case .pinned(let id) = program.source else { return nil }
        return config.programs.first { $0.id == id }?.overrides
    }
}

/// Windows command lines: splitting like `CommandLineToArgvW` and resolving the program the way
/// `CreateProcess(NULL, cmdline)` does when the path is not quoted (`C:\Program Files\X\unins000.exe /S`).
public enum WindowsCommandLine {
    /// Splits a command line into arguments (`CommandLineToArgvW` rules: quotes group, `\"` is a quote,
    /// backslashes are literal unless they precede a quote).
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                var n = 0
                while i < chars.count, chars[i] == "\\" { n += 1; i += 1 }
                if i < chars.count, chars[i] == "\"" {
                    current += String(repeating: "\\", count: n / 2)
                    if n % 2 == 1 { current.append("\""); i += 1 }
                } else {
                    current += String(repeating: "\\", count: n)
                }
                hasToken = true
                continue
            }
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\""); i += 2; continue   // "" inside quotes
                }
                inQuotes.toggle(); hasToken = true; i += 1; continue
            }
            if (c == " " || c == "\t") && !inQuotes {
                if hasToken { args.append(current); current = ""; hasToken = false }
                i += 1; continue
            }
            current.append(c); hasToken = true; i += 1
        }
        if hasToken { args.append(current) }
        return args
    }

    /// Quotes arguments for display / for storing a command line.
    public static func join(_ args: [String]) -> String {
        args.map { a in
            if a.isEmpty { return "\"\"" }
            if a.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) {
                return "\"" + a.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            return a
        }.joined(separator: " ")
    }

    public struct Resolved: Sendable, Equatable {
        /// What to give Wine as the program: a Windows path (C:\…\x.exe) or a bare name (msiexec).
        public var program: String
        /// Unix path when the program is a file inside the space (or on the Mac through Z:).
        public var unixPath: URL?
        public var arguments: [String]
        /// Wine arguments: program + arguments.
        public var wineArguments: [String] { [program] + arguments }
    }

    /// Splits `line` into program and arguments. An unquoted program path with spaces is found the way
    /// CreateProcess does it: try "C:\Program", "C:\Program Files\X\unins000.exe"… and take the first
    /// (shortest) one that exists, so a later argument that is itself a path is never swallowed.
    /// Bare names (notepad, msiexec, regedit) are looked up in C:\windows\system32 and C:\windows.
    public static func resolve(_ line: String, in space: Space) -> Resolved? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func existing(_ windowsPath: String) -> URL? {
            guard let unix = space.unixPath(forWindowsPath: windowsPath) else { return nil }
            if OnwinPaths.exists(unix), !OnwinPaths.isDirectory(unix) { return unix }
            if unix.pathExtension.isEmpty {
                let exe = unix.appendingPathExtension("exe")
                if OnwinPaths.exists(exe) { return exe }
            }
            return nil
        }

        if trimmed.hasPrefix("\"") {
            let args = split(trimmed)
            guard let program = args.first else { return nil }
            return Resolved(program: program, unixPath: lookup(program, in: space, existing: existing),
                            arguments: Array(args.dropFirst()))
        }

        // Unquoted: grow the program over spaces while a longer path exists.
        let pieces = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var best: (count: Int, unix: URL)?
        if trimmed.contains(":\\") || trimmed.contains(":/") {
            for n in 1...pieces.count {
                let candidate = pieces.prefix(n).joined(separator: " ")
                if let unix = existing(candidate) { best = (n, unix); break }
            }
        }
        if let best {
            let program = pieces.prefix(best.count).joined(separator: " ")
            let rest = pieces.dropFirst(best.count).joined(separator: " ")
            return Resolved(program: program, unixPath: best.unix, arguments: split(rest))
        }
        let args = split(trimmed)
        guard let program = args.first else { return nil }
        return Resolved(program: program, unixPath: lookup(program, in: space, existing: existing),
                        arguments: Array(args.dropFirst()))
    }

    private static func lookup(_ program: String, in space: Space, existing: (String) -> URL?) -> URL? {
        if program.count >= 2, program.dropFirst().first == ":" { return existing(program) }
        if program.hasPrefix("/") {
            let url = URL(fileURLWithPath: program)
            return OnwinPaths.exists(url) ? url : nil
        }
        guard !program.contains("\\"), !program.contains("/") else { return nil }
        for dir in [#"C:\windows\system32\"#, #"C:\windows\"#] {
            if let hit = existing(dir + program) { return hit }
        }
        return nil
    }
}
