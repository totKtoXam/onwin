import Foundation
import OnwinCore

// `onwinctl run` with automatic components (AutoComponents.swift): the same two steps as the app —
// before the first run of a program and once more after a run that failed for a missing library.

/// Runs `file` in the space and returns its exit status.
func runWithAutoComponents(space start: Space, file: URL, arguments: [String], auto requested: Bool) async throws -> Int32 {
    var b = start
    let auto = requested && AutoComponents.isEnabled(for: b.config)
    let exe = auto ? AutoComponents.executable(for: file, in: b) : nil

    if let exe, AutoComponents.needsAnalysis(exe, in: b) {
        print("onwin: проверяю, какие компоненты нужны \(exe.lastPathComponent)…")
        let plan = AutoComponents.staticPlan(for: exe, in: b)
        var installed = true
        if !plan.install.isEmpty {
            print("onwin: устанавливаю компоненты: \(plan.componentNames)")
            for line in AutoComponents.reasons(for: plan) { print("       \(line)") }
            do {
                b = try await AutoComponents.install(plan.install, into: b, progress: printProgress)
            } catch {
                installed = false
                FileHandle.standardError.write(Data("onwinctl: \(error.localizedDescription)\nonwin: запускаю программу без них.\n".utf8))
            }
        } else {
            print("onwin: дополнительные компоненты не нужны")
        }
        if let d3dmetal = plan.d3dmetal {
            print("onwin: \(d3dmetal.reason) D3DMetal ставится с вашим Apple ID: кнопкой «Установить D3DMetal» в onwin " +
                  "(или onwinctl d3dmetal-fetch, если образ уже скачан).")
        }
        // A failed install is retried at the next run.
        if installed { b = try AutoComponents.markAnalyzed(exe, in: b) }
    }

    var result = try await runOnce(b, file: file, arguments: arguments)
    guard auto, failed(result.status) else { return result.status }

    let plan = AutoComponents.logPlan(logText: result.output, in: b)
    guard !plan.install.isEmpty else { return result.status }
    print("\nonwin: программа завершилась с кодом \(result.status) — ей не хватает: \(plan.componentNames)")
    for line in AutoComponents.reasons(for: plan) { print("       \(line)") }
    b = try await AutoComponents.install(plan.install, into: b, progress: printProgress)
    print("onwin: компоненты установлены, запускаю программу ещё раз…\n")
    result = try await runOnce(b, file: file, arguments: arguments)
    if failed(result.status) {
        let left = AutoComponents.logPlan(logText: result.output, in: b)
        let missing = left.install.isEmpty ? "" : " Всё ещё не хватает: \(left.componentNames)."
        FileHandle.standardError.write(Data(("onwinctl: программа не запустилась и после установки компонентов " +
                                             "(код \(result.status)).\(missing)\n").utf8))
    }
    return result.status
}

private func runOnce(_ space: Space, file: URL, arguments: [String]) async throws -> ProcessRunner.Result {
    try await WineRunner(space: space).runAndWait(WineRunner.command(for: file, arguments: arguments),
                                                    currentDirectory: file.deletingLastPathComponent(),
                                                    onOutput: { print($0, terminator: "") })
}

/// Non-zero, and not an installer's "reboot required" / "already installed" / "cancelled".
private func failed(_ status: Int32) -> Bool {
    status != 0 && !([1602, 3010, 1638] as [Int32]).contains { WineRunner.exitStatus(status, matches: $0) }
}
