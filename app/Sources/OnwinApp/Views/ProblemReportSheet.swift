import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OnwinCore

// «Сообщить о проблеме»: collects diagnostics (OnwinCore/ProblemReport.swift, personal data removed),
// copies them and opens the support chat (OnwinLinks.supportChat), or saves them to a file.
//
// Entry points: Help menu (OnwinCommands), the error alert (ShellAlerts), the log viewer (LogsView),
// «Запущено» rows of failed programs (RunningProgramsView), the "still does not start" sheet
// (AutoComponentsNoticeSheet) and the failure banner on the space page (ComponentSuggestionsBanner).
//
//   AppModel.reportProblem(space:log:program:error:exitStatus:)   open the sheet for a run / space
//   AppModel.reportProblem(for program: RunningProgram)
//   AppModel.reportProblemFromMenu()                              selected space and its newest log
// The sheet is attached by `.onwinProblemReport()` (OnwinApp.swift).

/// What the sheet describes.
struct ProblemReportRequest: Identifiable {
    let id = UUID()
    var spaceID: UUID?
    var logURL: URL?
    /// Program file (name or path; only the name goes into the report).
    var programFile: String?
    var programTitle: String?
    var errorMessage: String?
    var exitStatus: Int32?
}

@MainActor
@Observable
final class ProblemReporter {
    static let shared = ProblemReporter()

    var request: ProblemReportRequest?

    /// Opens the sheet a moment later, so an alert or sheet that asked for it can close first
    /// (SwiftUI shows only one modal at a time).
    func present(_ request: ProblemReportRequest) {
        self.request = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.request = request
        }
    }
}

extension AppModel {
    func reportProblem(space: Space? = nil, log: URL? = nil, program: String? = nil, title: String? = nil,
                       error: String? = nil, exitStatus: Int32? = nil) {
        let resolvedSpace = space ?? log.flatMap { ProblemReport.space(forLog: $0) }
        ProblemReporter.shared.present(ProblemReportRequest(spaceID: resolvedSpace?.id, logURL: log, programFile: program,
                                                            programTitle: title, errorMessage: error,
                                                            exitStatus: exitStatus))
    }

    func reportProblem(for program: RunningProgram) {
        let file = ProblemReport.programFile(inCommand: "command: wine " + program.command.joined(separator: " "))
        reportProblem(space: space(id: program.spaceID), log: program.logURL, program: file, title: program.title,
                      exitStatus: program.exitStatus)
    }

    /// Help menu: the selected space (if any) and its newest run log.
    func reportProblemFromMenu() {
        guard let space = selectedSpace else {
            reportProblem()
            return
        }
        // A program of this space started from onwin knows its exit code.
        if let last = ProcessTracker.shared.programs.last(where: { $0.spaceID == space.id }),
           last.logURL == ProblemReport.latestLog(in: space) {
            reportProblem(for: last)
        } else {
            reportProblem(space: space, log: ProblemReport.latestLog(in: space))
        }
    }
}

extension View {
    /// Presents «Сообщить о проблеме» whenever `ProblemReporter.shared.request` is set.
    func onwinProblemReport() -> some View {
        modifier(ProblemReportPresenter())
    }
}

@MainActor
private struct ProblemReportPresenter: ViewModifier {
    @Bindable private var reporter = ProblemReporter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $reporter.request) { request in
            ProblemReportSheet(request: request)
                .environment(AppModel.shared)
                .tint(OnwinTheme.accent)
        }
    }
}

@MainActor
struct ProblemReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: ProblemReportRequest

    @State private var userText = ""
    @State private var includeLog = true
    /// Space picked in the sheet (nil = none); starts as the request's space.
    @State private var spaceID: UUID?
    @State private var logURL: URL?
    @State private var preview = ""
    @State private var isBuilding = true
    @State private var copied = false
    @State private var didSetUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Что случилось?")
                    .font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $userText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 76)
                    if userText.isEmpty {
                        Text("Например: игра запускается, но окно чёрное; после «Играть» в Steam ничего не происходит…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                Text("Необязательно, но так помочь будет проще.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Picker("Пространство:", selection: $spaceID) {
                    Text("Не выбрано").tag(UUID?.none)
                    ForEach(model.spaces) { space in
                        Text(verbatim: space.name).tag(Optional(space.id))
                    }
                }
                .fixedSize()
                Toggle(isOn: $includeLog) {
                    Text(logToggleTitle)
                }
                .toggleStyle(.checkbox)
                .disabled(logURL == nil)
                .help(logURL.map { ProblemReport.redact($0.lastPathComponent) } ?? "У этого пространства пока нет журналов")
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Что будет отправлено")
                        .font(.headline)
                    if isBuilding { ProgressView().controlSize(.small) }
                    Spacer()
                }
                ScrollView {
                    Text(verbatim: preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                Text("Имя пользователя, домашняя папка, имя компьютера, адреса почты, данные Steam и пароли из журнала убраны. Перед отправкой текст можно проверить.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if copied { copiedHint }

            HStack(spacing: 10) {
                Button("Сохранить в файл…") {
                    save()
                }
                .disabled(isBuilding)
                Spacer()
                Button(copied ? "Готово" : "Отмена", role: copied ? nil : .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    copyAndOpenChat()
                } label: {
                    Label(copied ? "Скопировать ещё раз" : "Скопировать и открыть чат поддержки",
                          systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBuilding)
            }
        }
        .padding(22)
        .frame(width: 640, height: 640)
        .onAppear(perform: setUp)
        .onChange(of: spaceID) { _, newValue in
            // Another space: its newest log (the request's own log belongs to the request's space).
            guard didSetUp else { return }
            if newValue == request.spaceID, request.logURL != nil {
                logURL = request.logURL
            } else {
                logURL = newValue.flatMap { model.space(id: $0) }.flatMap { ProblemReport.latestLog(in: $0) }
            }
        }
        .task(id: buildKey) {
            await rebuild()
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "ladybug.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.orange))
            VStack(alignment: .leading, spacing: 4) {
                Text(request.programTitle.map { "Проблема с «\($0)»" } ?? "Сообщить о проблеме")
                    .font(.title3.weight(.semibold))
                Text("onwin соберёт сведения о Mac, движке и настройках пространства. Вы скопируете их одной кнопкой и вставите в чат поддержки.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var copiedHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Текст скопирован — вставьте его в чат (⌘V) и при желании приложите скриншот.")
                if !OnwinLinks.hasSupportChat {
                    Text("Чат поддержки скоро появится — пока открыта страница с советами на сайте onwin. Текст можно сохранить в файл и отправить позже.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var logToggleTitle: String {
        guard let logURL else { return "Приложить последний журнал запуска (журналов нет)" }
        let title = LogsFileReader.displayTitle(for: logURL)
        return "Приложить последний журнал запуска (\(ProblemReport.redact(title)))"
    }

    // MARK: Building

    private func setUp() {
        guard !didSetUp else { return }
        spaceID = request.spaceID
        logURL = request.logURL
        didSetUp = true
    }

    private var buildKey: String {
        "\(spaceID?.uuidString ?? "-")|\(logURL?.path ?? "-")|\(includeLog)|\(userText)"
    }

    private var subject: ProblemReport.Subject {
        let space = spaceID.flatMap { model.space(id: $0) }
        let sameRun = logURL == request.logURL && logURL != nil
        return ProblemReport.Subject(space: space,
                                     logURL: logURL,
                                     programFile: sameRun ? request.programFile : nil,
                                     errorMessage: request.errorMessage,
                                     exitStatus: sameRun ? request.exitStatus : nil)
    }

    private func rebuild() async {
        guard didSetUp else { return }
        // Typing: wait for a pause before re-reading the log.
        if !preview.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
        }
        isBuilding = true
        let subject = subject
        let text = userText
        let attach = includeLog && logURL != nil
        let result = await Task.detached(priority: .userInitiated) {
            ProblemReport.build(subject, userText: text, includeLog: attach)
        }.value
        if Task.isCancelled { return }
        preview = result
        isBuilding = false
    }

    // MARK: Actions

    private func copyAndOpenChat() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(preview, forType: .string)
        NSWorkspace.shared.open(OnwinLinks.supportDestination)
        copied = true
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "Сохранить отчёт о проблеме"
        panel.message = "Текстовый файл можно отправить в чат поддержки или приложить к письму"
        panel.prompt = "Сохранить"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "onwin-отчёт-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preview.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.report(error)
        }
    }
}
