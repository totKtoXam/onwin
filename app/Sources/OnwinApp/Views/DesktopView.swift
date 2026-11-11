import AppKit
import SwiftUI
import OnwinCore

// «Рабочий стол» — the main screen: every launchable program of every space as a grid of big original
// icons (pinned programs, Start Menu shortcuts, Steam games, user-recipe programs), with search, sort,
// tile size, hidden items, «＋ Установить», drag & drop of Windows files and the «Запущено» strip.
// Logic: AppModel+Desktop.swift; aggregation: OnwinCore/DesktopCatalog.swift; the file sheet and the
// running strip: DesktopSheets.swift.

/// Order of the desktop grid.
enum DesktopSort: String, CaseIterable, Identifiable {
    case name, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return String(localized: "По имени", comment: "Desktop sort order")
        case .recent: return String(localized: "Недавние", comment: "Desktop sort order: recently used first")
        }
    }
}

/// Quick installs of the «＋ Установить» menu and the empty state.
enum DesktopQuickInstall {
    static let recipeIDs = ["steam", "epic", "gog", "battlenet"]
}

@MainActor
struct DesktopView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("onwin.desktop.sort") private var sortRaw = DesktopSort.name.rawValue
    @AppStorage("onwin.desktop.tileSize") private var tileSize: Double = 88
    @AppStorage("onwin.desktop.showHidden") private var showHidden = false
    @State private var query = ""
    @State private var selectedID: String?
    @State private var isDropTarget = false
    @State private var dialogs = ProgramDialogs.shared
    @State private var gridWidth: CGFloat = 800
    @FocusState private var gridFocused: Bool

    private var sort: DesktopSort { DesktopSort(rawValue: sortRaw) ?? .name }
    private var iconSize: CGFloat { CGFloat(tileSize) }
    private var cellWidth: CGFloat { iconSize + 48 }
    private static let spacing: CGFloat = 14
    private static let padding: CGFloat = 24

    var body: some View {
        @Bindable var desktop = model.desktop
        let visible = visibleItems

        VStack(spacing: 0) {
            DesktopTopBar(query: $query, sortRaw: $sortRaw, tileSize: $tileSize, showHidden: $showHidden,
                          itemCount: model.desktop.items.count - hiddenCount,
                          spaceCount: Set(model.desktop.items.map(\.spaceID)).count,
                          hiddenCount: hiddenCount)
            Divider()
            content(visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            DesktopRunningStrip()
        }
        .overlay {
            if isDropTarget {
                DesktopDropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            model.desktopHandleDrop(urls)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .task(id: model.desktopRefreshKey) {
            await model.refreshDesktop()
        }
        .task {
            // Steam finishing a download, a game installed from Steam's own window: rescan now and then.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await model.refreshDesktop()
            }
        }
        .sheet(item: $desktop.fileRequest) { request in
            DesktopFileSheet(request: request,
                             onCancel: { model.desktop.fileRequest = nil },
                             onConfirm: { work in startAfterClosingSheet(work) })
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .sheet(item: runOptionsRequest) { request in
            Group {
                if case .runWithOptions(let id, let target) = request {
                    RunOptionsSheet(spaceID: id, mode: .target(target))
                }
            }
            .environment(model)
            .tint(OnwinTheme.accent)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ visible: [DesktopItem]) -> some View {
        if !model.desktop.hasLoaded {
            ProgressView("Собираю программы из пространств…")
                .controlSize(.regular)
        } else if model.desktop.items.isEmpty {
            DesktopEmptyState()
        } else if visible.isEmpty {
            DesktopNoResults(query: trimmedQuery, hiddenCount: hiddenCount, onShowHidden: { showHidden = true },
                             onClear: { query = "" })
        } else {
            grid(visible)
        }
    }

    private func grid(_ visible: [DesktopItem]) -> some View {
        let highlighted = model.desktop.highlighted
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing + 4) {
                    ForEach(visible) { item in
                        tile(item, isHighlighted: highlighted.contains(item.id))
                            .id(item.id)
                    }
                }
                .padding(Self.padding)
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { gridWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in gridWidth = width }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.return) {
                guard let id = selectedID, let item = visible.first(where: { $0.id == id }) else { return .ignored }
                model.launch(item)
                return .handled
            }
            .onKeyPress(.leftArrow) { move(by: -1, in: visible, proxy: proxy) }
            .onKeyPress(.rightArrow) { move(by: 1, in: visible, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -columnCount, in: visible, proxy: proxy) }
            .onKeyPress(.downArrow) { move(by: columnCount, in: visible, proxy: proxy) }
            .onChange(of: highlighted) { _, ids in
                guard let first = visible.first(where: { ids.contains($0.id) }) else { return }
                selectedID = first.id
                withAnimation { proxy.scrollTo(first.id, anchor: .center) }
            }
        }
    }

    private func tile(_ item: DesktopItem, isHighlighted: Bool) -> some View {
        let isRunning = model.desktopIsRunning(item)
        let isHidden = model.isHiddenOnDesktop(item)
        return DesktopTile(item: item, iconSize: iconSize, width: cellWidth,
                           isSelected: selectedID == item.id, isRunning: isRunning,
                           isHighlighted: isHighlighted, isHidden: isHidden,
                           canRun: model.hasEngine && item.isLaunchable,
                           onSelect: {
                               selectedID = item.id
                               gridFocused = true
                           },
                           onRun: {
                               selectedID = item.id
                               model.launch(item)
                           })
            .contextMenu { DesktopTileMenu(item: item, isHidden: isHidden) }
    }

    // MARK: Keyboard

    private var columnCount: Int {
        let available = gridWidth - Self.padding * 2 + Self.spacing
        return max(1, Int(available / (cellWidth + Self.spacing)))
    }

    private func move(by offset: Int, in visible: [DesktopItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let current = selectedID.flatMap { id in visible.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), visible.count - 1)
        } else {
            next = offset < 0 ? visible.count - 1 : 0
        }
        selectedID = visible[next].id
        proxy.scrollTo(visible[next].id)
        return .handled
    }

    // MARK: Filtering & sorting

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hiddenCount: Int {
        model.desktop.items.filter { model.isHiddenOnDesktop($0) }.count
    }

    private var visibleItems: [DesktopItem] {
        let words = trimmedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var list = model.desktop.items.filter { item in
            (showHidden || !model.isHiddenOnDesktop(item))
                && words.allSatisfy { word in
                    item.name.localizedCaseInsensitiveContains(word) || item.spaceName.localizedCaseInsensitiveContains(word)
                }
        }
        if sort == .recent {
            let dates = Dictionary(uniqueKeysWithValues: list.map { ($0.id, model.desktopLastUsed($0) ?? .distantPast) })
            list.sort { a, b in
                let da = dates[a.id] ?? .distantPast, db = dates[b.id] ?? .distantPast
                return da != db ? da > db : DesktopCatalog.byName(a, b)
            }
        }
        return list
    }

    // MARK: Sheets

    private var runOptionsRequest: Binding<ProgramDialogs.Request?> {
        Binding(get: {
            if case .runWithOptions? = dialogs.request { return dialogs.request }
            return nil
        }, set: { dialogs.request = $0 })
    }

    /// Closes the file sheet, waits for its dismissal, then starts the work (it presents TaskProgressSheet).
    private func startAfterClosingSheet(_ work: @escaping @MainActor () async -> Void) {
        model.desktop.fileRequest = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await work()
        }
    }
}

// MARK: - Top bar

@MainActor
struct DesktopTopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    @Binding var sortRaw: String
    @Binding var tileSize: Double
    @Binding var showHidden: Bool
    let itemCount: Int
    let spaceCount: Int
    let hiddenCount: Int

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Рабочий стол")
                    .font(.title2.bold())
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            DesktopSearchField(text: $query)
                .frame(minWidth: 140, idealWidth: 240, maxWidth: 300)

            Spacer(minLength: 0)

            Picker("Сортировка", selection: $sortRaw) {
                ForEach(DesktopSort.allCases) { sort in
                    Text(sort.title).tag(sort.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Порядок программ")

            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3")
                    .font(.caption)
                Slider(value: $tileSize, in: 56...160)
                    .frame(width: 96)
                    .controlSize(.small)
                Image(systemName: "square.grid.2x2")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .help("Размер значков")

            if hiddenCount > 0 || showHidden {
                Toggle(isOn: $showHidden) {
                    Label(showHidden ? "Скрытые показаны" : "Показать скрытые (\(hiddenCount))",
                          systemImage: showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help("Показать программы, скрытые с рабочего стола")
            }

            DesktopInstallMenu()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var summary: String {
        guard itemCount > 0 else { return String(localized: "Все Windows-программы и игры из всех пространств") }
        // Two counted numbers: each half has its own plural forms in the catalog.
        let programs = String(localized: "\(itemCount) программ", comment: "Desktop summary, first half: N programs")
        let spaces = String(localized: "в \(spaceCount) пространствах", comment: "Desktop summary, second half: in N spaces")
        return String(localized: "\(programs) \(spaces)", comment: "Desktop summary: «5 программ» + «в 2 пространствах»")
    }
}

/// «＋ Установить»: from the catalog, from a file, or one click for the big launchers.
@MainActor
struct DesktopInstallMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.selection = .catalog
            } label: {
                Label("Из каталога…", systemImage: "square.grid.2x2")
            }
            Button {
                model.desktopChooseInstaller()
            } label: {
                Label("Из файла…", systemImage: "doc.badge.plus")
            }
            Divider()
            Section("Установить в один щелчок") {
                ForEach(DesktopQuickInstall.recipeIDs, id: \.self) { id in
                    if let recipe = Catalog.app(id) {
                        Button {
                            model.desktopInstallRecipe(id)
                        } label: {
                            Label(title(for: recipe), systemImage: recipe.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Установить", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!model.hasEngine)
        .help(model.hasEngine ? String(localized: "Установить Windows-программу или игру") : AppModel.noEngineMessage)
    }

    private func title(for recipe: AppRecipe) -> String {
        let installed = model.desktopSpaces(with: recipe.id)
        guard let first = installed.first else { return recipe.name }
        return String(localized: "\(recipe.name) — уже есть в «\(first.name)»")
    }
}

@MainActor
struct DesktopSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Программа или пространство", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
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
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? OnwinTheme.accent : Color.primary.opacity(0.08), lineWidth: isFocused ? 1.5 : 1)
        )
    }
}

// MARK: - Tile

@MainActor
struct DesktopTile: View {
    let item: DesktopItem
    let iconSize: CGFloat
    let width: CGFloat
    let isSelected: Bool
    let isRunning: Bool
    let isHighlighted: Bool
    let isHidden: Bool
    let canRun: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
        VStack(spacing: 7) {
            AppIconView(subject: item.iconSubject, size: iconSize) {
                OnwinSpaceIcon(symbol: item.placeholderSymbol, size: iconSize)
            }
            .overlay(alignment: .bottomTrailing) {
                if isRunning {
                    OnwinRunningDot(size: max(9, iconSize * 0.14))
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 4, y: 4)
                }
            }
            .padding(.top, 4)

            Text(verbatim: item.name)
                .font(iconSize >= 110 ? .callout.weight(.medium) : .caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: iconSize >= 110 ? 34 : 28, alignment: .top)

            HStack(spacing: 4) {
                if isRunning {
                    Text("Запущено")
                        .foregroundStyle(OnwinTheme.running)
                } else if let status = item.statusText {
                    Image(systemName: item.isLaunchable ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                    Text(status)
                } else {
                    Text(verbatim: item.spaceName)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: width)
        .background(
            shape.fill(isSelected ? OnwinTheme.accent.opacity(0.16)
                                  : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            shape.strokeBorder(isHighlighted ? OnwinTheme.accent : (isSelected ? OnwinTheme.accent.opacity(0.7) : Color.clear),
                               lineWidth: isHighlighted ? 2 : 1.2)
        )
        .overlay(alignment: .topLeading) {
            if isHighlighted {
                Text("Новое")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OnwinTheme.accent, in: Capsule())
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if (isHovering || isSelected) && canRun {
                Button(action: onRun) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: max(18, min(26, iconSize * 0.26))))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, OnwinTheme.accent)
                        .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(item.steamGame != nil ? "Играть" : "Запустить")
                .transition(.opacity)
            }
        }
        .opacity(isHidden ? 0.45 : 1)
        .contentShape(shape)
        .onTapGesture(count: 2) { if canRun { onRun() } }
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Запустить")) { if canRun { onRun() } }
    }

    private var helpText: String {
        var lines = [item.name, String(localized: "Пространство «\(item.spaceName)» · \(item.source.displayName)")]
        if isHidden { lines.append(String(localized: "Скрыта с рабочего стола")) }
        lines.append(item.steamGame != nil ? String(localized: "Двойной щелчок — играть через Steam")
                                           : String(localized: "Двойной щелчок — запустить"))
        return lines.joined(separator: "\n")
    }
}

/// Context menu of a tile.
@MainActor
struct DesktopTileMenu: View {
    @Environment(AppModel.self) private var model
    let item: DesktopItem
    let isHidden: Bool

    var body: some View {
        Button {
            model.launch(item)
        } label: {
            Label(item.steamGame != nil ? "Играть" : "Запустить", systemImage: "play.fill")
        }
        .disabled(!model.hasEngine || !item.isLaunchable)
        Button {
            model.runWithOptions(item)
        } label: {
            Label("Запустить с параметрами…", systemImage: "slider.horizontal.below.rectangle")
        }
        .disabled(!model.hasEngine)
        Divider()
        if let program = item.program, let space = model.space(id: item.spaceID) {
            LauncherMenuItems(program: program, space: space)   // LauncherViews.swift
        }
        Button {
            model.revealInFinder(item.revealTarget)
        } label: {
            Label("Показать в Finder", systemImage: "folder")
        }
        Button {
            model.selection = .space(item.spaceID)
        } label: {
            Label("Открыть пространство «\(item.spaceName)»", systemImage: "shippingbox")
        }
        Button {
            model.settingsSpaceID = item.spaceID   // SpaceSettingsView sheet (ShellViews.swift), stays on the desktop
        } label: {
            Label("Настройки пространства «\(item.spaceName)»…", systemImage: "slider.horizontal.3")
        }
        Divider()
        if isHidden {
            Button {
                model.setHidden(item, false)
            } label: {
                Label("Вернуть на рабочий стол", systemImage: "eye")
            }
        } else {
            Button {
                model.setHidden(item, true)
            } label: {
                Label("Скрыть с рабочего стола", systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Empty states

@MainActor
struct DesktopEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(OnwinTheme.accentGradient)
                        .frame(width: 104, height: 104)
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .shadow(color: OnwinTheme.accent.opacity(0.35), radius: 16, y: 6)

                VStack(spacing: 8) {
                    Text("Здесь будут ваши Windows-игры и программы")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                }

                HStack(spacing: 14) {
                    DesktopBigButton(title: "Установить Steam", subtitle: "Магазин и библиотека игр",
                                     symbol: "gamecontroller.fill", prominent: true) {
                        model.desktopInstallRecipe("steam")
                    }
                    .disabled(!model.hasEngine)
                    DesktopBigButton(title: "Установить из файла", subtitle: "Установщик .exe или .msi",
                                     symbol: "doc.badge.plus", prominent: false) {
                        model.desktopChooseInstaller()
                    }
                    .disabled(!model.hasEngine)
                    DesktopBigButton(title: "Открыть каталог", subtitle: "Лаунчеры, программы, компоненты",
                                     symbol: "square.grid.2x2.fill", prominent: false) {
                        model.selection = .catalog
                    }
                }

                Text("Можно просто перетащить сюда файл .exe, .msi или ярлык .lnk.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        if !model.hasEngine {
            return String(localized: "Сначала нужен движок Wine — как его получить, рассказано на стартовой странице.")
        }
        if model.spaces.isEmpty {
            return String(localized: "Установите игровой магазин или свою программу — onwin сам создаст для неё пространство, и она появится на рабочем столе.")
        }
        return String(localized: "В пространствах пока нет программ. Установите что-нибудь — значок появится здесь, запуск двойным щелчком.")
    }
}

@MainActor
struct DesktopBigButton: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : OnwinTheme.accent)
                    .frame(height: 36)
                VStack(spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(prominent ? Color.white : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(prominent ? Color.white.opacity(0.85) : Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 176, height: 128)
            .background(
                RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(OnwinTheme.accentGradient) : AnyShapeStyle(.regularMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(prominent ? 0 : (isHovering ? 0.18 : 0.08)), lineWidth: 1)
            )
            .scaleEffect(isHovering && isEnabled ? 1.03 : 1)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

@MainActor
struct DesktopNoResults: View {
    let query: String
    let hiddenCount: Int
    let onShowHidden: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "eye.slash" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Все программы скрыты" : "Ничего не найдено по запросу «\(query)»")
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                if !query.isEmpty {
                    Button("Очистить поиск", action: onClear)
                }
                if hiddenCount > 0 {
                    Button("Показать скрытые (\(hiddenCount))", action: onShowHidden)
                }
            }
        }
        .padding(40)
    }
}

@MainActor
struct DesktopDropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OnwinTheme.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(OnwinTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(OnwinTheme.accent)
                Text("Отпустите, чтобы установить или запустить")
                    .font(.title3.weight(.semibold))
                Text("Дальше можно выбрать: новое пространство или одно из существующих")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}
