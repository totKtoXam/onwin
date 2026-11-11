import SwiftUI
import OnwinCore

/// "Новое пространство" sheet. Presented by the shell through `model.showNewSpaceSheet`.
/// Cancel sets `showNewSpaceSheet = false`; "Создать" calls `model.createSpace(...)`, which closes this
/// sheet itself, shows TaskProgressSheet and selects the new space.
@MainActor
struct NewSpaceSheet: View {
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var backend: GraphicsBackend = .auto
    @State private var isCreating = false
    @State private var didPrepare = false
    @FocusState private var isNameFocused: Bool

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section {
                    TextField("Имя", text: $name, prompt: Text("Например, Steam или Ведьмак 3"))
                        .focused($isNameFocused)
                        .onSubmit { create() }
                    if let problem = nameProblem, didPrepare {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(trimmedName.isEmpty ? Color.secondary : Color.orange)
                    }
                    Picker("Версия Windows", selection: $windowsVersion) {
                        ForEach(WindowsVersion.allCases) { version in
                            Text(version.displayName).tag(version)
                        }
                    }
                } header: {
                    Text("Пространство")
                } footer: {
                    Text("Большинству игр и лаунчеров подходит Windows 10. Старым играм иногда нужна Windows 7 или XP — версию можно поменять потом в настройках пространства.")
                }

                Section {
                    SettingsBackendRows(selection: $backend, engine: model.defaultEngine)
                } header: {
                    Text("Графика")
                } footer: {
                    Text("«Автоматически» выбирает лучший доступный режим при каждом запуске. Режим тоже можно поменять потом.")
                }
            }
            .formStyle(.grouped)

            Divider()

            footer
        }
        .frame(width: 540, height: 640)
        .onAppear(perform: prepare)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 14) {
            OnwinSpaceIcon(symbol: "shippingbox.fill", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Новое пространство")
                    .font(.title2.weight(.semibold))
                Text("Отдельный «компьютер с Windows» для игры или программы. Пространства не мешают друг другу: в каждом свои настройки, библиотеки и сохранения.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(OnwinTheme.accent.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            engineStatus
            Spacer(minLength: 8)
            Button("Отмена") {
                model.showNewSpaceSheet = false
            }
            .keyboardShortcut(.cancelAction)
            Button {
                create()
            } label: {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 60)
                } else {
                    Text("Создать")
                        .frame(minWidth: 60)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
        }
        .padding(16)
    }

    @ViewBuilder
    private var engineStatus: some View {
        if let engine = model.defaultEngine {
            Label("\(engine.info.displayName) · Wine \(engine.info.wineVersion)", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Движок Wine для нового пространства (меняется в настройках onwin)")
        } else {
            Label("Движок Wine не установлен", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .help(AppModel.noEngineMessage)
        }
    }

    // MARK: Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        let candidate = trimmedName
        if candidate.isEmpty { return String(localized: "Введите имя пространства") }
        if candidate.hasPrefix(".") { return String(localized: "Имя не может начинаться с точки") }
        if candidate.count > 80 { return String(localized: "Слишком длинное имя — не больше 80 символов") }
        if model.spaces.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return String(localized: "Пространство «\(candidate)» уже есть — выберите другое имя")
        }
        return nil
    }

    private var isTaskRunning: Bool {
        if let task = model.activeTask { return !task.isFinished }
        return false
    }

    private var canCreate: Bool {
        nameProblem == nil && model.hasEngine && !isCreating && !isTaskRunning
    }

    // MARK: Actions

    private func prepare() {
        guard !didPrepare else { return }
        if name.isEmpty {
            name = SpaceManager.availableName(String(localized: "Новое пространство", comment: "Default name of a new space"))
        }
        backend = model.settings.defaultBackend
        didPrepare = true
        isNameFocused = true
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        let spaceName = trimmedName
        let version = windowsVersion
        let graphics = backend
        Task {
            await model.createSpace(name: spaceName, windowsVersion: version, backend: graphics)
            isCreating = false
        }
    }
}
