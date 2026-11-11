import AppKit
import SwiftUI
import OnwinCore

// Parts of «Рабочий стол» (DesktopView.swift): the «новое или существующее пространство?» sheet for a file
// chosen with «Установить → Из файла…» or dropped on the desktop, and the «Запущено» strip.

// MARK: - File sheet

@MainActor
struct DesktopFileSheet: View {
    @Environment(AppModel.self) private var model
    let request: DesktopFileRequest
    let onCancel: () -> Void
    let onConfirm: (@escaping @MainActor () async -> Void) -> Void

    @State private var action: DesktopFileAction = .install
    @State private var target: CatalogTarget = .newSpace
    @State private var newName = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var backend: GraphicsBackend = .auto
    @State private var pinToDesktop = true
    @State private var didPrepare = false

    private var file: URL { request.file }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(subject: .sources([.executable(file)]), size: 44) {
                    OnwinSpaceIcon(symbol: action == .install ? "square.and.arrow.down.fill" : "play.fill", size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(action == .install ? "Установка программы" : "Запуск программы")
                        .font(.title3.bold())
                    Text(verbatim: file.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                }
            }

            if request.actions.count > 1 {
                Picker("Что сделать", selection: $action) {
                    ForEach(request.actions, id: \.self) { option in
                        Text(option == .install ? "Установить" : "Запустить").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(actionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(action == .install ? "Куда установить?" : "В каком пространстве запустить?")
                .font(.headline)

            CatalogTargetPicker(spaces: model.spaces, target: $target, newName: $newName, nameProblem: nameProblem)

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

            if action == .run && canPin {
                Toggle("Добавить на рабочий стол", isOn: $pinToDesktop)
                    .help("Закрепить программу в пространстве — у неё появится свой значок на рабочем столе")
            }

            if action == .install {
                Text("Когда установщик закончит работу, onwin найдёт новые программы, покажет их на рабочем столе и предложит сохранить установку в «Мои приложения».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action == .install ? "Запустить установщик" : "Запустить") {
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

    private var actionHint: String {
        switch action {
        case .install: return String(localized: "Это установщик: onwin дождётся его окончания и найдёт, что он установил.")
        case .run: return String(localized: "Это сама программа (например, портативная версия): onwin просто запустит её.")
        }
    }

    private var canPin: Bool {
        ["exe", "bat", "cmd"].contains(file.pathExtension.lowercased())
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        action = request.actions.first ?? .install
        newName = CatalogView.suggestedSpaceName(for: file)
        backend = model.settings.defaultBackend
        target = .newSpace
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard target == .newSpace else { return nil }
        if trimmedName.isEmpty { return String(localized: "Укажите имя пространства") }
        if CatalogView.isNameTaken(trimmedName, in: model.spaces) {
            return String(localized: "Пространство с таким именем уже есть")
        }
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
        let action = self.action
        let target = self.target
        let name = trimmedName
        let windowsVersion = self.windowsVersion
        let backend = self.backend
        let pin = action == .run && canPin && pinToDesktop
        onConfirm {
            await model.desktopPerform(file, action: action, target: target, newName: name,
                                       windowsVersion: windowsVersion, backend: backend, pin: pin)
        }
    }
}

// MARK: - «Запущено» strip

/// Bottom strip of the desktop: running programs with icon, elapsed time and «Завершить».
@MainActor
struct DesktopRunningStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = ProcessTracker.shared.running.sorted { $0.started < $1.started }
        if !running.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        OnwinRunningDot(size: 7)
                        Text("Запущено")
                            .font(.headline)
                    }
                    .fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(running) { program in
                                DesktopRunningChip(program: program)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button {
                        model.selection = .running
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help("Все запущенные программы и журналы")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(.bar)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

@MainActor
struct DesktopRunningChip: View {
    @Environment(AppModel.self) private var model
    let program: RunningProgram
    @State private var confirmSpaceQuit = false

    var body: some View {
        let space = model.space(id: program.spaceID)
        let subject: AppIconSubject = model.desktopItem(for: program)?.iconSubject
            ?? .command(program.command, space: space)
        HStack(spacing: 8) {
            AppIconView(subject: subject, size: 26) {
                OnwinSpaceIcon(symbol: "app.fill", size: 26)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: program.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: "\(program.spaceName) · \(DesktopRunningChip.elapsed(from: program.started, to: context.date))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 180, alignment: .leading)
            Menu {
                Button("Завершить принудительно") {
                    model.desktopQuit(program, force: true)
                }
                if let space {
                    Divider()
                    Button("Завершить всё в «\(space.name)»…") {
                        confirmSpaceQuit = true
                    }
                }
            } label: {
                Text("Завершить")
            } primaryAction: {
                model.desktopQuit(program, force: false)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Завершить программу; в меню — принудительно или все программы пространства")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .confirmationDialog("Завершить все программы пространства?", isPresented: $confirmSpaceQuit, titleVisibility: .visible) {
            if let space {
                Button("Завершить всё в «\(space.name)»", role: .destructive) {
                    Task { await model.quitAll(in: space) }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Программам пространства будет предложено закрыться (несохранённые данные можно сохранить); через 10 секунд оставшиеся будут завершены принудительно.")
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
