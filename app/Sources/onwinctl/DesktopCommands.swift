import Foundation
import OnwinCore

// onwinctl desktop — debug view of «Рабочий стол» (OnwinCore/DesktopCatalog.swift). Read-only: scans the
// spaces' programs and Steam libraries and lists the icon candidates without resolving (no cache writes).
// Dispatched from main.swift.

let desktopCommandsUsage = String(localized: """
Рабочий стол (проверка):
  onwinctl desktop [--hidden] [--all-sources]  все программы всех пространств, как их покажет «Рабочий стол»:
                                           имя | пространство | источник | источник значка (--hidden: и скрытые)
""", bundle: .onwinctl)

/// Runs `onwinctl desktop`; false for other commands.
func runDesktopCommand(_ command: String, _ arguments: [String]) -> Bool {
    guard command == "desktop" else { return false }
    let showHidden = arguments.contains("--hidden")
    let allSources = arguments.contains("--all-sources")
    let state = DesktopStore.load()
    let items = DesktopCatalog.items(spaces: SpaceManager.list())
    let shown = items.filter { showHidden || !state.hidden.contains($0.id) }

    func iconText(_ item: DesktopItem) -> String {
        let sources = AppIcons.sources(for: item.iconSubject)
        let described = sources.map(describe)
        guard !described.isEmpty else { return String(localized: "— (значок-заглушка \(item.placeholderSymbol))", bundle: .onwinctl) }
        return allSources ? described.joined(separator: " → ") : described[0]
    }

    let rows = shown.map { item -> [String] in
        var name = item.name
        if state.hidden.contains(item.id) { name += " " + String(localized: "(скрыта)", bundle: .onwinctl, comment: "The program is hidden from the desktop") }
        if let status = item.statusText { name += " [\(status)]" }
        return [name, item.spaceName, item.source.displayName, iconText(item)]
    }
    let header = [String(localized: "Программа", bundle: .onwinctl, comment: "Column header"),
                  String(localized: "Пространство", bundle: .onwinctl, comment: "Column header"),
                  String(localized: "Источник", bundle: .onwinctl, comment: "Column header: where the program was found"),
                  String(localized: "Значок", bundle: .onwinctl, comment: "Column header: where the icon comes from")]
    let widths = (0..<3).map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
    func line(_ row: [String]) -> String {
        (0..<3).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: " | ")
            + " | " + row[3]
    }
    print(line(header))
    print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-") + "-+-" + String(repeating: "-", count: 10))
    for row in rows { print(line(row)) }
    let hidden = items.count - shown.count
    let total = hidden > 0
        ? String(localized: "Всего: \(shown.count) (скрыто ещё \(hidden), --hidden — показать)", bundle: .onwinctl)
        : String(localized: "Всего: \(shown.count)", bundle: .onwinctl)
    print("\n\(total) · \(DesktopStore.file.path)")
    return true
}

private func describe(_ source: AppIconSource) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func short(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    switch source {
    case .executable(let url): return "exe: \(short(url))"
    case .image(let url): return "image: \(short(url))"
    case .remote(let url): return "remote: \(url.absoluteString)"
    }
}
