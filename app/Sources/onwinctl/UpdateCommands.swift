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
    guard rest.isEmpty else { fail(String(localized: "использование: onwinctl update [--check] [--version <версия>]", bundle: .onwinctl)) }

    let manifest: ReleaseManifest
    if let version { manifest = try await Updater.manifest(forVersion: version) } else { manifest = try await Updater.latestManifest() }
    let app = Updater.installedApp()
    let plan = Updater.plan(for: manifest, app: app, exact: version != nil)

    if let app {
        print(String(localized: "Приложение:  onwin \(app.displayVersion) (сборка \(app.build ?? "?")) — \(app.url.path)", bundle: .onwinctl))
    } else {
        print(String(localized: "Приложение:  не установлено", bundle: .onwinctl))
    }
    let installed = Updater.installedEngine(id: manifest.engine.id) ?? app?.bundledEngine
    if let installed {
        let built = installed.info.built.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        print(String(localized: "Движок:      \(installed.id), собран \(built) — \(installed.root.path)", bundle: .onwinctl))
    } else {
        print(String(localized: "Движок:      \(manifest.engine.id) не установлен", bundle: .onwinctl))
    }
    let release = OnwinVersion.display(manifest.version), build = manifest.build
    let engineID = manifest.engine.id, engineBuilt = manifest.engine.built
    print(version == nil
          ? String(localized: "Последний выпуск: onwin \(release) (сборка \(build)), движок \(engineID) от \(engineBuilt)", bundle: .onwinctl)
          : String(localized: "Выпуск: onwin \(release) (сборка \(build)), движок \(engineID) от \(engineBuilt)", bundle: .onwinctl))
    print(String(localized: "Что нового:  \(manifest.releasePage.absoluteString)", bundle: .onwinctl))

    guard plan.hasUpdate else {
        print(version == nil ? String(localized: "Обновлять нечего: установлена последняя версия.", bundle: .onwinctl)
                             : String(localized: "Обновлять нечего: установлена эта версия.", bundle: .onwinctl))
        return true
    }
    print(String(localized: "Нужно:", bundle: .onwinctl, comment: "Followed by the list of parts to update"))
    if plan.appNeedsUpdate {
        print("  • " + String(localized: "приложение onwin \(release), \(Updater.sizeText(manifest.app.size))", bundle: .onwinctl))
    }
    switch plan.engine {
    case .none: break
    case .download:
        print("  • " + String(localized: "движок Wine \(engineID), \(Updater.sizeText(manifest.engine.size))", bundle: .onwinctl))
    case .copyFromApp:
        print("  • " + String(localized: "перенести движок Wine из приложения в \(OnwinPaths.engines.path) (без загрузки)", bundle: .onwinctl))
    }
    if checkOnly {
        print(String(localized: "Обновить: onwinctl update", bundle: .onwinctl))
        return true
    }
    guard manifest.supportsThisMac else { throw UpdateError.unsupportedMac(manifest.minimumMacOS ?? "?") }

    // The app is checked before anything is downloaded: nothing is half done when it cannot be replaced.
    let target = app?.url ?? Updater.defaultAppLocations.first { Updater.canReplaceApp(at: $0) } ?? Updater.defaultAppLocations[0]
    var appBlocked: String?
    if plan.appNeedsUpdate {
        if await Updater.isAppRunning(at: target) {
            appBlocked = String(localized: """
            onwin сейчас открыт. Обновите его из самого приложения: меню «onwin» → «Проверить обновления…»
            (onwin перезапустится сам) — или закройте onwin и выполните onwinctl update ещё раз.
            """, bundle: .onwinctl)
        } else if !Updater.canReplaceApp(at: target) {
            appBlocked = (UpdateError.notWritable(target).errorDescription ?? "") + "\n" +
                String(localized: "Страница выпуска: \(manifest.releasePage.absoluteString)", bundle: .onwinctl)
        }
    }

    if plan.engine != .none {
        if case .copyFromApp = plan.engine, appBlocked != nil {
            // The app stays as it is, with its engine inside: nothing to move.
        } else if let engine = try await Updater.installEngine(plan, progress: printProgress) {
            print(String(localized: "Движок установлен: \(engine.root.path)", bundle: .onwinctl))
        }
    }
    if plan.appNeedsUpdate {
        if let appBlocked { print(appBlocked); exit(1) }
        let prepared = try await Updater.prepareApp(plan, target: target, progress: printProgress)
        try await Updater.replaceApp(prepared, waitingFor: nil, relaunch: false)
        print(String(localized: "Приложение установлено: \(target.path)", bundle: .onwinctl))
    }
    Updater.cleanUpDownloads()
    print(String(localized: "Готово: onwin \(OnwinVersion.display(manifest.version)).", bundle: .onwinctl))
    return true
}
