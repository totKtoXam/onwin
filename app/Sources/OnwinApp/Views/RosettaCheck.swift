import SwiftUI
import OnwinCore

// Rosetta 2 check at app start.
// The engine is x86_64 Wine, so on Apple Silicon nothing starts without Rosetta. Hook: `.onwinRosettaCheck()`
// on the root view. Installing runs Apple's `softwareupdate --install-rosetta --agree-to-license` only
// after the user pressed the button that says what happens (licence + a possible macOS prompt).

extension View {
    /// Checks for Rosetta 2 once when the view appears and shows `RosettaInstallSheet` if it is missing.
    func onwinRosettaCheck() -> some View {
        modifier(RosettaCheckModifier())
    }
}

@MainActor
private struct RosettaCheckModifier: ViewModifier {
    @State private var isMissing = false
    @State private var didCheck = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !didCheck else { return }
                didCheck = true
                // `arch -x86_64` may have to start a process: keep it off the main thread.
                let installed = await Task.detached(priority: .utility) { HostSupport.isRosettaInstalled() }.value
                if !installed { isMissing = true }
            }
            .sheet(isPresented: $isMissing) {
                RosettaInstallSheet()
                    .tint(OnwinTheme.accent)
                    .interactiveDismissDisabled(true)
            }
    }
}

/// "Для onwin нужна Rosetta 2": explanation, install button, progress and result.
@MainActor
struct RosettaInstallSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case ask
        case installing
        case done
        case failed(String)
    }

    @State private var phase: Phase = .ask
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                OnwinSpaceIcon(symbol: symbol, size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if phase == .ask {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Rosetta 2 — переводчик Apple для программ, собранных для Intel. Windows-программы в onwin работают через неё.",
                          systemImage: "cpu")
                    Label("Кнопка «Установить» запустит softwareupdate --install-rosetta --agree-to-license: это значит, что вы принимаете лицензию Apple на Rosetta.",
                          systemImage: "doc.text")
                    Label("macOS может показать своё окно — запрос пароля администратора или подтверждение загрузки. Его нужно подтвердить вручную.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Label("Нужен интернет; загрузка — несколько сотен мегабайт и обычно занимает пару минут.",
                          systemImage: "arrow.down.circle")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .onwinCard(padding: 14)
            }

            if phase == .installing || !output.isEmpty {
                ScrollView {
                    Text(verbatim: output.isEmpty ? String(localized: "Запускаю softwareupdate…") : output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
                .onwinCard(padding: 10)
            }

            HStack {
                if phase == .installing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Устанавливаю Rosetta 2…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch phase {
                case .ask, .failed:
                    Button("Позже") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(phase == .ask ? "Установить Rosetta" : "Попробовать снова") { install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                case .installing:
                    EmptyView()
                case .done:
                    Button("Готово") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var symbol: String {
        switch phase {
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch phase {
        case .done: return String(localized: "Rosetta 2 установлена")
        case .failed: return String(localized: "Rosetta 2 не установилась")
        default: return String(localized: "Для onwin нужна Rosetta 2")
        }
    }

    private var message: String {
        switch phase {
        case .ask:
            return String(localized: "Движок onwin (Wine) собран для процессоров Intel. На Mac с Apple Silicon без Rosetta 2 не запустится ни одна Windows-программа. Установить её сейчас?")
        case .installing:
            return String(localized: "Если macOS попросит пароль администратора или подтверждение — подтвердите в её окне.")
        case .done:
            return String(localized: "Можно запускать Windows-программы.")
        case .failed(let reason):
            return String(localized: "\(reason)\nМожно установить вручную в Терминале: softwareupdate --install-rosetta --agree-to-license")
        }
    }

    private func install() {
        phase = .installing
        output = ""
        Task { @MainActor in
            do {
                try await HostSupport.installRosetta(onOutput: { text in
                    Task { @MainActor in output += text }
                })
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
