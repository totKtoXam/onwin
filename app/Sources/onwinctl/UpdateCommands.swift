import Foundation
import OnwinCore

// `onwinctl update [--check] [--version <версия>]`: the same update as «Проверить обновления…» in the app
// (Updater.swift). The engine is updated from here; the app too, when it is not open — an open onwin is
// updated from its own menu, so it can restart itself.

func runUpdateCommand(_ command: String, _ arguments: [String]) async throws -> Bool {
    guard command == "update" else { return false }
    var rest = arguments
    let version = option("--version", in: &rest)
    let checkOnly = rest.contains("--check")
    rest.removeAll { $0 == "--check" }
    guard rest.isEmpty else { fail("использование: onwinctl update [--check] [--version <версия>]") }

    let manifest: ReleaseManifest
    if let version { manifest = try await Updater.manifest(forVersion: version) } else { manifest = try await Updater.latestManifest() }
    let app = Updater.installedApp()
    let plan = Updater.plan(for: manifest, app: app, exact: version != nil)

    if let app {
        print("Приложение:  onwin \(app.displayVersion) (сборка \(app.build ?? "?")) — \(app.url.path)")
    } else {
        print("Приложение:  не установлено")
    }
    let installed = Updater.installedEngine(id: manifest.engine.id) ?? app?.bundledEngine
    if let installed {
        let built = installed.info.built.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        print("Движок:      \(installed.id), собран \(built) — \(installed.root.path)")
    } else {
        print("Движок:      \(manifest.engine.id) не установлен")
    }
    print("\(version == nil ? "Последний выпуск" : "Выпуск"): onwin \(OnwinVersion.display(manifest.version)) (сборка \(manifest.build)), " +
          "движок \(manifest.engine.id) от \(manifest.engine.built)")
    print("Что нового:  \(manifest.releasePage.absoluteString)")

    guard plan.hasUpdate else {
        print("Обновлять нечего: установлена \(version == nil ? "последняя" : "эта") версия.")
        return true
    }
    print("Нужно:")
    if plan.appNeedsUpdate { print("  • приложение onwin \(OnwinVersion.display(manifest.version)), \(Updater.sizeText(manifest.app.size))") }
    switch plan.engine {
    case .none: break
    case .download: print("  • движок Wine \(manifest.engine.id), \(Updater.sizeText(manifest.engine.size))")
    case .copyFromApp: print("  • перенести движок Wine из приложения в \(OnwinPaths.engines.path) (без загрузки)")
    }
    if checkOnly {
        print("Обновить: onwinctl update")
        return true
    }
    guard manifest.supportsThisMac else { throw UpdateError.unsupportedMac(manifest.minimumMacOS ?? "?") }

    // The app is checked before anything is downloaded: nothing is half done when it cannot be replaced.
    let target = app?.url ?? Updater.defaultAppLocations.first { Updater.canReplaceApp(at: $0) } ?? Updater.defaultAppLocations[0]
    var appBlocked: String?
    if plan.appNeedsUpdate {
        if await Updater.isAppRunning(at: target) {
            appBlocked = """
            onwin сейчас открыт. Обновите его из самого приложения: меню «onwin» → «Проверить обновления…»
            (onwin перезапустится сам) — или закройте onwin и выполните onwinctl update ещё раз.
            """
        } else if !Updater.canReplaceApp(at: target) {
            appBlocked = (UpdateError.notWritable(target).errorDescription ?? "") +
                "\nСтраница выпуска: \(manifest.releasePage.absoluteString)"
        }
    }

    if plan.engine != .none {
        if case .copyFromApp = plan.engine, appBlocked != nil {
            // The app stays as it is, with its engine inside: nothing to move.
        } else if let engine = try await Updater.installEngine(plan, progress: printProgress) {
            print("Движок установлен: \(engine.root.path)")
        }
    }
    if plan.appNeedsUpdate {
        if let appBlocked { print(appBlocked); exit(1) }
        let prepared = try await Updater.prepareApp(plan, target: target, progress: printProgress)
        try await Updater.replaceApp(prepared, waitingFor: nil, relaunch: false)
        print("Приложение установлено: \(target.path)")
    }
    Updater.cleanUpDownloads()
    print("Готово: onwin \(OnwinVersion.display(manifest.version)).")
    return true
}
