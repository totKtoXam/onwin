import Foundation

/// Automatic component installation («Устанавливать нужные компоненты автоматически»):
///
/// * before the first run of a program in a space: `DependencyAdvisor` reads its import tables, every
///   space component it finds (Visual C++, DirectX, d3dcompiler_47, Wine Mono, PhysX…) is installed
///   silently, the program is remembered in `SpaceConfig.analyzedPrograms`, then it starts;
/// * after a run that failed: the Wine log is read (`err:module:import_dll Library X.dll … not found`),
///   the missing components are installed and the program is started once more.
///
/// D3DMetal is never installed here: it needs the user's Apple ID, so the caller only offers it
/// (`Plan.d3dmetal`). Installers run with their quiet switches (Catalog.swift), no window asks anything.
public enum AutoComponents {
    /// What to do for one program.
    public struct Plan: Sendable {
        /// Space components to install, in catalog order (prerequisites are handled by the installer).
        public var install: [Component]
        /// D3DMetal suggestion (shown as an offer, never installed automatically).
        public var d3dmetal: Suggestion?
        /// Everything the analysis found, including hints (for logs and the CLI).
        public var suggestions: [Suggestion]

        public var isEmpty: Bool { install.isEmpty && d3dmetal == nil }

        public init(install: [Component] = [], d3dmetal: Suggestion? = nil, suggestions: [Suggestion] = []) {
            self.install = install; self.d3dmetal = d3dmetal; self.suggestions = suggestions
        }

        /// "Visual C++ v14 (2015–2026), DirectX (июнь 2010)"
        public var componentNames: String { install.map(\.name).joined(separator: ", ") }
    }

    // MARK: Settings

    /// The space's own choice, otherwise onwin's setting (on by default).
    public static func isEnabled(for config: SpaceConfig, settings: Settings = .load()) -> Bool {
        config.autoInstallComponents ?? settings.autoInstallComponents
    }

    // MARK: Which file

    /// The Windows program a launch file stands for: the exe itself, the target of a .lnk; nil for
    /// .msi / .bat / documents and for Wine's own programs in C:\windows.
    public static func executable(for launchFile: URL, in space: Space) -> URL? {
        var file = launchFile
        if file.pathExtension.lowercased() == "lnk" {
            guard let target = ShellLink.parse(file)?.targetPath, let unix = space.unixPath(forWindowsPath: target) else { return nil }
            file = unix
        }
        guard ["exe", "com", "scr"].contains(file.pathExtension.lowercased()), OnwinPaths.exists(file) else { return nil }
        let windows = space.driveC.appendingPathComponent("windows").standardizedFileURL.resolvingSymlinksInPath().path
        if file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(windows + "/") { return nil }
        return file
    }

    /// How a program is remembered in `analyzedPrograms`: its Windows path in lower case
    /// (stays valid when the space is renamed or moved).
    public static func key(for executable: URL, in space: Space) -> String {
        space.windowsPath(forUnixPath: executable).lowercased()
    }

    /// True when the program was not checked yet in this space.
    public static func needsAnalysis(_ executable: URL, in space: Space) -> Bool {
        !space.config.analyzedPrograms.contains(key(for: executable, in: space))
    }

    /// Remembers that the program was checked (config re-read from disk first, so nothing written
    /// meanwhile by an installer is lost). Returns the updated space.
    @discardableResult
    public static func markAnalyzed(_ executable: URL, in space: Space) throws -> Space {
        var current = (try? Space(url: space.url)) ?? space
        let key = key(for: executable, in: current)
        guard !current.config.analyzedPrograms.contains(key) else { return current }
        current.config.analyzedPrograms.append(key)
        // Keep the list bounded: oldest entries go first.
        if current.config.analyzedPrograms.count > 500 {
            current.config.analyzedPrograms.removeFirst(current.config.analyzedPrograms.count - 500)
        }
        try current.save()
        return current
    }

    // MARK: Plans

    /// Before the first run: from the import tables of the program and its folder.
    public static func staticPlan(for executable: URL, in space: Space) -> Plan {
        plan(from: DependencyAdvisor.analyze(executable: executable, space: space), space: space)
    }

    /// After a failed run: from its Wine log (a file, or the text printed by `onwinctl run`).
    public static func logPlan(log: URL, in space: Space) -> Plan {
        plan(from: DependencyAdvisor.analyze(log: log, space: space), space: space)
    }

    public static func logPlan(logText: String, in space: Space) -> Plan {
        plan(from: DependencyAdvisor.analyze(logText: logText, space: space), space: space)
    }

    static func plan(from suggestions: [Suggestion], space: Space) -> Plan {
        var install: [Component] = []
        var d3dmetal: Suggestion?
        for s in suggestions {
            guard let component = s.component else { continue }
            if component.kind == .global {
                if component.id == Catalog.d3dmetalID, !GraphicsSupport.isD3DMetalInstalled { d3dmetal = s }
                continue
            }
            if component.isInstalled(in: space.config) || install.contains(where: { $0.id == component.id }) { continue }
            install.append(component)
        }
        // Real .NET replaces Wine Mono: never install both.
        if install.contains(where: { $0.id == "dotnet48" }) { install.removeAll { $0.id == "wine-mono" } }
        let order = Dictionary(uniqueKeysWithValues: Catalog.components.enumerated().map { ($0.element.id, $0.offset) })
        install.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        return Plan(install: install, d3dmetal: d3dmetal, suggestions: suggestions)
    }

    // MARK: Installing

    /// Installs the plan's components one after another. `progress` gets "[1/2] Visual C++ …" lines.
    /// Returns the updated space. Stops at the first failure (the error names the component).
    public static func install(_ components: [Component], into space: Space,
                               progress: @escaping ProgressHandler) async throws -> Space {
        var current = space
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            if component.isInstalled(in: current.config) { continue }
            progress(.status("[\(index + 1)/\(components.count)] Устанавливаю \(component.name)…"))
            do {
                current = try await Installer.install(component: component, into: current, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw OnwinError("Не удалось установить \(component.name): \(error.localizedDescription)")
            }
        }
        return current
    }

    /// Russian explanation of why the components are needed (one line per component).
    public static func reasons(for plan: Plan) -> [String] {
        plan.install.map { c in
            let reason = plan.suggestions.first { $0.componentID == c.id }?.reason
            return reason.map { "\(c.name): \($0)" } ?? c.name
        }
    }
}
