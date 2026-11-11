import AppKit
import SwiftUI
import OnwinCore

/// Progress of the current long operation (`model.activeTask`): status, progress bar, collapsible log,
/// error state. Presented by the shell (ShellSheets); `model.dismissTask()` closes a finished task,
/// `model.cancelTask()` cancels a running one (Wine processes it already started keep running).
@MainActor
struct TaskProgressSheet: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var didCopy = false
    @State private var cancelRequestedFor: UUID?

    private static let bottomAnchor = "task-log-bottom"
    /// The sheet renders at most this many characters of the log (the full text is copied).
    private static let visibleLogLimit = 60_000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let task = model.activeTask {
                header(task)
                if task.error == nil {
                    progressBlock(task)
                } else {
                    Text(task.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let error = task.error {
                    errorBlock(error)
                }
                logBlock(task)
                InstallFollowUpBar(task: task)   // «Запустить <Program>» after a catalog install (MainProgramViews.swift)
                buttons(task)
            } else {
                HStack {
                    Spacer()
                    Text("Готово")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            if let task = model.activeTask, task.error != nil, !task.log.isEmpty { showLog = true }
        }
        .onChange(of: model.activeTask?.error) { _, newValue in
            if newValue != nil, !(model.activeTask?.log.isEmpty ?? true) { showLog = true }
        }
        .onChange(of: model.activeTask?.id) { _, _ in
            didCopy = false
            cancelRequestedFor = nil
        }
    }

    // MARK: Header

    private func header(_ task: TaskState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(task.error == nil ? OnwinTheme.accent : Color.red)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: statusSymbol(task))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.white)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                statusLine(task)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusSymbol(_ task: TaskState) -> String {
        if task.error != nil { return "exclamationmark.triangle.fill" }
        if task.isFinished { return "checkmark" }
        return "gearshape.2.fill"
    }

    @ViewBuilder
    private func statusLine(_ task: TaskState) -> some View {
        if task.error != nil {
            Text("Не удалось завершить")
        } else if task.isFinished {
            Text("Операция завершена")
        } else {
            let state = cancelRequestedFor == task.id ? String(localized: "Отменяю…") : String(localized: "Выполняется")
            TimelineView(.periodic(from: task.started, by: 1)) { context in
                Text(state + " · " + TaskProgressSheet.elapsed(from: task.started, to: context.date))
            }
        }
    }

    // MARK: Progress

    private func progressBlock(_ task: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if task.isFinished {
                ProgressView(value: 1.0)
            } else if let fraction = task.fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(task.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let fraction = task.fraction, !task.isFinished {
                    Text(min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0))))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Error

    @ViewBuilder
    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Операция не выполнена", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(Color.red)
            if error.count > 400 {
                ScrollView {
                    Text(error)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            } else {
                Text(error)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Log

    private func logBlock(_ task: TaskState) -> some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if task.log.isEmpty {
                            Text("Пока пусто")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(TaskProgressSheet.visibleLog(task.log))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(TaskProgressSheet.bottomAnchor)
                    }
                    .padding(10)
                }
                .frame(height: 220)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onAppear {
                    proxy.scrollTo(TaskProgressSheet.bottomAnchor, anchor: .bottom)
                }
                .onChange(of: task.log.utf8.count) { _, _ in
                    proxy.scrollTo(TaskProgressSheet.bottomAnchor, anchor: .bottom)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Журнал")
                    .font(.callout.weight(.medium))
                if !task.log.isEmpty {
                    Text(TaskProgressSheet.lineCountText(task.log))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Buttons

    private func buttons(_ task: TaskState) -> some View {
        HStack(spacing: 10) {
            Button {
                copyLog(task)
            } label: {
                Label(didCopy ? "Скопировано" : "Копировать журнал",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(task.log.isEmpty && task.error == nil)
            .help("Скопировать журнал операции в буфер обмена")

            Spacer()

            if !task.isFinished {
                Button("Отменить") {
                    cancelRequestedFor = task.id
                    model.cancelTask()
                }
                .disabled(cancelRequestedFor == task.id)
                .help("Остановить операцию. Уже запущенный установщик Windows может продолжить работу сам.")
            }

            Button("Закрыть") {
                model.dismissTask()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!task.isFinished)
        }
    }

    private func copyLog(_ task: TaskState) {
        var text = task.title + "\n"
        if let error = task.error {
            text += String(localized: "Ошибка: \(error)") + "\n"
        }
        if !task.log.isEmpty {
            text += "\n" + task.log
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = true
        let id = task.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if model.activeTask?.id == id || model.activeTask == nil { didCopy = false }
        }
    }

    // MARK: Helpers

    static func visibleLog(_ log: String) -> String {
        guard log.utf8.count > visibleLogLimit else { return log }
        return "…\n" + String(log.suffix(visibleLogLimit))
    }

    static func lineCountText(_ log: String) -> String {
        let lines = log.split(whereSeparator: { $0.isNewline }).count
        return String(localized: "\(lines) строк")
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
