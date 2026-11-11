import SwiftUI
import OnwinCore

/// Sidebar: Каталог / Пространства / Запущено.
@MainActor
struct ShellSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        let runningCount = ProcessTracker.shared.running.count

        List(selection: $model.selection) {
            Label("Рабочий стол", systemImage: "square.grid.3x3.fill")   // Views/DesktopView.swift, the main screen
                .tag(SidebarItem.desktop)

            Section("Каталог") {
                Label("Приложения и игры", systemImage: "square.grid.2x2.fill")
                    .tag(SidebarItem.catalog)
            }

            Section("Пространства") {
                if model.spaces.isEmpty {
                    Button {
                        model.showNewSpaceSheet = true
                    } label: {
                        Label("Создать пространство…", systemImage: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasEngine)
                }
                ForEach(model.spaces) { space in
                    ShellSpaceRow(space: space)
                        .tag(SidebarItem.space(space.id))
                }
            }

            Section("Запущено") {
                Label("Программы", systemImage: "play.rectangle.fill")
                    .badge(runningCount)
                    .tag(SidebarItem.running)
                Label("Журналы", systemImage: "doc.text.magnifyingglass")
                    .tag(SidebarItem.logs)
            }

            Section("onwin") {
                ShellSidebarAction("Настройки", systemImage: "gearshape", help: "Настройки onwin (⌘,)") {
                    PreferencesTab.select(.general)
                    openSettings()
                }
                ShellSidebarAction("Обновления", systemImage: "arrow.triangle.2.circlepath",
                                   help: "Версия onwin и проверка обновлений") {
                    PreferencesTab.select(.updates)
                    openSettings()
                }
                ShellSidebarAction("Документация", systemImage: "book", help: "Открыть документацию onwin на сайте") {
                    openURL(OnwinLinks.documentation)
                }
                ShellSidebarAction("Сообщить о проблеме", systemImage: "exclamationmark.bubble",
                                   help: "Собрать сведения о проблеме и открыть чат поддержки") {
                    model.reportProblemFromMenu()
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShellSidebarFooter()
        }
    }
}

/// One space in the sidebar: icon, name, Windows version, running dot, context menu, drop target.
@MainActor
struct ShellSpaceRow: View {
    @Environment(AppModel.self) private var model
    let space: Space
    @State private var isDropTarget = false

    var body: some View {
        let running = ProcessTracker.shared.running(in: space.id).count
        let runningHint: String = running == 1 ? "Запущена 1 программа" : "Запущено программ: \(running)"

        HStack(spacing: 9) {
            SpaceIconView(space: space, size: 24)   // main program's own icon (Views/AppIconView.swift)
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name)
                    .lineLimit(1)
                Text(space.config.windowsVersion.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if running > 0 {
                OnwinRunningDot()
                    .help(runningHint)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(OnwinTheme.accent, lineWidth: 2)
                .padding(-3)
                .opacity(isDropTarget ? 1 : 0)
        )
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(WineFileTypes.isRunnable)
            guard !files.isEmpty else { return false }
            model.run(files: files, in: space)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .contextMenu {
            Button {
                model.chooseAndRun(in: space)
            } label: {
                Label("Запустить программу…", systemImage: "play.fill")
            }
            .disabled(!model.hasEngine)
            Button {
                model.selection = .space(space.id)
                model.settingsSpaceID = space.id
            } label: {
                Label("Настройки", systemImage: "slider.horizontal.3")
            }
            Button {
                model.revealInFinder(space.url)
            } label: {
                Label("Показать в Finder", systemImage: "folder")
            }
            Divider()
            Button {
                Task { await model.duplicate(space) }
            } label: {
                Label("Дублировать", systemImage: "plus.square.on.square")
            }
            Button {
                model.renamingSpaceID = space.id
            } label: {
                Label("Переименовать…", systemImage: "pencil")
            }
            Button {
                model.archiveInteractively(space)
            } label: {
                Label("Архивировать…", systemImage: "archivebox")
            }
            if running > 0 {
                Divider()
                Button {
                    Task { await model.quitAll(in: space) }
                } label: {
                    Label("Завершить все программы", systemImage: "stop.fill")
                }
            }
            Divider()
            Button(role: .destructive) {
                model.deletingSpaceID = space.id
            } label: {
                Label("Удалить…", systemImage: "trash")
            }
        }
    }
}

/// A sidebar row that does something instead of opening a page: looks like the other rows
/// (icon + title, full width clickable) but never becomes the selection.
struct ShellSidebarAction: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Bottom of the sidebar: version, engine / graphics status at a glance.
@MainActor
struct ShellSidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.bottom, 4)
            Text("onwin \(OnwinVersion.displayString)")
                .lineLimit(1)
                .help("Установленная версия onwin")
            HStack(spacing: 6) {
                Image(systemName: model.hasEngine ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.hasEngine ? OnwinTheme.accent : Color.orange)
                Text(engineText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Image(systemName: model.isD3DMetalInstalled ? "cpu.fill" : "cpu")
                    .foregroundStyle(model.isD3DMetalInstalled ? OnwinTheme.accent : Color.secondary)
                Text(model.isD3DMetalInstalled ? "D3DMetal установлен" : "D3DMetal не установлен")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var engineText: String {
        guard let engine = model.defaultEngine else { return "Движок не установлен" }
        return "\(engine.info.displayName) · Wine \(engine.info.wineVersion)"
    }
}

/// «бета» next to the window title: every onwin below 1.0 is a beta test.
struct OnwinBetaBadge: View {
    var body: some View {
        if OnwinVersion.isBeta {
            Text("бета")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .help("onwin \(OnwinVersion.string) — бета-версия: многое уже работает, но возможны ошибки. Сообщить о проблеме — внизу боковой панели или в меню «Справка».")
        }
    }
}
