import Foundation
import ImageIO
import OnwinCore

// onwinctl icon — debug view of the icon pipeline (OnwinCore/AppIcons.swift). Dispatched from main.swift.

let iconCommandsUsage = String(localized: """
Значки (проверка):
  onwinctl icon <пространство|-> <программа|приложение|component:id|steam:appid> <файл.png> [--only exe|image|remote] [--cover]
                                           записать значок, который покажет onwin, в PNG и показать источники
""", bundle: .onwinctl)

/// Runs `onwinctl icon`; false for other commands.
func runIconCommand(_ command: String, _ arguments: [String]) async -> Bool {
    guard command == "icon" else { return false }
    var args = arguments
    let only = option("--only", in: &args)
    let cover = args.contains("--cover")
    args.removeAll { $0 == "--cover" }
    guard args.count == 3 else {
        fail(String(localized: "использование: onwinctl icon <пространство|-> <программа|приложение|component:id|steam:appid> <файл.png> [--only exe|image|remote]", bundle: .onwinctl))
    }
    let b: Space? = args[0] == "-" ? nil : space(args[0])
    let query = args[1]
    let output = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)

    let subject: AppIconSubject
    let lower = query.lowercased()
    if lower.hasPrefix("steam:"), let appID = Int(query.dropFirst(6)) {
        guard let b else { fail(String(localized: "для steam:<appid> нужно пространство со Steam", bundle: .onwinctl)) }
        subject = .steamGame(appID: appID, space: b, style: cover ? .cover : .icon)
    } else if lower.hasPrefix("component:") {
        guard let c = Catalog.component(String(query.dropFirst(10))) else { fail(String(localized: "нет компонента «\(query)»", bundle: .onwinctl)) }
        subject = .component(c)
    } else if lower.hasPrefix("recipe:") || lower.hasPrefix("app:") {
        let id = String(query[query.index(after: query.firstIndex(of: ":")!)...])
        guard let r = Catalog.app(id) else { fail(String(localized: "нет приложения «\(id)» в каталоге", bundle: .onwinctl)) }
        subject = .recipe(r, spaces: b.map { [$0] } ?? [])
    } else if let b, let program = lookupProgram(query, in: b) {
        subject = .program(program, space: b)
    } else if let r = Catalog.app(query) {
        subject = .recipe(r, spaces: b.map { [$0] } ?? [])
    } else if let c = Catalog.component(query) {
        subject = .component(c)
    } else {
        fail(String(localized: "«\(query)» — не программа пространства, не приложение и не компонент каталога", bundle: .onwinctl))
    }

    var sources = AppIcons.sources(for: subject)
    if let only {
        sources = sources.filter { source in
            switch source {
            case .executable: return only == "exe"
            case .image: return only == "image"
            case .remote: return only == "remote"
            }
        }
    }
    if sources.isEmpty { print(String(localized: "Источников нет — onwin нарисует значок SF Symbol", bundle: .onwinctl)) }
    for source in sources {
        let label: String
        switch source {
        case .executable(let url): label = String(localized: "значок exe/ico: \(url.path)", bundle: .onwinctl)
        case .image(let url): label = String(localized: "картинка: \(url.path)", bundle: .onwinctl)
        case .remote(let url): label = String(localized: "сайт разработчика: \(url.absoluteString)", bundle: .onwinctl)
        }
        guard let png = await AppIcons.pngData(for: .sources([source])) else {
            print("  ✗ \(label)")
            continue
        }
        print("  ✓ \(label)")
        do {
            try png.write(to: output, options: .atomic)
        } catch {
            fail(String(localized: "не удалось записать \(output.path): \(error.localizedDescription)", bundle: .onwinctl))
        }
        if let image = CGImageSourceCreateWithData(png as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
            print(String(localized: "Записано: \(output.path) (\(image.width)×\(image.height) px)", bundle: .onwinctl))
        } else {
            print(String(localized: "Записано: \(output.path)", bundle: .onwinctl))
        }
        print(String(localized: "Кэш значков: \(AppIcons.cacheDirectory.path)", bundle: .onwinctl))
        return true
    }
    fail(String(localized: "ни один источник не дал значка", bundle: .onwinctl))
}

/// A program of the space by id, name or file path; nil when there is none (no exit, unlike findProgram).
private func lookupProgram(_ query: String, in b: Space) -> SpaceProgram? {
    let list = ProgramScanner.programs(in: b)
    let unix = query.contains(":\\") ? b.unixPath(forWindowsPath: query)
        : (query.hasPrefix("/") ? URL(fileURLWithPath: query) : nil)
    return list.first { $0.id == query }
        ?? list.first { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
        ?? list.first { p in
            guard let unix else { return false }
            return [p.launchFile, p.executable].compactMap { $0?.standardizedFileURL.path.lowercased() }
                .contains(unix.standardizedFileURL.path.lowercased())
        }
}
