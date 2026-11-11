import AppKit
import Foundation
import Observation
import OnwinCore

// MARK: - AppModel API (read this first if you are writing a view)
//
// `AppModel` is the single source of truth of the app. It is injected with
// `.environment(AppModel.shared)` at the root; read it in views with
//
//     @Environment(AppModel.self) private var model
//     ...
//     var body: some View {
//         @Bindable var model = model          // when you need $model.something
//
// Mark your view structs `@MainActor` (the model is main-actor isolated).
// NOTE: both SwiftUI and OnwinCore declare a type called `Settings`; in files that import both,
// write `OnwinSettings` (typealias below) or `OnwinCore.Settings`, and `SwiftUI.Settings` for the scene.
//
// State (all observable):
//   var spaces: [Space]                    sorted by name (SpaceManager.list())
//   var engines: [Engine]                    EngineManager.installedEngines()
//   var selection: SidebarItem?              .desktop (default) / .catalog / .space(UUID) / .running / .logs ; nil = start page
//   var activeTask: TaskState?               long operation shown in TaskProgressSheet (one at a time)
//   var lastError: String?, lastErrorLog: URL?   shown by the shell's error alert
//   var settings: OnwinSettings              global settings (defaultEngineID, defaultBackend)
//   var isD3DMetalInstalled: Bool
//   var backgroundActivity: String?          small status text in the toolbar (e.g. applying winecfg -v)
//   var showNewSpaceSheet: Bool             presents NewSpaceSheet (set false to close it)
//   var settingsSpaceID: UUID?              presents SpaceSettingsView(spaceID:) in a sheet
//   var renamingSpaceID: UUID?              presents the rename alert
//   var deletingSpaceID: UUID?              presents the delete confirmation
//   var pendingOpen: PendingOpen?            presents "which space to run in?" for opened/dropped files
//   private(set) var programsBySpace: [UUID: [SpaceProgram]]   cached ProgramScanner results
//   Bindable helpers: isShowingError, isShowingTask, isShowingSpaceSettings, isRenaming, isConfirmingDelete
//
// Derived:
//   var hasEngine: Bool; var defaultEngine: Engine?; var selectedSpace: Space?
//   var renamingSpace: Space?; var deletingSpace: Space?
//   func space(id: UUID) -> Space?
//   func engine(for space: Space) -> Engine?
//   func resolvedBackend(for space: Space) -> GraphicsBackend?   (what .auto turns into)
//   func programs(in space: Space) -> [SpaceProgram]            (cached; refreshPrograms(of:) rescans)
//   func isRunning(_ spaceID: UUID) -> Bool
//   func runningPrograms(in spaceID: UUID) -> [RunningProgram]
//
// Actions:
//   func reload()                                  rescans engines, spaces, programs, D3DMetal
//   func refreshPrograms(of spaceID: UUID)
//   func report(_ error: Error, log: URL? = nil); func report(_ message: String, log: URL? = nil); func clearError()
//   func createSpace(name:windowsVersion:backend:) async -> Space?      (closes NewSpaceSheet, shows progress)
//   func deleteSpace(_ space: Space) async                             (moves to Trash, no confirmation here)
//   func rename(_ space: Space, to newName: String)
//   func duplicate(_ space: Space) async -> Space?
//   func archive(_ space: Space, to url: URL) async; func archiveInteractively(_ space: Space)
//   func restore(from url: URL) async -> Space?;      func restoreInteractively()
//   func updateConfig(of spaceID: UUID, _ change: (inout SpaceConfig) -> Void)
//        saves onwin-space.json; if windowsVersion / highResolution changed, applies them through
//        SpaceSetup in the background (backgroundActivity shows it). Changing `name` here renames.
//   func pinProgram(_ file: URL, name: String?, in spaceID: UUID); func unpinProgram(_ entryID: UUID, in spaceID: UUID)
//   func run(file: URL, in space: Space, arguments: [String] = []) -> RunningProgram?   (@discardableResult)
//   func run(files: [URL], in space: Space)
//   func run(program: SpaceProgram, in space: Space) -> RunningProgram?               (@discardableResult)
//   func runTool(_ tool: WineTool, in space: Space)
//   func chooseAndRun(in space: Space?)        NSOpenPanel; nil space → asks which space
//   func openFiles(_ urls: [URL], preferredSpaceID: UUID? = nil)   asks which space (pendingOpen)
//   func runPending(in space: Space)          runs pendingOpen files and closes the chooser
//   func quitAll(in space: Space) async       soft: wineboot --end-session (programs may save), after 10 s wineserver -k
//   Session control (AppModel+Session.swift): isSpaceRunning(_:), forceQuitAll(in:) = wineserver -k,
//   restartSpace(_:applying:) for MSync / Retina changes while the space runs (RestartSensitiveChange)
//   func install(recipe: AppRecipe, into space: Space? = nil) async -> Space?
//   Main program / installed recipes (Views/MainProgramViews.swift): mainProgram(in:), launchablePrograms(in:),
//   spacesWithInstalled(_:), launchInstalled(_:in:), Space.hasInstalled(_:), ProgramLaunchHistory, InstallFollowUp
//   «Мои приложения» (user recipes, custom installs with detection, .onwinrecipe): AppModel+UserRecipes.swift
//   (UserRecipeStore.shared, newUserRecipe(), editUserRecipe(_:), installCustom(file:in:), openUserRecipeFile(_:)...)
//   func install(component: Component, into space: Space) async -> Bool   (D3DMetal → fetchD3DMetal())
//   Components catalog, dependency suggestions and the guided D3DMetal import: AppModel+Components.swift
//   (suggestions(for:), analyzeDependencies(of:), adviseAfterFailure(_:), installComponents(_:into:), fetchD3DMetal()...)
//   Automatic components before the first run / after a failed one: AppModel+AutoComponents.swift
//   (launchPreparing(_:in:title:start:), repairAfterFailure(_:start:retriedAfter:), isPreparingLaunch(in:), autoComponentsNotice)
//   «Рабочий стол» (all programs of all spaces, the main screen): AppModel+Desktop.swift
//   (DesktopModel.shared, refreshDesktop(), launch(_ item:), desktopHandleDrop(_:), desktopInstallRecipe(_:)...)
//   Launchpad launchers, onwin:// URLs, opened .onwinspace files: AppModel+Launchers.swift
//   (handleOpened(_:), createLauncher(for:in:), removeLauncher(for:in:), launcher(for:in:), setAutoLaunchers(_:for:)...)
//   func installD3DMetal() async -> Bool   «Установить D3DMetal»: local .dmg, or Apple ID sign-in inside onwin
//        (WKWebView window), download of the newest GPTK, import — D3DMetalInstallFlow.swift; forgetAppleSignIn()
//   func importD3DMetal(from url: URL) async -> Bool (folder, volume or .dmg); func importD3DMetalInteractively(); func removeD3DMetal()
//   func installEngine(from url: URL) async -> Engine?; func installEngineInteractively()
//   func setDefaultEngine(_ id: String?); func updateSettings(_ change: (inout OnwinSettings) -> Void)
//   func revealInFinder(_ url: URL); func open(_ url: URL)
//   func performTask<T: Sendable>(_ title: String, autoClose: Bool = true,
//                                 _ work: @escaping (TaskContext) async throws -> T) async -> T?
//        generic long-operation runner: shows TaskProgressSheet, collects progress/log, reports errors.
//        Close your own sheets before calling it (the shell closes its own ones automatically).
//   func dismissTask()     closes a finished task sheet;   func cancelTask()   cancels the running task
//
// Reusable UI bits (Theme.swift): OnwinTheme.accent (teal), .onwinCard(), OnwinSpaceIcon(symbol:size:),
// OnwinRunningDot(), Space.onwinSymbol. Panels: OnwinPanels (FilePanels.swift).

typealias OnwinSettings = OnwinCore.Settings

/// What the sidebar shows / what the detail column displays.
enum SidebarItem: Hashable {
    case desktop   // «Рабочий стол», the main screen (AppModel+Desktop.swift)
    case catalog
    case space(UUID)
    case running
    case logs
}

/// A long operation (space creation, installation...) shown in `TaskProgressSheet`.
struct TaskState: Identifiable, Equatable {
    let id: UUID
    var title: String
    var message: String
    /// 0...1, nil = indeterminate.
    var fraction: Double?
    /// Everything the operation printed (wine output, installer progress).
    var log: String
    var isFinished: Bool
    /// Error text when the operation failed (then `isFinished` is true as well).
    var error: String?
    var started: Date

    init(title: String, message: String = "Подготовка…") {
        self.id = UUID()
        self.title = title
        self.message = message
        self.fraction = nil
        self.log = ""
        self.isFinished = false
        self.error = nil
        self.started = Date()
    }
}

/// Handed to `performTask` work closures; both callbacks are safe to call from any thread.
struct TaskContext: Sendable {
    /// Same type the core installers take.
    let progress: ProgressHandler
    /// Raw text output (wine logs); shown in the log area of the progress sheet.
    let log: @Sendable (String) -> Void

    func status(_ message: String, fraction: Double? = nil) {
        progress(InstallProgress.status(message, fraction: fraction))
    }
}

/// Files waiting for the user to pick a space.
struct PendingOpen: Identifiable {
    let id = UUID()
    var files: [URL]
    var suggestedSpaceID: UUID?
}

/// Built-in Wine tools offered for every space.
enum WineTool: String, CaseIterable, Identifiable {
    case winecfg, regedit, taskmgr, cmd, control, gameControllers, internetSettings, explorer, uninstaller, reboot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .winecfg: return "Настройка Wine"
        case .regedit: return "Редактор реестра"
        case .taskmgr: return "Диспетчер задач"
        case .cmd: return "Командная строка"
        case .control: return "Панель управления"
        case .gameControllers: return "Игровые контроллеры"
        case .internetSettings: return "Свойства интернета"
        case .explorer: return "Проводник"
        case .uninstaller: return "Установка и удаление программ"
        case .reboot: return "Перезагрузить Windows"
        }
    }

    var symbol: String {
        switch self {
        case .winecfg: return "slider.horizontal.3"
        case .regedit: return "list.bullet.indent"
        case .taskmgr: return "chart.bar.xaxis"
        case .cmd: return "terminal"
        case .control: return "switch.2"
        case .gameControllers: return "gamecontroller"
        case .internetSettings: return "globe"
        case .explorer: return "folder"
        case .uninstaller: return "trash"
        case .reboot: return "arrow.clockwise.circle"
        }
    }

    var wineArguments: [String] {
        switch self {
        case .winecfg: return ["winecfg"]
        case .regedit: return ["regedit"]
        case .taskmgr: return ["taskmgr"]
        case .cmd: return ["wineconsole", "cmd"]
        case .control: return ["control"]
        case .gameControllers: return ["control", "joy.cpl"]
        case .internetSettings: return ["control", "inetcpl.cpl"]
        case .explorer: return ["explorer"]
        case .uninstaller: return ["uninstaller"]
        // Simulated reboot: RunOnce entries and pending file renames, like Windows after
        // an installer asked for a restart (exit code 3010). Opens no window.
        case .reboot: return ["wineboot", "--restart"]
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: State

    var spaces: [Space] = []
    var engines: [Engine] = []
    var selection: SidebarItem?
    var activeTask: TaskState?
    var lastError: String?
    var lastErrorLog: URL?
    var settings: OnwinSettings = OnwinSettings.load()
    var isD3DMetalInstalled = false
    var backgroundActivity: String?

    var showNewSpaceSheet = false
    var settingsSpaceID: UUID?
    var renamingSpaceID: UUID?
    var deletingSpaceID: UUID?
    var pendingOpen: PendingOpen?

    private(set) var programsBySpace: [UUID: [SpaceProgram]] = [:]

    @ObservationIgnored private var cancelCurrent: (() -> Void)?
    @ObservationIgnored private var setupChain: Task<Void, Never>?
    @ObservationIgnored private var pendingSetups = 0

    static let cancelledMessage = "Операция отменена."

    static let noEngineMessage = "Движок Wine не установлен. Соберите его скриптом engine/build.sh из папки проекта onwin " +
        "или установите готовый движок в \(OnwinPaths.engines.path)."

    init() {
        try? OnwinPaths.ensureLayout()
        reload()
        if selection == nil, hasEngine {
            selection = .desktop   // «Рабочий стол» is the main screen; without an engine: the first-run page
        }
        ProcessTracker.shared.onFinish = { [weak self] program in
            self?.programFinished(program)
        }
    }

    // MARK: Bindable helpers (for alerts / sheets)

    var isShowingError: Bool {
        get { lastError != nil }
        set { if !newValue { clearError() } }
    }

    var isShowingTask: Bool {
        get { activeTask != nil }
        set { if !newValue { dismissTask() } }
    }

    var isShowingSpaceSettings: Bool {
        get { settingsSpaceID != nil }
        set { if !newValue { settingsSpaceID = nil } }
    }

    var isRenaming: Bool {
        get { renamingSpaceID != nil }
        set { if !newValue { renamingSpaceID = nil } }
    }

    var isConfirmingDelete: Bool {
        get { deletingSpaceID != nil }
        set { if !newValue { deletingSpaceID = nil } }
    }

    // MARK: Derived

    var hasEngine: Bool { !engines.isEmpty }

    var defaultEngine: Engine? {
        if let id = settings.defaultEngineID, let match = engines.first(where: { $0.id == id }) { return match }
        return engines.first
    }

    var selectedSpace: Space? {
        if case .space(let id)? = selection { return space(id: id) }
        return nil
    }

    var renamingSpace: Space? { renamingSpaceID.flatMap { space(id: $0) } }
    var deletingSpace: Space? { deletingSpaceID.flatMap { space(id: $0) } }

    func space(id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    func engine(for space: Space) -> Engine? {
        if let wanted = space.config.engineID, let match = engines.first(where: { $0.id == wanted }) { return match }
        return defaultEngine
    }

    func resolvedBackend(for space: Space) -> GraphicsBackend? {
        guard let engine = engine(for: space) else { return nil }
        return GraphicsSupport.resolve(space.config.graphicsBackend, engine: engine)
    }

    func programs(in space: Space) -> [SpaceProgram] {
        programsBySpace[space.id] ?? []
    }

    func isRunning(_ spaceID: UUID) -> Bool {
        !ProcessTracker.shared.running(in: spaceID).isEmpty
    }

    func runningPrograms(in spaceID: UUID) -> [RunningProgram] {
        ProcessTracker.shared.running(in: spaceID)
    }

    // MARK: Loading

    func reload() {
        engines = EngineManager.installedEngines()
        settings = OnwinSettings.load()
        isD3DMetalInstalled = GraphicsSupport.isD3DMetalInstalled

        var seen = Set<UUID>()
        var list: [Space] = []
        for space in SpaceManager.list() where !seen.contains(space.id) {
            seen.insert(space.id)
            list.append(space)
        }
        spaces = list

        var programs: [UUID: [SpaceProgram]] = [:]
        for space in list {
            programs[space.id] = ProgramScanner.programs(in: space)
        }
        programsBySpace = programs
        for space in list { analyzeDependencies(of: space.id) }

        if case .space(let id)? = selection, space(id: id) == nil {
            selection = hasEngine ? .desktop : nil   // «Рабочий стол» is the main screen (AppModel+Desktop.swift)
        }
        if let id = settingsSpaceID, space(id: id) == nil { settingsSpaceID = nil }
        UserRecipeStore.shared.reload()   // «Мои приложения» (also picks up `onwinctl recipe` changes)
    }

    func refreshPrograms(of spaceID: UUID) {
        guard let space = space(id: spaceID) else { return }
        programsBySpace[spaceID] = ProgramScanner.programs(in: space)
        analyzeDependencies(of: spaceID)
        syncLaunchers(of: spaceID)   // AppModel+Launchers.swift: automatic Launchpad launchers
    }

    // MARK: Errors

    func report(_ error: Error, log: URL? = nil) {
        if error is CancellationError { return }
        lastError = error.localizedDescription
        lastErrorLog = log
    }

    func report(_ message: String, log: URL? = nil) {
        lastError = message
        lastErrorLog = log
    }

    func clearError() {
        lastError = nil
        lastErrorLog = nil
    }

    // MARK: Long operations

    @discardableResult
    func performTask<T: Sendable>(_ title: String, autoClose: Bool = true,
                                  _ work: @escaping (TaskContext) async throws -> T) async -> T? {
        if let current = activeTask, !current.isFinished {
            report("Дождитесь окончания операции «\(current.title)».")
            return nil
        }
        await closeShellSheets()

        let state = TaskState(title: title)
        activeTask = state
        let id = state.id
        let context = TaskContext(
            progress: { [self] progress in
                Task { @MainActor in self.taskProgress(progress, id: id) }
            },
            log: { [self] text in
                Task { @MainActor in self.taskLog(text, id: id) }
            })

        let task = Task<T, Error> { @MainActor in
            try await work(context)
        }
        cancelCurrent = { task.cancel() }
        do {
            let value = try await task.value
            cancelCurrent = nil
            finishTask(id: id, error: nil, autoClose: autoClose)
            return value
        } catch {
            cancelCurrent = nil
            let message = error is CancellationError ? AppModel.cancelledMessage : error.localizedDescription
            finishTask(id: id, error: message, autoClose: false)
            return nil
        }
    }

    func dismissTask() {
        guard let task = activeTask else { return }
        if task.isFinished { activeTask = nil }
    }

    func cancelTask() {
        cancelCurrent?()
    }

    private func finishTask(id: UUID, error: String?, autoClose: Bool) {
        guard var task = activeTask, task.id == id else { return }
        task.isFinished = true
        task.error = error
        if error == nil {
            task.fraction = 1
            task.message = "Готово"
        }
        activeTask = task
        if error == nil && autoClose {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if self.activeTask?.id == id { self.activeTask = nil }
            }
        }
    }

    private func taskProgress(_ progress: InstallProgress, id: UUID) {
        guard var task = activeTask, task.id == id else { return }
        let text = progress.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            task.message = text
            task.log += text + "\n"
        }
        task.fraction = progress.fraction
        task.log = AppModel.trimmedLog(task.log)
        activeTask = task
    }

    private func taskLog(_ text: String, id: UUID) {
        guard var task = activeTask, task.id == id else { return }
        task.log += text
        // Show our own human-readable lines as the status, not raw wine debug output ("0024:err:...").
        if let last = text.split(whereSeparator: \.isNewline).last {
            let line = last.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !AppModel.looksLikeWineDebug(line) {
                task.message = line
            }
        }
        task.log = AppModel.trimmedLog(task.log)
        activeTask = task
    }

    private static func trimmedLog(_ log: String) -> String {
        log.utf8.count > 400_000 ? String(log.suffix(250_000)) : log
    }

    private static func looksLikeWineDebug(_ line: String) -> Bool {
        let chars = Array(line.prefix(5))
        guard chars.count == 5, chars[4] == ":" else { return false }
        return chars[0..<4].allSatisfy { $0.isHexDigit }
    }

    /// Closes the sheets owned by the shell so that the task sheet can be presented.
    private func closeShellSheets() async {
        guard showNewSpaceSheet || settingsSpaceID != nil || pendingOpen != nil || autoComponentsNotice != nil else { return }
        showNewSpaceSheet = false
        settingsSpaceID = nil
        pendingOpen = nil
        autoComponentsNotice = nil
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: Spaces

    @discardableResult
    func createSpace(name: String, windowsVersion: WindowsVersion, backend: GraphicsBackend) async -> Space? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report("Укажите имя пространства.")
            return nil
        }
        guard let engine = defaultEngine else {
            report(AppModel.noEngineMessage)
            return nil
        }
        if SpaceManager.find(trimmed) != nil {
            report("Пространство «\(trimmed)» уже существует.")
            return nil
        }
        let created = await performTask("Создание пространства «\(trimmed)»") { (context: TaskContext) async throws -> Space in
            context.status("Создаю пространство «\(trimmed)» (\(windowsVersion.displayName))…")
            return try await SpaceManager.create(name: trimmed, windowsVersion: windowsVersion,
                                                  backend: backend, engine: engine, log: context.log)
        }
        reload()
        if let created { selection = .space(created.id) }
        return created
    }

    func deleteSpace(_ space: Space) async {
        do {
            try await SpaceManager.delete(space)
            removeLaunchers(of: space.id)   // AppModel+Launchers.swift
        } catch {
            report(error)
        }
        if selection == .space(space.id) { selection = nil }
        if settingsSpaceID == space.id { settingsSpaceID = nil }
        reload()
        if selection == nil { selection = .desktop }
    }

    func rename(_ space: Space, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != space.name else { return }
        guard !isRunning(space.id) else {
            report("Закройте программы пространства «\(space.name)», прежде чем переименовывать его.")
            return
        }
        let current = self.space(id: space.id) ?? space
        do {
            let renamed = try SpaceManager.rename(current, to: trimmed)
            reload()
            selection = .space(renamed.id)
        } catch {
            report(error)
        }
    }

    @discardableResult
    func duplicate(_ space: Space) async -> Space? {
        let source = self.space(id: space.id) ?? space
        let newName = SpaceManager.availableName("\(source.name) копия")
        let copy = await performTask("Копирование «\(source.name)»") { (context: TaskContext) async throws -> Space in
            context.status("Копирую файлы пространства в «\(newName)»…")
            return try await Task.detached {
                try SpaceManager.duplicate(source, as: newName)
            }.value
        }
        reload()
        if let copy { selection = .space(copy.id) }
        return copy
    }

    func archive(_ space: Space, to url: URL) async {
        let source = self.space(id: space.id) ?? space
        await performTask("Архивирование «\(source.name)»") { (context: TaskContext) async throws -> Void in
            context.status("Упаковываю пространство в \(url.lastPathComponent)…")
            try await SpaceManager.archive(source, to: url)
        }
    }

    func archiveInteractively(_ space: Space) {
        if isRunning(space.id) {
            report("Закройте программы пространства «\(space.name)», прежде чем архивировать его.")
            return
        }
        guard let url = OnwinPanels.saveArchive(suggestedName: space.name) else { return }
        Task { await archive(space, to: url) }
    }

    @discardableResult
    func restore(from url: URL) async -> Space? {
        let restored = await performTask("Восстановление из архива") { (context: TaskContext) async throws -> Space in
            context.status("Распаковываю \(url.lastPathComponent)…")
            return try await SpaceManager.restore(from: url)
        }
        reload()
        if let restored { selection = .space(restored.id) }
        return restored
    }

    func restoreInteractively() {
        guard let url = OnwinPanels.chooseArchive() else { return }
        Task { await restore(from: url) }
    }

    /// Changes a space's settings and saves them. Windows version and Retina mode live in the
    /// registry too, so they are applied with SpaceSetup in the background.
    func updateConfig(of spaceID: UUID, _ change: (inout SpaceConfig) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var space = spaces[index]
        let old = space.config
        change(&space.config)
        space.config.id = old.id
        let requestedName = space.config.name
        space.config.name = old.name

        if space.config != old {
            do {
                try space.save()
            } catch {
                report(error)
                return
            }
            spaces[index] = space
            if space.config.programs != old.programs { refreshPrograms(of: spaceID) }
            let windowsChanged = space.config.windowsVersion != old.windowsVersion
            let registryChanged = space.config.highResolution != old.highResolution
            if (windowsChanged || registryChanged) && space.isInitialized && hasEngine {
                applySetup(spaceID: spaceID, windowsVersion: windowsChanged, registry: registryChanged)
            }
        }
        if requestedName != old.name, let current = self.space(id: spaceID) {
            rename(current, to: requestedName)
        }
    }

    private func applySetup(spaceID: UUID, windowsVersion: Bool, registry: Bool) {
        let previous = setupChain
        pendingSetups += 1
        backgroundActivity = "Применяю настройки пространства…"
        setupChain = Task { @MainActor in
            await previous?.value
            if let space = self.space(id: spaceID) {
                self.backgroundActivity = "Применяю настройки «\(space.name)»…"
                do {
                    if windowsVersion { try await SpaceSetup.applyWindowsVersion(space) }
                    if registry { try await SpaceSetup.applyRegistrySettings(space) }
                } catch {
                    self.report(error)
                }
            }
            self.pendingSetups -= 1
            if self.pendingSetups <= 0 {
                self.pendingSetups = 0
                self.backgroundActivity = nil
            }
        }
    }

    /// Adds a program (Unix path to an .exe inside or outside the space) to the space's launcher list.
    func pinProgram(_ file: URL, name: String? = nil, in spaceID: UUID) {
        guard let space = space(id: spaceID) else { return }
        let windowsPath = space.windowsPath(forUnixPath: file)
        guard !space.config.programs.contains(where: { $0.windowsPath.caseInsensitiveCompare(windowsPath) == .orderedSame }) else { return }
        let title = name ?? file.deletingPathExtension().lastPathComponent
        updateConfig(of: spaceID) { config in
            config.programs.append(ProgramEntry(name: title, windowsPath: windowsPath))
        }
    }

    func unpinProgram(_ entryID: UUID, in spaceID: UUID) {
        updateConfig(of: spaceID) { config in
            config.programs.removeAll { $0.id == entryID }
        }
    }

    // MARK: Running programs

    /// nil also when the start waits for components (`isPreparingLaunch(in:)`, AppModel+AutoComponents.swift).
    @discardableResult
    func run(file: URL, in space: Space, arguments: [String] = []) -> RunningProgram? {
        let current = self.space(id: space.id) ?? space
        guard current.isInitialized else {
            report("Пространство «\(current.name)» ещё не готово (нет system.reg). Создайте его заново.")
            return nil
        }
        return launchPreparing(file, in: current, title: file.deletingPathExtension().lastPathComponent) { [weak self] b in
            do {
                return try WineRunner(space: b).launch(file, arguments: arguments)
            } catch {
                self?.report(error)
                return nil
            }
        }
    }

    func run(files: [URL], in space: Space) {
        let runnable = files.filter(WineFileTypes.isRunnable)
        guard !runnable.isEmpty else {
            report("onwin запускает файлы .exe, .msi, .lnk, .bat и .cmd.")
            return
        }
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return
        }
        for file in runnable { run(file: file, in: space) }
    }

    /// nil also when the start waits for components (`isPreparingLaunch(in:)`, AppModel+AutoComponents.swift).
    @discardableResult
    func run(program: SpaceProgram, in space: Space) -> RunningProgram? {
        let current = self.space(id: space.id) ?? space
        ProgramLaunchHistory.shared.record(program, in: current.id)   // the space's main program (MainProgramViews.swift)
        return launchPreparing(program.executable ?? program.launchFile, in: current, title: program.name) { [weak self] b in
            do {
                // A pinned program may replace graphics / HUD / AVX / WINEDEBUG (saved by "Запустить с параметрами…").
                let runner = try WineRunner(space: b.applying(b.overrides(for: program)))
                return try runner.launch(program.launchFile, arguments: program.arguments, title: program.name,
                                         extraEnvironment: program.environment)
            } catch {
                self?.report(error)
                return nil
            }
        }
    }

    func runTool(_ tool: WineTool, in space: Space) {
        let current = self.space(id: space.id) ?? space
        do {
            let runner = try WineRunner(space: current)
            _ = try runner.launch(wineArguments: tool.wineArguments, title: tool.title)
        } catch {
            report(error)
        }
    }

    /// Shows an open panel and runs the chosen file; without a space, asks which one to use.
    func chooseAndRun(in space: Space?) {
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return
        }
        let files = OnwinPanels.chooseRunnableFiles()
        guard !files.isEmpty else { return }
        if let space {
            run(files: files, in: space)
        } else {
            openFiles(files)
        }
    }

    /// Files opened from Finder / dropped outside a space: ask which space to run them in.
    func openFiles(_ urls: [URL], preferredSpaceID: UUID? = nil) {
        let runnable = urls.filter(WineFileTypes.isRunnable)
        guard !runnable.isEmpty else {
            report("onwin запускает файлы .exe, .msi, .lnk, .bat и .cmd.")
            return
        }
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return
        }
        guard !spaces.isEmpty else {
            report("Сначала создайте пространство — в нём будет запускаться программа.")
            showNewSpaceSheet = true
            return
        }
        if let pending = pendingOpen, pending.files == runnable { return }
        let suggested = preferredSpaceID ?? selectedSpace?.id ?? spaces.first?.id
        pendingOpen = PendingOpen(files: runnable, suggestedSpaceID: suggested)
    }

    func runPending(in space: Space) {
        guard let pending = pendingOpen else { return }
        pendingOpen = nil
        run(files: pending.files, in: space)
        selection = .space(space.id)
    }

    func quitAll(in space: Space) async {
        await softShutdown(space)   // AppModel+Session.swift; forceQuitAll(in:) kills at once
    }

    private func programFinished(_ program: RunningProgram) {
        refreshPrograms(of: program.spaceID)
        let relaunch = takeRelaunchInfo(of: program)   // AppModel+AutoComponents.swift
        // A non-zero exit right after start usually means the program could not start at all.
        guard let status = program.exitStatus, status != 0,
              !([1602, 3010, 1638] as [Int32]).contains(where: { WineRunner.exitStatus(status, matches: $0) }) else { return }
        let quickExit = Date().timeIntervalSince(program.started) < 10
        Task { @MainActor in
            // Automatic components: install what the log says is missing and start once more.
            if await self.repairAfterFailure(program, start: relaunch.start, retriedAfter: relaunch.retriedAfter) { return }
            // What the run's log says is missing (shown as a banner on the space page).
            let advice = await self.adviseAfterFailure(program)
            guard quickExit else { return }
            let names = advice.compactMap { $0.component?.name }
            let hint = names.isEmpty ? "Подробности — в журнале."
                : "Похоже, не хватает: \(names.prefix(3).joined(separator: ", ")) — установить можно на странице пространства."
            self.report("«\(program.title)» завершилась с кодом \(status) сразу после запуска. \(hint)", log: program.logURL)
        }
    }

    // MARK: Catalog

    @discardableResult
    func install(recipe: AppRecipe, into space: Space? = nil) async -> Space? {
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return nil
        }
        let target = space.flatMap { self.space(id: $0.id) } ?? space
        let result = await performTask("Установка \(recipe.name)", autoClose: false) { (context: TaskContext) async throws -> Space in
            // User recipes: with detection of the installed program (AppModel+UserRecipes.swift).
            try await self.installDetecting(recipe: recipe, into: target, context: context)
        }
        reload()
        if let result {
            selection = .space(result.id)
            // TaskProgressSheet then offers «Запустить <Program>» / «Открыть пространство» (MainProgramViews.swift).
            InstallFollowUp.shared.present(after: activeTask, recipe: recipe, space: result)
        }
        return result
    }

    @discardableResult
    func install(component: Component, into space: Space) async -> Bool {
        if component.kind == .global { return await fetchD3DMetal() }
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return false
        }
        let target = self.space(id: space.id) ?? space
        let result = await performTask("Установка \(component.name)", autoClose: false) { (context: TaskContext) async throws -> Space in
            try await Installer.install(component: component, into: target, progress: context.progress)
        }
        reload()
        return result != nil
    }

    // MARK: Graphics & engines

    @discardableResult
    func importD3DMetal(from url: URL) async -> Bool {
        let ok = await performTask("Импорт D3DMetal") { (context: TaskContext) async throws -> Bool in
            if url.pathExtension.lowercased() == "dmg" {
                try await D3DMetalImporter.importFound(.diskImage(url), progress: context.progress)
                return true
            }
            // A folder or volume; the outer GPTK volume only holds the inner
            // "Evaluation environment…" image, which importFound mounts and detaches.
            try await D3DMetalImporter.importFound(.mountedVolume(url), progress: context.progress)
            return true
        }
        isD3DMetalInstalled = GraphicsSupport.isD3DMetalInstalled
        return ok ?? false
    }

    func importD3DMetalInteractively() {
        guard let url = OnwinPanels.chooseD3DMetalSource() else { return }
        Task { await importD3DMetal(from: url) }
    }

    func removeD3DMetal() {
        do {
            try GraphicsSupport.removeD3DMetal()
        } catch {
            report(error)
        }
        isD3DMetalInstalled = GraphicsSupport.isD3DMetalInstalled
    }

    @discardableResult
    func installEngine(from url: URL) async -> Engine? {
        let engine = await performTask("Установка движка") { (context: TaskContext) async throws -> Engine in
            context.status("Копирую движок из \(url.lastPathComponent)…")
            return try await Task.detached {
                try EngineManager.install(from: url)
            }.value
        }
        reload()
        return engine
    }

    func installEngineInteractively() {
        guard let url = OnwinPanels.chooseFolder(title: "Установка движка",
                                                 message: "Выберите папку собранного движка (в ней должен быть bin/wine)",
                                                 prompt: "Установить") else { return }
        Task { await installEngine(from: url) }
    }

    func setDefaultEngine(_ id: String?) {
        updateSettings { $0.defaultEngineID = id }
    }

    func updateSettings(_ change: (inout OnwinSettings) -> Void) {
        var updated = OnwinSettings.load()
        change(&updated)
        do {
            try updated.save()
            settings = updated
        } catch {
            report(error)
        }
    }

    // MARK: Finder

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
