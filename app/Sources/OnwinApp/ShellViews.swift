import AppKit
import SwiftUI
import OnwinCore

// Views owned by the app shell: detail routing, empty / first-run states, drop overlay,
// "run in which space?" chooser, the space settings sheet wrapper.

// MARK: - Detail column

@MainActor
struct ShellDetail: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTarget = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.hasEngine && model.selection != nil {
                    ShellEngineBanner()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                UpdateBanner()   // «Доступна onwin X» (Views/UpdateViews.swift)
            }
            .overlay {
                if isDropTarget {
                    ShellDropOverlay(spaceName: model.selectedSpace?.name)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDropTarget)
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
            } isTargeted: { targeted in
                isDropTarget = targeted
            }
    }

    @ViewBuilder
    private var content: some View {
        if let selection = model.selection {
            switch selection {
            case .desktop:
                DesktopView()   // Views/DesktopView.swift
            case .catalog:
                CatalogView()
            case .space(let id):
                if model.space(id: id) != nil {
                    SpaceDetailView(spaceID: id)
                        .id(id)
                } else {
                    ShellLibraryView()
                }
            case .running:
                RunningProgramsView()
            case .logs:
                LogsView(spaceID: nil)
            }
        } else if !model.hasEngine {
            ShellEngineMissingView()
        } else if model.spaces.isEmpty {
            ShellNoSpacesView()
        } else {
            ShellLibraryView()
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(WineFileTypes.isRunnable)
        guard !files.isEmpty else { return false }
        if model.selection == .desktop { return model.desktopHandleDrop(files) }   // new-or-existing-space sheet
        if let space = model.selectedSpace {
            model.run(files: files, in: space)
        } else {
            model.openFiles(files)
        }
        return true
    }
}

@MainActor
struct ShellDropOverlay: View {
    let spaceName: String?

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
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .allowsHitTesting(false)
    }

    private var title: String {
        if let spaceName { return "Отпустите, чтобы запустить в «\(spaceName)»" }
        return "Отпустите, чтобы выбрать пространство для запуска"
    }
}

// MARK: - Engine missing

/// Slim banner on top of the detail column when no engine is installed.
@MainActor
struct ShellEngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text("Движок Wine не установлен — запуск программ пока недоступен.")
                .font(.callout)
            Spacer()
            Button("Как установить") { model.selection = nil }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// First-run screen when no Wine engine is installed: the easiest fix is to re-run the installation command
/// from the onwin website (it installs or updates the engine); developers can build it with engine/build.sh.
@MainActor
struct ShellEngineMissingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    OnwinSpaceIcon(symbol: "hammer.fill", size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Добро пожаловать в onwin")
                            .font(.largeTitle.bold())
                        Text("Чтобы запускать Windows-игры, нужен движок Wine, а он пока не установлен.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    ShellStep(number: 1, title: "Повторите установку onwin",
                              detail: "Проще всего ещё раз выполнить в Терминале команду установки с сайта onwin: она установит движок или обновит его до последней версии.",
                              command: nil)
                    ShellStep(number: 2, title: "Проверьте",
                              detail: "Когда установка закончится, нажмите «Проверить снова». Если движок лежит в другом месте, выберите его папку кнопкой «Установить из папки…».",
                              command: nil)
                }
                .onwinCard(padding: 20)

                HStack(spacing: 10) {
                    Button {
                        model.reload()
                    } label: {
                        Label("Проверить снова", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        model.installEngineInteractively()
                    } label: {
                        Label("Установить из папки…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.large)

                    Button {
                        try? OnwinPaths.ensureLayout()
                        model.open(OnwinPaths.engines)
                    } label: {
                        Label("Открыть папку движков", systemImage: "folder")
                    }
                    .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Графика")
                        .font(.headline)
                    Text("Для DirectX 11/12 лучше всего подходит D3DMetal от Apple. onwin установит его сам: войдите с Apple ID прямо в приложении — Game Porting Toolkit скачается и установится автоматически.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            Task { @MainActor in await model.fetchD3DMetal() }
                        } label: {
                            Label("Установить D3DMetal", systemImage: "wand.and.stars")
                        }
                        .help("Вход с Apple ID, загрузка и установка — внутри onwin")
                        Button {
                            model.importD3DMetalInteractively()
                        } label: {
                            Label(d3dmetalButtonTitle, systemImage: "cpu")
                        }
                    }
                    .padding(.top, 4)
                }
                .onwinCard(padding: 20)

                Text("Для разработчиков: движок можно собрать самостоятельно скриптом engine/build.sh из исходного кода onwin (нужны Command Line Tools: xcode-select --install). Путь к движку можно задать переменной окружения ONWIN_ENGINE.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

extension ShellEngineMissingView {
    var d3dmetalButtonTitle: String {
        model.isD3DMetalInstalled ? "D3DMetal установлен — указать другой…" : "Указать .dmg вручную…"
    }
}

@MainActor
struct ShellStep: View {
    let number: Int
    let title: String
    let detail: String
    let command: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(OnwinTheme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    ShellCommandSnippet(command: command)
                }
            }
        }
    }
}

@MainActor
struct ShellCommandSnippet: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Скопировать")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - No spaces / library overview

@MainActor
struct ShellNoSpacesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Здесь будет ваша библиотека")
                        .font(.largeTitle.bold())
                    Text("Пространство — это отдельный маленький Windows со своими программами и настройками. Создайте первое или установите лаунчер из каталога — пространство создастся само.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ShellActionCard(symbol: "plus", title: "Новое пространство",
                                    detail: "Пустой Windows 10 или 11 для своих программ и игр") {
                        model.showNewSpaceSheet = true
                    }
                    ShellActionCard(symbol: "square.grid.2x2.fill", title: "Каталог",
                                    detail: "Steam, Epic Games, GOG Galaxy, Battle.net в один клик") {
                        model.selection = .catalog
                    }
                    ShellActionCard(symbol: "archivebox.fill", title: "Из архива",
                                    detail: "Восстановить пространство из файла .onwinspace") {
                        model.restoreInteractively()
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

@MainActor
struct ShellActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                OnwinSpaceIcon(symbol: symbol, size: 40)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .contentShape(Rectangle())
            .onwinCard(highlighted: isHovering)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in isHovering = hovering }
    }
}

/// Grid of space "covers" — shown when spaces exist but none is selected.
@MainActor
struct ShellLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Библиотека")
                        .font(.largeTitle.bold())
                    Text("Выберите пространство или перетащите сюда .exe, .msi или ярлык .lnk.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    ForEach(model.spaces) { space in
                        ShellSpaceCard(space: space,
                                        isRunning: model.isRunning(space.id)) {
                            model.selection = .space(space.id)
                        }
                    }
                    ShellActionCard(symbol: "plus", title: "Новое пространство",
                                    detail: "Создать ещё один Windows") {
                        model.showNewSpaceSheet = true
                    }
                }
            }
            .padding(28)
        }
    }
}

@MainActor
struct ShellSpaceCard: View {
    let space: Space
    let isRunning: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SpaceIconView(space: space, size: 48)
                    Spacer()
                    if isRunning {
                        HStack(spacing: 5) {
                            OnwinRunningDot(size: 7)
                            Text("Запущено")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(OnwinTheme.running.opacity(0.15), in: Capsule())
                    }
                }
                Text(space.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onwinCard(highlighted: isHovering)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in isHovering = hovering }
    }

    private var subtitle: String {
        "\(space.config.windowsVersion.displayName) · \(space.config.graphicsBackend.displayName)"
    }
}

// MARK: - Run in which space?

@MainActor
struct ShellRunInSpaceSheet: View {
    @Environment(AppModel.self) private var model
    let pending: PendingOpen
    @State private var chosen: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                OnwinSpaceIcon(symbol: "play.fill", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.title3.bold())
                    Text(fileNames)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Text("В каком пространстве запустить?")
                .font(.headline)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.spaces) { space in
                        ShellSpaceChoiceRow(space: space, isSelected: chosen == space.id)
                            .onTapGesture(count: 2) {
                                chosen = space.id
                                runChosen()
                            }
                            .onTapGesture {
                                chosen = space.id
                            }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 280)

            HStack {
                Spacer()
                Button("Отмена") {
                    model.pendingOpen = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Запустить") {
                    runChosen()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if chosen == nil {
                chosen = pending.suggestedSpaceID ?? model.spaces.first?.id
            }
        }
    }

    private var heading: String {
        pending.files.count == 1 ? "Запуск программы" : "Запуск программ"
    }

    private var fileNames: String {
        pending.files.map(\.lastPathComponent).joined(separator: ", ")
    }

    private func runChosen() {
        guard let id = chosen, let space = model.space(id: id) else { return }
        model.runPending(in: space)
    }
}

@MainActor
struct ShellSpaceChoiceRow: View {
    let space: Space
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SpaceIconView(space: space, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name)
                    .font(.body.weight(.medium))
                Text(space.config.windowsVersion.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OnwinTheme.accent)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? OnwinTheme.accent.opacity(0.14) : Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Space settings sheet

@MainActor
struct ShellSpaceSettingsSheet: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID

    var body: some View {
        VStack(spacing: 0) {
            SpaceSettingsView(spaceID: spaceID)
                .frame(minWidth: 580, idealWidth: 640, minHeight: 460, idealHeight: 560)
            Divider()
            HStack {
                if let space = model.space(id: spaceID) {
                    Button {
                        model.revealInFinder(space.url)
                    } label: {
                        Label("Показать в Finder", systemImage: "folder")
                    }
                }
                Spacer()
                Button("Готово") {
                    model.settingsSpaceID = nil
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
    }
}
