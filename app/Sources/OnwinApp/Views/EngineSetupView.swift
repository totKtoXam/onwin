import AppKit
import Observation
import SwiftUI
import OnwinCore

// First launch without an engine (the light DMG / app.zip have none): «Подготовка onwin» downloads the
// engine of this onwin version by itself — the same code path as an update (OnwinCore/Updater.swift:
// onwin-release.json, SHA-256, /usr/bin/tar, atomic swap into Engines/<id>). Nothing to ask: without the
// engine onwin cannot run anything. Can be cancelled and retried; a broken-off download continues.

@MainActor
@Observable
final class EngineSetupController {
    static let shared = EngineSetupController()

    enum Phase: Equatable {
        case idle
        case checking
        case working(message: String, fraction: Double?)
        case failed(String)
        case cancelled
        case finished
    }

    private(set) var phase: Phase = .idle
    /// Size of the engine download once the release is known.
    private(set) var downloadSize: Int64?
    /// «осталось ~3 мин» while downloading.
    private(set) var remaining: String?

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var started: Date?

    var isBusy: Bool {
        switch phase {
        case .checking, .working: return true
        default: return false
        }
    }

    /// Starts on its own when onwin has no engine (called by the screen when it appears).
    func startIfNeeded() {
        guard !AppModel.shared.hasEngine, !isBusy, phase != .cancelled, phase != .finished else { return }
        if case .failed = phase { return }   // the person retries with the button
        start()
    }

    func start() {
        guard !isBusy else { return }
        phase = .checking
        remaining = nil
        started = nil
        work = Task { @MainActor in
            do {
                let plan = try await Updater.engineSetupPlan()
                self.downloadSize = plan.engine == .none ? 0 : plan.manifest.engine.size
                guard plan.manifest.supportsThisMac else {
                    throw UpdateError.unsupportedMac(plan.manifest.minimumMacOS ?? "?")
                }
                let engine = try await Updater.installEngineForSetup(plan) { p in
                    Task { @MainActor in self.report(p) }
                }
                if EngineManager.defaultEngineID == nil { EngineManager.defaultEngineID = engine.id }
                self.phase = .finished
                AppModel.shared.reload()
                if AppModel.shared.selection == nil { AppModel.shared.selection = .desktop }
                // The one-time «check for updates automatically?» question waited for the engine.
                UpdateController.shared.checkAtLaunchIfNeeded()
            } catch is CancellationError {
                self.phase = .cancelled
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.work = nil
        }
    }

    func cancel() {
        work?.cancel()
    }

    private func report(_ p: InstallProgress) {
        guard isBusy else { return }
        if let fraction = p.fraction, fraction > 0.02, fraction < 1 {
            if started == nil { started = Date() }
            if let started {
                let elapsed = Date().timeIntervalSince(started)
                let left = elapsed / fraction * (1 - fraction)
                remaining = left < 60 ? "осталось меньше минуты" : "осталось ~\(Int((left / 60).rounded(.up))) мин"
            }
        } else if p.fraction == nil {
            remaining = nil
        }
        phase = .working(message: p.message, fraction: p.fraction)
    }
}

/// Slim banner on top of the detail column while there is no engine (another section is open).
@MainActor
struct ShellEngineBanner: View {
    @Environment(AppModel.self) private var model
    private var setup: EngineSetupController { .shared }

    var body: some View {
        HStack(spacing: 10) {
            if setup.isBusy {
                ProgressView().controlSize(.small)
                Text("onwin готовится к работе: скачивает движок Wine. Запуск программ — чуть позже.")
                    .font(.callout)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("Движок Wine ещё не установлен — запуск программ пока недоступен.")
                    .font(.callout)
            }
            Spacer()
            Button("Подробнее") { model.selection = nil }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// «Подготовка onwin»: the screen of the first launch while the engine is downloaded and installed.
@MainActor
struct ShellEngineSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showOtherWays = false
    private var setup: EngineSetupController { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    OnwinSpaceIcon(symbol: "shippingbox.fill", size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Подготовка onwin")
                            .font(.largeTitle.bold())
                        Text("Один раз onwin скачивает движок Wine — то, что запускает Windows-программы на Mac. Потом интернет для этого не нужен.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                status
                    .onwinCard(padding: 20)

                DisclosureGroup("Другие способы", isExpanded: $showOtherWays) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Если этот Mac не подключается к интернету, скачайте на другом компьютере вариант onwin «без интернета» (файл с «offline» в названии на странице выпуска: движок уже внутри) и перенесите onwin оттуда в «Программы».")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                model.open(OnwinLinks.releasePage(version: OnwinVersion.string))
                            } label: {
                                Label("Страница выпуска", systemImage: "safari")
                            }
                            Button {
                                model.installEngineInteractively()
                            } label: {
                                Label("Установить движок из папки…", systemImage: "folder.badge.plus")
                            }
                            .disabled(setup.isBusy)
                        }
                        Text("Для разработчиков: движок собирается скриптом engine/build.sh из исходного кода onwin; путь к нему можно задать переменной окружения ONWIN_ENGINE.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .task { setup.startIfNeeded() }
    }

    private var sizeLine: String? {
        guard let size = setup.downloadSize, size > 0 else { return nil }
        return "Размер загрузки: \(Updater.sizeText(size))."
    }

    @ViewBuilder
    private var status: some View {
        switch setup.phase {
        case .idle, .checking:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Узнаю, какой движок нужен этой версии onwin…")
            }
        case .working(let message, let fraction):
            VStack(alignment: .leading, spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(message)
                    .font(.callout.monospacedDigit())
                HStack {
                    Text([sizeLine, setup.remaining].compactMap { $0 }.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Отменить") { setup.cancel() }
                }
                Text("Можно пользоваться Mac как обычно. Если связь прервётся, нажмите «Повторить» — загрузка обычно продолжается с того же места.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("Движок не скачался", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(Color.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Проверьте подключение к интернету и нажмите «Повторить». Без интернета — см. «Другие способы» ниже.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 10) {
                Text("Загрузка остановлена. Без движка onwin не может запускать программы — продолжите, когда будет удобно.")
                    .fixedSize(horizontal: false, vertical: true)
                retryButton
            }
        case .finished:
            Label("Готово — движок установлен.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        }
    }

    private var retryButton: some View {
        Button {
            setup.start()
        } label: {
            Label("Повторить", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
