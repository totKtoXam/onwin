import Foundation
import Observation
import OnwinCore

// MARK: - Components & dependency suggestions (AppModel API, part 2)
//
// State (observable, in `ComponentAdvice.shared` because extensions cannot add stored properties;
// read it through the AppModel methods below):
//   staticSuggestions[spaceID]   from the import tables of the space's programs (DependencyAdvisor),
//                                 recomputed in the background whenever the program list loads
//   failures[spaceID]            from the Wine log of the last program that exited with an error
//   dismissed[spaceID]           suggestion ids the user hid ("Не сейчас"), kept in UserDefaults
//
// API:
//   func suggestions(for space: Space) -> [Suggestion]     merged (log first), installed / dismissed removed
//   func failureAdvice(for spaceID: UUID) -> FailureAdvice?  the failed run the log suggestions came from
//   func isAnalyzingDependencies(_ spaceID: UUID) -> Bool
//   func analyzeDependencies(of spaceID: UUID, force: Bool = false)   static scan (called from reload/refreshPrograms)
//   func adviseAfterFailure(_ program: RunningProgram) async -> [Suggestion]   (called from programFinished)
//   func dismissSuggestion(_ suggestion: Suggestion, in spaceID: UUID); func restoreDismissedSuggestions(in:)
//   func clearFailureAdvice(for spaceID: UUID)
//   func install(suggestion: Suggestion, in space: Space) async          component or D3DMetal flow
//   func installComponents(_ components: [Component], into space: Space) async -> Bool   one task, in order
//   func isInstalled(_ component: Component, in space: Space) -> Bool   (D3DMetal: imported globally)
//   func installedCount(of component: Component) -> Int                  spaces that have it
//   func fetchD3DMetal() async -> Bool      «Установить D3DMetal» = installD3DMetal() (D3DMetalInstallFlow.swift):
//                                           local .dmg or Apple ID sign-in in onwin, download, import

/// The failed run that produced log suggestions.
struct FailureAdvice: Equatable {
    var programTitle: String
    var logURL: URL
    var exitStatus: Int32
    var date: Date
    var suggestions: [Suggestion]
}

@MainActor
@Observable
final class ComponentAdvice {
    static let shared = ComponentAdvice()

    var staticSuggestions: [UUID: [Suggestion]] = [:]
    var failures: [UUID: FailureAdvice] = [:]
    var dismissed: [UUID: Set<String>] = ComponentAdvice.loadDismissed()
    var analyzing: Set<UUID> = []

    /// What the last static scan of a space was computed from (programs + installed components).
    @ObservationIgnored var staticKeys: [UUID: String] = [:]
    @ObservationIgnored var staticTasks: [UUID: Task<Void, Never>] = [:]

    private static let defaultsKey = "onwin.components.dismissedSuggestions"

    static func loadDismissed() -> [UUID: Set<String>] {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] else { return [:] }
        var result: [UUID: Set<String>] = [:]
        for (key, ids) in raw { if let id = UUID(uuidString: key) { result[id] = Set(ids) } }
        return result
    }

    func saveDismissed() {
        let raw = Dictionary(uniqueKeysWithValues: dismissed.map { ($0.key.uuidString, Array($0.value).sorted()) })
        UserDefaults.standard.set(raw, forKey: ComponentAdvice.defaultsKey)
    }
}

extension AppModel {
    private var advice: ComponentAdvice { ComponentAdvice.shared }

    // MARK: Reading

    func suggestions(for space: Space) -> [Suggestion] {
        let current = self.space(id: space.id) ?? space
        let hidden = advice.dismissed[current.id] ?? []
        let fromLog = advice.failures[current.id]?.suggestions ?? []
        return AppModel.merge(fromLog + (advice.staticSuggestions[current.id] ?? [])).filter { s in
            // Suggestions from a failed run are not hidden for good: they come back with the next failure.
            if hidden.contains(s.id) && s.source == .imports { return false }
            guard let component = s.component else { return true }
            if component.isInstalled(in: current.config) { return false }
            if component.id == "wine-mono", Catalog.component("dotnet48")?.isInstalled(in: current.config) == true { return false }
            return true
        }
    }

    func failureAdvice(for spaceID: UUID) -> FailureAdvice? {
        advice.failures[spaceID]
    }

    func isAnalyzingDependencies(_ spaceID: UUID) -> Bool {
        advice.analyzing.contains(spaceID)
    }

    func isInstalled(_ component: Component, in space: Space) -> Bool {
        if component.kind == .global { return isD3DMetalInstalled }
        return component.isInstalled(in: (self.space(id: space.id) ?? space).config)
    }

    func installedCount(of component: Component) -> Int {
        spaces.filter { component.isInstalled(in: $0.config) }.count
    }

    // MARK: Static analysis

    /// Scans the import tables of the space's programs in the background (skipped when neither the
    /// program list nor the installed components changed since the last scan).
    func analyzeDependencies(of spaceID: UUID, force: Bool = false) {
        guard let space = space(id: spaceID) else { return }
        let windowsDir = space.driveC.appendingPathComponent("windows").standardizedFileURL.path
        let executables = programs(in: space)
            .compactMap { $0.executable?.standardizedFileURL }
            .filter { $0.pathExtension.lowercased() == "exe" && !$0.path.hasPrefix(windowsDir + "/") }
        var unique: [URL] = []
        for exe in executables where !unique.contains(exe) { unique.append(exe) }
        let targets = Array(unique.prefix(12))
        let key = targets.map(\.path).joined(separator: "\n") + "|" + space.config.installedComponents.sorted().joined(separator: ",")
            + "|" + (isD3DMetalInstalled ? "d3dm" : "")
        if !force, advice.staticKeys[spaceID] == key { return }
        advice.staticKeys[spaceID] = key
        advice.staticTasks[spaceID]?.cancel()
        guard !targets.isEmpty else {
            // The cancelled scan (if any) never clears its own flag.
            advice.analyzing.remove(spaceID)
            advice.staticSuggestions[spaceID] = []
            return
        }
        advice.analyzing.insert(spaceID)
        let snapshot = space
        advice.staticTasks[spaceID] = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [Suggestion] in
                var all: [Suggestion] = []
                for exe in targets {
                    if Task.isCancelled { break }
                    all += DependencyAdvisor.analyze(executable: exe, space: snapshot)
                }
                return all
            }.value
            guard let self, !Task.isCancelled else { return }
            self.advice.staticSuggestions[spaceID] = AppModel.merge(found)
            self.advice.analyzing.remove(spaceID)
        }
    }

    // MARK: Dynamic analysis

    /// Reads the log of a program that exited with an error and remembers what it suggests.
    @discardableResult
    func adviseAfterFailure(_ program: RunningProgram) async -> [Suggestion] {
        guard let status = program.exitStatus, status != 0 else { return [] }
        let spaceID = program.spaceID
        let snapshot = space(id: spaceID)
        let log = program.logURL
        let found = await Task.detached(priority: .utility) {
            DependencyAdvisor.analyze(log: log, space: snapshot)
        }.value
        guard !found.isEmpty else { return [] }
        advice.failures[spaceID] = FailureAdvice(programTitle: program.title, logURL: log, exitStatus: status,
                                                  date: Date(), suggestions: found)
        return found
    }

    func clearFailureAdvice(for spaceID: UUID) {
        advice.failures[spaceID] = nil
    }

    func dismissSuggestion(_ suggestion: Suggestion, in spaceID: UUID) {
        if suggestion.source == .log, var failure = advice.failures[spaceID] {
            failure.suggestions.removeAll { $0.id == suggestion.id }
            advice.failures[spaceID] = failure.suggestions.isEmpty ? nil : failure
        }
        advice.dismissed[spaceID, default: []].insert(suggestion.id)
        advice.saveDismissed()
    }

    func restoreDismissedSuggestions(in spaceID: UUID) {
        advice.dismissed[spaceID] = nil
        advice.saveDismissed()
    }

    // MARK: Installing

    func install(suggestion: Suggestion, in space: Space) async {
        guard let component = suggestion.component else { return }
        await install(component: component, into: space)
        if isInstalled(component, in: space), var failure = advice.failures[space.id] {
            failure.suggestions.removeAll { $0.id == suggestion.id }
            advice.failures[space.id] = failure.suggestions.isEmpty ? nil : failure
        }
    }

    /// Installs several components into one space in a single progress sheet (D3DMetal is skipped:
    /// it has its own guided flow).
    @discardableResult
    func installComponents(_ components: [Component], into space: Space) async -> Bool {
        let list = components.filter { $0.kind == .space }
        guard !list.isEmpty else { return true }
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return false
        }
        let target = self.space(id: space.id) ?? space
        let title = list.count == 1 ? "Установка \(list[0].name)" : "Установка компонентов (\(list.count))"
        let result = await performTask(title, autoClose: false) { (context: TaskContext) async throws -> Space in
            var current = target
            for (index, component) in list.enumerated() where !component.isInstalled(in: current.config) {
                context.status("[\(index + 1)/\(list.count)] \(component.name)")
                current = try await Installer.install(component: component, into: current, progress: context.progress)
            }
            return current
        }
        reload()
        return result != nil
    }

    /// «Установить D3DMetal»: the in-app flow (sign-in, download, import) — D3DMetalInstallFlow.swift.
    @discardableResult
    func fetchD3DMetal() async -> Bool {
        await installD3DMetal()
    }

    // MARK: Helpers

    /// One entry per suggestion id (evidence of duplicates combined, highest priority kept).
    static func merge(_ list: [Suggestion]) -> [Suggestion] {
        var merged: [String: Suggestion] = [:]
        var order: [String] = []
        for s in list {
            if var existing = merged[s.id] {
                existing.evidence += s.evidence.filter { !existing.evidence.contains($0) }
                existing.evidence = Array(existing.evidence.prefix(8))
                existing.priority = max(existing.priority, s.priority)
                merged[s.id] = existing
            } else {
                merged[s.id] = s
                order.append(s.id)
            }
        }
        return order.compactMap { merged[$0] }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.title < $1.title }
    }
}
