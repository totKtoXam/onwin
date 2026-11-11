import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OnwinCore

// The form of a user recipe ("Мои приложения"): create, edit, review an imported .onwinrecipe, or
// «Сохранить в каталог?» right after an installer finished (launch path chosen from what it added).
// Presented by `.onwinUserRecipes()`; state and saving: AppModel+UserRecipes.swift.

@MainActor
struct RecipeEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let context: RecipeEditorContext

    @State private var draft = RecipeDraft()
    @State private var didPrepare = false
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 10)

            Form {
                if !context.candidates.isEmpty { candidatesSection }
                programSection
                installerSection
                spaceSection
                componentsSection
                launchSection
                advancedSection
            }
            .formStyle(.grouped)

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 640, height: 720)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        draft = context.draft
        showsAdvanced = !draft.environment.isEmpty || !draft.notes.isEmpty
    }

    // MARK: Header / footer

    private var title: String {
        switch context.mode {
        case .create: return String(localized: "Новое приложение")
        case .edit: return String(localized: "Изменить «\(context.draft.name)»")
        case .importing: return String(localized: "Импорт рецепта")
        case .afterInstall: return String(localized: "Сохранить в каталог?")
        }
    }

    private var subtitle: String {
        switch context.mode {
        case .create:
            return String(localized: "Рецепт для программы, которой нет в каталоге: откуда взять установщик, в какое пространство ставить и что запускать.")
        case .edit:
            return String(localized: "Изменения применятся при следующей установке по рецепту.")
        case .importing(let url):
            return String(localized: "Проверьте рецепт из «\(url.lastPathComponent)». Импорт ничего не устанавливает и не запускает — установка начнётся, только когда вы нажмёте «Установить» на карточке.")
        case .afterInstall:
            return String(localized: "Установка закончилась. onwin запомнит, как ставить эту программу, — в следующий раз она поставится из раздела «Мои приложения» в один щелчок.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            OnwinSpaceIcon(symbol: context.mode == .create ? "plus.app.fill" : "app.badge.fill", size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        let problems = draft.problems
        return VStack(alignment: .leading, spacing: 10) {
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems.prefix(4), id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                if case .afterInstall = context.mode {
                    Toggle("Закрепить программу в пространстве", isOn: $draft.pinInSpace)
                        .disabled(RecipeDraft.trimmed(draft.launchPath).isEmpty)
                }
                Spacer()
                Button(cancelTitle) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    if model.saveUserRecipe(draft, context: context) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!problems.isEmpty)
            }
        }
    }

    private var cancelTitle: String {
        if case .afterInstall = context.mode { return String(localized: "Не сохранять") }
        return String(localized: "Отмена")
    }

    private var saveTitle: String {
        switch context.mode {
        case .importing: return String(localized: "Добавить в «Мои приложения»")
        default: return String(localized: "Сохранить")
        }
    }

    // MARK: Sections

    private var candidatesSection: some View {
        Section {
            ForEach(context.candidates) { candidate in
                Button {
                    draft.launchPath = candidate.windowsPath
                    draft.launchArguments = WindowsCommandLine.join(candidate.arguments)
                } label: {
                    RecipeCandidateRow(candidate: candidate,
                                       isSelected: candidate.windowsPath.caseInsensitiveCompare(
                                           RecipeDraft.trimmed(draft.launchPath)) == .orderedSame)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Что запускать")
        } footer: {
            Text("onwin сравнил пространство до и после установки: новые ярлыки, записи в «Установке и удалении программ» и папки в Program Files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var programSection: some View {
        Section("Программа") {
            TextField("Название", text: $draft.name, prompt: Text("Например, Notepad++"))
            TextField("Описание", text: $draft.summary, prompt: Text("Коротко, для карточки в каталоге"))
        }
    }

    private var installerSection: some View {
        Section {
            Picker("Источник", selection: $draft.installerKind) {
                Text("Ссылка").tag(RecipeDraft.InstallerKind.url)
                Text("Файл на Mac").tag(RecipeDraft.InstallerKind.file)
            }
            .pickerStyle(.segmented)

            switch draft.installerKind {
            case .url:
                TextField("Ссылка", text: $draft.url, prompt: Text("https://…/setup.exe"))
                TextField("SHA-256", text: $draft.sha256, prompt: Text("необязательно: файл будет проверен"))
                    .font(.system(.body, design: .monospaced))
            case .file:
                LabeledContent("Файл") {
                    HStack(spacing: 8) {
                        Text(installerFileTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(hasInstallerFile ? .primary : .secondary)
                            .help(draft.localFile?.path ?? installerFileTitle)
                        Button("Выбрать…") { chooseInstallerFile() }
                    }
                }
            }

            LabeledContent("Ключи установщика") {
                HStack(spacing: 6) {
                    TextField("Ключи", text: $draft.installerArguments, prompt: Text("например, /S"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    Menu("Типовые") {
                        Button("NSIS — /S") { draft.installerArguments = "/S" }
                        Button("Inno Setup — /VERYSILENT /SUPPRESSMSGBOXES /NORESTART") {
                            draft.installerArguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
                        }
                        Button("MSI — /qn") { draft.installerArguments = "/qn" }
                        Button("InstallShield — /s /v\"/qn\"") { draft.installerArguments = "/s /v\"/qn\"" }
                        Divider()
                        Button("Без ключей (обычное окно установщика)") { draft.installerArguments = "" }
                    }
                    .fixedSize()
                }
            }
        } header: {
            Text("Установщик")
        } footer: {
            Text(installerFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hasInstallerFile: Bool {
        draft.localFile != nil || draft.storedFileName != nil
    }

    private var installerFileTitle: String {
        if let file = draft.localFile { return file.lastPathComponent }
        if let stored = draft.storedFileName { return stored }
        return String(localized: "не выбран", comment: "Installer file: none chosen yet")
    }

    private var installerFooter: String {
        switch draft.installerKind {
        case .url:
            return String(localized: "Установщик скачивается при установке. С SHA-256 onwin откажется запускать файл, если издатель его подменил.")
        case .file:
            return String(localized: "Файл копируется в рецепт (~/Library/Application Support/onwin/Recipes/Files), так что рецепт продолжит работать, даже если оригинал удалить.")
        }
    }

    private var existingSpace: Space? {
        let name = RecipeDraft.trimmed(draft.spaceName)
        return model.spaces.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private var spaceSection: some View {
        Section {
            LabeledContent("Пространство") {
                HStack(spacing: 6) {
                    TextField("Пространство", text: $draft.spaceName,
                              prompt: RecipeDraft.trimmed(draft.name).isEmpty ? Text("Имя пространства")
                                                                              : Text(verbatim: RecipeDraft.trimmed(draft.name)))
                        .labelsHidden()
                    if !model.spaces.isEmpty {
                        Menu("Существующие") {
                            ForEach(model.spaces) { space in
                                Button(space.name) {
                                    draft.spaceName = space.name
                                    draft.windowsVersion = space.config.windowsVersion
                                    draft.backend = space.config.graphicsBackend
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Picker("Windows", selection: $draft.windowsVersion) {
                ForEach(WindowsVersion.allCases) { version in
                    Text(version.displayName).tag(version)
                }
            }
            Picker("Графика", selection: $draft.backend) {
                ForEach(GraphicsBackend.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Пространство")
        } footer: {
            Text(spaceFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var spaceFooter: String {
        let backendSummary = draft.backend.summary
        if let space = existingSpace {
            let version = space.config.windowsVersion.displayName
            let backend = space.config.graphicsBackend.displayName
            return String(localized: "Программа установится в существующее пространство «\(space.name)» (\(version), \(backend)); версия Windows и графика выше — для нового пространства. \(backendSummary)")
        }
        return String(localized: "Будет создано новое пространство с этими настройками. \(backendSummary)")
    }

    private var componentsSection: some View {
        Section {
            ForEach(componentCategories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(selectableComponents.filter { $0.category == category }) { component in
                        Toggle(isOn: binding(for: component.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(component.name)
                                Text(component.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Компоненты")
                Spacer()
                if !draft.components.isEmpty {
                    Text("выбрано: \(draft.components.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Ставятся перед установщиком, если их ещё нет в пространстве.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectableComponents: [Component] {
        Catalog.listedComponents.filter { $0.kind == .space }
    }

    private var componentCategories: [Component.Category] {
        Component.Category.allCases.filter { category in selectableComponents.contains { $0.category == category } }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { draft.components.contains(id) },
                set: { on in if on { draft.components.insert(id) } else { draft.components.remove(id) } })
    }

    private var launchSection: some View {
        Section {
            LabeledContent("Программа") {
                HStack(spacing: 6) {
                    TextField("Путь запуска", text: $draft.launchPath,
                              prompt: Text("C:\\Program Files\\Программа\\app.exe"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    if let space = existingSpace {
                        Button("Выбрать…") { chooseLaunchFile(in: space) }
                            .help("Выбрать .exe внутри пространства «\(space.name)»")
                    }
                }
            }
            TextField("Аргументы", text: $draft.launchArguments, prompt: Text("необязательно"))
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Запуск")
        } footer: {
            Text("Путь Windows внутри пространства. Можно оставить пустым: после установки onwin сам найдёт, что добавил установщик, и предложит.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Окружение и заметки", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Переменные окружения программы — по одной на строку, ИМЯ=ЗНАЧЕНИЕ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft.environment)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    Text("Заметки (показываются на карточке)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    TextEditor(text: $draft.notes)
                        .frame(height: 50)
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Panels

    private func chooseInstallerFile() {
        guard let url = OnwinPanels.chooseFile(title: String(localized: "Установщик программы"),
                                               message: String(localized: "Выберите установщик Windows-программы (.exe или .msi)"),
                                               prompt: String(localized: "Выбрать", comment: "Open panel button: choose the file"),
                                               extensions: ["exe", "msi"]) else { return }
        draft.localFile = url
        draft.storedFileName = nil
        if RecipeDraft.trimmed(draft.name).isEmpty { draft.name = CatalogView.suggestedSpaceName(for: url) }
    }

    private func chooseLaunchFile(in space: Space) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Программа для запуска")
        panel.message = String(localized: "Выберите .exe внутри пространства «\(space.name)»")
        panel.prompt = String(localized: "Выбрать", comment: "Open panel button: choose the file")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let programFiles = space.driveC.appendingPathComponent("Program Files", isDirectory: true)
        panel.directoryURL = OnwinPaths.isDirectory(programFiles) ? programFiles : space.driveC
        let types = ["exe", "lnk", "bat"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.launchPath = space.windowsPath(forUnixPath: url)
    }
}

/// One proposed launch program (icon, name, Windows path, where it was found).
@MainActor
struct RecipeCandidateRow: View {
    let candidate: LaunchCandidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = IconExtractor.icon(for: candidate.unixPath) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                } else {
                    OnwinSpaceIcon(symbol: "app.fill", size: 30)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(candidate.windowsPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(candidate.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? OnwinTheme.accent : Color.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}
