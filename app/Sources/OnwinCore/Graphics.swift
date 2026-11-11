import Foundation

/// Graphics backends: every backend is a directory
/// with the Wine DLL layout (x86_64-windows/, i386-windows/, x86_64-unix/) that is put *in front*
/// of Wine's own builtin DLL directory for the process. Our `cxcompatdb.so` replacement
/// (engine/compat/onwincompat.c) reads `ONWIN_DLL_PATHS` and does the prepending inside ntdll.
public enum GraphicsSupport {
    /// D3DMetal imported from Apple's Game Porting Toolkit:
    ///     Graphics/D3DMetal/wine/{x86_64-windows,x86_64-unix}
    ///     Graphics/D3DMetal/external/{D3DMetal.framework,libd3dshared.dylib}
    public static var d3dmetalWineDir: URL { OnwinPaths.d3dmetal.appendingPathComponent("wine", isDirectory: true) }
    public static var d3dmetalExternalDir: URL { OnwinPaths.d3dmetal.appendingPathComponent("external", isDirectory: true) }
    public static var libd3dshared: URL { d3dmetalExternalDir.appendingPathComponent("libd3dshared.dylib") }

    public static var isD3DMetalInstalled: Bool {
        OnwinPaths.exists(d3dmetalWineDir.appendingPathComponent("x86_64-windows/d3d12.dll")) &&
        OnwinPaths.exists(d3dmetalExternalDir.appendingPathComponent("D3DMetal.framework"))
    }

    public static func isAvailable(_ backend: GraphicsBackend, engine: Engine) -> Bool {
        // Apple Silicon / macOS gating (HostSupport) comes before "is it installed".
        if HostSupport.unsupportedReason(backend) != nil { return false }
        switch backend {
        case .auto, .wined3d: return true
        case .d3dmetal: return isD3DMetalInstalled
        case .dxmt: return engine.hasDXMT
        case .dxvk: return engine.hasDXVK
        }
    }

    /// What `.auto` resolves to: D3DMetal if imported, otherwise DXMT, otherwise DXVK, otherwise WineD3D.
    public static func resolve(_ backend: GraphicsBackend, engine: Engine) -> GraphicsBackend {
        if backend != .auto {
            return isAvailable(backend, engine: engine) ? backend : resolve(.auto, engine: engine)
        }
        if isAvailable(.d3dmetal, engine: engine) { return .d3dmetal }
        if isAvailable(.dxmt, engine: engine) { return .dxmt }
        if engine.hasDXVK { return .dxvk }
        return .wined3d
    }

    /// DLL directories to prepend, highest priority first.
    public static func dllPathChain(for backend: GraphicsBackend, engine: Engine) -> [URL] {
        switch resolve(backend, engine: engine) {
        case .d3dmetal: return [d3dmetalWineDir]
        case .dxmt: return [engine.dxmtDir]
        case .dxvk: return [engine.dxvkDir]
        case .wined3d, .auto: return []
        }
    }

    /// Backend-specific environment variables.
    public static func environment(for config: SpaceConfig, engine: Engine) -> [String: String] {
        var env: [String: String] = [:]
        let backend = resolve(config.graphicsBackend, engine: engine)
        let chain = dllPathChain(for: config.graphicsBackend, engine: engine)
        if !chain.isEmpty {
            env["ONWIN_DLL_PATHS"] = chain.map(\.path).joined(separator: ":")
        }
        // Read by the CW Wine tree (dlls/ntdll/unix/loader.c) whenever D3DMetal is present: libd3dshared
        // is then used for presenting, whichever backend is active.
        if OnwinPaths.exists(libd3dshared) {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = libd3dshared.path
        }
        if config.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        switch backend {
        case .d3dmetal:
            if config.dxrRaytracing && HostSupport.raytracingUnsupportedReason(.d3dmetal) == nil { env["D3DM_SUPPORT_DXR"] = "1" }
            if config.metalFX && HostSupport.metalFXUnsupportedReason(.d3dmetal) == nil { env["D3DM_ENABLE_METALFX"] = "1" }
        case .dxmt:
            // One "DLSS" switch for both Metal backends: D3DM_ENABLE_METALFX (Apple's Game Porting Toolkit
            // documentation) for D3DMetal, DXMT_ENABLE_NVEXT for DXMT.
            // DXMT v0.80 dxgi.dll reads DXMT_ENABLE_NVEXT=1: NVIDIA vendor extension (nvapi64/nvngx),
            // DLSS Super Resolution → MetalFX temporal scaler, Apple Silicon, Sonoma+ (DXMT wiki
            // "Vendor Extensions"). Without it DXMT's nvapi64/nvngx stay inert.
            if config.metalFX && HostSupport.metalFXUnsupportedReason(.dxmt) == nil { env["DXMT_ENABLE_NVEXT"] = "1" }
        case .dxvk:
            // No DXVK_ASYNC: the CW DXVK 1.10.3 tree has no async patch, the variable did nothing.
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
            if config.metalHUD { env["DXVK_HUD"] = "fps,devinfo" }
        case .wined3d, .auto:
            break
        }
        return env
    }

    // MARK: - D3DMetal import

    /// Imports D3DMetal from a Game Porting Toolkit download. `source` may be the mounted DMG
    /// volume, its `redist` folder, or a `lib` folder — we look for `D3DMetal.framework`.
    public static func importD3DMetal(from source: URL) throws {
        let fm = FileManager.default
        guard let framework = findItem(named: "D3DMetal.framework", under: source, maxDepth: 6) else {
            throw OnwinError(String(localized: "Не нашёл D3DMetal.framework в \(source.path). Укажите том Game Porting Toolkit (папку redist).", bundle: .onwinCore))
        }
        let external = framework.deletingLastPathComponent()           // .../lib/external
        let libRoot = external.deletingLastPathComponent()             // .../lib
        let wineSrc = libRoot.appendingPathComponent("wine", isDirectory: true)
        guard OnwinPaths.exists(wineSrc.appendingPathComponent("x86_64-windows")) else {
            throw OnwinError(String(localized: "Рядом с D3DMetal.framework нет папки wine/x86_64-windows (\(wineSrc.path))", bundle: .onwinCore))
        }
        try OnwinPaths.ensureLayout()
        let staging = OnwinPaths.graphics.appendingPathComponent(".D3DMetal-import", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.copyItem(at: external, to: staging.appendingPathComponent("external"))
        try fm.createDirectory(at: staging.appendingPathComponent("wine"), withIntermediateDirectories: true)
        for sub in ["x86_64-windows", "x86_64-unix", "i386-windows"] {
            let s = wineSrc.appendingPathComponent(sub)
            if OnwinPaths.exists(s) { try fm.copyItem(at: s, to: staging.appendingPathComponent("wine/\(sub)")) }
        }
        // Remove quarantine so that macOS does not refuse to load the framework.
        let xattr = try? Process.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", staging.path])
        xattr?.waitUntilExit()
        try? fm.removeItem(at: OnwinPaths.d3dmetal)
        try fm.moveItem(at: staging, to: OnwinPaths.d3dmetal)
    }

    public static func removeD3DMetal() throws {
        if OnwinPaths.exists(OnwinPaths.d3dmetal) { try FileManager.default.removeItem(at: OnwinPaths.d3dmetal) }
    }

    static func findItem(named name: String, under root: URL, maxDepth: Int) -> URL? {
        if root.lastPathComponent == name { return root }
        guard maxDepth > 0 else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        if let hit = entries.first(where: { $0.lastPathComponent == name }) { return hit }
        for entry in entries where OnwinPaths.isDirectory(entry) && entry.pathExtension != "framework" {
            if let hit = findItem(named: name, under: entry, maxDepth: maxDepth - 1) { return hit }
        }
        return nil
    }
}
