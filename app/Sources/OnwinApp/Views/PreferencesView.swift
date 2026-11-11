import AppKit
import SwiftUI
import OnwinCore

/// onwin preferences (the Settings scene, ⌘,): engines, D3DMetal, defaults for new spaces, folders.
/// Long operations started here (engine install, D3DMetal import) show their progress sheet in the
/// main window; a short status line is mirrored at the top of each tab.
@MainActor
struct PreferencesView: View {
    init() {}

    var body: some View {
        TabView {
            PreferencesGeneralTab()
                .tabItem { Label("Основные", systemImage: "gearshape") }
            PreferencesEnginesTab()
                .tabItem { Label("Движки", systemImage: "cpu") }
            PreferencesD3DMetalTab()
                .tabItem { Label("D3DMetal", systemImage: "cube.transparent") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - Shared bits

/// Status of a running long operation (its sheet lives in the main window).
@MainActor
struct PreferencesTaskStatus: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        if let task = model.activeTask {
            HStack(spacing: 10) {
                if task.isFinished {
                    Image(systemName: task.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(task.error == nil ? OnwinTheme.accent : Color.orange)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout.weight(.medium))
                    Text(task.error ?? task.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text("подробности — в главном окне")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Small "has / has not" capsule.
@MainActor
struct PreferencesBadge: View {
    let title: String
    let isOn: Bool

    init(_ title: String, isOn: Bool) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: isOn ? "checkmark" : "xmark")
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(isOn ? OnwinTheme.accent.opacity(0.15) : Color.primary.opacity(0.06)))
        .foregroundStyle(isOn ? OnwinTheme.accent : Color.secondary)
    }
}

/// A folder of onwin with an "open" button.
@MainActor
struct PreferencesPathRow: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let symbol: String
    let url: URL

    init(_ title: LocalizedStringKey, symbol: String, url: URL) {
        self.title = title
        self.symbol = symbol
        self.url = url
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(OnwinTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                model.open(url)
            } label: {
                Text("Открыть", comment: "Button: open the folder in Finder")
            }
        }
    }
}

// MARK: - Основные

@MainActor
struct PreferencesGeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var defaultBackend: GraphicsBackend = .auto

    init() {}

    var body: some View {
        Form {
            if model.activeTask != nil {
                Section {
                    PreferencesTaskStatus()
                }
            }

            LanguagePreferenceSection()   // Views/LanguagePreferenceSection.swift

            Section {
                SettingsBackendRows(selection: $defaultBackend, engine: model.defaultEngine)
            } header: {
                Text("Графика для новых пространств")
            } footer: {
                Text("С этим режимом создаются новые пространства. У каждого пространства режим можно поменять в его настройках. Рецепты каталога могут выбрать свой режим.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.settings.autoInstallComponents },
                                     set: { value in model.updateSettings { $0.autoInstallComponents = value } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Устанавливать нужные компоненты автоматически")
                        Text("Перед первым запуском программы onwin сам проверит, какие библиотеки ей нужны (Visual C++, DirectX, .NET, шрифты…), и тихо поставит их. Если программа всё же не запустится из-за нехватки библиотеки — поставит недостающее и запустит её ещё раз.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Компоненты для игр")
            } footer: {
                Text("D3DMetal onwin только предложит — для него нужен вход с Apple ID. У каждого пространства это можно поменять в его настройках. Если выключить, onwin будет лишь подсказывать, чего не хватает.")
            }

            PreferencesUpdatesSection()   // Views/UpdateViews.swift

            Section {
                PreferencesPathRow("Данные onwin", symbol: "externaldrive", url: OnwinPaths.root)
                PreferencesPathRow("Пространства", symbol: "shippingbox", url: OnwinPaths.spaces)
                PreferencesPathRow("Движки Wine", symbol: "cpu", url: OnwinPaths.engines)
                PreferencesPathRow("Графика (D3DMetal)", symbol: "cube.transparent", url: OnwinPaths.graphics)
                PreferencesPathRow("Журналы", symbol: "doc.text", url: OnwinPaths.logs)
                PreferencesPathRow("Кэш загрузок", symbol: "arrow.down.circle", url: OnwinPaths.cache)
            } header: {
                Text("Папки")
            } footer: {
                Text("В кэше лежат скачанные установщики и компоненты — его можно очистить вручную, onwin скачает нужное заново.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Перечитать всё с диска")
                        Text("Движки, пространства, программы и D3DMetal — если вы меняли файлы вручную")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Обновить") {
                        model.reload()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            defaultBackend = model.settings.defaultBackend
        }
        .onChange(of: defaultBackend) { _, newValue in
            if newValue != model.settings.defaultBackend {
                model.updateSettings { $0.defaultBackend = newValue }
            }
        }
        .onChange(of: model.settings.defaultBackend) { _, newValue in
            if defaultBackend != newValue { defaultBackend = newValue }
        }
    }
}

// MARK: - Движки

@MainActor
struct PreferencesEnginesTab: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        Form {
            if model.activeTask != nil {
                Section {
                    PreferencesTaskStatus()
                }
            }

            Section {
                if model.engines.isEmpty {
                    emptyState
                } else {
                    ForEach(model.engines, id: \.root) { engine in
                        PreferencesEngineRow(engine: engine, isDefault: model.defaultEngine?.root == engine.root)
                    }
                }
            } header: {
                Text("Установленные движки")
            } footer: {
                Text("Движок по умолчанию используют все пространства, у которых в настройках не выбран свой. Новые пространства создаются движком по умолчанию.")
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        model.installEngineInteractively()
                    } label: {
                        Label("Установить из папки…", systemImage: "plus")
                    }
                    .disabled(isTaskRunning)
                    Button {
                        try? FileManager.default.createDirectory(at: OnwinPaths.engines, withIntermediateDirectories: true)
                        model.open(OnwinPaths.engines)
                    } label: {
                        Label("Папка движков", systemImage: "folder")
                    }
                    Spacer()
                    Button {
                        model.reload()
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                }
            } footer: {
                Text("Движок — это Wine, собранный из открытых (LGPL) исходников CrossOver от CodeWeavers: папка с bin/wine, lib/wine и onwin-engine.json. При установке он копируется в папку движков onwin.")
            }
        }
        .formStyle(.grouped)
    }

    private var isTaskRunning: Bool {
        if let task = model.activeTask { return !task.isFinished }
        return false
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Движок Wine не установлен", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.orange)
            Text("Без движка onwin не может создавать пространства и запускать программы. Проще всего снова выполнить в Терминале команду со страницы «Установка» на сайте onwin — она скачает движок. Разработчики могут собрать его из исходного кода:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "xcode-select --install\n./engine/build.sh")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            Text("…или установите готовый движок кнопкой «Установить из папки…».")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
struct PreferencesEngineRow: View {
    @Environment(AppModel.self) private var model
    let engine: Engine
    let isDefault: Bool

    init(engine: Engine, isDefault: Bool) {
        self.engine = engine
        self.isDefault = isDefault
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.setDefaultEngine(engine.id)
            } label: {
                Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDefault ? OnwinTheme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isDefault ? "Движок по умолчанию" : "Сделать движком по умолчанию")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(engine.info.displayName)
                        .font(.headline)
                    if isDefault {
                        Text("по умолчанию")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(OnwinTheme.accent))
                            .foregroundStyle(Color.white)
                    }
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    PreferencesBadge("DXMT", isOn: engine.hasDXMT)
                    PreferencesBadge("DXVK", isOn: engine.hasDXVK)
                    PreferencesBadge("MoltenVK", isOn: engine.hasMoltenVK)
                }
                Text((engine.root.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if !isDefault {
                    Button("Сделать основным") {
                        model.setDefaultEngine(engine.id)
                    }
                }
                Button {
                    model.revealInFinder(engine.root)
                } label: {
                    Label("Показать", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts = ["Wine \(engine.info.wineVersion)"]
        if let source = engine.info.crossoverSourceVersion, !source.isEmpty {
            parts.append(String(localized: "исходники CrossOver \(source)"))
        }
        if let built = engine.info.built {
            parts.append(String(localized: "собран \(built.formatted(date: .abbreviated, time: .omitted))"))
        }
        parts.append("id: \(engine.id)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - D3DMetal

@MainActor
struct PreferencesD3DMetalTab: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingRemove = false
    @AppStorage(D3DMetalInstallFlow.deleteImageKey) private var deleteImageAfterImport = false

    init() {}

    var body: some View {
        Form {
            if model.activeTask != nil {
                Section {
                    PreferencesTaskStatus()
                }
            }

            Section {
                if model.isD3DMetalInstalled {
                    installedStatus
                } else {
                    missingStatus
                }
            } header: {
                Text("Состояние")
            }

            Section {
                PreferencesD3DMetalStep(number: 1,
                                        text: "Войдите со своим Apple ID в окне onwin — на странице самой Apple. Платная подписка разработчика не нужна, достаточно бесплатной учётной записи. onwin не видит и не хранит пароль; вход запоминается, и в следующий раз он не понадобится.")
                PreferencesD3DMetalStep(number: 2,
                                        text: "onwin сам найдёт последнюю стабильную версию Game Porting Toolkit и скачает её (прерванная загрузка продолжится с того же места).")
                PreferencesD3DMetalStep(number: 3,
                                        text: "onwin подключит образ, установит D3DMetal для всех пространств и отключит образ. Уже скачанный .dmg в «Загрузках» берётся сразу, без входа.")
                Toggle("Удалять скачанный образ после установки", isOn: $deleteImageAfterImport)
                    .help("По умолчанию .dmg остаётся в кэше onwin (~/Library/Caches/onwin/Downloads), чтобы переустановка не требовала новой загрузки")
                HStack {
                    Link(destination: Catalog.gameportingToolkitURL) {
                        Label("Открыть в браузере", systemImage: "arrow.up.right.square")
                    }
                    .help("Скачать Game Porting Toolkit в браузере — onwin подхватит .dmg из «Загрузок»")
                    Button("Забыть вход в Apple ID") {
                        Task { @MainActor in await model.forgetAppleSignIn() }
                    }
                    .buttonStyle(.link)
                    .help("Удалить сохранённую сессию developer.apple.com из onwin")
                    Spacer()
                    Button {
                        chooseAndImport()
                    } label: {
                        Label("Указать вручную…", systemImage: "folder")
                    }
                    .help("Выбрать подключённый том Game Porting Toolkit или папку redist")
                    .disabled(isTaskRunning)
                    Button {
                        Task { @MainActor in await model.installD3DMetal() }
                    } label: {
                        Label(model.isD3DMetalInstalled ? "Обновить D3DMetal" : "Установить D3DMetal",
                              systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTaskRunning)
                }
            } header: {
                Text("Установка D3DMetal")
            } footer: {
                Text("D3DMetal — часть Game Porting Toolkit, его лицензирует Apple. onwin не распространяет его: набор скачивается с вашей учётной записью Apple, и onwin копирует нужные файлы к себе (в папку «Графика») только на этом Mac.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Удалить D3DMetal?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                model.removeD3DMetal()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Пространства, где выбран D3DMetal, перейдут на другой доступный режим графики. Установить D3DMetal можно будет снова.")
        }
    }

    private var isTaskRunning: Bool {
        if let task = model.activeTask { return !task.isFinished }
        return false
    }

    private var installedStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(OnwinTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("D3DMetal установлен")
                    .font(.headline)
                Text("Доступен режим графики D3DMetal: DirectX 11 и 12 напрямую в Metal. В режиме «Автоматически» onwin выбирает его первым.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text((OnwinPaths.d3dmetal.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button {
                        model.revealInFinder(OnwinPaths.d3dmetal)
                    } label: {
                        Label("Показать в Finder", systemImage: "folder")
                    }
                    Button("Удалить…", role: .destructive) {
                        isConfirmingRemove = true
                    }
                    .disabled(isTaskRunning)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var missingStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title)
                .foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("D3DMetal не установлен")
                    .font(.headline)
                Text("Это лучший режим для современных игр на DirectX 11 и 12. Без него onwin использует DXMT, DXVK или WineD3D — многие игры работают и так, но медленнее или с ошибками.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// Folder picker that starts in /Volumes, where the mounted Game Porting Toolkit DMG appears.
    private func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт D3DMetal")
        panel.message = String(localized: "Выберите смонтированный диск Game Porting Toolkit или папку redist на нём")
        panel.prompt = String(localized: "Импортировать")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importD3DMetal(from: url) }
    }
}

/// Numbered instruction line.
@MainActor
struct PreferencesD3DMetalStep: View {
    let number: Int
    let text: LocalizedStringKey

    init(number: Int, text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(OnwinTheme.accent))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
