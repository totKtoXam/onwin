import Foundation

/// One per-executable rule for `engine/compat/onwincompat.c`.
public struct CompatRule: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Case-insensitive globs (`*`, `?`). With `\` or `:` the pattern is matched against the whole
    /// Windows path of the exe, otherwise against its file name.
    public var patterns: [String]
    /// nil or `.auto`: keep the space's backend for this exe.
    public var backend: GraphicsBackend?
    /// Variables set for this exe only (not inherited by the processes it starts).
    public var environment: [String: String]
    /// Where the rule comes from ("program:<name>", "db:<id>"), written to the file for diagnostics.
    public var source: String
    /// Arguments appended to the program's command line.
    public var appendArguments: String?
    /// The rule is skipped for command lines containing any of these (case-insensitive substrings).
    public var forbiddenArguments: [String]

    public init(id: String, patterns: [String], backend: GraphicsBackend? = nil,
                environment: [String: String] = [:], appendArguments: String? = nil,
                forbiddenArguments: [String] = [], source: String) {
        self.id = id
        self.patterns = patterns
        self.backend = backend
        self.environment = environment
        self.appendArguments = appendArguments
        self.forbiddenArguments = forbiddenArguments
        self.source = source
    }

    /// Same matching as onwincompat.c.
    public func matches(windowsPath: String) -> Bool {
        let path = windowsPath.replacingOccurrences(of: "/", with: "\\").lowercased()
        let name = path.split(separator: "\\").last.map(String.init) ?? path
        return patterns.contains { pattern in
            let p = pattern.replacingOccurrences(of: "/", with: "\\").lowercased()
            return CompatRules.globMatch(p, (p.contains("\\") || p.contains(":")) ? path : name)
        }
    }
}

/// Writes the rules file `onwincompat.c` reads (`ONWIN_COMPAT_RULES`) for a space: the space's
/// per-program settings first, then the built-in `CompatDB`. Priority, as in the module:
/// per-program rule > built-in rule > space backend.
///
/// File format (one rule per line, fields separated by `;`, `\;` is a literal `;`,
/// patterns separated by `|`, which cannot occur in Windows file names):
///
///     exe=c:\games\foo\foo.exe|z:\users\...\drive_c\games\foo\foo.exe ; backend=dxvk ; env:DXVK_HUD=fps ; from=program:Foo
///     exe=steam.exe|steamwebhelper.exe ; backend=wined3d ; from=db:steam
public enum CompatRules {
    public static let fileFormatVersion = 1

    /// Per-program rules from `SpaceConfig.programs`: programs whose saved settings
    /// (`ProgramEntry.overrides.graphicsBackend`, see RunOptions.swift) name a backend of their own.
    /// As a rule the choice follows the exe itself, also when a launcher or another program starts it.
    public static func programRules(for space: Space) -> [CompatRule] {
        space.config.programs.compactMap { program in
            guard let backend = program.overrides?.graphicsBackend, backend != .auto else { return nil }
            var patterns = [program.windowsPath]
            // Wine names a program started by its Unix path through drive Z: (z:\users\...\drive_c\...),
            // so match that spelling as well.
            if let unix = space.unixPath(forWindowsPath: program.windowsPath) {
                let z = WineRunner.dosPath(unix)
                if z.caseInsensitiveCompare(program.windowsPath) != .orderedSame { patterns.append(z) }
            }
            return CompatRule(id: program.id.uuidString, patterns: patterns, backend: backend,
                              source: "program:\(program.name)")
        }
    }

    /// Every rule for the space, highest priority first.
    public static func rules(for space: Space) -> [CompatRule] {
        programRules(for: space) + CompatDB.rules
    }

    /// Backend a Windows exe gets in this space, and why (for the UI and logs).
    public static func effectiveBackend(forWindowsPath windowsPath: String, in space: Space,
                                        engine: Engine) -> (backend: GraphicsBackend, rule: CompatRule?) {
        let fallback = GraphicsSupport.resolve(space.config.graphicsBackend, engine: engine)
        for rule in rules(for: space) where rule.matches(windowsPath: windowsPath) {
            guard let backend = rule.backend, backend != .auto else { continue }
            // onwincompat keeps the default when the rule's backend is not installed.
            guard GraphicsSupport.isAvailable(backend, engine: engine) else { return (fallback, nil) }
            return (backend, rule)
        }
        return (fallback, nil)
    }

    // MARK: File

    public static func render(_ rules: [CompatRule], spaceName: String) -> String {
        var lines = [
            "# onwin compat rules v\(fileFormatVersion) for space \(sanitize(spaceName)) — generated by onwin, do not edit.",
            "# Read by cxcompatdb.so (engine/compat/onwincompat.c) in every Wine process of the space.",
        ]
        for rule in rules {
            let patterns = rule.patterns
                .map { sanitize($0).replacingOccurrences(of: "|", with: "") }
                .filter { !$0.isEmpty }
            guard !patterns.isEmpty else { continue }
            var fields = ["exe=" + escape(patterns.joined(separator: "|"))]
            if let backend = rule.backend, backend != .auto { fields.append("backend=\(backend.rawValue)") }
            for (key, value) in rule.environment.sorted(by: { $0.key < $1.key }) {
                guard isValidName(key), !value.contains(where: \.isNewline) else { continue }
                fields.append("env:\(key)=\(escape(value))")
            }
            if let append = rule.appendArguments?.trimmingCharacters(in: .whitespaces), !append.isEmpty,
               !append.contains(where: \.isNewline) {
                fields.append("append=" + escape(append))
            }
            let forbid = rule.forbiddenArguments.map { sanitize($0).replacingOccurrences(of: "|", with: "") }
                .filter { !$0.isEmpty }
            if !forbid.isEmpty { fields.append("forbid=" + escape(forbid.joined(separator: "|"))) }
            fields.append("from=" + escape(sanitize(rule.source)))
            // " ; ": a value ending in '\' (e.g. a folder) must not turn the separator into "\;".
            lines.append(fields.joined(separator: " ; "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where a space's rules file lives (regenerated on every launch).
    public static func fileURL(for space: Space) -> URL {
        OnwinPaths.cache.appendingPathComponent("compat", isDirectory: true)
            .appendingPathComponent("\(space.id.uuidString).rules")
    }

    /// Writes the rules file if its content changed; nil when it cannot be written.
    @discardableResult
    public static func write(for space: Space) -> URL? {
        let url = fileURL(for: space)
        let data = Data(render(rules(for: space), spaceName: space.name).utf8)
        if let existing = try? Data(contentsOf: url), existing == data { return url }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: processes of a running space may be reading the old file right now.
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Launch environment for onwincompat (writes the rules file). `base` is the environment built
    /// so far (with `GraphicsSupport.environment` for the space's backend):
    ///
    ///     ONWIN_BACKEND_DEFAULT        the space's backend, resolved (its DLLs: ONWIN_DLL_PATHS)
    ///     ONWIN_BACKEND_DIR_<backend>  DLL directory of every other available backend
    ///     ONWIN_COMPAT_RULES           the rules file
    ///     CX_ACTIVE_GRAPHICS_BACKEND   the default; onwincompat sets the real one per process
    ///                                  (also covers engines whose module predates the rules)
    ///
    /// plus the switches of the other available backends (D3DM_*, DXMT_*, DXVK_HUD...), which only
    /// that backend reads, so that a rule choosing it gets the space's settings too.
    public static func environment(for space: Space, engine: Engine, base: [String: String] = [:]) -> [String: String] {
        let config = space.config
        let backend = GraphicsSupport.resolve(config.graphicsBackend, engine: engine)
        var env: [String: String] = [
            "ONWIN_BACKEND_DEFAULT": backend.rawValue,
            "CX_ACTIVE_GRAPHICS_BACKEND": backend.rawValue,
        ]
        for other in [GraphicsBackend.d3dmetal, .dxmt, .dxvk] where GraphicsSupport.isAvailable(other, engine: engine) {
            if let dir = GraphicsSupport.dllPathChain(for: other, engine: engine).first {
                env["ONWIN_BACKEND_DIR_\(other.rawValue)"] = dir.path
            }
            guard other != backend else { continue }
            var alternative = config
            alternative.graphicsBackend = other
            for (k, v) in GraphicsSupport.environment(for: alternative, engine: engine)
            where k != "ONWIN_DLL_PATHS" && base[k] == nil && env[k] == nil {
                env[k] = v
            }
        }
        if let url = write(for: space) { env["ONWIN_COMPAT_RULES"] = url.path }
        return env
    }

    // MARK: Helpers

    /// Case-insensitive glob with `*` and `?` (inputs already lowercased).
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), s = Array(text)
        var pi = 0, si = 0, star = -1, resume = 0
        while si < s.count {
            if pi < p.count && p[pi] == "*" {
                star = pi; pi += 1; resume = si
            } else if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1; si += 1
            } else if star >= 0 {
                pi = star + 1; resume += 1; si = resume
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ";", with: "\\;")
    }

    private static func sanitize(_ value: String) -> String {
        String(value.map { $0.isNewline ? " " : $0 })
    }

    private static func isValidName(_ key: String) -> Bool {
        !key.isEmpty && !key.contains("=") && !key.contains(";") && !key.contains(where: { $0.isWhitespace })
    }
}
