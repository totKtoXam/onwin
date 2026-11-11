import Foundation
import Metal

/// What this Mac can do: Rosetta 2, Apple Silicon, macOS version and Apple GPU family.
/// D3DMetal and DXMT need Apple Silicon and macOS Sonoma; MetalFX upscaling ("DLSS") needs macOS Tahoe
/// with D3DMetal and macOS Sonoma with DXMT (Apple's GPTK notes, DXMT wiki "Vendor Extensions").
public enum HostSupport {
    // MARK: Rosetta 2

    /// The Rosetta daemon; present once Rosetta 2 is installed.
    static let oahd = URL(fileURLWithPath: "/Library/Apple/usr/libexec/oahd")

    /// True on Apple Silicon (also when the caller itself runs translated).
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    /// The engine is x86_64 Wine, so on Apple Silicon nothing runs without Rosetta 2.
    /// Intel Macs do not need it. Checks the oahd daemon first, then really runs an x86_64 binary.
    public static func isRosettaInstalled() -> Bool {
        guard isAppleSilicon else { return true }
        if FileManager.default.isExecutableFile(atPath: oahd.path) { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Installs Rosetta 2 with Apple's tool. `--agree-to-license` accepts Apple's licence on the
    /// user's behalf, so only call this after the user pressed the button that says so. macOS may
    /// still show its own prompt (administrator password or a download confirmation).
    public static func installRosetta(onOutput: (@Sendable (String) -> Void)? = nil) async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                                            arguments: ["--install-rosetta", "--agree-to-license"],
                                            onOutput: onOutput)
        guard r.status == 0, isRosettaInstalled() else {
            let tail = r.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw OnwinError(String(localized: "Не удалось установить Rosetta 2 (код \(Int(r.status))). \(tail)", bundle: .onwinCore))
        }
    }

    // MARK: macOS and GPU

    public static func isOS(atLeast major: Int, _ minor: Int = 0) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
    }

    /// Apple GPU family 9 = M3 and newer: hardware ray tracing (needed by D3DMetal DXR).
    public static let supportsHardwareRaytracing: Bool = {
        guard isAppleSilicon, let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple9)
    }()

    public static var gpuName: String? { MTLCreateSystemDefaultDevice()?.name }

    /// "26.5.1 (25F80)": the same in every interface language (operatingSystemVersionString is worded
    /// in the system language, and macOS has no Kazakh).
    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { version += ".\(v.patchVersion)" }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return version }
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else { return version }
        return "\(version) (\(String(cString: build)))"
    }

    // MARK: Gating

    /// Why a backend cannot run on this Mac at all (independent of what is installed), or nil.
    public static func unsupportedReason(_ backend: GraphicsBackend) -> String? {
        switch backend {
        case .auto, .wined3d, .dxvk:
            return nil
        case .d3dmetal, .dxmt:
            if !isAppleSilicon { return String(localized: "нужен Mac с Apple Silicon", bundle: .onwinCore) }
            if !isOS(atLeast: 14) { return String(localized: "нужна macOS 14 Sonoma или новее", bundle: .onwinCore) }
            return nil
        }
    }

    /// Why DLSS → MetalFX cannot work with `backend` on this Mac, or nil.
    /// D3DMetal needs macOS 26 Tahoe; DXMT (DXMT_ENABLE_NVEXT) works on Apple Silicon with Sonoma+.
    public static func metalFXUnsupportedReason(_ backend: GraphicsBackend) -> String? {
        switch backend {
        case .d3dmetal:
            if let r = unsupportedReason(.d3dmetal) { return r }
            return isOS(atLeast: 26) ? nil : String(localized: "для D3DMetal нужна macOS 26 Tahoe или новее", bundle: .onwinCore)
        case .dxmt:
            return unsupportedReason(.dxmt)
        case .auto, .dxvk, .wined3d:
            return String(localized: "работает только с D3DMetal и DXMT", bundle: .onwinCore)
        }
    }

    /// Why DXR cannot work with `backend` on this Mac, or nil.
    public static func raytracingUnsupportedReason(_ backend: GraphicsBackend) -> String? {
        guard backend == .d3dmetal else { return String(localized: "работает только с D3DMetal", bundle: .onwinCore) }
        if let r = unsupportedReason(.d3dmetal) { return r }
        return supportsHardwareRaytracing ? nil : String(localized: "нужен чип M3 или новее (аппаратная трассировка лучей)", bundle: .onwinCore)
    }
}
