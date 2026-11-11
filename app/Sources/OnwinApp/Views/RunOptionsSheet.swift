import AppKit
import SwiftUI
import OnwinCore

// "Запустить с параметрами…" (a program, Steam game or file) and "Выполнить команду…" (a free-form
// Windows command line). Both set, for this run only: arguments, variables, WINEDEBUG channels,
// Metal HUD, "не сообщать AVX" and the graphics backend; "Сохранить как программу" pins the program
// with these settings.

extension View {
    /// Attaches the program dialogs (ProgramDialogs.shared) for one space page.
    @MainActor
    func programDialogs(spaceID: UUID) -> some View {
        modifier(ProgramDialogsModifier(spaceID: spaceID))
    }
}

@MainActor
private struct ProgramDialogsModifier: ViewModifier {
    let spaceID: UUID
    @Environment(AppModel.self) private var model
    @State private var dialogs = ProgramDialogs.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { dialogs.request?.spaceID == spaceID ? dialogs.request : nil },
                                    set: { dialogs.request = $0 })) { request in
            Group {
                switch request {
                case .runWithOptions(let id, let target):
                    RunOptionsSheet(spaceID: id, mode: .target(target))
                case .runCommand(let id):
                    RunOptionsSheet(spaceID: id, mode: .command)
                case .uninstall(let id):
                    UninstallProgramsSheet(spaceID: id)
                }
            }
            .environment(model)
            .tint(OnwinTheme.accent)
        }
    }
}

/// One `KEY=VALUE` row of the variables editor.
private struct RunEnvRow: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""
}

@MainActor
struct RunOptionsSheet: View {
    enum Mode { case target(RunTarget), command }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID
    let mode: Mode

    @State private var commandLine = ""
    @State private var argumentsText = ""
    @State private var envRows: [RunEnvRow] = []
    @State private var wineDebug = ""
    @State private var metalHUD = false
    @State private var noAVX = false
    @State private var backend: GraphicsBackend = .auto
    @State private var saveAsProgram = false
    @State private var programName = ""
    @State private var didLoad = false

    private static let debugPresets: [(LocalizedStringKey, String)] = [
        ("Ошибки и загрузка DLL", "+err,+warn,+seh,+loaddll"),
        ("Только загрузка DLL", "+loaddll"),
        ("Графика (D3D, DXGI)", "+d3d,+dxgi,+d3d11,+d3d12"),
        ("Звук", "+mmdevapi,+xaudio2,+dsound"),
        ("Ввод и контроллеры", "+dinput,+xinput,+hid"),
        ("Сеть", "+winsock,+winhttp,+wininet"),
        ("Выключить журнал", "-all"),
    ]

    var body: some View {
        let space = model.space(id: spaceID)
        VStack(spacing: 0) {
            header(space)
            Divider()
            Form {
                if case .command = mode {
                    Section {
                        HStack(spacing: 8) {
                            TextField("Команда", text: $commandLine,
                                      prompt: Text(verbatim: #""C:\Games\game.exe" -windowed"#))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .onSubmit(run)
                            Button("Обзор…") { chooseFile(space) }
                        }
                        if let space, let hint = resolvedHint(in: space) {
                            Text(verbatim: hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("Командная строка Windows")
                    } footer: {
                        Text("Программа и аргументы, как в окне «Выполнить» Windows: notepad, regedit, msiexec /i C:\\setup.msi. Пути с пробелами возьмите в кавычки.")
                    }
                } else {
                    Section {
                        TextField("Аргументы", text: $argumentsText, prompt: Text("например -windowed -dx11"))
                            .font(.body.monospaced())
                    } header: {
                        Text("Аргументы")
                    } footer: {
                        Text("Через пробел; значения с пробелами возьмите в кавычки.")
                    }
                }

                Section {
                    Picker("Графика", selection: $backend) {
                        ForEach(GraphicsBackend.allCases) { b in
                            Text(verbatim: backendTitle(b, space: space)).tag(b)
                        }
                    }
                    Toggle("Показывать Metal HUD (FPS, кадры, память)", isOn: $metalHUD)
                    Toggle("Не сообщать о поддержке AVX", isOn: $noAVX)
                        .help("Rosetta 2 не будет сообщать игре об AVX/AVX2. Помогает играм, которые падают на инструкциях AVX.")
                } header: {
                    Text("Только для этого запуска")
                } footer: {
                    Text("Настройки пространства не меняются.")
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("WINEDEBUG", text: $wineDebug, prompt: Text("пусто — только ошибки"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Menu("Шаблоны") {
                            ForEach(Self.debugPresets, id: \.1) { preset in
                                Button(preset.0) { wineDebug = preset.1 }
                            }
                        }
                        .fixedSize()
                    }
                } header: {
                    Text("Журнал Wine (WINEDEBUG)")
                } footer: {
                    Text("Каналы через запятую: +канал включает, -канал выключает. Журнал запуска — в «Журналах» пространства.")
                }

                Section {
                    ForEach($envRows) { $row in
                        HStack(spacing: 6) {
                            TextField("Переменная", text: $row.key, prompt: Text("ИМЯ"))
                                .labelsHidden()
                                .font(.body.monospaced())
                            Text(verbatim: "=").foregroundStyle(.secondary)
                            TextField("Значение", text: $row.value, prompt: Text("значение"))
                                .labelsHidden()
                                .font(.body.monospaced())
                            Button {
                                let rowID = row.id
                                envRows.removeAll { $0.id == rowID }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить переменную")
                        }
                    }
                    Button {
                        envRows.append(RunEnvRow())
                    } label: {
                        Label("Добавить переменную", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Переменные окружения")
                } footer: {
                    Text("Поверх переменных пространства, например DXVK_HUD=full или DXMT_LOG_LEVEL=debug.")
                }

                Section {
                    Toggle(isOn: $saveAsProgram) {
                        Text(isPinnedTarget ? "Сохранить параметры в закреплённой программе" : "Сохранить как программу")
                    }
                    if saveAsProgram {
                        TextField("Название", text: $programName)
                    }
                } footer: {
                    Text(isPinnedTarget
                         ? "Аргументы, переменные и настройки этого окна станут настройками программы."
                         : "Программа появится в разделе «Закреплённые» и будет запускаться с этими настройками.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    Label("Запустить", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(space == nil || !model.hasEngine || !canRun)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
        .onAppear { load(space) }
    }

    // MARK: Pieces

    private func header(_ space: Space?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(OnwinTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: headerTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("Пространство «\(space?.name ?? "—")»")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var headerTitle: String {
        switch mode {
        case .command: return String(localized: "Выполнить команду")
        case .target(let t): return String(localized: "Запустить «\(t.title)» с параметрами")
        }
    }

    private var headerSymbol: String {
        switch mode {
        case .command: return "terminal"
        case .target(.steamGame): return "gamecontroller.fill"
        case .target: return "play.rectangle"
        }
    }

    private var isPinnedTarget: Bool {
        if case .target(.program(let p)) = mode, case .pinned = p.source { return true }
        return false
    }

    private var canRun: Bool {
        if case .command = mode { return !commandLine.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    private func backendTitle(_ b: GraphicsBackend, space: Space?) -> String {
        guard let space, let engine = model.engine(for: space) else { return b.displayName }
        if b == .auto {
            return String(localized: "Автоматически (\(GraphicsSupport.resolve(.auto, engine: engine).displayName))")
        }
        return GraphicsSupport.isAvailable(b, engine: engine)
            ? b.displayName : String(localized: "\(b.displayName) — недоступен")
    }

    private func resolvedHint(in space: Space) -> String? {
        guard let r = WindowsCommandLine.resolve(commandLine, in: space) else { return nil }
        if let unix = r.unixPath { return String(localized: "Запустится: \(space.windowsPath(forUnixPath: unix))") }
        return String(localized: "Запустится: \(r.program) (встроенная команда или программа из PATH Windows)")
    }

    // MARK: Behaviour

    private func load(_ space: Space?) {
        guard !didLoad, let space else { return }
        didLoad = true
        var config = space.config
        switch mode {
        case .command:
            programName = ""
        case .target(let target):
            programName = target.title
            switch target {
            case .program(let p):
                config = config.applying(space.overrides(for: p))
                argumentsText = WindowsCommandLine.join(p.arguments)
                envRows = p.environment.sorted { $0.key < $1.key }.map { RunEnvRow(key: $0.key, value: $0.value) }
            case .file, .steamGame:
                break
            }
        }
        backend = config.graphicsBackend
        metalHUD = config.metalHUD
        noAVX = !config.advertiseAVX
        wineDebug = config.debugLogging ? config.wineDebugChannels : ""
    }

    private func request() -> RunRequest {
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { env[key] = row.value }
        }
        let name = programName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunRequest(arguments: WindowsCommandLine.split(argumentsText), environment: env,
                          overrides: RunOverrides(graphicsBackend: backend, metalHUD: metalHUD, advertiseAVX: !noAVX,
                                                  wineDebug: wineDebug.trimmingCharacters(in: .whitespaces)),
                          saveAs: saveAsProgram ? name : nil)
    }

    private func run() {
        guard let space = model.space(id: spaceID), canRun else { return }
        let r = request()
        dismiss()
        switch mode {
        case .command:
            var commandRequest = r
            commandRequest.arguments = []
            if r.saveAs?.isEmpty == true {
                commandRequest.saveAs = WindowsCommandLine.resolve(commandLine, in: space)?
                    .unixPath?.deletingPathExtension().lastPathComponent ?? String(localized: "Программа")
            }
            model.runCommandLine(commandLine, in: space, request: commandRequest)
        case .target(let target):
            model.run(target, in: space, request: r)
        }
    }

    private func chooseFile(_ space: Space?) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Выбрать программу")
        panel.prompt = String(localized: "Выбрать", comment: "Open panel button: choose the file")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let space { panel.directoryURL = space.driveC }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = space?.windowsPath(forUnixPath: url) ?? WineRunner.dosPath(url)
        commandLine = path.contains(" ") ? "\"\(path)\"" : path
        if programName.isEmpty { programName = url.deletingPathExtension().lastPathComponent }
    }
}
