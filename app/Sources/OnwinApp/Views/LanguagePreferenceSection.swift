import AppKit
import SwiftUI
import OnwinCore

/// «Язык интерфейса» in Preferences → Основные: follow the system or force one of the translations
/// (OnwinLanguage in OnwinCore/Localization.swift). macOS reads the language once at launch, so a
/// change offers to restart onwin.
@MainActor
struct LanguagePreferenceSection: View {
    @Environment(AppModel.self) private var model
    /// nil = as in the system.
    @State private var choice: OnwinLanguage? = OnwinLanguage.appOverride
    /// The choice the running app was started with.
    @State private var launchChoice: OnwinLanguage? = OnwinLanguage.appOverride

    init() {}

    var body: some View {
        Section {
            Picker("Язык интерфейса", selection: $choice) {
                Text("Как в системе").tag(OnwinLanguage?.none)
                Divider()
                ForEach(OnwinLanguage.allCases) { language in
                    Text(verbatim: language.nativeName).tag(OnwinLanguage?.some(language))
                }
            }
            .onChange(of: choice) { _, newValue in
                OnwinLanguage.appOverride = newValue
            }
            if choice != launchChoice {
                HStack(alignment: .firstTextBaseline) {
                    Text("Новый язык появится после перезапуска onwin. Запущенные Windows-программы продолжат работать.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Перезапустить") {
                        Self.relaunch()
                    }
                    .disabled(model.activeTask.map { !$0.isFinished } ?? false)
                    .help(model.activeTask.map { !$0.isFinished } ?? false
                          ? String(localized: "Дождитесь окончания текущей операции")
                          : String(localized: "Закрыть onwin и сразу открыть его снова"))
                }
            }
        } footer: {
            Text("«Как в системе» — первый язык из настроек macOS, на который переведён onwin.")
        }
    }

    /// Quits onwin and opens it again once this process has exited.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
