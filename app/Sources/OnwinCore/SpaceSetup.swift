import Foundation

/// Prefix initialisation and the settings that live in the Windows registry.
public enum SpaceSetup {
    /// Overrides used only while the prefix is being created: skip the Wine Mono / Gecko
    /// download prompts (they can be installed later as components).
    static let initOverrides = ["mscoree": "", "mshtml": ""]

    public static func initialize(_ space: Space, engine: Engine,
                                  log: @escaping @Sendable (String) -> Void) async throws {
        let runner = try WineRunner(space: space, engine: engine)
        log("Создаю окружение Windows (wineboot)…\n")
        let boot = try await runner.runAndWait(["wineboot", "--init"], extraOverrides: engine.addonInstallOverrides, onOutput: log)
        try await runner.waitForServer()
        guard boot.status == 0, space.isInitialized else {
            throw OnwinError("wineboot завершился с кодом \(boot.status):\n\(boot.output.suffix(2000))")
        }
        try await applyWindowsVersion(space, runner: runner, log: log)
        try await applyRegistrySettings(space, runner: runner, log: log)
        try await runner.waitForServer()
        log("Готово.\n")
    }

    public static func applyWindowsVersion(_ space: Space, runner: WineRunner? = nil,
                                           log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let runner = try runner ?? WineRunner(space: space)
        log("Версия Windows: \(space.config.windowsVersion.displayName)\n")
        let r = try await runner.runAndWait(["winecfg", "-v", space.config.windowsVersion.winecfgName])
        try await runner.waitForServer()
        if r.status != 0 { log("winecfg -v вернул \(r.status): \(r.output.suffix(500))\n") }
    }

    /// Settings stored in the registry: Retina mode / DPI and a couple of Mac driver defaults.
    public static func applyRegistrySettings(_ space: Space, runner: WineRunner? = nil,
                                             log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let runner = try runner ?? WineRunner(space: space)
        let c = space.config
        let reg = RegFile()
            .set(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", .string(c.highResolution ? "y" : "n"))
            .set(#"HKEY_CURRENT_USER\Control Panel\Desktop"#, "LogPixels", .dword(c.highResolution ? 192 : 96))
            .set(#"HKEY_CURRENT_USER\Software\Wine\Fonts"#, "LogPixels", .dword(c.highResolution ? 192 : 96))
        try await Registry.importReg(reg, runner: runner)
        log("Настройки реестра применены.\n")
    }
}

/// Builder for a `.reg` file (REGEDIT4 format, understood by `regedit /S`).
public struct RegFile: Sendable {
    public enum Value: Sendable {
        case string(String)
        case dword(UInt32)
        case delete

        var text: String {
            switch self {
            case .string(let s):
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            case .dword(let d): return String(format: "dword:%08x", d)
            case .delete: return "-"
            }
        }
    }

    private var keys: [(String, [(String, Value)])] = []

    public init() {}

    public func set(_ key: String, _ name: String, _ value: Value) -> RegFile {
        var copy = self
        if let i = copy.keys.firstIndex(where: { $0.0 == key }) {
            copy.keys[i].1.append((name, value))
        } else {
            copy.keys.append((key, [(name, value)]))
        }
        return copy
    }

    public var text: String {
        var out = "REGEDIT4\n\n"
        for (key, values) in keys {
            out += "[\(key)]\n"
            for (name, value) in values {
                let n = name == "@" ? "@" : "\"\(name)\""
                out += "\(n)=\(value.text)\n"
            }
            out += "\n"
        }
        return out
    }
}

public enum Registry {
    public static func importReg(_ reg: RegFile, runner: WineRunner) async throws {
        let file = OnwinPaths.cache.appendingPathComponent("onwin-\(UUID().uuidString).reg")
        try FileManager.default.createDirectory(at: OnwinPaths.cache, withIntermediateDirectories: true)
        try reg.text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = try await runner.runAndWait(["regedit", "/S", WineRunner.dosPath(file)])
        try await runner.waitForServer()
        if r.status != 0 { throw OnwinError("regedit вернул \(r.status): \(r.output.suffix(500))") }
    }

    /// Reads a value with `reg query`. Returns nil if it does not exist.
    public static func query(_ key: String, _ name: String, runner: WineRunner) async throws -> String? {
        let r = try await runner.runAndWait(["reg", "query", key, "/v", name])
        guard r.status == 0 else { return nil }
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 3, parts[0].caseInsensitiveCompare(name) == .orderedSame {
                return parts[2...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
