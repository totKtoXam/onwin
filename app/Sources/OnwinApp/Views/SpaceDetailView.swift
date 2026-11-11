import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OnwinCore

// Detail page of one space:
//   header      name, Windows version, graphics backend (configured → resolved), engine, running state + "Завершить всё"
//   actions     big «▶ Запустить <main program>» with its own icon (+ dropdown of the other pinned programs;
//               SpaceMainProgramButton, MainProgramViews.swift), "Открыть диск C:", journals, settings,
//               "Ещё" menu (its first item «Открыть .exe с диска…» runs any file through a file panel)
//   advice      "Игре может понадобиться: …" (ComponentSuggestionsBanner.swift) — components the programs need
//   running     programs of this space that run right now (RunningProgramRow from RunningProgramsView.swift)
//   programs    grid of program cards (pinned first, then Start Menu / desktop shortcuts); double click or ▶ runs;
//               context menu: Запустить / Закрепить·Открепить / Показать в Finder / Свойства…
//               the "Добавить" tile pins chosen or dropped files (dropping anywhere else in the window runs them —
//               that drop is handled by the shell's ShellDetail)
//   tools       "Инструменты Windows": WineTool buttons

// MARK: - Program icons (hook)

/// Icon of a program, nil → an SF Symbol tile is drawn instead.
///
/// TODO(IconExtractor): when `app/Sources/OnwinCore/IconExtractor.swift` exists, replace the body with
///
///     return IconExtractor.icon(for: program.executable ?? program.launchFile)
///
/// (`IconExtractor.icon(for: URL) -> NSImage?`). Icons are loaded once per program list change and cached
/// in SpaceDetailView's state, so this may do file I/O.
@MainActor
private func programIcon(for program: SpaceProgram) -> NSImage? {
    // The program's own icon from its .exe resources (the original application logo).
    if let exe = program.executable, let image = IconExtractor.icon(for: exe) { return image }
    if ["exe", "dll"].contains(program.launchFile.pathExtension.lowercased()) {
        return IconExtractor.icon(for: program.launchFile)
    }
    return nil
}

// MARK: - Space detail

@MainActor
struct SpaceDetailView: View {
    let spaceID: UUID

    @Environment(AppModel.self) private var model
    @State private var selectedProgramID: String?
    @State private var propertiesProgram: SpaceProgram?
    @State private var logProgram: RunningProgram?
    @State private var showsLogs = false
    @State private var confirmQuitAll = false
    @State private var icons: [String: NSImage] = [:]

    var body: some View {
        if let space = model.space(id: spaceID) {
            content(space)
        } else {
            ContentUnavailableView("Пространство не найдено", systemImage: "questionmark.folder",
                                   description: Text("Возможно, его удалили или переименовали в Finder."))
        }
    }

    // MARK: Layout

    private func content(_ space: Space) -> some View {
        let programs = model.programs(in: space)
        let programIDs = programs.map { $0.id }
        let running = model.runningPrograms(in: space.id)
        let suggestions = model.suggestions(for: space)

        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(space, running: running)
                actionBar(space, running: running)
                if !space.isInitialized {
                    notInitializedWarning(space)
                }
                if !suggestions.isEmpty {
                    ComponentSuggestionsBanner(space: space, suggestions: suggestions)
                }
                if !running.isEmpty {
                    runningSection(running)
                }
                programsSection(space, programs: programs, running: running)
                SteamGamesSection(space: space)   // SteamGamesSection.swift; empty without Steam
                toolsSection(space)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshPrograms(of: spaceID)
        }
        .onChange(of: programIDs, initial: true) { _, _ in
            loadIcons(for: model.programs(in: space))
        }
        .task(id: programIDs) {
            await loadArtwork(for: model.programs(in: space), in: space)
        }
        .confirmationDialog("Завершить все программы пространства?", isPresented: $confirmQuitAll,
                            titleVisibility: .visible) {
            Button("Завершить всё", role: .destructive) {
                quitAll(space)
            }
            Button("Принудительно") {
                Task { @MainActor in await model.forceQuitAll(in: space) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("«Завершить всё»: программы пространства «\(space.name)» получат команду закрыться и смогут сохранить данные; то, что не закроется за 10 секунд, будет завершено принудительно. Если программа спросит, сохранить ли изменения, ответьте в её окне.\n«Принудительно»: остановить все процессы сразу (wineserver -k), несохранённое пропадёт.")
        }
        .sheet(item: $propertiesProgram) { program in
            SpaceProgramPropertiesSheet(spaceID: spaceID, program: program)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .sheet(item: $logProgram) { program in
            RunningLogSheet(program: program)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .sheet(isPresented: $showsLogs) {
            SpaceDetailLogsSheet(spaceID: spaceID)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .programDialogs(spaceID: spaceID)   // run with options, run command, uninstall (RunOptionsSheet.swift)
    }

    // MARK: Header

    private func header(_ space: Space, running: [RunningProgram]) -> some View {
        HStack(alignment: .center, spacing: 18) {
            SpaceIconView(space: space, size: 72)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: space.name)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !space.config.description.isEmpty {
                    Text(verbatim: space.config.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    SpaceDetailBadge(text: space.config.windowsVersion.displayName,
                                      symbol: "macwindow", tint: OnwinTheme.accent)
                    backendBadge(space)
                    if let engine = model.engine(for: space) {
                        SpaceDetailBadge(text: "Wine \(engine.info.wineVersion)",
                                          symbol: "wineglass", tint: Color.secondary)
                            .help(engine.info.displayName)
                    }
                }
            }
            Spacer(minLength: 12)
            runningState(running)
        }
    }

    @ViewBuilder
    private func backendBadge(_ space: Space) -> some View {
        let configured = space.config.graphicsBackend
        if let resolved = model.resolvedBackend(for: space) {
            if configured == .auto {
                SpaceDetailBadge(text: String(localized: "Авто → \(resolved.displayName)"), symbol: "cpu", tint: Color.indigo)
                    .help("Графика выбирается автоматически: сейчас \(resolved.displayName) — \(resolved.summary)")
            } else if resolved != configured {
                SpaceDetailBadge(text: "\(configured.displayName) → \(resolved.displayName)",
                                  symbol: "exclamationmark.triangle.fill", tint: Color.orange)
                    .help("\(configured.displayName) недоступен, вместо него используется \(resolved.displayName)")
            } else {
                SpaceDetailBadge(text: resolved.displayName, symbol: "cpu", tint: Color.indigo)
                    .help(resolved.summary)
            }
        } else {
            SpaceDetailBadge(text: configured.displayName, symbol: "cpu", tint: Color.secondary)
                .help("Нет движка Wine — графика будет выбрана после его установки")
        }
    }

    @ViewBuilder
    private func runningState(_ running: [RunningProgram]) -> some View {
        if running.isEmpty {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text("Ничего не запущено")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    OnwinRunningDot(size: 8)
                    Text("Работает: \(running.count) программ")
                        .font(.callout.weight(.medium))
                }
                Button(role: .destructive) {
                    confirmQuitAll = true
                } label: {
                    Label("Завершить всё", systemImage: "stop.fill")
                }
                .help("Остановить все Windows-процессы этого пространства")
            }
        }
    }

    // MARK: Actions bar

    /// Main program button on the left, the space's own actions on the right; on a narrow window the
    /// main button gets its own row.
    private func actionBar(_ space: Space, running: [RunningProgram]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if model.mainProgram(in: space) != nil {
                    mainProgramButton(space, running: running)
                    Spacer(minLength: 12)
                    secondaryActions(space)
                } else {
                    secondaryActions(space)
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                mainProgramButton(space, running: running)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    secondaryActions(space)
                }
            }
        }
    }

    @ViewBuilder
    private func mainProgramButton(_ space: Space, running: [RunningProgram]) -> some View {
        if let main = model.mainProgram(in: space) {
            SpaceMainProgramButton(space: space, program: main,
                                    alternatives: model.launchablePrograms(in: space),
                                    isRunning: running.contains { $0.title == main.name },
                                    onRun: { program in run(program, in: space) })
        }
    }

    private func secondaryActions(_ space: Space) -> some View {
        HStack(spacing: 10) {
            Button {
                model.open(space.driveC)
            } label: {
                Label("Открыть диск C:", systemImage: "internaldrive")
            }
            .disabled(!OnwinPaths.isDirectory(space.driveC))
            .help("Открыть drive_c пространства в Finder")

            Button {
                showsLogs = true
            } label: {
                Label("Журналы", systemImage: "doc.text")
            }

            Button {
                model.settingsSpaceID = space.id
            } label: {
                Label("Настройки", systemImage: "slider.horizontal.3")
            }

            Menu {
                Button {
                    model.chooseAndRun(in: space)
                } label: {
                    Label("Открыть .exe с диска…", systemImage: "arrow.up.forward.app")
                }
                .disabled(!model.hasEngine || !space.isInitialized)
                .help("Выбрать .exe, .msi, .lnk или .bat на диске и запустить в этом пространстве")
                Divider()
                Button {
                    pinChosenFiles(space)
                } label: {
                    Label("Добавить программу в список…", systemImage: "pin")
                }
                Button {
                    model.refreshPrograms(of: space.id)
                } label: {
                    Label("Обновить список программ", systemImage: "arrow.clockwise")
                }
                Button {
                    ProgramDialogs.shared.request = .runCommand(space.id)
                } label: {
                    Label("Выполнить команду…", systemImage: "terminal")
                }
                .disabled(!model.hasEngine || !space.isInitialized)
                Button {
                    ProgramDialogs.shared.request = .uninstall(space.id)
                } label: {
                    Label("Удалить программу…", systemImage: "trash")
                }
                .disabled(!space.isInitialized)
                Divider()
                Button {
                    model.revealInFinder(space.url)
                } label: {
                    Label("Показать пространство в Finder", systemImage: "folder")
                }
                Button {
                    model.selection = .catalog
                } label: {
                    Label("Установить из каталога", systemImage: "square.grid.2x2")
                }
                Divider()
                Button {
                    Task { @MainActor in await model.duplicate(space) }
                } label: {
                    Label("Дублировать", systemImage: "plus.square.on.square")
                }
                Button {
                    model.archiveInteractively(space)
                } label: {
                    Label("Архивировать…", systemImage: "archivebox")
                }
                Button {
                    model.renamingSpaceID = space.id
                } label: {
                    Label("Переименовать…", systemImage: "pencil")
                }
                Divider()
                Button {
                    confirmQuitAll = true
                } label: {
                    Label("Завершить все процессы пространства", systemImage: "stop.fill")
                }
                .disabled(!model.hasEngine)
                Button(role: .destructive) {
                    model.deletingSpaceID = space.id
                } label: {
                    Label("Удалить…", systemImage: "trash")
                }
            } label: {
                Label("Ещё", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .controlSize(.large)
    }

    private func notInitializedWarning(_ space: Space) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Пространство не готово")
                    .font(.headline)
                Text("В папке пространства нет system.reg — похоже, его создание прервалось. Удалите его и создайте заново.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .onwinCard(padding: 14)
    }

    // MARK: Running

    private func runningSection(_ running: [RunningProgram]) -> some View {
        let lastID = running.last?.id
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Сейчас работает", detail: nil)
            VStack(spacing: 0) {
                ForEach(running) { program in
                    RunningProgramRow(program: program, showsSpace: false) {
                        logProgram = program
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if program.id != lastID {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
            .onwinCard(padding: 0, highlighted: true)
        }
    }

    // MARK: Programs

    private func programsSection(_ space: Space, programs: [SpaceProgram], running: [RunningProgram]) -> some View {
        let pinned = programs.filter { SpaceDetailView.pinnedEntryID(of: $0) != nil }
        let others = programs.filter { SpaceDetailView.pinnedEntryID(of: $0) == nil }
        let runningTitles = Set(running.map { $0.title })
        let columns = [GridItem(.adaptive(minimum: 136, maximum: 180), spacing: 14)]

        return VStack(alignment: .leading, spacing: 18) {
            if programs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Программы", detail: nil)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "square.dashed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("В пространстве пока нет программ")
                                .font(.headline)
                            Text("Установите приложение из каталога или запустите свой установщик (.exe или .msi) — кнопкой ниже или перетащив его в окно. Установленные программы появятся здесь из меню «Пуск».")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Открыть каталог") {
                                    model.selection = .catalog
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Открыть .exe с диска…") {
                                    model.chooseAndRun(in: space)
                                }
                                .disabled(!model.hasEngine || !space.isInitialized)
                            }
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                    .onwinCard(padding: 14)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        addTile(space)
                    }
                }
            } else {
                if !pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Закреплённые", detail: nil)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(pinned) { program in
                                programCard(program, in: space, isRunning: runningTitles.contains(program.name))
                            }
                            if others.isEmpty {
                                addTile(space)
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(pinned.isEmpty ? "Программы" : "Установленные программы",
                                      detail: "Двойной щелчок — запуск. Перетащите .exe в окно, чтобы запустить его здесь.")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(others) { program in
                                programCard(program, in: space, isRunning: runningTitles.contains(program.name))
                            }
                            addTile(space)
                        }
                    }
                }
            }
        }
    }

    private func programCard(_ program: SpaceProgram, in space: Space, isRunning: Bool) -> some View {
        let entryID = SpaceDetailView.pinnedEntryID(of: program)
        return SpaceProgramCard(program: program,
                                 icon: icons[program.id],
                                 isPinned: entryID != nil,
                                 isSelected: selectedProgramID == program.id,
                                 isRunning: isRunning,
                                 onSelect: { selectedProgramID = program.id },
                                 onRun: { run(program, in: space) })
            .contextMenu {
                Button {
                    run(program, in: space)
                } label: {
                    Label("Запустить", systemImage: "play.fill")
                }
                .disabled(!model.hasEngine)
                Button {
                    ProgramDialogs.shared.request = .runWithOptions(space.id, .program(program))
                } label: {
                    Label("Запустить с параметрами…", systemImage: "slider.horizontal.below.rectangle")
                }
                .disabled(!model.hasEngine)
                if let entryID {
                    Button {
                        model.unpinProgram(entryID, in: space.id)
                    } label: {
                        Label("Открепить", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        _ = model.spaceDetailPin(program, in: space.id)
                    } label: {
                        Label("Закрепить", systemImage: "pin")
                    }
                }
                Button {
                    model.revealInFinder(SpaceDetailView.revealTarget(of: program))
                } label: {
                    Label("Показать в Finder", systemImage: "folder")
                }
                LauncherMenuItems(program: program, space: space)   // LauncherViews.swift
                Divider()
                Button {
                    selectedProgramID = program.id
                    propertiesProgram = program
                } label: {
                    Label("Свойства…", systemImage: "info.circle")
                }
            }
    }

    private func addTile(_ space: Space) -> some View {
        SpaceAddProgramTile(onChoose: {
            pinChosenFiles(space)
        }, onDrop: { urls in
            pinFiles(urls, in: space)
        })
    }

    // MARK: Tools

    private func toolsSection(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Инструменты Windows",
                          detail: "Встроенные программы Wine для настройки этого пространства")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(WineTool.allCases) { tool in
                    SpaceToolButton(tool: tool) {
                        model.runTool(tool, in: space)
                    }
                    .disabled(!model.hasEngine || !space.isInitialized)
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Behaviour

    private func run(_ program: SpaceProgram, in space: Space) {
        selectedProgramID = program.id
        guard model.hasEngine else {
            model.report(AppModel.noEngineMessage)
            return
        }
        model.run(program: program, in: space)
    }

    private func quitAll(_ space: Space) {
        Task { @MainActor in
            await model.quitAll(in: space)
        }
    }

    private func pinChosenFiles(_ space: Space) {
        let files = SpaceDetailPanels.chooseFilesToPin(startingIn: space.driveC)
        guard !files.isEmpty else { return }
        _ = pinFiles(files, in: space)
    }

    @discardableResult
    private func pinFiles(_ urls: [URL], in space: Space) -> Bool {
        let files = urls.filter(WineFileTypes.isRunnable)
        guard !files.isEmpty else { return false }
        for file in files {
            model.pinProgram(file, in: space.id)
        }
        return true
    }

    private func loadIcons(for programs: [SpaceProgram]) {
        var loaded: [String: NSImage] = [:]
        for program in programs {
            if let image = programIcon(for: program) {
                loaded[program.id] = image
            }
        }
        icons = loaded
    }

    /// Second pass (AppIcons.swift, off the main thread): Steam games get Steam's own art (shortcut icon,
    /// library cover), programs without an exe icon get their Start Menu icon.
    private func loadArtwork(for programs: [SpaceProgram], in space: Space) async {
        for program in programs {
            let isSteamGame = program.executable?.path.lowercased().contains("/steamapps/common/") == true
            guard isSteamGame || icons[program.id] == nil else { continue }
            guard let url = await AppIcons.resolve(.program(program, space: space)), !Task.isCancelled,
                  let image = AppIcons.image(at: url) else { continue }
            icons[program.id] = image
        }
    }

    static func pinnedEntryID(of program: SpaceProgram) -> UUID? {
        if case .pinned(let id) = program.source { return id }
        return nil
    }

    static func revealTarget(of program: SpaceProgram) -> URL {
        if let exe = program.executable, OnwinPaths.exists(exe) { return exe }
        return program.launchFile
    }
}

// MARK: - Pinning helper

extension AppModel {
    /// Pins a program found in the Start Menu / on the desktop (pinned ones are returned as is) and
    /// returns its `ProgramEntry` id. The shortcut's target is pinned (so the Start Menu duplicate disappears),
    /// keeping the shortcut's arguments; when the target is unknown the .lnk itself is pinned.
    fileprivate func spaceDetailPin(_ program: SpaceProgram, in spaceID: UUID) -> UUID? {
        if let id = SpaceDetailView.pinnedEntryID(of: program) { return id }
        guard let space = space(id: spaceID) else { return nil }

        var target = program.launchFile
        var arguments: [String] = []
        if let exe = program.executable, OnwinPaths.exists(exe) {
            target = exe
            if program.launchFile.pathExtension.lowercased() == "lnk",
               let linkArguments = ShellLink.parse(program.launchFile)?.arguments {
                arguments = SpaceDetailArguments.split(linkArguments)
            }
        }
        pinProgram(target, name: program.name, in: spaceID)

        let windowsPath = space.windowsPath(forUnixPath: target)
        guard let entry = self.space(id: spaceID)?.config.programs.first(where: {
            $0.windowsPath.caseInsensitiveCompare(windowsPath) == .orderedSame
        }) else { return nil }
        if !arguments.isEmpty && entry.arguments.isEmpty {
            let entryID = entry.id
            updateConfig(of: spaceID) { config in
                if let index = config.programs.firstIndex(where: { $0.id == entryID }) {
                    config.programs[index].arguments = arguments
                }
            }
        }
        return entry.id
    }
}

// MARK: - Program card

@MainActor
private struct SpaceProgramCard: View {
    let program: SpaceProgram
    let icon: NSImage?
    let isPinned: Bool
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 9) {
            SpaceProgramIcon(program: program, image: icon, size: 64)
                .overlay(alignment: .topLeading) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(4)
                            .background(OnwinTheme.accent, in: Circle())
                            .offset(x: -6, y: -6)
                    }
                }
            Text(verbatim: program.name)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(height: 34, alignment: .top)
            HStack(spacing: 5) {
                if isRunning {
                    OnwinRunningDot(size: 6)
                    Text("Запущено")
                } else {
                    Text(verbatim: sourceText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                .fill(isSelected ? OnwinTheme.accent.opacity(0.14)
                                 : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? OnwinTheme.accent : Color.primary.opacity(0.06),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isHovering || isSelected {
                Button(action: onRun) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, OnwinTheme.accent)
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("Запустить")
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous))
        .onTapGesture(count: 2, perform: onRun)
        .onTapGesture(perform: onSelect)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Запустить")) { onRun() }
    }

    private var sourceText: String {
        switch program.source {
        case .pinned: return String(localized: "Закреплено", comment: "Program source: pinned by the user")
        case .startMenu: return String(localized: "Меню «Пуск»")
        case .desktop: return String(localized: "Рабочий стол")
        }
    }

    private var helpText: String {
        let file = program.executable ?? program.launchFile
        return String(localized: "\(program.name)\n\(file.lastPathComponent) — двойной щелчок запускает")
    }
}

/// The program's own icon when available, otherwise a coloured tile with an SF Symbol.
@MainActor
private struct SpaceProgramIcon: View {
    let program: SpaceProgram
    let image: NSImage?
    var size: CGFloat = 64

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            let tint = SpaceProgramLook.tint(for: program.name)
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: SpaceProgramLook.symbol(for: program))
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(Color.white)
                )
                .shadow(color: Color.black.opacity(0.14), radius: size * 0.06, y: size * 0.03)
        }
    }
}

private enum SpaceProgramLook {
    static let palette: [Color] = [.teal, .blue, .indigo, .purple, .pink, .orange, .green, .cyan, .mint]

    /// Stable colour per name (String.hashValue is randomised per launch, so a tiny hash of our own).
    static func tint(for name: String) -> Color {
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return palette[hash % palette.count]
    }

    static func symbol(for program: SpaceProgram) -> String {
        let name = program.name.lowercased()
        let ext = (program.executable ?? program.launchFile).pathExtension.lowercased()
        if ext == "bat" || ext == "cmd" { return "terminal.fill" }
        if ext == "msi" { return "shippingbox.fill" }
        let gameWords = ["steam", "game", "игр", "epic", "battle.net", "ubisoft", "ea app", "origin", "gog", "launcher"]
        if gameWords.contains(where: { name.contains($0) }) { return "gamecontroller.fill" }
        if name.contains("setup") || name.contains("install") || name.contains("установ") { return "arrow.down.app.fill" }
        if name.contains("config") || name.contains("settings") || name.contains("настро") { return "gearshape.fill" }
        if name.contains("help") || name.contains("manual") || name.contains("справк") { return "questionmark.circle.fill" }
        return "app.fill"
    }
}

// MARK: - Add tile (choose or drop files to pin)

@MainActor
private struct SpaceAddProgramTile: View {
    let onChoose: () -> Void
    let onDrop: ([URL]) -> Bool
    @State private var isTargeted = false
    @State private var isHovering = false

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(OnwinTheme.accent)
                    .frame(width: 64, height: 64)
                Text("Добавить")
                    .font(.callout.weight(.medium))
                    .frame(height: 34, alignment: .top)
                (isTargeted ? Text("Отпустите, чтобы закрепить") : Text("Выберите или перетащите .exe"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                    .fill(isTargeted ? OnwinTheme.accent.opacity(0.14)
                                     : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                    .strokeBorder(isTargeted ? OnwinTheme.accent : Color.primary.opacity(0.18),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .help("Закрепить программу в этом пространстве: выберите .exe или перетащите его сюда")
    }
}

// MARK: - Windows tool button

@MainActor
private struct SpaceToolButton: View {
    let tool: WineTool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnwinTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(OnwinTheme.accent.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(verbatim: tool.title)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering in isHovering = hovering }
        .help(tool == .cmd ? Text("Командная строка Windows (wineconsole cmd)") : Text("Запустить «\(tool.title)»"))
    }
}

// MARK: - Logs sheet

@MainActor
private struct SpaceDetailLogsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID

    var body: some View {
        VStack(spacing: 0) {
            LogsView(spaceID: spaceID)
                .frame(minWidth: 720, idealWidth: 820, minHeight: 440, idealHeight: 560)
            Divider()
            HStack {
                if let space = model.space(id: spaceID) {
                    Button {
                        try? FileManager.default.createDirectory(at: space.logDirectory,
                                                                 withIntermediateDirectories: true)
                        model.open(space.logDirectory)
                    } label: {
                        Label("Папка журналов", systemImage: "folder")
                    }
                }
                Spacer()
                Button("Готово") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
    }
}

// MARK: - Program properties

private struct SpaceProgramEnvRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

/// "Свойства": what the program is and, for pinned programs, its name, arguments and own environment.
@MainActor
private struct SpaceProgramPropertiesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID
    let program: SpaceProgram

    @State private var entryID: UUID?
    @State private var name = ""
    @State private var argumentsText = ""
    @State private var envRows: [SpaceProgramEnvRow] = []
    @State private var graphicsBackend: GraphicsBackend = .auto
    @State private var didLoad = false

    var body: some View {
        let space = model.space(id: spaceID)
        let entry = currentEntry(in: space)
        let link: ShellLink.Info? = program.launchFile.pathExtension.lowercased() == "lnk"
            ? ShellLink.parse(program.launchFile) : nil

        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SpaceProgramIcon(program: program, image: programIcon(for: program), size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry?.name ?? program.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    (entry != nil ? Text("Закреплённая программа") : Text("Программа из меню «Пуск»"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Form {
                if let entry, let space {
                    Section("Программа") {
                        TextField("Название", text: $name)
                        LabeledContent("Путь Windows") {
                            Text(verbatim: entry.windowsPath)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                        if let unix = space.unixPath(forWindowsPath: entry.windowsPath) {
                            LabeledContent("Файл на Mac") {
                                Text(verbatim: unix.path)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundStyle(OnwinPaths.exists(unix) ? Color.primary : Color.red)
                            }
                        }
                    }
                    ProgramGraphicsSection(selection: $graphicsBackend, space: space, windowsPath: entry.windowsPath)
                    Section {
                        TextField("Аргументы", text: $argumentsText, prompt: Text("например -windowed -dx11"))
                            .font(.body.monospaced())
                    } header: {
                        Text("Аргументы запуска")
                    } footer: {
                        Text("Через пробел; значения с пробелами возьмите в кавычки.")
                    }
                    Section {
                        ForEach($envRows) { $row in
                            HStack(spacing: 6) {
                                TextField("Переменная", text: $row.key, prompt: Text("ИМЯ"))
                                    .labelsHidden()
                                    .font(.body.monospaced())
                                Text(verbatim: "=")
                                    .foregroundStyle(.secondary)
                                TextField("Значение", text: $row.value, prompt: Text("значение"))
                                    .labelsHidden()
                                    .font(.body.monospaced())
                                Button {
                                    let rowID = row.id
                                    envRows.removeAll { $0.id == rowID }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Удалить переменную")
                            }
                        }
                        Button {
                            envRows.append(SpaceProgramEnvRow())
                        } label: {
                            Label("Добавить переменную", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text("Переменные окружения")
                    } footer: {
                        Text("Только для этой программы, поверх настроек пространства. Например DXVK_HUD=fps или MTL_HUD_ENABLED=1.")
                    }
                } else {
                    Section("Программа") {
                        LabeledContent("Название") {
                            Text(verbatim: program.name)
                        }
                        LabeledContent("Источник") {
                            Text(verbatim: sourceText)
                        }
                        LabeledContent("Ярлык") {
                            Text(verbatim: program.launchFile.lastPathComponent)
                                .textSelection(.enabled)
                        }
                        if let exe = program.executable, let space {
                            LabeledContent("Запускает") {
                                Text(verbatim: space.windowsPath(forUnixPath: exe))
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        } else if let target = link?.targetPath {
                            LabeledContent("Запускает") {
                                Text(verbatim: target)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if let arguments = link?.arguments, !arguments.isEmpty {
                            LabeledContent("Аргументы ярлыка") {
                                Text(verbatim: arguments)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if let directory = link?.workingDirectory, !directory.isEmpty {
                            LabeledContent("Рабочая папка") {
                                Text(verbatim: directory)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Section {
                        Text("Чтобы задать свои аргументы запуска и переменные окружения, закрепите программу — она появится в разделе «Закреплённые».")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            pinAndEdit()
                        } label: {
                            Label("Закрепить и настроить", systemImage: "pin")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.revealInFinder(SpaceDetailView.revealTarget(of: program))
                } label: {
                    Label("Показать в Finder", systemImage: "folder")
                }
                Spacer()
                if entry != nil {
                    Button("Отмена") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Сохранить") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Закрыть") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
        .frame(width: 600, height: 580)
        .onAppear {
            load()
        }
    }

    private var sourceText: String {
        switch program.source {
        case .pinned: return String(localized: "Закреплено", comment: "Program source: pinned by the user")
        case .startMenu: return String(localized: "Меню «Пуск»")
        case .desktop: return String(localized: "Рабочий стол")
        }
    }

    private func currentEntry(in space: Space?) -> ProgramEntry? {
        guard let id = entryID, let space else { return nil }
        return space.config.programs.first { $0.id == id }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        entryID = SpaceDetailView.pinnedEntryID(of: program)
        fill()
    }

    private func fill() {
        if let entry = currentEntry(in: model.space(id: spaceID)) {
            name = entry.name
            argumentsText = SpaceDetailArguments.join(entry.arguments)
            envRows = entry.environment.sorted { $0.key < $1.key }
                .map { SpaceProgramEnvRow(key: $0.key, value: $0.value) }
            graphicsBackend = entry.overrides?.graphicsBackend ?? .auto
        } else {
            name = program.name
            argumentsText = SpaceDetailArguments.join(program.arguments)
            envRows = program.environment.sorted { $0.key < $1.key }
                .map { SpaceProgramEnvRow(key: $0.key, value: $0.value) }
        }
    }

    private func pinAndEdit() {
        if let id = model.spaceDetailPin(program, in: spaceID) {
            entryID = id
            fill()
        }
    }

    private func save() {
        guard let id = entryID else {
            dismiss()
            return
        }
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = SpaceDetailArguments.split(argumentsText)
        var environment: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { environment[key] = row.value }
        }
        let backend = graphicsBackend
        dismiss()
        model.updateConfig(of: spaceID) { config in
            guard let index = config.programs.firstIndex(where: { $0.id == id }) else { return }
            if !newName.isEmpty { config.programs[index].name = newName }
            config.programs[index].arguments = arguments
            config.programs[index].environment = environment
            // Per-program backend (CompatRules turns it into an onwincompat rule for this exe).
            var overrides = config.programs[index].overrides ?? RunOverrides()
            overrides.graphicsBackend = backend == .auto ? nil : backend
            config.programs[index].overrides = overrides.isEmpty ? nil : overrides
        }
    }
}

// MARK: - Small helpers

/// Command-line text ⇄ argument list (double quotes group words with spaces).
private enum SpaceDetailArguments {
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace && !inQuotes {
                if hasToken {
                    result.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    static func join(_ arguments: [String]) -> String {
        arguments.map { argument in
            (argument.isEmpty || argument.contains(where: { $0.isWhitespace })) ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
    }
}

@MainActor
private enum SpaceDetailPanels {
    /// Programs to pin (the panel opens in the space's drive C:).
    static func chooseFilesToPin(startingIn directory: URL) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Добавить программу")
        panel.message = String(localized: "Выберите программу (.exe), ярлык (.lnk) или сценарий (.bat) — она появится в списке пространства")
        panel.prompt = String(localized: "Добавить", comment: "Open panel button: add the chosen programs to the space")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let types = OnwinPanels.runnableTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        if OnwinPaths.isDirectory(directory) { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Small capsule in the space header (Windows version, graphics backend, engine).
@MainActor
private struct SpaceDetailBadge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(verbatim: text)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
    }
}
