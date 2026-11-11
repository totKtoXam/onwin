import AppKit
import Darwin
import SwiftUI
import OnwinCore

// "Запущено" screen: programs started from this onwin instance (ProcessTracker.shared.programs),
// running ones first, then recently finished ones with their exit status.
//
// Types declared here and reused by SpaceDetailView.swift:
//   RunningProgramRow      one program: status, elapsed time, exit code, log / stop buttons
//   RunningLogSheet        in-app viewer of a program's log file (tail, refreshed while it runs)
//   RunningProgramControl  SIGTERM / SIGKILL by pid, log tail reading, Russian plural helper
//
// Note: we only know the pid of the `wine` process we started. Programs launched through a .lnk
// (`start /unix`) or a launcher may keep running after that process exits — "Завершить всё в пространстве"
// (AppModel.quitAll: soft wineboot --end-session, then wineserver -k after 10 s) stops everything in the space.

@MainActor
struct RunningProgramsView: View {
    @Environment(AppModel.self) private var model
    /// Finished programs started before this moment are hidden ("Очистить").
    @AppStorage("onwin.running.clearedBefore") private var clearedBefore: Double = 0
    @State private var logProgram: RunningProgram?
    @State private var confirmQuitEverything = false

    var body: some View {
        let all = ProcessTracker.shared.programs
        let running = all.filter { $0.isRunning }.sorted { $0.started > $1.started }
        let finished = all
            .filter { !$0.isRunning && $0.started.timeIntervalSinceReferenceDate >= clearedBefore }
            .sorted { $0.started > $1.started }

        Group {
            if running.isEmpty && finished.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header(runningCount: running.count)
                        runningSection(running)
                        if !finished.isEmpty {
                            finishedSection(finished)
                        }
                        Text("Если игра запущена через ярлык или лаунчер, её процесс может работать и после того, как отслеживаемый процесс завершился. «Завершить всё в пространстве» останавливает все Windows-процессы пространства.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $logProgram) { program in
            RunningLogSheet(program: program)
                .environment(model)
                .tint(OnwinTheme.accent)
        }
        .confirmationDialog("Завершить все программы?", isPresented: $confirmQuitEverything,
                            titleVisibility: .visible) {
            Button("Завершить всё", role: .destructive) {
                quitEverything()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут остановлены все Windows-процессы во всех пространствах, где что-то запущено. Несохранённые данные в этих программах пропадут.")
        }
    }

    // MARK: Sections

    private func header(runningCount: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Запущенные программы")
                    .font(.largeTitle.bold())
                (runningCount == 0 ? Text("Сейчас ничего не запущено") : Text("Работает: \(runningCount) программ"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if runningCount > 0 {
                Button(role: .destructive) {
                    confirmQuitEverything = true
                } label: {
                    Label("Завершить всё", systemImage: "stop.fill")
                }
                .controlSize(.large)
                .help("Остановить все Windows-процессы во всех пространствах")
            }
        }
    }

    @ViewBuilder
    private func runningSection(_ running: [RunningProgram]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Сейчас работают", symbol: "play.circle")
            if running.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("Ничего не запущено. Запустите программу из пространства или перетащите .exe в окно.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onwinCard(padding: 14)
            } else {
                programList(running)
            }
        }
    }

    private func finishedSection(_ finished: [RunningProgram]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Недавно завершённые", symbol: "clock.arrow.circlepath")
                Spacer()
                Button("Очистить") {
                    clearedBefore = Date().timeIntervalSinceReferenceDate
                }
                .buttonStyle(.borderless)
                .help("Скрыть завершённые программы из списка")
            }
            programList(finished)
        }
    }

    private func programList(_ programs: [RunningProgram]) -> some View {
        let lastID = programs.last?.id
        return VStack(spacing: 0) {
            ForEach(programs) { program in
                RunningProgramRow(program: program, showsSpace: true) {
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
        .onwinCard(padding: 0)
    }

    private func sectionTitle(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(OnwinTheme.accent)
        }
        .font(.title3.weight(.semibold))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ничего не запущено", systemImage: "play.slash")
        } description: {
            Text("Здесь появятся программы, запущенные в пространствах onwin: сколько они работают, чем завершились и их журналы.")
        } actions: {
            if let space = model.selectedSpace ?? model.spaces.first {
                Button {
                    model.selection = .space(space.id)
                } label: {
                    Text("Открыть «\(space.name)»")
                }
            }
            Button("Запустить программу…") {
                model.chooseAndRun(in: nil)
            }
            .disabled(!model.hasEngine)
        }
    }

    // MARK: Actions

    private func quitEverything() {
        let running = ProcessTracker.shared.running
        var spaceIDs: [UUID] = []
        for program in running {
            if model.space(id: program.spaceID) == nil {
                // The space is gone (deleted / renamed away): only the pid is left.
                _ = RunningProgramControl.terminate(program, force: true)
            } else if !spaceIDs.contains(program.spaceID) {
                spaceIDs.append(program.spaceID)
            }
        }
        Task { @MainActor in
            for id in spaceIDs {
                if let space = model.space(id: id) {
                    await model.quitAll(in: space)
                }
            }
        }
    }
}

// MARK: - One program row

/// A started program: status icon, title, space, pid, elapsed time or exit status, log and stop buttons.
@MainActor
struct RunningProgramRow: View {
    @Environment(AppModel.self) private var model
    let program: RunningProgram
    var showsSpace = true
    let onShowLog: () -> Void
    /// After the first SIGTERM the primary "stop" action becomes SIGKILL.
    @State private var askedToTerminate = false

    var body: some View {
        HStack(spacing: 12) {
            programIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: program.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if showsSpace {
                        Label {
                            Text(verbatim: program.spaceName)
                        } icon: {
                            Image(systemName: "shippingbox")
                        }
                        .lineLimit(1)
                    }
                    if program.pid > 0 {
                        Text(verbatim: "PID \(program.pid)")
                            .monospacedDigit()
                    }
                    Text("начало \(Text(program.started, style: .time))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(verbatim: "wine " + program.command.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailingStatus
            actions
        }
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
    }

    // MARK: Pieces

    private var isSuccess: Bool {
        guard let status = program.exitStatus else { return true }
        return RunningProgramControl.isSuccess(status)
    }

    /// The program's own icon (AppIconView.swift) with a small status badge; the status tile until it loads.
    private var programIcon: some View {
        AppIconView(subject: .command(program.command, space: model.space(id: program.spaceID)), size: 38) {
            statusIcon
        }
        .overlay(alignment: .bottomTrailing) {
            statusBadge
                .offset(x: 4, y: 4)
        }
    }

    private var statusBadge: some View {
        let symbol = program.isRunning ? "play.fill" : (isSuccess ? "checkmark" : "exclamationmark")
        let tint = program.isRunning ? OnwinTheme.running : (isSuccess ? Color.secondary : Color.orange)
        return Image(systemName: symbol)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(Color.white)
            .frame(width: 15, height: 15)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .accessibilityHidden(true)
    }

    private var statusIcon: some View {
        let symbol: String
        let tint: Color
        if program.isRunning {
            symbol = "play.fill"
            tint = OnwinTheme.running
        } else if isSuccess {
            symbol = "checkmark"
            tint = Color.secondary
        } else {
            symbol = "exclamationmark.triangle.fill"
            tint = Color.orange
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: 38, height: 38)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if program.isRunning {
            VStack(alignment: .trailing, spacing: 1) {
                Text(program.started, style: .timer)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text("в работе")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("Сколько времени программа работает")
        } else if let status = program.exitStatus {
            let ok = RunningProgramControl.isSuccess(status)
            Text(verbatim: RunningProgramControl.statusText(status))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(ok ? Color.secondary : Color.red)
                .background((ok ? Color.secondary : Color.red).opacity(0.13), in: Capsule())
                .fixedSize()
                .help(ok ? "Программа завершилась" : "Программа завершилась с ошибкой — загляните в журнал")
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            onShowLog()
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Показать журнал")

        if !program.isRunning && !isSuccess {
            Button {
                model.reportProblem(for: program)
            } label: {
                Image(systemName: "ladybug")
            }
            .buttonStyle(.borderless)
            .help("Сообщить о проблеме: собрать сведения для чата поддержки")
        }

        if program.isRunning {
            Menu {
                Button("Завершить (SIGTERM)") {
                    terminate(force: false)
                }
                Button("Завершить принудительно (SIGKILL)") {
                    terminate(force: true)
                }
                if model.space(id: program.spaceID) != nil {
                    Divider()
                    Button {
                        quitSpace()
                    } label: {
                        Text("Завершить всё в пространстве «\(program.spaceName)»")
                    }
                }
            } label: {
                Text(askedToTerminate ? "Принудительно" : "Завершить")
            } primaryAction: {
                terminate(force: askedToTerminate)
            }
            .fixedSize()
            .help(askedToTerminate
                  ? "Программа не закрылась — завершить её принудительно (SIGKILL)"
                  : "Попросить программу завершиться (SIGTERM)")
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button {
            onShowLog()
        } label: {
            Label("Показать журнал", systemImage: "doc.text.magnifyingglass")
        }
        Button {
            model.open(program.logURL)
        } label: {
            Label("Открыть журнал в Консоли", systemImage: "terminal")
        }
        Button {
            model.revealInFinder(program.logURL)
        } label: {
            Label("Показать журнал в Finder", systemImage: "folder")
        }
        Button {
            model.reportProblem(for: program)
        } label: {
            Label("Сообщить о проблеме…", systemImage: "ladybug")
        }
        if model.space(id: program.spaceID) != nil {
            Divider()
            Button {
                model.selection = .space(program.spaceID)
            } label: {
                Label("Перейти к пространству", systemImage: "shippingbox")
            }
        }
        if program.isRunning {
            Divider()
            Button {
                terminate(force: false)
            } label: {
                Label("Завершить", systemImage: "stop")
            }
            Button {
                terminate(force: true)
            } label: {
                Label("Завершить принудительно", systemImage: "xmark.octagon")
            }
            if model.space(id: program.spaceID) != nil {
                Button {
                    quitSpace()
                } label: {
                    Label("Завершить всё в пространстве", systemImage: "stop.fill")
                }
            }
        }
    }

    // MARK: Actions

    private func terminate(force: Bool) {
        guard program.isRunning else { return }
        if !RunningProgramControl.terminate(program, force: force) {
            model.report(String(localized: "Не удалось завершить «\(program.title)» (PID \(Int(program.pid))). Попробуйте «Завершить всё в пространстве»."))
        }
        askedToTerminate = true
    }

    private func quitSpace() {
        guard let space = model.space(id: program.spaceID) else { return }
        Task { @MainActor in
            await model.quitAll(in: space)
        }
    }
}

// MARK: - Log viewer

/// Shows the end of a program's log; refreshes every 1.5 s while the program runs.
@MainActor
struct RunningLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let program: RunningProgram
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(OnwinTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: program.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: "\(program.spaceName) · \(program.logURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if program.isRunning {
                    HStack(spacing: 6) {
                        OnwinRunningDot(size: 7)
                        Text("обновляется")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let status = program.exitStatus {
                    Text(verbatim: RunningProgramControl.statusText(status))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RunningProgramControl.isSuccess(status) ? Color.secondary : Color.red)
                }
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        (text.isEmpty ? Text("Журнал пока пуст.") : Text(verbatim: text))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id("onwin.log.end")
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { _, _ in
                    proxy.scrollTo("onwin.log.end", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.revealInFinder(program.logURL)
                } label: {
                    Label("Показать в Finder", systemImage: "folder")
                }
                Button {
                    model.open(program.logURL)
                } label: {
                    Label("Открыть в Консоли", systemImage: "terminal")
                }
                Button {
                    text = RunningProgramControl.readTail(of: program.logURL)
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
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
        .frame(minWidth: 680, idealWidth: 780, minHeight: 440, idealHeight: 560)
        .task { @MainActor in
            while !Task.isCancelled {
                text = RunningProgramControl.readTail(of: program.logURL)
                if !program.isRunning { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

// MARK: - Helpers

@MainActor
enum RunningProgramControl {
    /// Exit codes of installers that are not errors: 1602 cancelled by user, 1638 already installed,
    /// 3010 success but reboot required (same list AppModel ignores).
    static func isSuccess(_ status: Int32) -> Bool {
        status == 0 || ([1602, 1638, 3010] as [Int32]).contains(where: { WineRunner.exitStatus(status, matches: $0) })
    }

    static func statusText(_ status: Int32) -> String {
        switch status {
        case 0: return String(localized: "Завершена", comment: "Exit status of a program: finished normally")
        case _ where WineRunner.exitStatus(status, matches: 1602): return String(localized: "Отменено пользователем")
        case _ where WineRunner.exitStatus(status, matches: 1638): return String(localized: "Уже установлено")
        case _ where WineRunner.exitStatus(status, matches: 3010): return String(localized: "Готово, нужна перезагрузка")
        default: return String(localized: "Код \(Int(status))", comment: "Exit code of a program")
        }
    }

    /// Sends SIGTERM (or SIGKILL with `force`) to the `wine` process we started. Returns false
    /// when the signal could not be sent (no pid, already gone, no permission).
    @discardableResult
    static func terminate(_ program: RunningProgram, force: Bool = false) -> Bool {
        guard program.isRunning, program.pid > 0 else { return false }
        return Darwin.kill(program.pid, force ? SIGKILL : SIGTERM) == 0
    }

    /// The last `maxBytes` of a log file as text.
    static func readTail(of url: URL, maxBytes: Int = 160_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let limit = UInt64(maxBytes)
        let start: UInt64 = size > limit ? size - limit : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return ""
        }
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0 {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            let shown = Int64(maxBytes).formatted(.byteCount(style: .file))
            text = String(localized: "… показан конец журнала (последние \(shown)) …") + "\n" + text
        }
        return text
    }
}
