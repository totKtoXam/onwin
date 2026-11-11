import AppKit
import SwiftUI
import OnwinCore

// Run logs written by WineRunner.launch into ~/Library/Logs/onwin/<space>/<date> <title>.log.
// `LogsView(spaceID: nil)` shows every space's logs grouped by space; with an id, only that space's.
// Only the last ~2 MB of a log are loaded (Wine debug output can grow to hundreds of megabytes).

/// One log file on disk.
struct LogsEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let folder: String
    let modified: Date
    let size: Int64

    var id: URL { url }
}

/// Logs of one folder (one space).
struct LogsGroup: Identifiable, Sendable {
    let name: String
    let entries: [LogsEntry]

    var id: String { name }
}

/// The loaded tail of a log file.
struct LogsLoadedText: Sendable {
    let url: URL
    let text: String
    let fileSize: UInt64
    let isTruncated: Bool
    let errorMessage: String?
}

/// File-system work for LogsView; safe to call from any thread.
enum LogsFileReader {
    static let tailLimit = 2 * 1024 * 1024
    static let logExtensions: Set<String> = ["log", "txt"]

    /// Folders to show: every space folder under the logs root (and the root itself for loose files),
    /// or only the folder(s) belonging to one space.
    static func folders(forSpaceNamed spaceName: String?, logDirectory: URL?) -> [URL] {
        let root = OnwinPaths.logs
        let subdirectories = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { OnwinPaths.isDirectory($0) }

        guard let spaceName else { return [root] + subdirectories }

        var result: [URL] = []
        if let logDirectory { result.append(logDirectory) }
        // The folder name is derived from the space name; match it loosely as well.
        for dir in subdirectories where dir.lastPathComponent.caseInsensitiveCompare(spaceName) == .orderedSame {
            if !result.contains(where: { $0.standardizedFileURL.path == dir.standardizedFileURL.path }) {
                result.append(dir)
            }
        }
        return result
    }

    static func scan(folders: [URL]) -> [LogsGroup] {
        let root = OnwinPaths.logs.standardizedFileURL.path
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var groups: [LogsGroup] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])) ?? []
            let name = folder.standardizedFileURL.path == root ? "Общие" : folder.lastPathComponent
            var entries: [LogsEntry] = []
            for file in files where logExtensions.contains(file.pathExtension.lowercased()) {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == false { continue }
                entries.append(LogsEntry(url: file,
                                         title: displayTitle(for: file),
                                         folder: name,
                                         modified: values?.contentModificationDate ?? .distantPast,
                                         size: Int64(values?.fileSize ?? 0)))
            }
            guard !entries.isEmpty else { continue }
            entries.sort { $0.modified > $1.modified }
            groups.append(LogsGroup(name: name, entries: entries))
        }
        groups.sort { ($0.entries.first?.modified ?? .distantPast) > ($1.entries.first?.modified ?? .distantPast) }
        return groups
    }

    /// "2026-11-11 10.20.30 Steam.log" → "Steam".
    static func displayTitle(for file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        let chars = Array(name)
        if chars.count > 20, chars[4] == "-", chars[7] == "-", chars[10] == " ",
           chars[13] == ".", chars[16] == ".", chars[19] == " " {
            return String(chars[20...])
        }
        return name
    }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Reads at most `limit` bytes from the end of the file.
    static func readTail(of url: URL, limit: Int = tailLimit) -> LogsLoadedText {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let start: UInt64 = size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let newline = text.firstIndex(where: { $0.isNewline }) {
                // Start at a line boundary instead of in the middle of a line.
                text = String(text[text.index(after: newline)...])
            }
            return LogsLoadedText(url: url, text: text, fileSize: size, isTruncated: start > 0, errorMessage: nil)
        } catch {
            return LogsLoadedText(url: url, text: "", fileSize: 0, isTruncated: false,
                             errorMessage: error.localizedDescription)
        }
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

@MainActor
struct LogsView: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID?

    @State private var groups: [LogsGroup] = []
    @State private var selectedURL: URL?
    @State private var loaded: LogsLoadedText?
    @State private var loadToken: UUID?
    @State private var version = 0
    @State private var follow = false
    @State private var didCopy = false

    var body: some View {
        let finishedCount = ProcessTracker.shared.programs.count - ProcessTracker.shared.running.count
        let startedCount = ProcessTracker.shared.programs.count

        HStack(spacing: 0) {
            sidebar
                .frame(width: 290)
            Divider()
            viewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            rescan()
        }
        .onChange(of: selectedURL) { _, _ in
            load()
        }
        .onChange(of: startedCount) { _, _ in
            rescan()
        }
        .onChange(of: finishedCount) { _, _ in
            rescan()
            load()
        }
        .task(id: followKey) {
            await followSelectedLog()
        }
    }

    // MARK: Data

    private var space: Space? {
        spaceID.flatMap { model.space(id: $0) }
    }

    private var entries: [LogsEntry] {
        groups.flatMap(\.entries)
    }

    private var selectedEntry: LogsEntry? {
        guard let selectedURL else { return nil }
        return entries.first { $0.url == selectedURL }
    }

    private var runningLogPaths: Set<String> {
        Set(ProcessTracker.shared.running.map { $0.logURL.standardizedFileURL.path })
    }

    private var followKey: String {
        "\(follow)|\(selectedURL?.path ?? "")"
    }

    private func rescan() {
        let folders: [URL]
        if let spaceID {
            if let space = model.space(id: spaceID) {
                folders = LogsFileReader.folders(forSpaceNamed: space.name, logDirectory: space.logDirectory)
            } else {
                folders = []
            }
        } else {
            folders = LogsFileReader.folders(forSpaceNamed: nil, logDirectory: nil)
        }
        groups = LogsFileReader.scan(folders: folders)
        let all = entries
        if let selectedURL, all.contains(where: { $0.url == selectedURL }) { return }
        selectedURL = all.first?.url
        if selectedURL == nil { loaded = nil }
    }

    private func load() {
        guard let url = selectedURL else {
            loaded = nil
            loadToken = nil
            return
        }
        let token = UUID()
        loadToken = token
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LogsFileReader.readTail(of: url)
            }.value
            guard loadToken == token else { return }
            loaded = result
            version += 1
        }
    }

    /// While "Следить" is on, reloads the selected log whenever its size changes.
    private func followSelectedLog() async {
        guard follow, let url = selectedURL else { return }
        var lastSize = LogsFileReader.size(of: url)
        load()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }
            let size = LogsFileReader.size(of: url)
            if size != lastSize {
                lastSize = size
                load()
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.map { "Журналы «\($0.name)»" } ?? "Журналы")
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    rescan()
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить список")
                Button {
                    openLogsFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Открыть папку журналов в Finder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Журналов пока нет")
                        .font(.headline)
                    Text("Журнал появляется при каждом запуске программы в пространстве.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedURL) {
                    ForEach(groups) { group in
                        if spaceID == nil {
                            Section(group.name) {
                                rows(group)
                            }
                        } else {
                            rows(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func rows(_ group: LogsGroup) -> some View {
        let running = runningLogPaths
        ForEach(group.entries) { entry in
            LogsEntryRow(entry: entry, isRunning: running.contains(entry.url.standardizedFileURL.path))
                .contextMenu {
                    Button("Показать в Finder") {
                        model.revealInFinder(entry.url)
                    }
                    Button("Открыть в Консоли") {
                        model.open(entry.url)
                    }
                    Divider()
                    Button("Переместить в Корзину") {
                        moveToTrash(entry)
                    }
                    .disabled(running.contains(entry.url.standardizedFileURL.path))
                }
        }
    }

    private var countText: String {
        let count = entries.count
        if count == 0 { return "нет файлов" }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        return "\(count) " + CatalogView.plural(count, "файл", "файла", "файлов") +
            " · " + LogsFileReader.formattedSize(total)
    }

    private func openLogsFolder() {
        if let space, OnwinPaths.isDirectory(space.logDirectory) {
            model.open(space.logDirectory)
        } else {
            try? OnwinPaths.ensureLayout()
            model.open(OnwinPaths.logs)
        }
    }

    private func moveToTrash(_ entry: LogsEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        } catch {
            model.report(error)
        }
        if selectedURL == entry.url { selectedURL = nil }
        rescan()
    }

    // MARK: Viewer

    @ViewBuilder
    private var viewer: some View {
        if let entry = selectedEntry {
            VStack(spacing: 0) {
                viewerHeader(entry)
                Divider()
                viewerBody(entry)
            }
        } else if groups.isEmpty {
            ContentUnavailableView("Нет журналов",
                                   systemImage: "doc.text",
                                   description: Text("Запустите программу в пространстве — onwin запишет сюда всё, что выводит Wine."))
        } else {
            ContentUnavailableView("Выберите журнал", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func viewerHeader(_ entry: LogsEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if runningLogPaths.contains(entry.url.standardizedFileURL.path) {
                        OnwinRunningDot(size: 7)
                    }
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Toggle("Следить", isOn: $follow)
                .toggleStyle(.checkbox)
                .help("Обновлять журнал автоматически, пока программа пишет в него")

            Button {
                load()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .help("Перечитать файл")

            Button {
                copyLoadedText()
            } label: {
                Label(didCopy ? "Скопировано" : "Копировать", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(loaded?.url != entry.url || (loaded?.text.isEmpty ?? true))
            .help("Скопировать показанный текст журнала")

            Button {
                model.revealInFinder(entry.url)
            } label: {
                Label("В Finder", systemImage: "folder")
            }
            .help("Показать файл в Finder")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func subtitle(_ entry: LogsEntry) -> String {
        var parts: [String] = []
        if spaceID == nil { parts.append(entry.folder) }
        parts.append(entry.modified.formatted(date: .abbreviated, time: .standard))
        parts.append(LogsFileReader.formattedSize(entry.size))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func viewerBody(_ entry: LogsEntry) -> some View {
        if let loaded, loaded.url == entry.url {
            if let message = loaded.errorMessage {
                ContentUnavailableView("Не удалось открыть журнал",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            } else if loaded.text.isEmpty {
                ContentUnavailableView("Журнал пуст",
                                       systemImage: "doc",
                                       description: Text("Программа пока ничего не вывела."))
            } else {
                VStack(spacing: 0) {
                    if loaded.isTruncated {
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                            Text("Файл большой (\(LogsFileReader.formattedSize(Int64(loaded.fileSize)))) — " +
                                 "показаны последние \(LogsFileReader.formattedSize(Int64(LogsFileReader.tailLimit))).")
                            Spacer(minLength: 0)
                            Button("Открыть целиком") {
                                model.open(entry.url)
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.08))
                        Divider()
                    }
                    LogsTextView(text: loaded.text, fileURL: loaded.url, version: version)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copyLoadedText() {
        guard let loaded else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(loaded.text, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

@MainActor
struct LogsEntryRow: View {
    let entry: LogsEntry
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isRunning {
                    OnwinRunningDot(size: 6)
                }
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(entry.modified.formatted(date: .abbreviated, time: .shortened) + " · " +
                 LogsFileReader.formattedSize(entry.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(entry.url.lastPathComponent)
    }
}

/// Read-only, selectable, monospaced text view (AppKit, so multi-megabyte logs stay fast; ⌘F works).
struct LogsTextView: NSViewRepresentable {
    let text: String
    let fileURL: URL
    /// Changes whenever new text was loaded; the view only touches its text storage then.
    let version: Int

    final class Coordinator {
        var version = -1
        var fileURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.drawsBackground = true
            textView.backgroundColor = NSColor.textBackgroundColor
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.font = LogsTextView.font
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.version != version || coordinator.fileURL != fileURL else { return }

        let sameFile = coordinator.fileURL == fileURL
        let visible = scrollView.contentView.documentVisibleRect
        let wasAtBottom = visible.maxY >= textView.bounds.height - 40
        coordinator.version = version
        coordinator.fileURL = fileURL

        let attributes: [NSAttributedString.Key: Any] = [
            .font: LogsTextView.font,
            .foregroundColor: NSColor.textColor,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))

        if !sameFile || wasAtBottom {
            let length = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        }
    }

    static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}
