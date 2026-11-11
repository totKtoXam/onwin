import Foundation

/// Windows version a space pretends to be (`winecfg -v`).
public enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case win11, win10, win81, win8, win7, vista, winxp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win8: return "Windows 8"
        case .win7: return "Windows 7"
        case .vista: return "Windows Vista"
        case .winxp: return "Windows XP"
        }
    }

    /// Value understood by `winecfg -v`.
    public var winecfgName: String { rawValue }
}

/// How DirectX is translated to something macOS can draw.
public enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pick per application: D3DMetal when available, otherwise DXMT.
    case auto
    /// Apple's D3DMetal (Game Porting Toolkit): D3D11/D3D12 → Metal.
    case d3dmetal
    /// DXMT: D3D10/D3D11 → Metal.
    case dxmt
    /// DXVK + MoltenVK: D3D9/10/11 → Vulkan → Metal.
    case dxvk
    /// Wine's own wined3d: D3D → OpenGL (most compatible, slowest).
    case wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Автоматически"
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D (OpenGL)"
        }
    }

    public var summary: String {
        switch self {
        case .auto: return "onwin сам выберет лучший вариант"
        case .d3dmetal: return "DirectX 11/12 → Metal, лучший для новых игр"
        case .dxmt: return "DirectX 10/11 → Metal, открытый"
        case .dxvk: return "DirectX 9–11 → Vulkan → Metal"
        case .wined3d: return "DirectX → OpenGL, самый совместимый"
        }
    }
}

/// Per-space settings, stored as `onwin-space.json` inside the space directory.
public struct SpaceConfig: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var windowsVersion: WindowsVersion
    /// Engine id to use; nil means "the default engine".
    public var engineID: String?
    public var created: Date

    // Graphics & performance
    public var graphicsBackend: GraphicsBackend
    public var msync: Bool          // Mach-semaphore synchronisation (server/msync.c in the CW Wine tree)
    public var highResolution: Bool // Retina mode in the Mac driver
    public var metalHUD: Bool       // Apple's Metal performance HUD
    public var advertiseAVX: Bool   // Rosetta 2 advertises AVX/AVX2 to the game
    public var dxrRaytracing: Bool  // D3DMetal DXR (ray tracing) support
    public var metalFX: Bool        // DLSS → MetalFX: D3DM_ENABLE_METALFX (D3DMetal) / DXMT_ENABLE_NVEXT (DXMT)

    // Debugging
    public var debugLogging: Bool
    public var wineDebugChannels: String

    // Advanced
    public var environment: [String: String]
    public var dllOverrides: [String: String]  // dll name → "n,b" / "b" / "" (disabled)
    public var description: String

    // Contents
    public var installedComponents: [String]
    public var programs: [ProgramEntry]

    // macOS integration
    /// Make a Launchpad / Dock `.app` for every Start Menu shortcut, see
    /// `LauncherBuilder.sync`. Off by default.
    public var autoLaunchers: Bool

    // Components
    /// «Устанавливать нужные компоненты автоматически» for this space; nil = as in onwin's settings
    /// (`Settings.autoInstallComponents`). See AutoComponents.swift.
    public var autoInstallComponents: Bool?
    /// Programs whose import tables were already checked before their first run (lower-case Windows
    /// paths, `AutoComponents.key(for:in:)`), so the check does not repeat.
    public var analyzedPrograms: [String]

    /// Format of the stored file; older files are migrated while decoding (see `init(from:)`).
    ///   1: had `esync` and `dxvkAsync` toggles (both no-ops with the CW Wine 11 / DXVK 1.10.3 tree)
    ///   2: no ESync / DXVK async; `esync=true` or WINEESYNC=1 became `msync=true` (the CW Wine 11
    ///      tree has only MSync on macOS)
    public var configVersion: Int
    public static let currentConfigVersion = 2

    public init(name: String,
                windowsVersion: WindowsVersion = .win10,
                graphicsBackend: GraphicsBackend = .auto) {
        self.id = UUID()
        self.name = name
        self.windowsVersion = windowsVersion
        self.engineID = nil
        self.created = Date()
        self.graphicsBackend = graphicsBackend
        self.msync = true
        self.highResolution = false
        self.metalHUD = false
        self.advertiseAVX = true
        self.dxrRaytracing = false
        self.metalFX = false
        self.debugLogging = false
        self.wineDebugChannels = "+err,+warn,+seh,+loaddll"
        self.environment = [:]
        self.dllOverrides = [:]
        self.description = ""
        self.installedComponents = []
        self.programs = []
        self.autoLaunchers = false
        self.autoInstallComponents = nil
        self.analyzedPrograms = []
        self.configVersion = SpaceConfig.currentConfigVersion
    }

    // Tolerant decoding so that older/newer config files keep loading.
    private enum CodingKeys: String, CodingKey {
        case id, name, windowsVersion, engineID, created, graphicsBackend, msync, esync,
             highResolution, metalHUD, advertiseAVX, dxrRaytracing, metalFX, dxvkAsync,
             debugLogging, wineDebugChannels, environment, dllOverrides, description,
             installedComponents, programs, configVersion, autoLaunchers,
             autoInstallComponents, analyzedPrograms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SpaceConfig(name: (try? c.decode(String.self, forKey: .name)) ?? "Space")
        id = (try? c.decode(UUID.self, forKey: .id)) ?? defaults.id
        name = defaults.name
        windowsVersion = (try? c.decode(WindowsVersion.self, forKey: .windowsVersion)) ?? defaults.windowsVersion
        engineID = try? c.decodeIfPresent(String.self, forKey: .engineID)
        created = (try? c.decode(Date.self, forKey: .created)) ?? defaults.created
        graphicsBackend = (try? c.decode(GraphicsBackend.self, forKey: .graphicsBackend)) ?? defaults.graphicsBackend
        msync = (try? c.decode(Bool.self, forKey: .msync)) ?? defaults.msync
        highResolution = (try? c.decode(Bool.self, forKey: .highResolution)) ?? defaults.highResolution
        metalHUD = (try? c.decode(Bool.self, forKey: .metalHUD)) ?? defaults.metalHUD
        advertiseAVX = (try? c.decode(Bool.self, forKey: .advertiseAVX)) ?? defaults.advertiseAVX
        dxrRaytracing = (try? c.decode(Bool.self, forKey: .dxrRaytracing)) ?? defaults.dxrRaytracing
        metalFX = (try? c.decode(Bool.self, forKey: .metalFX)) ?? defaults.metalFX
        debugLogging = (try? c.decode(Bool.self, forKey: .debugLogging)) ?? defaults.debugLogging
        wineDebugChannels = (try? c.decode(String.self, forKey: .wineDebugChannels)) ?? defaults.wineDebugChannels
        environment = (try? c.decode([String: String].self, forKey: .environment)) ?? [:]
        dllOverrides = (try? c.decode([String: String].self, forKey: .dllOverrides)) ?? [:]
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        installedComponents = (try? c.decode([String].self, forKey: .installedComponents)) ?? []
        programs = (try? c.decode([ProgramEntry].self, forKey: .programs)) ?? []
        autoLaunchers = (try? c.decode(Bool.self, forKey: .autoLaunchers)) ?? false
        autoInstallComponents = try? c.decodeIfPresent(Bool.self, forKey: .autoInstallComponents)
        analyzedPrograms = (try? c.decode([String].self, forKey: .analyzedPrograms)) ?? []
        configVersion = (try? c.decode(Int.self, forKey: .configVersion)) ?? 1

        // Migrations. Removed keys (esync, dxvkAsync) are read here once and never written again.
        if configVersion < 2 {
            let esync = (try? c.decode(Bool.self, forKey: .esync)) ?? false
            if let value = environment.removeValue(forKey: "WINEESYNC") {
                if value != "0" && !value.isEmpty { msync = true }
            }
            if esync { msync = true }
            configVersion = 2
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(windowsVersion, forKey: .windowsVersion)
        try c.encodeIfPresent(engineID, forKey: .engineID)
        try c.encode(created, forKey: .created)
        try c.encode(graphicsBackend, forKey: .graphicsBackend)
        try c.encode(msync, forKey: .msync)
        try c.encode(highResolution, forKey: .highResolution)
        try c.encode(metalHUD, forKey: .metalHUD)
        try c.encode(advertiseAVX, forKey: .advertiseAVX)
        try c.encode(dxrRaytracing, forKey: .dxrRaytracing)
        try c.encode(metalFX, forKey: .metalFX)
        try c.encode(debugLogging, forKey: .debugLogging)
        try c.encode(wineDebugChannels, forKey: .wineDebugChannels)
        try c.encode(environment, forKey: .environment)
        try c.encode(dllOverrides, forKey: .dllOverrides)
        try c.encode(description, forKey: .description)
        try c.encode(installedComponents, forKey: .installedComponents)
        try c.encode(programs, forKey: .programs)
        try c.encode(autoLaunchers, forKey: .autoLaunchers)
        try c.encodeIfPresent(autoInstallComponents, forKey: .autoInstallComponents)
        try c.encode(analyzedPrograms, forKey: .analyzedPrograms)
        try c.encode(configVersion, forKey: .configVersion)
    }
}

/// A program the user (or a recipe) added to the space's launcher list.
public struct ProgramEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Windows path, e.g. C:\Program Files (x86)\Steam\steam.exe
    public var windowsPath: String
    public var arguments: [String]
    /// Per-program environment additions (e.g. a different graphics backend).
    public var environment: [String: String]
    /// Space settings replaced for this program (graphics, Metal HUD, AVX, WINEDEBUG); see RunOptions.swift.
    public var overrides: RunOverrides?

    public init(name: String, windowsPath: String, arguments: [String] = [], environment: [String: String] = [:],
                overrides: RunOverrides? = nil) {
        self.id = UUID()
        self.name = name
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.environment = environment
        self.overrides = overrides
    }
}

extension SpaceConfig {
    static let fileName = "onwin-space.json"
    /// Name used before spaces were called "bottles"; read (and renamed) when the new file is missing.
    static let legacyFileName = "onwin-bottle.json"

    /// True when `dir` holds a space config under the current or the legacy name.
    static func exists(in dir: URL) -> Bool {
        OnwinPaths.exists(dir.appendingPathComponent(fileName)) || OnwinPaths.exists(dir.appendingPathComponent(legacyFileName))
    }

    static func load(from spaceDir: URL) throws -> SpaceConfig {
        let current = spaceDir.appendingPathComponent(fileName)
        let legacy = spaceDir.appendingPathComponent(legacyFileName)
        if !OnwinPaths.exists(current), OnwinPaths.exists(legacy) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        let data = try Data(contentsOf: OnwinPaths.exists(current) ? current : legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SpaceConfig.self, from: data)
    }

    func save(to spaceDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: spaceDir.appendingPathComponent(SpaceConfig.fileName), options: .atomic)
    }
}
