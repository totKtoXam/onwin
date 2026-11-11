import AppKit
import SwiftUI
import OnwinCore

// The install browser: ready-made recipes (onwin's analogue of CrossTies), components that can be
// added to any space, and "install your own program" (pick an installer, pick or create a space, run it).
//
// Sheets presented from here are closed *before* any long operation starts, because
// `AppModel.performTask` presents TaskProgressSheet from the window root and two sheets must not collide.

/// What the catalog sheet is showing.
enum CatalogSheet: Identifiable {
    case recipe(AppRecipe)
    case component(Component)
    case custom(URL)

    var id: String {
        switch self {
        case .recipe(let recipe): return "recipe-\(recipe.id)"
        case .component(let component): return "component-\(component.id)"
        case .custom(let url): return "custom-\(url.path)"
        }
    }
}

/// Where to install: a new space or an existing one.
enum CatalogTarget: Hashable {
    case newSpace
    case existing(UUID)
}

@MainActor
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var activeSheet: CatalogSheet?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if !model.hasEngine {
                    CatalogNotice(symbol: "exclamationmark.triangle.fill",
                                  text: "Движок Wine не установлен — установка из каталога станет доступна, когда он появится.")
                }

                ForEach(visibleCategories, id: \.self) { category in
                    CatalogSection(title: category.rawValue, symbol: CatalogView.symbol(for: category)) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(apps(in: category)) { recipe in
                                CatalogRecipeCard(recipe: recipe,
                                                  installedIn: installedSpaces(for: recipe),
                                                  canInstall: model.hasEngine,
                                                  onInstall: { activeSheet = .recipe(recipe) },
                                                  onOpen: { space in model.selection = .space(space.id) },
                                                  onLaunch: { space in model.launchInstalled(recipe, in: space) })
                            }
                        }
                    }
                }

                // «Мои приложения»: the user's own recipes + «Добавить приложение» (UserRecipesSection.swift).
                UserRecipesSection(query: query, columns: columns, onInstall: { recipe in activeSheet = .recipe(recipe) })

                if !visibleComponents.isEmpty {
                    CatalogSection(title: "Компоненты", symbol: "puzzlepiece.extension",
                                   subtitle: "То, что нужно играм: ставится в выбранное пространство в пару щелчков") {
                        VStack(alignment: .leading, spacing: 20) {
                            if let d3dmetal = visibleComponents.first(where: { $0.kind == .global }) {
                                CatalogD3DMetalCard(component: d3dmetal,
                                                    isInstalled: model.isD3DMetalInstalled,
                                                    onFetch: { Task { @MainActor in await model.fetchD3DMetal() } },
                                                    onChooseManually: { model.importD3DMetalInteractively() })
                            }
                            ForEach(visibleComponentCategories, id: \.self) { category in
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(category.rawValue, systemImage: category.symbol)
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                        ForEach(components(in: category)) { component in
                                            CatalogComponentCard(component: component,
                                                                 installedCount: model.installedCount(of: component),
                                                                 canInstall: model.hasEngine) {
                                                activeSheet = .component(component)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if nothingFound {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text("По запросу «\(trimmedQuery)» ничего не нашлось")
                            .font(.headline)
                        Text("Любую программу можно поставить вручную — выберите её установщик ниже.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Сбросить поиск") { query = "" }
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }

                if showsCustomCard {
                    CatalogSection(title: "Своя программа", symbol: "square.and.arrow.down") {
                        CatalogCustomInstallCard(canInstall: model.hasEngine,
                                                 onChoose: { chooseInstaller() },
                                                 onDropFile: { url in activeSheet = .custom(url) })
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Каталог")
                    .font(.largeTitle.bold())
                Text("Готовые рецепты: onwin создаст пространство, поставит нужные компоненты и запустит установщик.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            CatalogSearchField(text: $query)
                .frame(width: 260)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: CatalogSheet) -> some View {
        switch sheet {
        case .recipe(let recipe):
            CatalogRecipeSheet(recipe: recipe,
                               onCancel: { activeSheet = nil },
                               onConfirm: { work in startAfterClosingSheet(work) })
        case .component(let component):
            CatalogComponentSheet(component: component,
                                  onCancel: { activeSheet = nil },
                                  onConfirm: { work in startAfterClosingSheet(work) })
        case .custom(let url):
            CatalogCustomSheet(file: url,
                               onCancel: { activeSheet = nil },
                               onConfirm: { work in startAfterClosingSheet(work) })
        }
    }

    /// Closes the catalog sheet, waits for its dismissal animation, then runs the work
    /// (which usually presents TaskProgressSheet through `AppModel.performTask`).
    private func startAfterClosingSheet(_ work: @escaping @MainActor () async -> Void) {
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await work()
        }
    }

    private func chooseInstaller() {
        guard let url = OnwinPanels.chooseFile(title: "Установить свою программу",
                                               message: "Выберите установщик Windows-программы (.exe или .msi)",
                                               prompt: "Выбрать",
                                               extensions: ["exe", "msi"]) else { return }
        activeSheet = .custom(url)
    }

    // MARK: Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ texts: [String]) -> Bool {
        let words = trimmedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in texts.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    private func recipeMatches(_ recipe: AppRecipe) -> Bool {
        let componentNames = recipe.components.compactMap { Catalog.component($0)?.name }
        return matches([recipe.name, recipe.summary, recipe.notes, recipe.category.rawValue, recipe.spaceName]
                       + componentNames)
    }

    private func apps(in category: AppRecipe.Category) -> [AppRecipe] {
        Catalog.apps.filter { $0.category == category && recipeMatches($0) }
    }

    private var visibleCategories: [AppRecipe.Category] {
        // User recipes have their own section (UserRecipesSection.swift).
        AppRecipe.Category.allCases.filter { $0 != .user && !apps(in: $0).isEmpty }
    }

    private var visibleComponents: [Component] {
        Catalog.listedComponents.filter {
            matches([$0.name, $0.summary, $0.id, $0.category.rawValue, "компонент"] + $0.providesDLLs + $0.satisfiesImports)
        }
    }

    private func components(in category: Component.Category) -> [Component] {
        visibleComponents.filter { $0.category == category && $0.kind == .space }
    }

    private var visibleComponentCategories: [Component.Category] {
        Component.Category.allCases.filter { !components(in: $0).isEmpty }
    }

    private var showsCustomCard: Bool {
        trimmedQuery.isEmpty || nothingFound
            || matches(["Установить свою программу", "установщик", "exe", "msi", "своя"])
    }

    private var nothingFound: Bool {
        !trimmedQuery.isEmpty && visibleCategories.isEmpty && visibleComponents.isEmpty && apps(in: .user).isEmpty
    }

    // MARK: Installed state

    /// Spaces where the recipe's program (launchPath) exists on disk (MainProgramViews.swift).
    private func installedSpaces(for recipe: AppRecipe) -> [Space] {
        model.spacesWithInstalled(recipe)
    }

    // MARK: Helpers

    static func symbol(for category: AppRecipe.Category) -> String {
        if category == .launchers { return "gamecontroller" }
        if category == .runtimes { return "cube" }
        return "wrench.and.screwdriver"
    }

    /// Russian plural form: 1 компонент, 2 компонента, 5 компонентов.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10
        let n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// "SteamSetup.exe" → "Steam", "Battle.net-Setup.exe" → "Battle.net"; never an existing space's name.
    static func suggestedSpaceName(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        var name = stem
        for word in ["installer", "install", "setup"] {
            name = name.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -.()[]"))
        if name.isEmpty { name = stem }
        return SpaceManager.availableName(name)
    }

    static func isNameTaken(_ name: String, in spaces: [Space]) -> Bool {
        spaces.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Building blocks

@MainActor
struct CatalogSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Поиск в каталоге", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Очистить")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? OnwinTheme.accent : Color.primary.opacity(0.08),
                              lineWidth: isFocused ? 1.5 : 1)
        )
    }
}

@MainActor
struct CatalogSection<Content: View>: View {
    let title: String
    let symbol: String
    let subtitle: String?
    let content: Content

    init(title: String, symbol: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(OnwinTheme.accent)
                Text(title)
                    .font(.title2.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            content
        }
    }
}

@MainActor
struct CatalogNotice: View {
    let symbol: String
    let text: String
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
struct CatalogTag: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Cards

@MainActor
struct CatalogRecipeCard: View {
    let recipe: AppRecipe
    let installedIn: [Space]
    let canInstall: Bool
    let onInstall: () -> Void
    let onOpen: (Space) -> Void
    var onLaunch: (Space) -> Void = { _ in }
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(subject: .recipe(recipe, spaces: AppModel.shared.spaces), symbol: recipe.symbol, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name)
                        .font(.headline)
                    Text(recipe.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                CatalogTag(text: recipe.windowsVersion.displayName, symbol: "macwindow")
                CatalogTag(text: recipe.backend.displayName, symbol: "cpu")
                if !recipe.components.isEmpty {
                    CatalogTag(text: "+ \(recipe.components.count) " +
                               CatalogView.plural(recipe.components.count, "компонент", "компонента", "компонентов"),
                               symbol: "puzzlepiece.extension")
                        .help(componentNames)
                }
            }

            if !recipe.notes.isEmpty {
                Label {
                    Text(recipe.notes)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let space = installedIn.first {
                    Button {
                        onOpen(space)
                    } label: {
                        Label("Установлено в «\(space.name)»", systemImage: "checkmark.circle.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OnwinTheme.accent)
                    .help("Открыть пространство")
                }
                Spacer(minLength: 0)
                if let space = installedIn.first {
                    // Installed: launching is the main action, reinstalling a small secondary one.
                    CatalogReinstallButton(canInstall: canInstall, action: onInstall)
                    CatalogLaunchButton(name: recipe.name, space: space, canLaunch: canInstall,
                                        action: { onLaunch(space) })
                } else {
                    Button("Установить…", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canInstall)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onwinCard(highlighted: isHovering)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contextMenu {
            if let space = installedIn.first {
                Button("Запустить в «\(space.name)»") { onLaunch(space) }
                    .disabled(!canInstall)
                Button("Открыть пространство «\(space.name)»") { onOpen(space) }
                Divider()
                Button("Установить ещё раз…", action: onInstall)
                    .disabled(!canInstall)
            } else {
                Button("Установить…", action: onInstall)
                    .disabled(!canInstall)
            }
        }
    }

    private var componentNames: String {
        recipe.components.map { Catalog.component($0)?.name ?? $0 }.joined(separator: ", ")
    }
}

@MainActor
struct CatalogComponentCard: View {
    let component: Component
    let installedCount: Int
    let canInstall: Bool
    let onInstall: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(subject: .component(component), symbol: component.symbol, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(component.name)
                        .font(.headline)
                    Text(component.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                CatalogTag(text: component.sizeDescription, symbol: "arrow.down.circle")
                if !component.providesDLLs.isEmpty {
                    CatalogTag(text: CatalogComponentCard.shortList(component.providesDLLs), symbol: "doc.on.doc")
                        .help("Даёт: " + component.providesDLLs.joined(separator: ", "))
                }
            }
            HStack(spacing: 8) {
                if installedCount > 0 {
                    Label("Есть в \(installedCount) " + CatalogView.plural(installedCount, "пространстве", "пространствах", "пространствах"),
                          systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OnwinTheme.accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(installedCount > 0 ? "Добавить ещё…" : "Добавить…", action: onInstall)
                    .buttonStyle(.bordered)
                    .disabled(!canInstall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onwinCard(highlighted: isHovering)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    /// "msvcp140*, vcruntime140 +4"
    static func shortList(_ items: [String]) -> String {
        let head = items.prefix(2).joined(separator: ", ")
        return items.count > 2 ? "\(head) +\(items.count - 2)" : head
    }
}

/// D3DMetal is not a per-space download: Apple ships it in the Game Porting Toolkit behind a developer
/// sign-in, so the card explains the three steps and starts the guided import.
@MainActor
struct CatalogD3DMetalCard: View {
    let component: Component
    let isInstalled: Bool
    let onFetch: () -> Void
    let onChooseManually: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIconView(subject: .component(component), symbol: component.symbol, size: 52)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.headline)
                    if isInstalled {
                        Label("Установлен", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(OnwinTheme.accent)
                    } else {
                        CatalogTag(text: "для всех пространств", symbol: "square.stack.3d.up")
                    }
                }
                Text(component.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isInstalled {
                    VStack(alignment: .leading, spacing: 4) {
                        step(1, "войдите с Apple ID прямо в onwin (бесплатной учётной записи достаточно)")
                        step(2, "onwin сам скачает последнюю версию Game Porting Toolkit")
                        step(3, "и установит из неё D3DMetal для всех пространств")
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button(isInstalled ? "Обновить D3DMetal" : "Установить D3DMetal", action: onFetch)
                    .buttonStyle(.borderedProminent)
                    .help("Вход с Apple ID, загрузка и установка — внутри onwin. Уже скачанный .dmg из «Загрузок» берётся без входа")
                Button("Указать вручную…", action: onChooseManually)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Выбрать уже скачанный .dmg, подключённый том Game Porting Toolkit или папку redist")
                Link("Открыть в браузере", destination: Catalog.gameportingToolkitURL)
                    .font(.caption)
                    .help("Страница Game Porting Toolkit на developer.apple.com — скачанный там .dmg onwin подхватит сам")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onwinCard(highlighted: !isInstalled)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption2.bold())
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(OnwinTheme.accent, in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct CatalogCustomInstallCard: View {
    let canInstall: Bool
    let onChoose: () -> Void
    let onDropFile: (URL) -> Void
    @State private var isDropTarget = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            OnwinSpaceIcon(symbol: "square.and.arrow.down.fill", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("Установить свою программу")
                    .font(.headline)
                Text("Программы нет в каталоге? Выберите её установщик (.exe или .msi) — onwin запустит его " +
                     "в новом или существующем пространстве. Файл можно просто перетащить на эту карточку.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Выбрать установщик…", action: onChoose)
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onwinCard(highlighted: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            guard canInstall,
                  let file = urls.first(where: { ["exe", "msi"].contains($0.pathExtension.lowercased()) }) else { return false }
            onDropFile(file)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}

// MARK: - Space choice

@MainActor
struct CatalogChoiceRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            OnwinSpaceIcon(symbol: symbol, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OnwinTheme.accent)
                    .lineLimit(1)
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? OnwinTheme.accent : Color.secondary.opacity(0.5))
        }
        .padding(10)
        .frame(height: 50)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? OnwinTheme.accent.opacity(0.14) : Color.primary.opacity(0.04))
        )
    }
}

/// "New space" + the list of existing spaces, one of them selected.
@MainActor
struct CatalogTargetPicker: View {
    let spaces: [Space]
    @Binding var target: CatalogTarget
    @Binding var newName: String
    var allowsNewSpace = true
    var nameProblem: String? = nil
    var badge: (Space) -> String? = { _ in nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if allowsNewSpace {
                    Button {
                        target = .newSpace
                    } label: {
                        CatalogChoiceRow(symbol: "plus", title: "Новое пространство",
                                         subtitle: "Отдельный Windows только для этой программы",
                                         isSelected: target == .newSpace)
                    }
                    .buttonStyle(.plain)

                    if target == .newSpace {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Имя нового пространства", text: $newName)
                                .textFieldStyle(.roundedBorder)
                            if let nameProblem {
                                Text(nameProblem)
                                    .font(.caption)
                                    .foregroundStyle(Color.red)
                            }
                        }
                        .padding(.leading, 50)
                        .padding(.trailing, 10)
                        .padding(.bottom, 4)
                    }
                }

                ForEach(spaces) { space in
                    Button {
                        target = .existing(space.id)
                    } label: {
                        CatalogChoiceRow(symbol: space.onwinSymbol, title: space.name,
                                         subtitle: "\(space.config.windowsVersion.displayName) · \(space.config.graphicsBackend.displayName)",
                                         badge: badge(space),
                                         isSelected: target == .existing(space.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: listHeight)
    }

    private var listHeight: CGFloat {
        let rows = spaces.count + (allowsNewSpace ? 1 : 0)
        var height = CGFloat(rows) * 56
        if allowsNewSpace && target == .newSpace {
            height += nameProblem == nil ? 40 : 58
        }
        return min(max(height, 56), 300)
    }
}

// MARK: - Recipe sheet

@MainActor
struct CatalogRecipeSheet: View {
    @Environment(AppModel.self) private var model
    let recipe: AppRecipe
    let onCancel: () -> Void
    let onConfirm: (@escaping @MainActor () async -> Void) -> Void

    @State private var target: CatalogTarget = .newSpace
    @State private var newName = ""
    @State private var didPrepare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(subject: .recipe(recipe, spaces: model.spaces), symbol: recipe.symbol, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Установка \(recipe.name)")
                        .font(.title3.bold())
                    Text(recipe.summary)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("onwin сделает следующее:")
                    .font(.headline)
                ForEach(Array(plannedSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }

            Text("Куда установить?")
                .font(.headline)

            CatalogTargetPicker(spaces: model.spaces, target: $target, newName: $newName,
                                nameProblem: nameProblem,
                                badge: { space in isInstalled(in: space) ? "уже установлено" : nil })

            ForEach(warnings, id: \.self) { warning in
                CatalogNotice(symbol: "info.circle.fill", text: warning, color: .blue)
            }

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Установить") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        if let existing = model.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(recipe.spaceName) == .orderedSame
        }) {
            target = .existing(existing.id)
            newName = SpaceManager.availableName(recipe.spaceName)
        } else {
            target = .newSpace
            newName = recipe.spaceName
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard target == .newSpace else { return nil }
        if trimmedName.isEmpty { return "Укажите имя пространства" }
        if CatalogView.isNameTaken(trimmedName, in: model.spaces) { return "Пространство с таким именем уже есть" }
        return nil
    }

    private var canConfirm: Bool {
        guard model.hasEngine else { return false }
        switch target {
        case .newSpace: return nameProblem == nil
        case .existing(let id): return model.space(id: id) != nil
        }
    }

    private func isInstalled(in space: Space) -> Bool {
        space.hasInstalled(recipe)
    }

    private var plannedSteps: [String] {
        var steps: [String] = []
        switch target {
        case .newSpace:
            steps.append("Создаст пространство «\(trimmedName.isEmpty ? recipe.spaceName : trimmedName)» " +
                         "(\(recipe.windowsVersion.displayName), графика: \(recipe.backend.displayName))")
        case .existing(let id):
            steps.append("Использует пространство «\(model.space(id: id)?.name ?? "")»")
        }
        let names = recipe.components.compactMap { Catalog.component($0)?.name }
        if !names.isEmpty {
            steps.append("Установит компоненты: \(names.joined(separator: ", ")) (если их ещё нет)")
        }
        if let installer = recipe.installer {
            steps.append(installer.url.isFileURL ? "Запустит установщик \(installer.fileName), сохранённый в рецепте"
                                                 : "Скачает и запустит установщик \(installer.fileName)")
        }
        if recipe.launchPath != nil {
            steps.append("Добавит \(recipe.name) в список программ пространства")
        }
        return steps
    }

    private var warnings: [String] {
        var result: [String] = []
        if recipe.backend == .d3dmetal && !model.isD3DMetalInstalled {
            result.append("Рецепт рассчитан на D3DMetal, но он ещё не установлен — onwin временно выберет другой вариант графики.")
        }
        if case .existing(let id) = target, let space = model.space(id: id) {
            if space.config.windowsVersion != recipe.windowsVersion {
                result.append("Рецепт рассчитан на \(recipe.windowsVersion.displayName), а в пространстве «\(space.name)» — " +
                              "\(space.config.windowsVersion.displayName). Обычно это не мешает.")
            }
            if model.isRunning(space.id) {
                result.append("В пространстве «\(space.name)» сейчас работают программы — установка может дождаться их закрытия.")
            }
        }
        if let installer = recipe.installer, !installer.url.isFileURL {
            result.append(recipe.category == .user ? "Установщик будет скачан по ссылке из вашего рецепта."
                                                   : "Установщик будет скачан из интернета от издателя программы.")
        }
        return result
    }

    private func confirm() {
        guard canConfirm else { return }
        let model = self.model
        let recipe = self.recipe
        switch target {
        case .existing(let id):
            guard let space = model.space(id: id) else { return }
            onConfirm {
                _ = await model.install(recipe: recipe, into: space)
            }
        case .newSpace:
            let name = trimmedName
            if name == recipe.spaceName {
                // The installer creates the space itself, with the recipe's Windows version and graphics.
                onConfirm {
                    _ = await model.install(recipe: recipe, into: nil)
                }
            } else {
                onConfirm {
                    if let space = await model.createSpace(name: name, windowsVersion: recipe.windowsVersion,
                                                             backend: recipe.backend) {
                        _ = await model.install(recipe: recipe, into: space)
                    }
                }
            }
        }
    }
}

// MARK: - Component sheet

@MainActor
struct CatalogComponentSheet: View {
    @Environment(AppModel.self) private var model
    let component: Component
    let onCancel: () -> Void
    let onConfirm: (@escaping @MainActor () async -> Void) -> Void

    @State private var target: CatalogTarget = .newSpace
    @State private var unusedName = ""
    @State private var didPrepare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(subject: .component(component), symbol: component.symbol, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Добавить \(component.name)")
                        .font(.title3.bold())
                    Text(component.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                CatalogTag(text: component.sizeDescription, symbol: "arrow.down.circle")
                if !component.requires.isEmpty {
                    CatalogTag(text: "+ " + component.requires.compactMap { Catalog.component($0)?.name }.joined(separator: ", "),
                               symbol: "link")
                }
            }
            if !component.providesDLLs.isEmpty {
                Text("Даёт: " + component.providesDLLs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !component.notes.isEmpty {
                Label(component.notes, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.spaces.isEmpty {
                CatalogNotice(symbol: "shippingbox", text: "Компоненты устанавливаются в пространство, а пространств пока нет.",
                              color: .blue)
                HStack {
                    Spacer()
                    Button("Отмена", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Создать пространство…") {
                        let model = self.model
                        onConfirm { model.showNewSpaceSheet = true }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasEngine)
                }
            } else {
                Text("В какое пространство?")
                    .font(.headline)

                CatalogTargetPicker(spaces: model.spaces, target: $target, newName: $unusedName,
                                    allowsNewSpace: false,
                                    badge: { space in
                                        component.isInstalled(in: space.config) ? "уже установлен" : nil
                                    })

                if let space = chosenSpace, component.isInstalled(in: space.config) {
                    CatalogNotice(symbol: "info.circle.fill",
                                  text: "\(component.name) уже есть в «\(space.name)». Повторная установка его переустановит.",
                                  color: .blue)
                }

                Text("Файлы скачиваются с официальных серверов (Microsoft, WineHQ, NVIDIA), проверяются и кешируются — повторно они не загружаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Отмена", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Установить") {
                        confirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenSpace == nil || !model.hasEngine)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear(perform: prepare)
    }

    private var chosenSpace: Space? {
        if case .existing(let id) = target { return model.space(id: id) }
        return nil
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        // Prefer a space that does not have the component yet.
        let preferred = model.selectedSpace.flatMap { component.isInstalled(in: $0.config) ? nil : $0 }
        let candidate = preferred ?? model.spaces.first { !component.isInstalled(in: $0.config) } ?? model.spaces.first
        if let candidate { target = .existing(candidate.id) }
    }

    private func confirm() {
        guard let space = chosenSpace else { return }
        let model = self.model
        let component = self.component
        onConfirm {
            _ = await model.install(component: component, into: space)
        }
    }
}

// MARK: - Custom installer sheet

@MainActor
struct CatalogCustomSheet: View {
    @Environment(AppModel.self) private var model
    let file: URL
    let onCancel: () -> Void
    let onConfirm: (@escaping @MainActor () async -> Void) -> Void

    @State private var target: CatalogTarget = .newSpace
    @State private var newName = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var backend: GraphicsBackend = .auto
    @State private var didPrepare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                OnwinSpaceIcon(symbol: "square.and.arrow.down.fill", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Установка программы")
                        .font(.title3.bold())
                    Text(file.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                }
            }

            Text("Где запустить установщик?")
                .font(.headline)

            CatalogTargetPicker(spaces: model.spaces, target: $target, newName: $newName,
                                nameProblem: nameProblem)

            if target == .newSpace {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Windows:")
                            .gridColumnAlignment(.trailing)
                        Picker("Windows", selection: $windowsVersion) {
                            ForEach(WindowsVersion.allCases) { version in
                                Text(version.displayName).tag(version)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    GridRow {
                        Text("Графика:")
                        Picker("Графика", selection: $backend) {
                            ForEach(GraphicsBackend.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text(backend.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
            }

            Text("Когда установщик закончит работу, onwin найдёт установленную программу и предложит сохранить её в «Мои приложения».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Запустить установщик") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        newName = CatalogView.suggestedSpaceName(for: file)
        backend = model.settings.defaultBackend
        target = .newSpace
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard target == .newSpace else { return nil }
        if trimmedName.isEmpty { return "Укажите имя пространства" }
        if CatalogView.isNameTaken(trimmedName, in: model.spaces) { return "Пространство с таким именем уже есть" }
        return nil
    }

    private var canConfirm: Bool {
        guard model.hasEngine else { return false }
        switch target {
        case .newSpace: return nameProblem == nil
        case .existing(let id): return model.space(id: id) != nil
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        let model = self.model
        let file = self.file
        switch target {
        case .existing(let id):
            guard let space = model.space(id: id) else { return }
            onConfirm {
                // Waits for the installer, then offers «Сохранить в каталог?» (AppModel+UserRecipes.swift).
                await model.installCustom(file: file, in: space)
            }
        case .newSpace:
            let name = trimmedName
            let windowsVersion = self.windowsVersion
            let backend = self.backend
            onConfirm {
                if let space = await model.createSpace(name: name, windowsVersion: windowsVersion, backend: backend) {
                    await model.installCustom(file: file, in: space)
                }
            }
        }
    }
}
