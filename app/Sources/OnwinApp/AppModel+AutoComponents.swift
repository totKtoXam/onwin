import Foundation
import Observation
import OnwinCore

// MARK: - Automatic components («Устанавливать нужные компоненты автоматически»)
//
// Core logic: OnwinCore/AutoComponents.swift. Here it is wired into every launch of a Windows program:
//
//   launchPreparing(_ launchFile:in:title:start:)   the gate all program launches go through
//       (run(file:), run(program:), «Запустить с параметрами…», «Выполнить команду…»). When the option is on
//       and the exe was never checked in this space: its imports are read in the background, the
//       components it needs are installed silently in the progress sheet, the exe is remembered
//       (SpaceConfig.analyzedPrograms), then `start` runs. Otherwise `start` runs at once.
//       D3DMetal is only offered (AutoComponentsNotice.d3dmetal, buttons → installD3DMetal()).
//   repairAfterFailure(_:)   from programFinished: a run that failed within two minutes → its Wine log
//       is read, the missing components are installed and the program is started once more; a second
//       failure shows AutoComponentsNotice.failure with the log.
//   isPreparingLaunch(in:)   a deferred start is in progress for the space (callers treat it as started)
//   autoInstallsComponents(in:)   effective setting of a space (its own, otherwise Preferences)

/// Starts a program again the same way it was started (arguments, environment, per-program settings).
typealias LaunchAction = @MainActor (Space) -> RunningProgram?

/// What the automatic-components flow wants to tell the user (one sheet at a time, ShellSheets).
enum AutoComponentsNotice: Identifiable {
    struct D3DMetalOffer {
        var programTitle: String
        var spaceID: UUID
        var reason: String
        var start: LaunchAction
    }

    struct Failure {
        var programTitle: String
        var exitStatus: Int32
        var installed: [String]
        var stillMissing: [String]
        var logURL: URL
    }

    case d3dmetal(D3DMetalOffer)
    case failure(Failure)

    var id: String {
        switch self {
        case .d3dmetal(let o): return "d3dmetal-\(o.spaceID)-\(o.programTitle)"
        case .failure(let f): return "failure-\(f.logURL.path)"
        }
    }
}

@MainActor
@Observable
final class AutoComponentsState {
    static let shared = AutoComponentsState()

    var notice: AutoComponentsNotice?
    /// Spaces with a deferred start (checking / installing before the first run).
    private(set) var preparingSpaces: [UUID: Int] = [:]

    /// "<space id>|<exe key>" being prepared: a second click does not start a second check.
    @ObservationIgnored var preparing: Set<String> = []
    /// How each program started through the gate can be started again (RunningProgram.id → action).
    @ObservationIgnored var relaunch: [UUID: LaunchAction] = [:]
    /// Programs that are already the automatic second attempt.
    @ObservationIgnored var retried: [UUID: [String]] = [:]

    func beginPreparing(_ spaceID: UUID) { preparingSpaces[spaceID, default: 0] += 1 }

    func endPreparing(_ spaceID: UUID) {
        let left = (preparingSpaces[spaceID] ?? 1) - 1
        preparingSpaces[spaceID] = left > 0 ? left : nil
    }
}

extension AppModel {
    private var auto: AutoComponentsState { AutoComponentsState.shared }

    /// How long a failed run may have lasted for onwin to repair and restart it on its own.
    static let autoRepairWindow: TimeInterval = 120

    var autoComponentsNotice: AutoComponentsNotice? {
        get { auto.notice }
        set { auto.notice = newValue }
    }

    func isPreparingLaunch(in spaceID: UUID) -> Bool {
        auto.preparingSpaces[spaceID] != nil
    }

    func autoInstallsComponents(in space: Space) -> Bool {
        AutoComponents.isEnabled(for: (self.space(id: space.id) ?? space).config, settings: settings)
    }

    // MARK: Before the first run

    /// Runs `start` now, or first installs what the program needs (see the header). Returns the started
    /// program; nil when the start failed or was deferred (then `isPreparingLaunch(in:)` is true).
    @discardableResult
    func launchPreparing(_ launchFile: URL?, in space: Space, title: String,
                         start: @escaping LaunchAction) -> RunningProgram? {
        let current = self.space(id: space.id) ?? space
        guard hasEngine, current.isInitialized, autoInstallsComponents(in: current),
              let file = launchFile, let exe = AutoComponents.executable(for: file, in: current),
              AutoComponents.needsAnalysis(exe, in: current) else {
            return startTracked(start, in: current)
        }
        let key = "\(current.id)|\(AutoComponents.key(for: exe, in: current))"
        guard !auto.preparing.contains(key) else { return nil }
        auto.preparing.insert(key)
        auto.beginPreparing(current.id)
        Task { @MainActor in
            await self.prepare(exe, in: current, title: title, start: start)
            self.auto.preparing.remove(key)
            self.auto.endPreparing(current.id)
        }
        return nil
    }

    private func prepare(_ exe: URL, in snapshot: Space, title: String, start: @escaping LaunchAction) async {
        let activity = "Проверяю, что нужно «\(title)»…"
        backgroundActivity = activity
        let plan = await Task.detached(priority: .userInitiated) {
            AutoComponents.staticPlan(for: exe, in: snapshot)
        }.value
        if backgroundActivity == activity { backgroundActivity = nil }

        var space = self.space(id: snapshot.id) ?? snapshot
        if !plan.install.isEmpty {
            if let task = activeTask, !task.isFinished {
                // Another operation is running: start now, the check repeats at the next launch.
                startTracked(start, in: space)
                return
            }
            let names = plan.componentNames
            let target = space
            // The sheet the start came from (run options, «Запустить в…») may still be closing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let installed = await performTask("Подготовка к запуску «\(title)»") { (context: TaskContext) async throws -> Space in
                context.status("Для «\(title)» нужны: \(names). onwin установит их сам — это нужно только один раз.")
                for line in AutoComponents.reasons(for: plan) { context.log(line + "\n") }
                do {
                    return try await AutoComponents.install(plan.install, into: target, progress: context.progress)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw OnwinError(error.localizedDescription + "\n\nПрограмма всё равно запускается: многие игры работают и без этого. " +
                                     "onwin попробует установить компонент снова при следующем запуске.")
                }
            }
            reload()
            guard let installed else {
                // Cancelled: do not start. Failed: start anyway (the sheet explains), check again next time.
                if activeTask?.error != AppModel.cancelledMessage, let fresh = self.space(id: snapshot.id) {
                    startTracked(start, in: fresh)
                }
                return
            }
            space = installed
        }
        if let marked = try? AutoComponents.markAnalyzed(exe, in: space) {
            space = marked
            if let index = spaces.firstIndex(where: { $0.id == marked.id }) { spaces[index] = marked }
        }

        if let d3dmetal = plan.d3dmetal, !isD3DMetalInstalled {
            await waitForTaskSheetToClose()
            autoComponentsNotice = .d3dmetal(.init(programTitle: title, spaceID: space.id,
                                                   reason: d3dmetal.reason, start: start))
            return
        }
        startTracked(start, in: space)
    }

    /// «Установить D3DMetal» in the offer: the in-app flow, then the program.
    func acceptD3DMetalOffer(_ offer: AutoComponentsNotice.D3DMetalOffer) {
        autoComponentsNotice = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)   // let the offer sheet close
            guard await self.installD3DMetal() else { return }
            await self.waitForTaskSheetToClose()
            if let space = self.space(id: offer.spaceID) { self.startTracked(offer.start, in: space) }
        }
    }

    /// «Запустить без D3DMetal».
    func declineD3DMetalOffer(_ offer: AutoComponentsNotice.D3DMetalOffer) {
        autoComponentsNotice = nil
        if let space = space(id: offer.spaceID) { startTracked(offer.start, in: space) }
    }

    @discardableResult
    private func startTracked(_ start: @escaping LaunchAction, in space: Space) -> RunningProgram? {
        guard let program = start(space) else { return nil }
        auto.relaunch[program.id] = start
        return program
    }

    private func waitForTaskSheetToClose() async {
        for _ in 0..<40 where activeTask != nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: After a failed run

    /// Forgets how a finished program was started; returns the action and, for an automatic second
    /// attempt, the components installed before it.
    func takeRelaunchInfo(of program: RunningProgram) -> (start: LaunchAction?, retriedAfter: [String]?) {
        (auto.relaunch.removeValue(forKey: program.id), auto.retried.removeValue(forKey: program.id))
    }

    /// True when the failure was handled here (components installed and the program restarted, or the
    /// final explanation shown); false → the usual suggestions.
    func repairAfterFailure(_ program: RunningProgram, start: LaunchAction?, retriedAfter: [String]?) async -> Bool {
        guard let status = program.exitStatus, let space = space(id: program.spaceID), hasEngine,
              autoInstallsComponents(in: space),
              Date().timeIntervalSince(program.started) < AppModel.autoRepairWindow else { return false }
        let snapshot = space
        let log = program.logURL
        let plan = await Task.detached(priority: .userInitiated) {
            AutoComponents.logPlan(log: log, in: snapshot)
        }.value

        if let installed = retriedAfter {
            // Second failure right after onwin installed what the first one lacked.
            await adviseAfterFailure(program)
            autoComponentsNotice = .failure(.init(programTitle: program.title, exitStatus: status, installed: installed,
                                                  stillMissing: plan.install.map(\.name), logURL: log))
            return true
        }
        guard !plan.install.isEmpty else { return false }
        if let task = activeTask, !task.isFinished { return false }

        let names = plan.componentNames
        let title = program.title
        let result = await performTask("Исправление запуска «\(title)»") { (context: TaskContext) async throws -> Space in
            context.status("«\(title)» не запустилась: не хватает \(names). Устанавливаю…")
            for line in AutoComponents.reasons(for: plan) { context.log(line + "\n") }
            return try await AutoComponents.install(plan.install, into: snapshot, progress: context.progress)
        }
        reload()
        guard result != nil else { return true }   // the sheet shows the error
        clearFailureAdvice(for: snapshot.id)
        guard let start, let fresh = self.space(id: snapshot.id) else {
            report("onwin установил \(names) для «\(title)». Запустите программу ещё раз.")
            return true
        }
        await waitForTaskSheetToClose()
        if let again = startTracked(start, in: fresh) {
            auto.retried[again.id] = plan.install.map(\.name)
        }
        return true
    }
}
