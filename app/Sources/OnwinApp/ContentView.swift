import SwiftUI
import OnwinCore

/// Main window: sidebar (Каталог / Пространства / Запущено) + detail, toolbar, sheets and alerts.
@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            ShellDetail()
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                ShellToolbarStatus()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseAndRun(in: model.selectedSpace)
                } label: {
                    Label("Запустить .exe", systemImage: "play.fill")
                }
                .help("Запустить Windows-программу (.exe, .msi, .lnk)")
                .disabled(!model.hasEngine)

                Button {
                    model.showNewSpaceSheet = true
                } label: {
                    Label("Новое пространство", systemImage: "plus")
                }
                .help("Создать пространство")
                .disabled(!model.hasEngine)
            }
        }
        .tint(OnwinTheme.accent)
        .frame(minWidth: 880, minHeight: 560)
        .modifier(ShellSheets())
        .modifier(ShellAlerts())
    }
}

/// Sheets owned by the shell (new space, space settings, run-in chooser, task progress).
@MainActor
struct ShellSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    @ViewBuilder
    func body(content: Content) -> some View {
        @Bindable var model = model

        content
        .sheet(isPresented: $model.showNewSpaceSheet) {
            NewSpaceSheet()
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .sheet(isPresented: $model.isShowingSpaceSettings) {
            if let id = model.settingsSpaceID {
                ShellSpaceSettingsSheet(spaceID: id)
                    .environment(model)
                    .tint(OnwinTheme.accent)
            }
        }
        .sheet(item: $model.pendingOpen) { pending in
            ShellRunInSpaceSheet(pending: pending)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .sheet(isPresented: $model.isShowingTask) {
            TaskProgressSheet()
                .environment(model)
                .tint(OnwinTheme.accent)
                .interactiveDismissDisabled(!(model.activeTask?.isFinished ?? true))
        }
        // Automatic components: D3DMetal offer / "still does not start" (AppModel+AutoComponents.swift).
        .sheet(item: $model.autoComponentsNotice) { notice in
            AutoComponentsNoticeSheet(notice: notice)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
    }
}

/// Rename / delete / error dialogs.
@MainActor
struct ShellAlerts: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var renameText = ""

    @ViewBuilder
    func body(content: Content) -> some View {
        @Bindable var model = model

        content
        .alert("Переименовать пространство", isPresented: $model.isRenaming, presenting: model.renamingSpace) { space in
            TextField("Имя пространства", text: $renameText)
            Button("Переименовать") {
                model.rename(space, to: renameText)
            }
            .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) {}
        } message: { space in
            Text("Новое имя для «\(space.name)»")
        }
        .onChange(of: model.renamingSpaceID) { _, newValue in
            if let id = newValue, let space = model.space(id: id) {
                renameText = space.name
            }
        }
        .confirmationDialog("Удалить пространство?", isPresented: $model.isConfirmingDelete,
                            titleVisibility: .visible, presenting: model.deletingSpace) { space in
            Button("Переместить «\(space.name)» в Корзину", role: .destructive) {
                Task { await model.deleteSpace(space) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Пространство и всё, что в него установлено, будут перемещены в Корзину. Запущенные в нём программы будут закрыты.")
        }
        .alert("Что-то пошло не так", isPresented: $model.isShowingError, presenting: model.lastError) { _ in
            if let log = model.lastErrorLog {
                Button("Показать журнал") {
                    model.revealInFinder(log)
                    model.clearError()
                }
            }
            Button("Сообщить о проблеме…") {
                let message = model.lastError
                let log = model.lastErrorLog
                model.clearError()
                model.reportProblem(log: log, error: message)
            }
            Button("OK", role: .cancel) {
                model.clearError()
            }
        } message: { message in
            Text(message)
        }
    }
}

/// Toolbar status: background activity (e.g. applying settings) and running programs.
@MainActor
struct ShellToolbarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = ProcessTracker.shared.running.count
        HStack(spacing: 8) {
            if let activity = model.backgroundActivity {
                ProgressView()
                    .controlSize(.small)
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if running > 0 {
                Button {
                    model.selection = .running
                } label: {
                    HStack(spacing: 6) {
                        OnwinRunningDot(size: 7)
                        Text(runningText(running))
                            .font(.callout)
                    }
                }
                .buttonStyle(.plain)
                .help("Показать запущенные программы")
            }
        }
    }

    private func runningText(_ count: Int) -> String {
        count == 1 ? "Запущена 1 программа" : "Запущено: \(count)"
    }
}
