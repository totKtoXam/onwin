import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import OnwinCore

// MARK: - "Мои приложения": the user's own recipes (read this if you add UI for them)
//
// Core: OnwinCore/UserRecipes.swift (storage, validation, import/export), InstallDetection.swift
// (what an installer added). Views: Views/UserRecipesSection.swift (catalog section and cards),
// Views/RecipeEditorSheet.swift (the form). The editor is presented from the window root by
// `.onwinUserRecipes()` (OnwinApp.swift), never on top of TaskProgressSheet: `UserRecipeStore.present`
// waits until the running task's sheet has closed.
//
//   UserRecipeStore.shared.recipes                       observable list (reload() after changes)
//   UserRecipeStore.shared.present(_ context)            opens RecipeEditorSheet (.create / .edit / .importing / .afterInstall)
//   AppModel.newUserRecipe(); editUserRecipe(_:); importUserRecipeInteractively(); openUserRecipeFile(_:)
//   AppModel.exportUserRecipe(_:)  (NSSavePanel);  deleteUserRecipe(_:)
//   AppModel.saveUserRecipe(_ draft:, context:) -> Bool
//   AppModel.installCustom(file:in:) async      «Установить свою программу»: runs the installer, waits,
//                                               detects the program and offers «Сохранить в каталог?»
//   AppModel.installDetecting(recipe:into:context:)   used by install(recipe:) — a user recipe without a
//                                               launch path gets the found program proposed afterwards

/// What the recipe editor is doing.
struct RecipeEditorContext: Identifiable {
    enum Mode: Equatable {
        case create
        case edit(String)
        /// Opened .onwinrecipe file (not saved until the user presses «Сохранить»).
        case importing(URL)
        /// Right after an installer finished in this space: «Сохранить в каталог?».
        case afterInstall(spaceID: UUID)
    }

    let id = UUID()
    var mode: Mode
    var draft: RecipeDraft
    /// Programs the installer added (best first), offered as the launch path.
    var candidates: [LaunchCandidate] = []
}

/// Form state of a recipe (strings as typed; converted by `makeRecipe()`).
struct RecipeDraft: Equatable {
    enum InstallerKind: String, Hashable { case url, file }

    var id = ""
    var name = ""
    var summary = ""
    var installerKind: InstallerKind = .url
    var url = ""
    var sha256 = ""
    /// A file chosen on this Mac (copied into the recipe on save).
    var localFile: URL?
    /// Installer already stored with the recipe (Files/<id>/<name>), or named by an imported file.
    var storedFileName: String?
    var installerArguments = ""
    var spaceName = ""
    var windowsVersion: WindowsVersion = .win10
    var backend: GraphicsBackend = .auto
    var components: Set<String> = []
    var launchPath = ""
    var launchArguments = ""
    /// KEY=VALUE per line.
    var environment = ""
    var notes = ""
    var symbol = UserRecipe.defaultSymbol
    /// After an install: pin the chosen program in the space when saving.
    var pinInSpace = true

    init() {}

    init(recipe r: UserRecipe) {
        id = r.id
        name = r.name
        summary = r.summary
        if let installer = r.installer {
            if let url = installer.url {
                installerKind = .url
                self.url = url
                sha256 = installer.sha256 ?? ""
            } else if let file = installer.file {
                installerKind = .file
                if file.hasPrefix("/") { localFile = URL(fileURLWithPath: file) } else { storedFileName = file }
            }
            installerArguments = WindowsCommandLine.join(installer.arguments)
        }
        spaceName = r.spaceName
        windowsVersion = r.windowsVersion
        backend = r.backend
        components = Set(r.components)
        launchPath = r.launchPath ?? ""
        launchArguments = WindowsCommandLine.join(r.launchArguments)
        environment = r.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        notes = r.notes
        symbol = r.symbol
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Environment lines that are not KEY=VALUE.
    var environmentProblems: [String] {
        environment.split(whereSeparator: \.isNewline).map { RecipeDraft.trimmed(String($0)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line in
                guard let eq = line.firstIndex(of: "="), eq != line.startIndex else {
                    return String(localized: "Строка окружения «\(line)»: нужно ИМЯ=ЗНАЧЕНИЕ")
                }
                return nil
            }
    }

    var parsedEnvironment: [String: String] {
        var env: [String: String] = [:]
        for raw in environment.split(whereSeparator: \.isNewline) {
            let line = RecipeDraft.trimmed(String(raw))
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            env[RecipeDraft.trimmed(String(line[..<eq]))] = String(line[line.index(after: eq)...])
        }
        return env
    }

    /// The recipe and the local file to copy into it.
    func makeRecipe() -> (recipe: UserRecipe, installerFile: URL?) {
        var installer = UserRecipe.InstallerSource(arguments: WindowsCommandLine.split(installerArguments))
        var file: URL?
        switch installerKind {
        case .url:
            installer.url = RecipeDraft.trimmed(url)
            let sha = RecipeDraft.trimmed(sha256).lowercased()
            installer.sha256 = sha.isEmpty ? nil : sha
            if installer.url?.isEmpty == true { installer.url = nil }
        case .file:
            if let localFile {
                file = localFile
                installer.file = localFile.path
            } else {
                installer.file = storedFileName
            }
        }
        let launch = RecipeDraft.trimmed(launchPath)
        var recipe = UserRecipe(id: id, name: RecipeDraft.trimmed(name), summary: RecipeDraft.trimmed(summary),
                                installer: installer, spaceName: RecipeDraft.trimmed(spaceName),
                                windowsVersion: windowsVersion, backend: backend,
                                components: Catalog.components.map(\.id).filter { components.contains($0) },
                                launchPath: launch.isEmpty ? nil : launch,
                                launchArguments: WindowsCommandLine.split(launchArguments),
                                environment: parsedEnvironment, notes: RecipeDraft.trimmed(notes), symbol: symbol)
        if recipe.spaceName.isEmpty { recipe.spaceName = recipe.name }
        return (recipe, file)
    }

    /// Everything that keeps «Сохранить» disabled.
    var problems: [String] {
        let (recipe, file) = makeRecipe()
        var result = UserRecipes.validate(recipe, checkFiles: false)
        if installerKind == .file {
            if let file {
                if !FileManager.default.fileExists(atPath: file.path) { result.append(String(localized: "Нет файла \(file.path)")) }
            } else if let stored = storedFileName {
                let url = UserRecipes.filesDirectory(for: id).appendingPathComponent(stored)
                if id.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
                    result.append(String(localized: "Нет файла установщика «\(stored)» — выберите его на этом Mac"))
                }
            }
        }
        return result + environmentProblems
    }
}

/// User recipes and the editor presentation.
@MainActor
@Observable
final class UserRecipeStore {
    static let shared = UserRecipeStore()

    private(set) var recipes: [UserRecipe] = UserRecipes.all()
    /// The editor sheet (presented by `.onwinUserRecipes()`).
    var editor: RecipeEditorContext?
    /// Waits for TaskProgressSheet to close.
    @ObservationIgnored private(set) var pendingEditor: RecipeEditorContext?
    /// Informational alert («Рецепт экспортирован…»).
    var notice: String?

    func reload() {
        UserRecipes.invalidateCache()
        recipes = UserRecipes.all()
    }

    func present(_ context: RecipeEditorContext) {
        if AppModel.shared.activeTask == nil && editor == nil {
            editor = context
        } else {
            pendingEditor = context
        }
    }

    /// Called when the task sheet closed.
    func presentPending() {
        guard let pending = pendingEditor, editor == nil, AppModel.shared.activeTask == nil else { return }
        pendingEditor = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)   // let the task sheet finish its dismissal
            if self.editor == nil { self.editor = pending } else { self.pendingEditor = pending }
        }
    }
}

extension AppModel {
    // MARK: Editor entry points

    func newUserRecipe(installer file: URL? = nil) {
        var draft = RecipeDraft()
        draft.backend = settings.defaultBackend
        if let file {
            draft.installerKind = .file
            draft.localFile = file
            draft.name = CatalogView.suggestedSpaceName(for: file)
        }
        UserRecipeStore.shared.present(RecipeEditorContext(mode: .create, draft: draft))
    }

    func editUserRecipe(_ recipe: UserRecipe) {
        UserRecipeStore.shared.present(RecipeEditorContext(mode: .edit(recipe.id), draft: RecipeDraft(recipe: recipe)))
    }

    func importUserRecipeInteractively() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт рецепта")
        panel.message = String(localized: "Выберите файл рецепта onwin (.\(UserRecipe.fileExtension)). Импорт ничего не устанавливает и не запускает.")
        panel.prompt = String(localized: "Импортировать")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: UserRecipe.fileExtension), .json].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openUserRecipeFile(url)
    }

    /// A .onwinrecipe opened from Finder or the import panel: shown in the editor for review, saved only on
    /// «Сохранить». Nothing is installed or run.
    func openUserRecipeFile(_ url: URL) {
        do {
            let (recipe, sibling) = try UserRecipes.read(url)
            var draft = RecipeDraft(recipe: recipe)
            // A free id is kept; otherwise saving makes a new one (never replaces another recipe silently).
            if !UserRecipes.isValidID(recipe.id) || UserRecipes.recipe(recipe.id) != nil
                || Catalog.builtinApps.contains(where: { $0.id.caseInsensitiveCompare(recipe.id) == .orderedSame }) {
                draft.id = ""
            }
            if let sibling { draft.localFile = sibling; draft.storedFileName = nil }
            selection = .catalog
            UserRecipeStore.shared.present(RecipeEditorContext(mode: .importing(url), draft: draft))
        } catch {
            report(error)
        }
    }

    func exportUserRecipe(_ recipe: UserRecipe) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт рецепта")
        panel.message = String(localized: "Рецепт сохранится в один файл — его можно передать на другой Mac")
        panel.prompt = String(localized: "Экспортировать")
        panel.nameFieldStringValue = "\(recipe.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")).\(UserRecipe.fileExtension)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: UserRecipe.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UserRecipes.export(recipe.id, to: url)
            UserRecipeStore.shared.notice = String(localized: "Рецепт «\(recipe.name)» сохранён в \(url.lastPathComponent).") +
                (UserRecipes.exportNote(for: recipe).map { "\n\n\($0)" } ?? "")
        } catch {
            report(error)
        }
    }

    func deleteUserRecipe(_ recipe: UserRecipe) {
        do {
            try UserRecipes.remove(recipe.id)
        } catch {
            report(error)
        }
        UserRecipeStore.shared.reload()
    }

    /// Saves the editor's recipe; after an install also pins the program and keeps its icon.
    @discardableResult
    func saveUserRecipe(_ draft: RecipeDraft, context: RecipeEditorContext) -> Bool {
        let (recipe, file) = draft.makeRecipe()
        do {
            let saved = try UserRecipes.save(recipe, installerFile: file)
            if case .afterInstall(let spaceID) = context.mode, let space = self.space(id: spaceID),
               let path = saved.launchPath {
                if draft.pinInSpace,
                   !space.config.programs.contains(where: { $0.windowsPath.caseInsensitiveCompare(path) == .orderedSame }) {
                    updateConfig(of: spaceID) { config in
                        config.programs.append(ProgramEntry(name: saved.name, windowsPath: path,
                                                            arguments: saved.launchArguments, environment: saved.environment))
                    }
                    refreshPrograms(of: spaceID)
                }
                if let exe = space.unixPath(forWindowsPath: path), let png = AppModel.pngIcon(of: exe) {
                    try? UserRecipes.saveIcon(png, for: saved.id)
                }
            }
            UserRecipeStore.shared.reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    static func pngIcon(of exe: URL) -> Data? {
        guard let image = IconExtractor.icon(for: exe) else { return nil }
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Installing

    /// «Установить свою программу»: runs the installer and waits for it, then proposes saving it as a recipe
    /// with the program it added as the launch path.
    func installCustom(file: URL, in space: Space) async {
        let current = self.space(id: space.id) ?? space
        guard current.isInitialized else {
            report(String(localized: "Пространство «\(current.name)» ещё не готово (нет system.reg). Создайте его заново."))
            return
        }
        // Waiting for the whole space would never end while e.g. Steam runs in it.
        let waitForSpace = ProcessTracker.shared.running(in: current.id).isEmpty
        let result = await performTask(String(localized: "Установка \(file.deletingPathExtension().lastPathComponent)")) {
            (context: TaskContext) async throws -> RecipeInstallOutcome in
            context.status(String(localized: "Работает установщик \(file.lastPathComponent) — завершите установку в его окне…"))
            let r = try await RecipeInstaller.runInstaller(file, in: current, waitForSpace: waitForSpace, output: context.log)
            return RecipeInstallOutcome(status: r.status, detection: r.detection)
        }
        reload()
        selection = .space(current.id)
        refreshPrograms(of: current.id)
        guard let result else { return }
        guard RecipeInstaller.isSuccess(result.status) || !result.detection.candidates.isEmpty else {
            if !result.detection.isEmpty || !WineRunner.exitStatus(result.status, matches: 1602) {
                report(String(localized: "Установщик \(file.lastPathComponent) завершился с кодом \(Int(result.status))."))
            }
            return
        }
        let installed = self.space(id: current.id) ?? current
        var draft = RecipeDraft()
        draft.name = result.detection.productName ?? CatalogView.suggestedSpaceName(for: file)
        draft.summary = [result.detection.publisher, result.detection.version.map { String(localized: "версия \($0)") }]
            .compactMap { $0 }.joined(separator: ", ")
        draft.installerKind = .file
        draft.localFile = file
        draft.spaceName = installed.name
        draft.windowsVersion = installed.config.windowsVersion
        draft.backend = installed.config.graphicsBackend
        if let best = result.detection.candidates.first {
            draft.launchPath = best.windowsPath
            draft.launchArguments = WindowsCommandLine.join(best.arguments)
        }
        UserRecipeStore.shared.present(RecipeEditorContext(mode: .afterInstall(spaceID: installed.id), draft: draft,
                                                           candidates: result.detection.candidates))
    }

    /// Recipe install used by `install(recipe:into:)`: user recipes are installed with detection, and when
    /// one has no launch path yet, the found program is proposed once the task sheet closes.
    func installDetecting(recipe: AppRecipe, into target: Space?, context: TaskContext) async throws -> Space {
        guard recipe.category == .user, let user = UserRecipes.recipe(recipe.id) else {
            return try await Installer.install(recipe: recipe, into: target, progress: context.progress)
        }
        let problems = UserRecipes.validate(user)
        guard problems.isEmpty else {
            throw OnwinError(String(localized: "Рецепт «\(user.name)» не готов к установке:") + "\n"
                             + problems.map { "• \($0)" }.joined(separator: "\n"))
        }
        let result = try await RecipeInstaller.install(recipe: recipe, into: target, progress: context.progress)
        if user.launchPath == nil, let best = result.detection.candidates.first {
            context.status(String(localized: "Найдена программа: \(best.windowsPath)"))
            var draft = RecipeDraft(recipe: user)
            draft.launchPath = best.windowsPath
            draft.launchArguments = WindowsCommandLine.join(best.arguments)
            draft.spaceName = result.space.name
            UserRecipeStore.shared.present(RecipeEditorContext(mode: .afterInstall(spaceID: result.space.id), draft: draft,
                                                               candidates: result.detection.candidates))
        }
        return result.space
    }
}

struct RecipeInstallOutcome: Sendable {
    var status: Int32
    var detection: InstallDetection
}

// MARK: - Root presentation

extension View {
    /// Presents the recipe editor and its notices from the window root (OnwinApp.swift).
    func onwinUserRecipes() -> some View {
        modifier(UserRecipesPresenter())
    }
}

@MainActor
private struct UserRecipesPresenter: ViewModifier {
    @Bindable private var store = UserRecipeStore.shared
    private let model = AppModel.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.editor) { context in
                RecipeEditorSheet(context: context)
                    .environment(model)
                    .tint(OnwinTheme.accent)
            }
            .onChange(of: model.activeTask == nil) { _, idle in
                if idle { store.presentPending() }
            }
            .onChange(of: store.editor == nil) { _, closed in
                if closed { store.presentPending() }
            }
            .alert(AppRecipe.Category.user.title, isPresented: Binding(get: { store.notice != nil },
                                                                       set: { if !$0 { store.notice = nil } })) {
                Button("OK", role: .cancel) { store.notice = nil }
            } message: {
                Text(store.notice ?? "")
            }
    }
}
