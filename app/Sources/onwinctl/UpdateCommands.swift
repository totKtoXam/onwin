import Foundation
import OnwinCore

// `onwinctl update [--check] [--version <версия>]`: the same update as «Проверить обновления…» in the app
// (Updater.swift). The engine is updated from here; the app too, when it is not open — an open onwin is
// updated from its own menu, so it can restart itself.

func runUpdateCommand(_ command: String, _ arguments: [String]) async throws -> Bool {
    if command == "engine-setup" { try await runEngineSetup(arguments); return true }
    if command == "addons" { try await runAddons(arguments); return true }
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

// `onwinctl engine-setup [--check]`: what the app does at first launch when it has no engine (the light DMG):
// the engine of this onwin version's release (Updater.manifestForEngineSetup) into Engines/<id>.
func runEngineSetup(_ arguments: [String]) async throws {
    let checkOnly = arguments.contains("--check")
    guard arguments.allSatisfy({ $0 == "--check" }) else { fail("использование: onwinctl engine-setup [--check]") }
    let plan = try await Updater.engineSetupPlan()
    let asset = plan.manifest.engine
    print("Выпуск:  onwin \(OnwinVersion.display(plan.manifest.version)), движок \(asset.id) от \(asset.built), \(Updater.sizeText(asset.size))")
    if plan.engine == .none, let engine = Updater.installedEngine(id: asset.id) {
        print("Движок уже установлен: \(engine.root.path)")
        return
    }
    if checkOnly { print("Установить: onwinctl engine-setup"); return }
    let engine = try await Updater.installEngineForSetup(plan, progress: printProgress)
    print("Движок установлен: \(engine.root.path)")
}

// `onwinctl addons [install mono|gecko|all]`: Wine Mono / Gecko of the default engine (EngineAddons.swift).
// Normally onwin adds them by itself when a program needs them.
func runAddons(_ arguments: [String]) async throws {
    let usage = "использование: onwinctl addons [install mono|gecko|all]"
    guard let engine = try? EngineManager.engine(for: nil) else { fail("движок Wine не установлен (onwinctl engine-setup)") }
    if arguments.isEmpty {
        print("Движок: \(engine.id) — \(engine.root.path)")
        for addon in EngineAddon.allCases {
            print("  \(addon.title): \(addon.isInstalled(in: engine) ? "есть" : "нет (\(Updater.sizeText(addon.size)) при первой необходимости)")")
        }
        return
    }
    guard arguments.count == 2, arguments[0] == "install" else { fail(usage) }
    let addons: [EngineAddon]
    switch arguments[1] {
    case "mono": addons = [.mono]
    case "gecko": addons = EngineAddon.gecko
    case "all": addons = EngineAddon.allCases
    default: fail(usage)
    }
    if try await EngineAddons.install(addons, into: engine, progress: printProgress) {
        print("Готово. Пространства обновятся при следующем запуске.")
    } else {
        print("Уже установлено.")
    }
}
