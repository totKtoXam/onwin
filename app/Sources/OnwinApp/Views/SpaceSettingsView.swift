import AppKit
import SwiftUI
import OnwinCore

// Space settings: a grouped Form. Shown by the shell in a sheet (ShellSpaceSettingsSheet adds "Готово"),
// but it also works embedded in another view. Every change goes through `AppModel.updateConfig`.
//
// How editing works: the form edits a local copy (`draft`) of the space's config with ordinary
// `$draft.x` bindings. `onChange(of: draft)` sends only the fields that changed to
// `model.updateConfig`, and `onChange(of: space.config)` pulls changes made elsewhere (component
// installs, renames) back into the draft. Text fields (description, WINEDEBUG channels) are committed
// when they lose focus, on Return and when the view disappears — not on every keystroke. The name is
// committed only on Return / "Переименовать", because renaming moves the space directory.

/// Settings of one space.
@MainActor
struct SpaceSettingsView: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID

    init(spaceID: UUID) {
        self.spaceID = spaceID
    }

    var body: some View {
        if let space = model.space(id: spaceID) {
            SpaceSettingsForm(space: space)
                .id(spaceID)
        } else {
            ContentUnavailableView("Пространство не найдено",
                                   systemImage: "shippingbox",
                                   description: Text("Возможно, его удалили или переименовали вне onwin."))
        }
    }
}

// MARK: - Form

/// Text fields of the form that can hold keyboard focus.
enum SpaceSettingsField: Hashable {
    case name, notes, channels, envKey, envValue, dllName
}

/// WINEDLLOVERRIDES modes.
enum SpaceSettingsDLLMode: String, CaseIterable, Identifiable {
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case native = "n"
    case builtin = "b"
    case disabled = ""

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeThenBuiltin: return String(localized: "Сначала родная, потом встроенная (n,b)")
        case .builtinThenNative: return String(localized: "Сначала встроенная, потом родная (b,n)")
        case .native: return String(localized: "Только родная Windows-библиотека (n)")
        case .builtin: return String(localized: "Только встроенная библиотека Wine (b)")
        case .disabled: return String(localized: "Отключить", comment: "DLL override mode: disable the library")
        }
    }

    var shortTitle: String {
        switch self {
        case .nativeThenBuiltin: return "n,b"
        case .builtinThenNative: return "b,n"
        case .native: return "n"
        case .builtin: return "b"
        case .disabled: return String(localized: "отключена", comment: "DLL override mode, short: the library is disabled")
        }
    }

    static func shortTitle(for raw: String) -> String {
        SpaceSettingsDLLMode(rawValue: raw)?.shortTitle ?? raw
    }
}

@MainActor
struct SpaceSettingsForm: View {
    @Environment(AppModel.self) private var model
    let space: Space

    @State private var draft: SpaceConfig
    @State private var nameDraft: String
    @State private var nameProblem: String?
    @State private var descriptionDraft: String
    @State private var channelsDraft: String

    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var newDLLName = ""
    @State private var newDLLMode: SpaceSettingsDLLMode = .nativeThenBuiltin

    @State private var isConfirmingDelete = false
    /// MSync / Retina change held back while the space runs (SpaceRestartPrompt.swift asks).
    @State private var pendingRestart: RestartSensitiveChange?
    @FocusState private var focus: SpaceSettingsField?

    init(space: Space) {
        self.space = space
        _draft = State(initialValue: space.config)
        _nameDraft = State(initialValue: space.config.name)
        _descriptionDraft = State(initialValue: space.config.description)
        _channelsDraft = State(initialValue: space.config.wineDebugChannels)
    }

    var body: some View {
        Form {
            generalSection
            graphicsSection
            performanceSection
            macFoldersSection
            debugSection
            environmentSection
            dllSection
            componentsSection
            LauncherSettingsSection(space: space)   // LauncherViews.swift: Launchpad launchers
            dangerSection
        }
        .formStyle(.grouped)
        .onChange(of: draft) { old, new in
            commit(from: old, to: new)
        }
        .onChange(of: space.config) { old, new in
            sync(from: old, to: new)
        }
        .onChange(of: focus) { old, _ in
            if old == .notes || old == .channels {
                commitTextFields()
            }
        }
        .onDisappear {
            commitTextFields()
        }
        .spaceRestartPrompt($pendingRestart, space: space)
        .alert("Папки пространства",
               isPresented: Binding(get: { model.macFoldersNotice != nil },
                                    set: { if !$0 { model.macFoldersNotice = nil } }),
               presenting: model.macFoldersNotice) { _ in
            Button("Показать в Finder") {
                model.macFoldersNotice = nil
                model.open(MacFolders.profile(of: space))
            }
            Button("OK", role: .cancel) { model.macFoldersNotice = nil }
        } message: { message in
            Text(verbatim: message)
        }
        .confirmationDialog("Удалить пространство «\(space.name)»?",
                            isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Переместить в Корзину", role: .destructive) {
                let target = space
                Task { await model.deleteSpace(target) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Пространство и всё, что в него установлено, будут перемещены в Корзину. Запущенные в нём программы будут закрыты.")
        }
    }

    // MARK: Derived values

    /// Engine the space will use with the current draft (its own pick, otherwise the default).
    private var engine: Engine? {
        if let id = draft.engineID, let match = model.engines.first(where: { $0.id == id }) { return match }
        return model.defaultEngine
    }

    /// What the selected backend turns into right now (nil without an engine).
    private var resolvedBackend: GraphicsBackend? {
        SettingsBackendAvailability.resolved(draft.graphicsBackend, engine: engine)
    }

    private var isRunning: Bool { model.isRunning(space.id) }

    private var isBusy: Bool {
        if let task = model.activeTask { return !task.isFinished }
        return false
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameEdited: Bool { trimmedName != space.name }

    // MARK: Основное

    private var generalSection: some View {
        Section {
            TextField("Имя", text: $nameDraft)
                .focused($focus, equals: .name)
                .onSubmit { commitName() }

            if isNameEdited || nameProblem != nil {
                HStack(spacing: 8) {
                    if let nameProblem {
                        Label(nameProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("Папка пространства будет переименована.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Отменить") {
                        nameDraft = space.name
                        nameProblem = nil
                    }
                    Button("Переименовать") {
                        commitName()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isNameEdited)
                }
            }

            Picker("Версия Windows", selection: $draft.windowsVersion) {
                ForEach(WindowsVersion.allCases) { version in
                    Text(version.displayName).tag(version)
                }
            }

            if let activity = model.backgroundActivity {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Описание", text: $descriptionDraft, prompt: Text("Заметки: что установлено, что настроено…"),
                      axis: .vertical)
                .lineLimit(2...6)
                .focused($focus, equals: .notes)
                .onSubmit { commitTextFields() }

            enginePicker

            LabeledContent("Создана", value: space.config.created.formatted(date: .long, time: .shortened))

            if !space.isInitialized {
                Label("Пространство ещё не готово: в нём нет system.reg. Создайте его заново.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text("Основное")
        } footer: {
            Text("Версия Windows меняется через winecfg. Если в пространстве запущены программы, onwin применит её после их закрытия.")
        }
    }

    @ViewBuilder
    private var enginePicker: some View {
        if model.engines.isEmpty {
            LabeledContent("Движок") {
                Text("не установлен")
                    .foregroundStyle(Color.orange)
            }
        } else {
            Picker("Движок", selection: $draft.engineID) {
                Text("Как в настройках onwin (\(model.defaultEngine?.info.displayName ?? String(localized: "нет", comment: "No default engine")))")
                    .tag(String?.none)
                if let id = draft.engineID, !model.engines.contains(where: { $0.id == id }) {
                    Text("\(id) — не найден")
                        .tag(Optional(id))
                }
                ForEach(model.engines, id: \.root) { engine in
                    Text(verbatim: "\(engine.info.displayName) — Wine \(engine.info.wineVersion)")
                        .tag(Optional(engine.id))
                }
            }
        }
    }

    // MARK: Графика

    private var graphicsSection: some View {
        Section {
            SettingsBackendRows(selection: $draft.graphicsBackend, engine: engine)

            if let note = selectedBackendNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.orange)
            }

            if !model.isD3DMetalInstalled {
                d3dmetalCallToAction
            }

            Toggle(isOn: $draft.metalHUD) {
                optionLabel("Metal HUD",
                            "Частота кадров, время кадра и память GPU поверх игры")
            }

            Toggle(isOn: $draft.highResolution) {
                optionLabel("Высокое разрешение (Retina)",
                            "Программы видят настоящее разрешение экрана: картинка чётче, но игры работают медленнее, а интерфейс старых программ может стать мелким. Если пространство запущено, его придётся перезапустить",
                            warning: DisplayScaleInfo.retinaNote)
            }

            Toggle(isOn: $draft.dxrRaytracing) {
                optionLabel("Трассировка лучей (DXR)",
                            "DirectX 12 Raytracing через D3DMetal. Аппаратная трассировка лучей есть в чипах M3 и новее",
                            warning: HostSupport.raytracingUnsupportedReason(.d3dmetal).map { String(localized: "Недоступно: \($0)") }
                                ?? onlyWithWarning(.d3dmetal))
            }
            .disabled(HostSupport.raytracingUnsupportedReason(.d3dmetal) != nil && !draft.dxrRaytracing)

            Toggle(isOn: $draft.metalFX) {
                optionLabel("DLSS через MetalFX (D3DMetal и DXMT)",
                            "Игра видит NVIDIA DLSS, а апскейлинг делает MetalFX от Apple. Включите DLSS в настройках самой игры. С DXMT включает расширения NVIDIA (DXMT_ENABLE_NVEXT), и игра видит видеокарту NVIDIA — держите выключенным, если игре DLSS не нужен",
                            warning: metalFXWarning)
            }
            .disabled(metalFXHostReason != nil && !draft.metalFX)
        } header: {
            Text("Графика")
        } footer: {
            Text("Изменения графики действуют при следующем запуске программы.")
        }
    }

    private var selectedBackendNote: String? {
        guard let reason = SettingsBackendAvailability.unavailableReason(draft.graphicsBackend, engine: engine,
                                                                         d3dmetalInstalled: model.isD3DMetalInstalled)
        else { return nil }
        if let resolvedBackend {
            return String(localized: "\(draft.graphicsBackend.displayName) недоступен (\(reason)). Сейчас будет использован \(resolvedBackend.displayName).")
        }
        return String(localized: "\(draft.graphicsBackend.displayName) недоступен: \(reason).")
    }

    /// Why DLSS → MetalFX cannot work on this Mac with the backend in use (nil = it can, or unknown).
    private var metalFXHostReason: String? {
        let backend = resolvedBackend ?? .d3dmetal
        guard backend == .d3dmetal || backend == .dxmt else { return nil }
        return HostSupport.metalFXUnsupportedReason(backend)
    }

    private var metalFXWarning: String? {
        if let metalFXHostReason { return String(localized: "Недоступно: \(metalFXHostReason)") }
        guard let resolvedBackend else { return String(localized: "Работает только с D3DMetal и DXMT") }
        if resolvedBackend == .d3dmetal || resolvedBackend == .dxmt { return nil }
        return String(localized: "Работает только с D3DMetal и DXMT — сейчас используется \(resolvedBackend.displayName)")
    }

    /// Warning for options that only work with one backend; nil when that backend is active.
    private func onlyWithWarning(_ backend: GraphicsBackend) -> String? {
        guard let resolvedBackend else { return String(localized: "Работает только с \(backend.displayName)") }
        if resolvedBackend == backend { return nil }
        return String(localized: "Работает только с \(backend.displayName) — сейчас используется \(resolvedBackend.displayName)")
    }

    private var d3dmetalCallToAction: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(OnwinTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("D3DMetal не установлен")
                    .font(.headline)
                Text("Лучший режим для игр на DirectX 11 и 12. Его делает Apple: войдите с Apple ID прямо в onwin — Game Porting Toolkit скачается и установится сам, для всех пространств.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Установить D3DMetal") {
                Task { @MainActor in await model.installD3DMetal() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }

    // MARK: Производительность

    private var performanceSection: some View {
        Section {
            Toggle(isOn: $draft.msync) {
                optionLabel("MSync",
                            "Синхронизация потоков через семафоры Mach — быстрее и стабильнее в играх. Рекомендуется. Если пространство запущено, его придётся перезапустить")
            }

            Toggle(isOn: $draft.advertiseAVX) {
                optionLabel("Сообщать о поддержке AVX",
                            "Rosetta 2 умеет выполнять инструкции AVX/AVX2 и скажет об этом игре. Без этого некоторые новые игры не запускаются")
            }
        } header: {
            Text("Производительность")
        }
    }

    // MARK: Папки

    private var macFoldersSection: some View {
        Section {
            Toggle(isOn: $draft.linkMacFolders) {
                optionLabel("Связать «Документы», «Загрузки» и другие папки с папками Mac",
                            "Windows-программы будут видеть ваши папки Mac «Документы», «Загрузки», «Музыка», «Изображения», «Фильмы» и рабочий стол. Эти папки macOS охраняет, поэтому она будет спрашивать, разрешить ли onwin доступ к ним. Если выключено, у пространства свои отдельные папки: сохранения игр и файлы программ остаются внутри него, а macOS ничего не спрашивает")
            }

            HStack {
                Button {
                    model.open(MacFolders.profile(of: space))
                } label: {
                    Label("Показать папки пространства", systemImage: "folder")
                }
                Spacer()
            }
        } header: {
            Text("Папки")
        } footer: {
            Text("При переключении ничего не удаляется: файлы в папках Mac остаются на месте, а файлы, уже лежащие в папках пространства, сохраняются рядом под именем вроде «Documents (onwin)». Менять можно, только пока в пространстве ничего не запущено.")
        }
    }

    // MARK: Отладка

    private var debugSection: some View {
        Section {
            Toggle(isOn: $draft.debugLogging) {
                optionLabel("Подробный журнал Wine",
                            "Записывать отладочные сообщения Wine в журнал программы. Замедляет игры — включайте только для поиска проблем")
            }

            HStack(spacing: 8) {
                TextField("Каналы WINEDEBUG", text: $channelsDraft, prompt: Text(verbatim: "+err,+warn"))
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .channels)
                    .onSubmit { commitTextFields() }
                Menu("Шаблоны") {
                    channelPreset("Стандартный", "+err,+warn,+seh,+loaddll")
                    channelPreset("Только ошибки", "-all,+err")
                    channelPreset("Загрузка библиотек", "+err,+loaddll,+module")
                    channelPreset("Графика", "+err,+d3d,+d3d11,+dxgi,+vulkan")
                    Divider()
                    channelPreset("Всё (очень медленно)", "+all")
                }
                .fixedSize()
            }
            .disabled(!draft.debugLogging)

            HStack(spacing: 12) {
                Button {
                    openLogsFolder()
                } label: {
                    Label("Открыть папку журналов", systemImage: "folder")
                }
                if let latest = space.logFiles().first {
                    Button {
                        model.open(latest)
                    } label: {
                        Label("Последний журнал", systemImage: "doc.text.magnifyingglass")
                    }
                    .help(latest.lastPathComponent)
                }
            }
        } header: {
            Text("Отладка")
        } footer: {
            Text("Без подробного журнала onwin запускает программы с WINEDEBUG=-all, так быстрее. Вывод самих программ записывается в журнал всегда.")
        }
    }

    private func channelPreset(_ title: LocalizedStringKey, _ channels: String) -> some View {
        Button(title) {
            channelsDraft = channels
            commitTextFields()
        }
    }

    // MARK: Дополнительно — переменные окружения

    private var environmentSection: some View {
        Section {
            if draft.environment.isEmpty {
                Text("Своих переменных нет")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.environment.keys.sorted(), id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                    Text(verbatim: "=")
                        .foregroundStyle(.secondary)
                    Text(draft.environment[key] ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        newEnvKey = key
                        newEnvValue = draft.environment[key] ?? ""
                        focus = .envValue
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Изменить")
                    Button {
                        draft.environment[key] = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Удалить переменную")
                }
            }

            HStack(spacing: 8) {
                TextField("Имя", text: $newEnvKey, prompt: Text("ИМЯ"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .envKey)
                    .onSubmit { focus = .envValue }
                Text(verbatim: "=")
                    .foregroundStyle(.secondary)
                TextField("Значение", text: $newEnvValue, prompt: Text("значение"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .envValue)
                    .onSubmit { addEnvironmentVariable() }
                Button {
                    addEnvironmentVariable()
                } label: {
                    draft.environment[trimmedEnvKey] == nil ? Text("Добавить") : Text("Заменить")
                }
                .disabled(trimmedEnvKey.isEmpty || envKeyProblem != nil)
            }

            if let envKeyProblem, !trimmedEnvKey.isEmpty {
                Text(envKeyProblem)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text("Дополнительно: переменные окружения")
        } footer: {
            Text("Передаются всем программам пространства и переопределяют значения onwin (например, DXVK_HUD=full или MTL_HUD_ENABLED=1).")
        }
    }

    private var trimmedEnvKey: String {
        newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var envKeyProblem: String? {
        let key = trimmedEnvKey
        if key.isEmpty { return String(localized: "Укажите имя переменной") }
        if key.contains("=") || key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return String(localized: "Имя переменной не может содержать пробелы и знак «=»")
        }
        if let first = key.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            return String(localized: "Имя переменной не может начинаться с цифры")
        }
        return nil
    }

    private func addEnvironmentVariable() {
        let key = trimmedEnvKey
        guard !key.isEmpty, envKeyProblem == nil else { return }
        draft.environment[key] = newEnvValue
        newEnvKey = ""
        newEnvValue = ""
        focus = .envKey
    }

    // MARK: Дополнительно — DLL overrides

    private var dllSection: some View {
        Section {
            if draft.dllOverrides.isEmpty {
                Text("Переопределений нет — Wine сам выбирает библиотеки")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.dllOverrides.keys.sorted(), id: \.self) { dll in
                HStack(spacing: 8) {
                    Text(dll)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Menu(SpaceSettingsDLLMode.shortTitle(for: draft.dllOverrides[dll] ?? "")) {
                        ForEach(SpaceSettingsDLLMode.allCases) { mode in
                            Button(mode.title) {
                                draft.dllOverrides[dll] = mode.rawValue
                            }
                        }
                    }
                    .fixedSize()
                    Button {
                        draft.dllOverrides[dll] = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать переопределение")
                }
            }

            HStack(spacing: 8) {
                TextField("Библиотека", text: $newDLLName, prompt: Text(verbatim: "d3dx9_43"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .dllName)
                    .onSubmit { addDLLOverride() }
                Picker("Режим", selection: $newDLLMode) {
                    ForEach(SpaceSettingsDLLMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    addDLLOverride()
                } label: {
                    draft.dllOverrides[normalizedDLLName] == nil ? Text("Добавить") : Text("Заменить")
                }
                .disabled(dllNameProblem != nil)
            }

            if let dllNameProblem, !newDLLName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(dllNameProblem)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text("Дополнительно: библиотеки DLL")
        } footer: {
            Text("«Родная» — DLL, которую принесла сама программа или установщик Windows; «встроенная» — реализация Wine. Режимы графики onwin подставляет сам, их здесь указывать не нужно.")
        }
    }

    private var normalizedDLLName: String {
        var name = newDLLName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".dll") { name = String(name.dropLast(4)) }
        return name
    }

    private var dllNameProblem: String? {
        let name = normalizedDLLName
        if name.isEmpty { return String(localized: "Укажите имя библиотеки") }
        let forbidden = CharacterSet(charactersIn: "=;,").union(.whitespacesAndNewlines)
        if name.rangeOfCharacter(from: forbidden) != nil {
            return String(localized: "Имя библиотеки не может содержать пробелы и символы «=», «;», «,»")
        }
        return nil
    }

    private func addDLLOverride() {
        guard dllNameProblem == nil else { return }
        draft.dllOverrides[normalizedDLLName] = newDLLMode.rawValue
        newDLLName = ""
        focus = .dllName
    }

    // MARK: Компоненты

    /// Effective «Устанавливать нужные компоненты автоматически»; nil in the config = as in Preferences,
    /// so only a value different from the global one is stored.
    private var autoComponents: Binding<Bool> {
        Binding(
            get: { draft.autoInstallComponents ?? model.settings.autoInstallComponents },
            set: { draft.autoInstallComponents = $0 == model.settings.autoInstallComponents ? nil : $0 })
    }

    private var componentsSection: some View {
        Section {
            Toggle(isOn: autoComponents) {
                optionLabel("Устанавливать нужные компоненты автоматически",
                            draft.autoInstallComponents == nil
                                ? "Перед первым запуском программы onwin сам поставит Visual C++, DirectX, .NET и другое, что ей нужно, а если она не запустится из-за нехватки библиотеки — поставит и перезапустит. Как в настройках onwin"
                                : "Перед первым запуском программы onwin сам поставит Visual C++, DirectX, .NET и другое, что ей нужно, а если она не запустится из-за нехватки библиотеки — поставит и перезапустит. Своя настройка этого пространства")
            }

            ForEach(Catalog.listedComponents.filter { $0.kind == .space }) { component in
                componentRow(component)
            }

            ForEach(unknownComponents, id: \.self) { id in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(OnwinTheme.accent)
                        .frame(width: 22)
                    Text(id)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("установлен")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Компоненты")
        } footer: {
            if !model.hasEngine {
                Text("Чтобы устанавливать компоненты, нужен движок Wine.")
            } else {
                autoComponents.wrappedValue
                    ? Text("Компоненты скачиваются с сайтов Microsoft и других авторов и ставятся тихо, без вопросов. D3DMetal onwin только предложит: для него нужен вход с Apple ID.")
                    : Text("Автоматическая установка выключена: onwin только подскажет на странице пространства, чего не хватает. Компоненты скачиваются из интернета и устанавливаются в это пространство.")
            }
        }
    }

    private var unknownComponents: [String] {
        draft.installedComponents.filter { Catalog.component($0) == nil }
    }

    private func componentRow(_ component: Component) -> some View {
        let installed = component.isInstalled(in: draft)
        return HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.seal.fill" : "shippingbox")
                .foregroundStyle(installed ? OnwinTheme.accent : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                Text(verbatim: "\(component.summary) · \(component.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                let target = space
                Task { await model.install(component: component, into: target) }
            } label: {
                installed ? Text("Переустановить") : Text("Установить")
            }
            .disabled(!model.hasEngine || !space.isInitialized || isBusy)
        }
    }

    // MARK: Опасная зона

    private var dangerSection: some View {
        Section {
            dangerRow("Архивировать",
                      isRunning
                        ? "Закройте программы пространства, чтобы упаковать его."
                        : "Упаковать пространство в один файл .onwinspace — для резервной копии или переноса на другой Mac.",
                      symbol: "archivebox") {
                Button("Архивировать…") {
                    model.archiveInteractively(space)
                }
                .disabled(isRunning || isBusy)
            }

            dangerRow("Дублировать",
                      "Создать независимую копию «\(space.name)» со всеми установленными программами.",
                      symbol: "plus.square.on.square") {
                Button("Дублировать") {
                    let source = space
                    Task { await model.duplicate(source) }
                }
                .disabled(isBusy)
            }

            dangerRow("Удалить",
                      "Переместить пространство в Корзину вместе со всем, что в него установлено.",
                      symbol: "trash",
                      tint: Color.red) {
                Button("Удалить…", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        } header: {
            Text("Опасная зона")
        }
    }

    private func dangerRow<Action: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, symbol: String,
                                         tint: Color = Color.secondary,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
    }

    // MARK: Helpers

    private func optionLabel(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, warning: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private func openLogsFolder() {
        let directory = space.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.open(directory)
    }

    // MARK: Saving

    /// Sends the fields that changed between two drafts to the model.
    private func commit(from old: SpaceConfig, to new: SpaceConfig) {
        guard old != new else { return }
        // MSync / Retina are read when the wineserver and the programs start: with the space running
        // they need a restart, so hold them back and ask (SpaceRestartPrompt.swift).
        let restartChange = RestartSensitiveChange(from: old, to: new)
        if !restartChange.isEmpty {
            if model.isSpaceRunning(space) {
                pendingRestart = restartChange
            } else {
                model.updateConfig(of: space.id) { restartChange.apply(to: &$0) }
            }
        }
        model.updateConfig(of: space.id) { c in
            if old.windowsVersion != new.windowsVersion { c.windowsVersion = new.windowsVersion }
            if old.engineID != new.engineID { c.engineID = new.engineID }
            if old.graphicsBackend != new.graphicsBackend { c.graphicsBackend = new.graphicsBackend }
            if old.metalHUD != new.metalHUD { c.metalHUD = new.metalHUD }
            if old.advertiseAVX != new.advertiseAVX { c.advertiseAVX = new.advertiseAVX }
            if old.dxrRaytracing != new.dxrRaytracing { c.dxrRaytracing = new.dxrRaytracing }
            if old.metalFX != new.metalFX { c.metalFX = new.metalFX }
            if old.debugLogging != new.debugLogging { c.debugLogging = new.debugLogging }
            if old.wineDebugChannels != new.wineDebugChannels { c.wineDebugChannels = new.wineDebugChannels }
            if old.environment != new.environment { c.environment = new.environment }
            if old.dllOverrides != new.dllOverrides { c.dllOverrides = new.dllOverrides }
            if old.description != new.description { c.description = new.description }
            if old.autoInstallComponents != new.autoInstallComponents { c.autoInstallComponents = new.autoInstallComponents }
        }
        // If saving failed, show what is really stored instead of the rejected value.
        if let stored = model.space(id: space.id)?.config, stored != draft {
            draft = stored
        }
    }

    /// Pulls changes made elsewhere (component installs, renames, another window) into the form.
    private func sync(from old: SpaceConfig, to new: SpaceConfig) {
        if draft != new { draft = new }
        if old.name != new.name {
            nameDraft = new.name
            nameProblem = nil
        }
        if focus != .notes && descriptionDraft != new.description {
            descriptionDraft = new.description
        }
        if focus != .channels && channelsDraft != new.wineDebugChannels {
            channelsDraft = new.wineDebugChannels
        }
    }

    private func commitTextFields() {
        let description = descriptionDraft
        let channels = channelsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if channels != channelsDraft { channelsDraft = channels }
        guard let stored = model.space(id: space.id)?.config,
              stored.description != description || stored.wineDebugChannels != channels else { return }
        model.updateConfig(of: space.id) { c in
            c.description = description
            c.wineDebugChannels = channels
        }
        if let updated = model.space(id: space.id)?.config, updated != draft {
            draft = updated
        }
    }

    private func commitName() {
        let name = trimmedName
        guard name != space.name else {
            nameDraft = space.name
            nameProblem = nil
            return
        }
        if name.isEmpty {
            nameProblem = String(localized: "Имя пространства не может быть пустым")
            return
        }
        if name.hasPrefix(".") {
            nameProblem = String(localized: "Имя не может начинаться с точки")
            return
        }
        if model.spaces.contains(where: { $0.id != space.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            nameProblem = String(localized: "Пространство «\(name)» уже есть")
            return
        }
        if isRunning {
            nameProblem = String(localized: "Закройте программы пространства, чтобы переименовать его")
            return
        }
        nameProblem = nil
        model.rename(space, to: name)
        if let renamed = model.space(id: space.id) {
            nameDraft = renamed.name
        }
    }
}

// MARK: - Graphics backend choice (shared with NewSpaceSheet and PreferencesView)

/// Why a backend cannot be used right now, and what `.auto` turns into.
enum SettingsBackendAvailability {
    static func unavailableReason(_ backend: GraphicsBackend, engine: Engine?, d3dmetalInstalled: Bool) -> String? {
        // Apple Silicon / macOS first: no import or engine can fix those (HostSupport).
        if let host = HostSupport.unsupportedReason(backend) { return host }
        switch backend {
        case .auto, .wined3d:
            return nil
        case .d3dmetal:
            return d3dmetalInstalled ? nil : String(localized: "нужно импортировать D3DMetal из Game Porting Toolkit")
        case .dxmt:
            guard let engine else { return String(localized: "сначала установите движок Wine") }
            return engine.hasDXMT ? nil : String(localized: "в движке «\(engine.info.displayName)» нет DXMT")
        case .dxvk:
            guard let engine else { return String(localized: "сначала установите движок Wine") }
            return engine.hasDXVK ? nil : String(localized: "в движке «\(engine.info.displayName)» нет DXVK")
        }
    }

    static func resolved(_ backend: GraphicsBackend, engine: Engine?) -> GraphicsBackend? {
        guard let engine else { return nil }
        return GraphicsSupport.resolve(backend, engine: engine)
    }
}

/// Radio-style rows (one Form row per backend) with the backend summary; unavailable backends are
/// disabled and say why.
@MainActor
struct SettingsBackendRows: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: GraphicsBackend
    let engine: Engine?

    init(selection: Binding<GraphicsBackend>, engine: Engine?) {
        _selection = selection
        self.engine = engine
    }

    var body: some View {
        ForEach(GraphicsBackend.allCases) { backend in
            row(for: backend)
        }
    }

    private func row(for backend: GraphicsBackend) -> some View {
        let reason = SettingsBackendAvailability.unavailableReason(backend, engine: engine,
                                                                   d3dmetalInstalled: model.isD3DMetalInstalled)
        let isSelected = selection == backend
        let resolvedAuto: GraphicsBackend? = backend == .auto
            ? SettingsBackendAvailability.resolved(.auto, engine: engine)
            : nil
        return Button {
            selection = backend
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? OnwinTheme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.displayName)
                        .foregroundStyle(reason == nil ? Color.primary : Color.secondary)
                    if let reason {
                        Text("Недоступно: \(reason)")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    } else {
                        Text(backend.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let resolvedAuto {
                    Text("сейчас: \(resolvedAuto.displayName)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(OnwinTheme.accent.opacity(0.14)))
                        .foregroundStyle(OnwinTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}
