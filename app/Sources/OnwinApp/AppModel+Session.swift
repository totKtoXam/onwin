import AppKit
import Foundation
import OnwinCore

// Space session control for views (see WineRunner+Session.swift in OnwinCore):
//
//   func isSpaceRunning(_ space: Space) -> Bool     wineserver alive (also for programs started outside onwin)
//   func quitAll(in space: Space) async              (AppModel.swift) soft: wineboot --end-session --shutdown --kill --force,
//                                                      after 10 s wineserver -k; reports a refusal
//   func forceQuitAll(in space: Space) async         "Принудительно": wineserver -k right away
//   func restartSpace(_ spaceID: UUID, applying: RestartSensitiveChange) async
//        "Перезапустить пространство": soft shutdown (→ kill), then saves the change (MSync / Retina) through
//        updateConfig, in the task sheet.

/// Settings a running wineserver does not pick up: MSync (WINEMSYNC is read by the server and by
/// every process at start — switching it live mixes sync modes) and Retina mode (RetinaMode/LogPixels
/// are read when the Mac driver and the programs start).
struct RestartSensitiveChange: Equatable, Sendable {
    var msync: Bool?
    var highResolution: Bool?

    var isEmpty: Bool { msync == nil && highResolution == nil }

    /// The fields of `new` that differ from `old`.
    init(from old: SpaceConfig, to new: SpaceConfig) {
        msync = old.msync != new.msync ? new.msync : nil
        highResolution = old.highResolution != new.highResolution ? new.highResolution : nil
    }

    func apply(to config: inout SpaceConfig) {
        if let msync { config.msync = msync }
        if let highResolution { config.highResolution = highResolution }
    }

    /// "Перезапустить пространство и включить MSync"
    var actionTitle: String {
        var parts: [String] = []
        if let msync { parts.append(msync ? "включить MSync" : "выключить MSync") }
        if let highResolution { parts.append(highResolution ? "включить режим Retina" : "выключить режим Retina") }
        return "Перезапустить пространство и " + parts.joined(separator: ", ")
    }
}

extension AppModel {
    /// True while the space's wineserver runs: programs started from onwin, from onwinctl, from a
    /// launcher, or Wine's own services that linger a few seconds after the last program.
    func isSpaceRunning(_ space: Space) -> Bool {
        guard let engine = engine(for: space), let runner = try? WineRunner(space: space, engine: engine) else {
            return isRunning(space.id)
        }
        return runner.isServerRunning || isRunning(space.id)
    }

    /// Soft shutdown used by every "Завершить всё" (`quitAll` calls it).
    func softShutdown(_ space: Space) async {
        let current = self.space(id: space.id) ?? space
        backgroundActivity = "Завершаю программы «\(current.name)»…"
        defer { backgroundActivity = nil }
        do {
            let runner = try WineRunner(space: current)
            if try await runner.shutdown() == .refused {
                report("Программа в пространстве «\(current.name)» отказалась завершаться — возможно, она спрашивает, сохранить ли изменения. Ответьте ей или выберите «Принудительно».")
            }
        } catch {
            report(error)
        }
    }

    /// `wineserver -k`: stops everything at once, unsaved data is lost.
    func forceQuitAll(in space: Space) async {
        do {
            try await WineRunner(space: self.space(id: space.id) ?? space).killAll()
        } catch {
            report(error)
        }
    }

    /// Shuts the space down (soft, then kill after 10 s) and saves `change`; registry parts (Retina)
    /// are then applied by `updateConfig` as usual, with the space already stopped.
    func restartSpace(_ spaceID: UUID, applying change: RestartSensitiveChange) async {
        guard let space = space(id: spaceID), !change.isEmpty else { return }
        let name = space.name
        _ = await performTask("Перезапуск пространства «\(name)»", autoClose: true) { [self] context in
            context.status("Закрываю программы пространства…")
            let runner = try WineRunner(space: space)
            let outcome = try await runner.shutdown(onOutput: context.log)
            if outcome == .refused {
                throw OnwinError("Программа в пространстве «\(name)» отказалась завершаться (например, ждёт ответа «Сохранить изменения?»). Ответьте ей и повторите, или завершите пространство принудительно. Настройка не изменена.")
            }
            if outcome == .forced { context.log("Часть программ пришлось завершить принудительно.\n") }
            context.status("Сохраняю настройки…")
            self.updateConfig(of: spaceID) { change.apply(to: &$0) }
            context.status("Пространство перезапущено. Запустите программы снова — настройка уже действует.")
        }
    }
}
