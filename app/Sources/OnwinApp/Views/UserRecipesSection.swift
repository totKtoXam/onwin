import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OnwinCore

// Catalog section «Мои приложения»: the user's own recipes (install / edit / export / delete) and the
// «Добавить приложение» card (new recipe, import .onwinrecipe; installers and recipe files can be dropped on it).
// Installing reuses CatalogRecipeSheet through `onInstall`. Logic: AppModel+UserRecipes.swift.

@MainActor
struct UserRecipesSection: View {
    @Environment(AppModel.self) private var model
    let query: String
    let columns: [GridItem]
    let onInstall: (AppRecipe) -> Void
    @State private var deleting: UserRecipe?

    private var store: UserRecipeStore { UserRecipeStore.shared }

    var body: some View {
        if isVisible {
            CatalogSection(title: AppRecipe.Category.user.title, symbol: "person.crop.square",
                           subtitle: "Программы, которых нет в каталоге: свои рецепты установки") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(visibleRecipes) { recipe in
                        UserRecipeCard(recipe: recipe,
                                       installedIn: installedSpaces(for: recipe),
                                       canInstall: model.hasEngine,
                                       onInstall: { onInstall(recipe.appRecipe) },
                                       onEdit: { model.editUserRecipe(recipe) },
                                       onExport: { model.exportUserRecipe(recipe) },
                                       onDelete: { deleting = recipe },
                                       onOpen: { space in model.selection = .space(space.id) },
                                       onLaunch: { space in model.launchInstalled(recipe.appRecipe, in: space) })
                    }
                    if showsAddCard {
                        UserRecipeAddCard(onCreate: { model.newUserRecipe() },
                                          onImport: { model.importUserRecipeInteractively() },
                                          onDropInstaller: { url in model.newUserRecipe(installer: url) },
                                          onDropRecipe: { url in model.openUserRecipeFile(url) })
                    }
                }
            }
            .confirmationDialog("Удалить рецепт?", isPresented: Binding(get: { deleting != nil },
                                                                       set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { recipe in
                Button("Удалить «\(recipe.name)»", role: .destructive) {
                    model.deleteUserRecipe(recipe)
                    deleting = nil
                }
                Button("Отмена", role: .cancel) { deleting = nil }
            } message: { _ in
                Text("Рецепт и сохранённый с ним установщик будут удалены. Пространства и установленные программы останутся.")
            }
        }
    }

    // MARK: Filtering

    private var words: [String] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func matches(_ texts: [String]) -> Bool {
        words.allSatisfy { word in texts.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    var visibleRecipes: [UserRecipe] {
        store.recipes.filter { r in
            matches([r.name, r.summary, r.notes, r.spaceName, r.id, AppRecipe.Category.user.title]
                    + r.components.compactMap { Catalog.component($0)?.name })
        }
    }

    private var showsAddCard: Bool {
        words.isEmpty || matches(["Добавить приложение", "мои приложения", "рецепт", "импорт", "onwinrecipe"])
    }

    private var isVisible: Bool { !visibleRecipes.isEmpty || showsAddCard }

    /// Spaces where the recipe's program (launchPath) exists on disk (MainProgramViews.swift).
    private func installedSpaces(for recipe: UserRecipe) -> [Space] {
        model.spacesWithInstalled(recipe.appRecipe)
    }
}

/// Icon of a user recipe through the common icon pipeline (OnwinCore/AppIcons.swift, resolved off the main
/// thread): the program's own icon in a space, the icon saved with the recipe, its installer's icon, or
/// the SF Symbol tile.
@MainActor
struct UserRecipeIcon: View {
    let recipe: UserRecipe
    let installedIn: [Space]
    var size: CGFloat = 46

    var body: some View {
        AppIconView(subject: .recipe(recipe.appRecipe, spaces: installedIn), symbol: recipe.symbol, size: size)
    }
}

@MainActor
struct UserRecipeCard: View {
    let recipe: UserRecipe
    let installedIn: [Space]
    let canInstall: Bool
    let onInstall: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onOpen: (Space) -> Void
    var onLaunch: (Space) -> Void = { _ in }
    @State private var isHovering = false

    private var isValid: Bool { UserRecipes.validate(recipe).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                UserRecipeIcon(recipe: recipe, installedIn: installedIn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name)
                        .font(.headline)
                    Text(recipe.summary.isEmpty ? "Моё приложение" : recipe.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Изменить…", action: onEdit)
                    Button("Экспортировать…", action: onExport)
                    Divider()
                    Button("Удалить…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Изменить, экспортировать или удалить рецепт")
            }

            HStack(spacing: 6) {
                CatalogTag(text: recipe.windowsVersion.displayName, symbol: "macwindow")
                CatalogTag(text: recipe.backend.displayName, symbol: "cpu")
                if let installer = recipe.installer {
                    CatalogTag(text: installer.isLocalFile ? "файл" : "ссылка",
                               symbol: installer.isLocalFile ? "doc" : "link")
                        .help(installer.url ?? installer.effectiveFileName)
                }
                if !recipe.components.isEmpty {
                    CatalogTag(text: "+ \(recipe.components.count) " +
                               CatalogView.plural(recipe.components.count, "компонент", "компонента", "компонентов"),
                               symbol: "puzzlepiece.extension")
                        .help(recipe.components.map { Catalog.component($0)?.name ?? $0 }.joined(separator: ", "))
                }
            }

            if recipe.isMissingInstallerFile {
                Label("Нет файла установщика «\(recipe.installer?.effectiveFileName ?? "")» — выберите его в «Изменить…»",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !recipe.notes.isEmpty {
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
                    // Installed: launching is the main action (the installer file is not needed for it).
                    if !recipe.isMissingInstallerFile {
                        CatalogReinstallButton(canInstall: canInstall && isValid, action: onInstall)
                    }
                    CatalogLaunchButton(name: recipe.name, space: space, canLaunch: canInstall,
                                        action: { onLaunch(space) })
                } else if recipe.isMissingInstallerFile {
                    Button("Изменить…", action: onEdit)
                        .buttonStyle(.bordered)
                } else {
                    Button("Установить…", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canInstall || !isValid)
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
            }
            Button("Изменить…", action: onEdit)
            Button("Экспортировать…", action: onExport)
            Divider()
            Button("Удалить…", role: .destructive, action: onDelete)
        }
    }
}

@MainActor
struct UserRecipeAddCard: View {
    let onCreate: () -> Void
    let onImport: () -> Void
    let onDropInstaller: (URL) -> Void
    let onDropRecipe: (URL) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                OnwinSpaceIcon(symbol: "plus.app.fill", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Добавить приложение")
                        .font(.headline)
                    Text("Свой рецепт для программы не из каталога: ссылка или файл установщика, ключи тихой установки, " +
                         "пространство, компоненты и что запускать. Можно перетащить сюда установщик или файл .\(UserRecipe.fileExtension).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Импортировать…", action: onImport)
                    .buttonStyle(.bordered)
                    .help("Добавить рецепт из файла .\(UserRecipe.fileExtension) — ничего не устанавливается")
                Button("Создать…", action: onCreate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onwinCard(highlighted: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            if let recipe = urls.first(where: { ["onwinrecipe", "json"].contains($0.pathExtension.lowercased()) }) {
                onDropRecipe(recipe)
                return true
            }
            if let installer = urls.first(where: { ["exe", "msi"].contains($0.pathExtension.lowercased()) }) {
                onDropInstaller(installer)
                return true
            }
            return false
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}
