import SwiftUI
import OnwinCore

// "Удалить программу…": what the space's registry lists under …\CurrentVersion\Uninstall
// (HKLM, its 32-bit view and HKCU), with the program's own uninstaller one click away.
// The list re-reads system.reg / user.reg whenever wineserver writes them, so a removed
// program disappears by itself once its uninstaller has finished.

@MainActor
struct UninstallProgramsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID

    @State private var apps: [InstalledApplication] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var selection: InstalledApplication.ID?
    @State private var confirming: InstalledApplication?
    @State private var started: [String: RunningProgram] = [:]

    var body: some View {
        let space = model.space(id: spaceID)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(OnwinTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Удаление программ")
                        .font(.title3.weight(.semibold))
                    Text("Пространство «\(space?.name ?? "—")» — программы, которые зарегистрировали свой деинсталлятор")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 10) {
                Button {
                    if let space { model.runTool(.uninstaller, in: space) }
                } label: {
                    Label("Окно Wine «Установка и удаление»", systemImage: "macwindow")
                }
                .disabled(space == nil || !model.hasEngine)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
        .task(id: spaceID) { await watchRegistry() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil },
                                                               set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { app in
            Button("Открыть деинсталлятор", role: .destructive) { start(app, quietly: false) }
            if UninstallRegistry.canUninstallQuietly(app) {
                Button("Удалить без вопросов", role: .destructive) { start(app, quietly: true) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { app in
            Text(verbatim: confirmMessage(app))
        }
    }

    @ViewBuilder
    private var content: some View {
        let shown = filtered
        if !loaded {
            ProgressView().controlSize(.small)
        } else if apps.isEmpty {
            ContentUnavailableView("Удалять нечего", systemImage: "checkmark.circle",
                                   description: Text("В реестре пространства нет программ с деинсталлятором. Программы без установщика просто удалите из папки на диске C:."))
        } else {
            VStack(spacing: 0) {
                TextField("Поиск", text: $search, prompt: Text("Найти программу"))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                List(selection: $selection) {
                    ForEach(shown) { app in
                        row(app)
                            .tag(app.id)
                            .contextMenu {
                                Button("Удалить…") { confirming = app }
                            }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if shown.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
        }
    }

    private func row(_ app: InstalledApplication) -> some View {
        let running = started[app.id].map(\.isRunning) ?? false
        return HStack(spacing: 12) {
            Image(systemName: app.isWindowsInstaller ? "shippingbox" : "app.dashed")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OnwinTheme.accent)
                .frame(width: 32, height: 32)
                .background(OnwinTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: app.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let v = app.displayVersion {
                        Text(verbatim: v).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: detail(app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Удаляется…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Удалить…") { confirming = app }
                    .disabled(!model.hasEngine)
            }
        }
        .padding(.vertical, 4)
        .help(app.uninstallString ?? (app.isWindowsInstaller ? "msiexec /x \(app.keyName)" : ""))
    }

    private func detail(_ app: InstalledApplication) -> String {
        var parts: [String] = []
        if let p = app.publisher { parts.append(p) }
        if let kb = app.estimatedSizeKB {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file))
        }
        if app.scope == .machine32 { parts.append(String(localized: "32-бит", comment: "A 32-bit Windows program")) }
        if app.scope == .user { parts.append(String(localized: "для пользователя", comment: "Program installed only for the current Windows user")) }
        if let location = app.installLocation { parts.append(location) }
        return parts.isEmpty ? app.keyName : parts.joined(separator: " · ")
    }

    private var filtered: [InstalledApplication] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(q) || ($0.publisher ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var confirmTitle: String {
        confirming.map { String(localized: "Удалить «\($0.displayName)»?") } ?? ""
    }

    private func confirmMessage(_ app: InstalledApplication) -> String {
        guard UninstallRegistry.canUninstallQuietly(app) else {
            return String(localized: "Откроется деинсталлятор программы — следуйте его шагам.")
        }
        let command = app.isWindowsInstaller ? "msiexec /qn" : "QuietUninstallString"
        return String(localized: "Откроется деинсталлятор программы — следуйте его шагам. «Удалить без вопросов» запустит тихое удаление (\(command)).")
    }

    private func start(_ app: InstalledApplication, quietly: Bool) {
        guard let space = model.space(id: spaceID),
              let program = model.uninstall(app, quietly: quietly, in: space) else { return }
        started[app.id] = program
    }

    // MARK: Registry

    private func reload() async {
        guard let space = model.space(id: spaceID) else { return }
        let list = await Task.detached { UninstallRegistry.applications(in: space) }.value
        apps = list
        loaded = true
    }

    /// Reads the list, then again whenever wineserver rewrites system.reg or user.reg.
    private func watchRegistry() async {
        await reload()
        guard let space = model.space(id: spaceID) else { return }
        let files = [WineRegistry.machineHive(of: space), WineRegistry.userHive(of: space)]
        func stamp() -> [Date] {
            files.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date) ?? .distantPast }
        }
        var last = stamp()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let now = stamp()
            if now != last {
                last = now
                await reload()
                model.refreshPrograms(of: spaceID)
            }
        }
    }
}
