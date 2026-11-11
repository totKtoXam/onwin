import AppKit
import Observation
import SwiftUI
import OnwinCore

// Built-in updates (OnwinCore/Updater.swift): the launch check (at most once a day, «Проверять обновления
// автоматически» in Preferences), the menu item «Проверить обновления…», the banner «Доступна onwin X» above
// the main window's content with its progress, and the final restart into the new version.

@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        /// Downloading / installing: status line and 0...1 (nil = unknown).
        case working(message: String, fraction: Double?)
        /// The helper waits for onwin to quit; onwin is quitting.
        case restarting
        /// Engine-only update finished (no restart needed).
        case finished(String)
    }

    /// The update the banner offers; nil = nothing to show.
    private(set) var plan: UpdatePlan?
    private(set) var phase: Phase = .idle

    @ObservationIgnored private var work: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .checking, .working, .restarting: return true
        case .idle, .finished: return false
        }
    }

    // MARK: Checking

    /// At launch: the first time asks whether to check automatically (opt-in, nothing is sent before the
    /// answer); afterwards checks when enabled and the last check was more than a day ago.
    func checkAtLaunchIfNeeded() {
        let settings = OnwinSettings.load()
        guard Self.runningApp != nil else { return }
        guard let enabled = settings.checkForUpdates else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // after the main window has appeared
                self.askAboutAutomaticChecks()
            }
            return
        }
        guard enabled else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600, last <= Date() { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // let the window and the engine scan settle
            await self.check(userInitiated: false)
        }
    }

    /// The one-time question of the first launch; the answer can be changed in Preferences.
    private func askAboutAutomaticChecks() {
        guard OnwinSettings.load().checkForUpdates == nil else { return }
        let answer = Self.alert("Проверять обновления onwin автоматически?",
                                "onwin раз в день спросит у GitHub, вышла ли новая версия. Ничего не скачивается без вашего согласия.\n\nЭто можно поменять в любой момент в настройках onwin.",
                                buttons: ["Проверять", "Не проверять"])
        let yes = answer == .alertFirstButtonReturn
        AppModel.shared.updateSettings { $0.checkForUpdates = yes }
        if yes { Task { await self.check(userInitiated: false) } }
    }

    /// «Проверить обновления…». `userInitiated` also reports «нет обновлений» and errors; the automatic
    /// check is silent and respects «Пропустить эту версию».
    func check(userInitiated: Bool) async {
        if isBusy {
            if userInitiated { showMainWindow() }
            return
        }
        phase = .checking
        do {
            let manifest = try await Updater.latestManifest()
            AppModel.shared.updateSettings { $0.lastUpdateCheck = Date() }
            phase = .idle
            let found = Updater.plan(for: manifest, app: Self.runningApp)
            guard found.hasUpdate else {
                plan = nil
                if userInitiated {
                    Self.alert("У вас последняя версия onwin",
                               "Установлена onwin \(OnwinVersion.displayString). Новее пока ничего не выходило.")
                }
                return
            }
            guard manifest.supportsThisMac else {
                plan = nil
                if userInitiated {
                    Self.alert("Вышла onwin \(OnwinVersion.display(manifest.version))",
                               UpdateError.unsupportedMac(manifest.minimumMacOS ?? "?").errorDescription ?? "")
                }
                return
            }
            if !userInitiated, OnwinSettings.load().skippedUpdateVersion == manifest.version { return }
            plan = found
            if userInitiated { presentFound(found) }
        } catch {
            phase = .idle
            if userInitiated, !(error is CancellationError) {
                Self.alert("Не удалось проверить обновления", error.localizedDescription)
            }
        }
    }

    /// The banner lives in the main window; without one (all windows closed) ask in an alert instead.
    private func presentFound(_ found: UpdatePlan) {
        if showMainWindow() { return }
        let answer = Self.alert("Доступна onwin \(OnwinVersion.display(found.manifest.version))", Self.sizeLine(found),
                                buttons: ["Обновить", "Позже", "Пропустить эту версию"])
        switch answer {
        case .alertFirstButtonReturn: update()
        case .alertThirdButtonReturn: skip()
        default: later()
        }
    }

    @discardableResult
    private func showMainWindow() -> Bool {
        guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    /// The app this process runs from — the one an update replaces. nil for a build started outside an
    /// Onwin.app (swift run): it is not updated in place, the update offers the download page instead.
    /// ONWIN_APP_DIR (tests) points at another copy.
    static var runningApp: InstalledApp? {
        if let dir = ProcessInfo.processInfo.environment["ONWIN_APP_DIR"], !dir.isEmpty { return Updater.installedApp() }
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? InstalledApp(url: bundle) : nil
    }

    // MARK: Banner buttons

    func later() {
        plan = nil
    }

    func skip() {
        if let version = plan?.manifest.version {
            AppModel.shared.updateSettings { $0.skippedUpdateVersion = version }
        }
        plan = nil
    }

    func dismissFinished() {
        if case .finished = phase { phase = .idle }
    }

    func cancel() {
        work?.cancel()
    }

    func update() {
        guard let plan, !isBusy else { return }
        work = Task { @MainActor in
            await self.run(plan)
            self.work = nil
        }
    }

    // MARK: Update

    private func run(_ plan: UpdatePlan) async {
        let manifest = plan.manifest
        if plan.appNeedsUpdate {
            guard let app = plan.app, Updater.canReplaceApp(at: app.url) else {
                offerDownloadPage(manifest, reason: UpdateError.notWritable(plan.app?.url ?? Bundle.main.bundleURL)
                    .errorDescription ?? "")
                return
            }
        }
        // Wine programs: an engine cannot be replaced under them; the app restart leaves them running.
        let servers = await Updater.runningWineServers()
        if plan.engine == .download,
           await Updater.isEngineInUse(OnwinPaths.engines.appendingPathComponent(manifest.engine.id), servers: servers) {
            Self.alert("Сначала закройте Windows-программы", UpdateError.engineInUse(manifest.engine.id).errorDescription ?? "")
            return
        }
        if plan.appNeedsUpdate {
            if let bundled = plan.app?.bundledEngine, await Updater.isEngineInUse(bundled.root, servers: servers) {
                Self.alert("Сначала закройте Windows-программы",
                           "Сейчас работают Windows-программы, а движок Wine у них внутри приложения onwin, которое будет заменено. Закройте их и нажмите «Обновить» ещё раз.")
                return
            }
            if !servers.isEmpty || !ProcessTracker.shared.running.isEmpty {
                let answer = Self.alert("onwin закроется и откроется снова",
                                        "Сейчас работают Windows-программы. Они продолжат работать, но в окне onwin после перезапуска их не будет в списке «Запущено». Если в программе есть несохранённые данные — сохраните их заранее.",
                                        buttons: ["Обновить", "Отмена"])
                guard answer == .alertFirstButtonReturn else { return }
            }
        }

        phase = .working(message: "Готовлюсь к обновлению…", fraction: nil)
        let progress: ProgressHandler = { [weak self] p in
            Task { @MainActor in self?.report(p) }
        }
        do {
            if plan.engine != .none {
                try await Updater.installEngine(plan, progress: progress)
                AppModel.shared.reload()
            }
            try Task.checkCancellation()
            guard plan.appNeedsUpdate, let app = plan.app else {
                Updater.cleanUpDownloads()
                self.plan = nil
                phase = .finished("Движок Wine обновлён до сборки от \(Self.dateText(manifest.engine.builtDate)).")
                return
            }
            let prepared = try await Updater.prepareApp(plan, target: app.url, progress: progress)
            try Task.checkCancellation()
            phase = .restarting
            try await Updater.replaceApp(prepared, waitingFor: ProcessInfo.processInfo.processIdentifier, relaunch: true)
            Updater.cleanUpDownloads()
            try? await Task.sleep(nanoseconds: 300_000_000)   // the restart line is visible for a moment
            NSApplication.shared.terminate(nil)
        } catch is CancellationError {
            phase = .idle
        } catch let error as URLError where error.code == .cancelled {
            phase = .idle
        } catch UpdateError.notWritable(let url) {
            phase = .idle
            offerDownloadPage(manifest, reason: UpdateError.notWritable(url).errorDescription ?? "")
        } catch {
            phase = .idle
            Self.alert("Не удалось обновить onwin", error.localizedDescription)
        }
    }

    private func report(_ p: InstallProgress) {
        guard case .working = phase else { return }
        let text = p.message.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .working(message: text.isEmpty ? "Обновляю…" : text, fraction: p.fraction)
    }

    private func offerDownloadPage(_ manifest: ReleaseManifest, reason: String) {
        let answer = Self.alert("Обновите onwin вручную", reason, buttons: ["Открыть страницу загрузки", "Отмена"])
        if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(manifest.releasePage) }
    }

    // MARK: Text

    /// «~5 МБ», «~5 МБ + ~200 МБ движок», «движок Wine ~200 МБ».
    static func sizeLine(_ plan: UpdatePlan) -> String {
        var parts: [String] = []
        if plan.appNeedsUpdate { parts.append(Updater.sizeText(plan.appDownloadSize)) }
        if plan.engineDownloadSize > 0 {
            parts.append(plan.appNeedsUpdate ? "+ \(Updater.sizeText(plan.engineDownloadSize)) движок"
                                             : "движок Wine \(Updater.sizeText(plan.engineDownloadSize))")
        }
        return "Скачать: " + parts.joined(separator: " ")
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    @discardableResult
    static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

// MARK: - Banner

/// «Доступна onwin X» above the content of the main window (ShellDetail).
@MainActor
struct UpdateBanner: View {
    var body: some View {
        let updates = UpdateController.shared
        if let plan = updates.plan {
            content(plan, updates: updates)
        } else if case .finished(let message) = updates.phase {
            bar {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OnwinTheme.accent)
                Text(message)
                    .font(.callout)
                Spacer()
                Button("Закрыть") { updates.dismissFinished() }
            }
        }
    }

    @ViewBuilder
    private func content(_ plan: UpdatePlan, updates: UpdateController) -> some View {
        bar {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(OnwinTheme.accent)
            switch updates.phase {
            case .working(let message, let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Обновляю onwin до \(OnwinVersion.display(plan.manifest.version))")
                        .font(.callout.weight(.semibold))
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Отменить") { updates.cancel() }
            case .restarting:
                ProgressView()
                    .controlSize(.small)
                Text("Перезапускаю onwin…")
                    .font(.callout.weight(.semibold))
                Spacer()
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Доступна onwin \(OnwinVersion.display(plan.manifest.version))")
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(UpdateController.sizeLine(plan))
                            .foregroundStyle(.secondary)
                        Link("Что нового", destination: plan.manifest.releasePage)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 12)
                Button("Пропустить эту версию") { updates.skip() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Не напоминать об onwin \(OnwinVersion.display(plan.manifest.version)). Проверить вручную можно в меню onwin.")
                Button("Позже") { updates.later() }
                Button("Обновить") { updates.update() }
                    .buttonStyle(.borderedProminent)
                    .disabled(updates.isBusy)
                    .help("onwin скачает новую версию, закроется и откроется снова")
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Preferences

/// «Обновления» in Preferences → Основные.
@MainActor
struct PreferencesUpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = UpdateController.shared
        Section {
            Toggle(isOn: Binding(get: { model.settings.checkForUpdates ?? false },
                                 set: { value in model.updateSettings { $0.checkForUpdates = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Проверять обновления автоматически")
                    Text("Раз в день onwin спрашивает у GitHub, вышла ли новая версия. Ничего не скачивается без вашего согласия: новая версия ставится, только когда вы нажмёте «Обновить». Меню onwin → «Проверить обновления…» работает всегда.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Установлена onwin \(OnwinVersion.displayString)")
                    if let last = model.settings.lastUpdateCheck {
                        Text("Последняя проверка: \(last.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU"))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if updates.phase == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Проверить сейчас") {
                    Task { await updates.check(userInitiated: true) }
                }
                .disabled(updates.isBusy)
            }
        } header: {
            Text("Обновления")
        }
    }
}
