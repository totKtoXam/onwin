import Foundation
import OnwinCore

// onwinctl pin / launcher / launcher-remove / launchers / launchers-sync / open-url.
// Dispatched from main.swift; `fail`, `space` and `option` live there.

/// A program of the space by id, name (case-insensitive) or path of its file.
func findProgram(_ query: String, in b: Space) -> SpaceProgram {
    let list = ProgramScanner.programs(in: b)
    let unix = query.contains(":\\") ? b.unixPath(forWindowsPath: query) : URL(fileURLWithPath: query)
    let found = list.first { $0.id == query }
        ?? list.first { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
        ?? list.first { p in
            guard let unix else { return false }
            return [p.launchFile, p.executable].compactMap { $0?.standardizedFileURL.path.lowercased() }
                .contains(unix.standardizedFileURL.path.lowercased())
        }
    guard let found else {
        fail(String(localized: "в пространстве «\(b.name)» нет программы «\(query)». Список: onwinctl programs \(b.name)", bundle: .onwinctl))
    }
    return found
}

func launcherCommand(_ command: String, _ arguments: [String]) async throws {
    var args = arguments
    let root = option("--dir", in: &args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? LauncherBuilder.defaultRoot

    switch command {
    case "pin":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl pin <пространство> <путь> [имя]", bundle: .onwinctl)) }
        var b = space(args[0])
        let path = args[1]
        let windowsPath: String
        if path.count >= 2, path[path.index(after: path.startIndex)] == ":" {
            windowsPath = path
        } else {
            windowsPath = b.windowsPath(forUnixPath: URL(fileURLWithPath: path))
        }
        guard let unix = b.unixPath(forWindowsPath: windowsPath), OnwinPaths.exists(unix) else {
            fail(String(localized: "файл не найден: \(windowsPath)", bundle: .onwinctl))
        }
        if let existing = b.config.programs.first(where: { $0.windowsPath.caseInsensitiveCompare(windowsPath) == .orderedSame }) {
            print(String(localized: "Уже закреплена: \(existing.name)\t\(existing.id.uuidString)", bundle: .onwinctl))
            return
        }
        let name = args.count > 2 ? args[2] : unix.deletingPathExtension().lastPathComponent
        let entry = ProgramEntry(name: name, windowsPath: windowsPath)
        b.config.programs.append(entry)
        try b.save()
        print(String(localized: "Закреплена: \(name)\t\(entry.id.uuidString)", bundle: .onwinctl))

    case "unpin":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl unpin <пространство> <программа>", bundle: .onwinctl)) }
        var b = space(args[0])
        let program = findProgram(args[1], in: b)
        guard case .pinned(let entryID) = program.source else { fail(String(localized: "«\(program.name)» не закреплена", bundle: .onwinctl)) }
        b.config.programs.removeAll { $0.id == entryID }
        try b.save()
        print(String(localized: "Откреплена: \(program.name)", bundle: .onwinctl))

    case "launcher":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl launcher <пространство> <программа> [--dir папка]", bundle: .onwinctl)) }
        let b = space(args[0])
        let program = findProgram(args[1], in: b)
        let app = try LauncherBuilder.create(for: program, in: b, root: root)
        print(String(localized: "Ярлык: \(app.path)", bundle: .onwinctl))

    case "launcher-remove":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl launcher-remove <пространство> <программа> [--dir папка]", bundle: .onwinctl)) }
        let b = space(args[0])
        let program = findProgram(args[1], in: b)
        guard let launcher = LauncherBuilder.launcher(for: program, in: b, root: root) else {
            fail(String(localized: "у программы «\(program.name)» нет ярлыка в \(root.path)", bundle: .onwinctl))
        }
        try LauncherBuilder.remove(launcher)
        print(String(localized: "Ярлык перемещён в корзину: \(launcher.url.path)", bundle: .onwinctl))

    case "launchers":
        let list = args.first.map { LauncherBuilder.launchers(for: space($0).id, root: root) } ?? LauncherBuilder.launchers(root: root)
        if list.isEmpty { print(String(localized: "Ярлыков нет (\(root.path))", bundle: .onwinctl)) }
        let automatic = String(localized: "авто", bundle: .onwinctl, comment: "The shortcut was made automatically")
        let manual = String(localized: "вручную", bundle: .onwinctl, comment: "The shortcut was made by the user")
        for l in list {
            print("\(l.name)\t\(l.isAutomatic ? automatic : manual)\t\(l.url.path)")
        }

    case "launchers-sync":
        guard let name = args.first(where: { !$0.hasPrefix("--") }) else {
            fail(String(localized: "использование: onwinctl launchers-sync <пространство> [--rescan] [--dir папка]", bundle: .onwinctl))
        }
        let b = space(name)
        if !b.config.autoLaunchers {
            print(String(localized: "В пространстве «\(b.name)» выключено «Создавать ярлыки автоматически» (onwinctl set \(b.name) launchers on): только перенос ярлыков", bundle: .onwinctl))
        }
        if args.contains("--rescan") {
            print("winemenubuilder --cx-all-menus…")
            try await StartMenuHook.rescan(b)
        }
        let result = LauncherBuilder.sync(b, root: root)
        for url in result.created { print(String(localized: "создан: \(url.path)", bundle: .onwinctl, comment: "A shortcut was created")) }
        for url in result.removed { print(String(localized: "удалён: \(url.path)", bundle: .onwinctl, comment: "A shortcut was removed")) }
        for url in result.moved { print(String(localized: "перенесён: \(url.path)", bundle: .onwinctl, comment: "A shortcut was moved")) }
        for error in result.errors { print(String(localized: "ошибка: \(error)", bundle: .onwinctl)) }
        if !result.changed && result.errors.isEmpty { print(String(localized: "Ярлыки в порядке", bundle: .onwinctl)) }

    case "open-url":
        guard let text = args.first, let url = URL(string: text), let request = LaunchRequest(url: url) else {
            fail(String(localized: "использование: onwinctl open-url 'onwin://run?space=<id>&program=<id>'", bundle: .onwinctl))
        }
        let (b, program) = try request.resolve()
        let runner = try WineRunner(space: b)
        runner.prepareProfileFolders()
        let result = try await ProcessRunner.run(runner.engine.wine,
                                                 arguments: WineRunner.command(for: program.launchFile, arguments: program.arguments),
                                                 environment: runner.environment(extraEnvironment: program.environment),
                                                 currentDirectory: program.launchFile.deletingLastPathComponent(),
                                                 onOutput: { print($0, terminator: "") })
        exit(result.status)

    default:
        fail(String(localized: "неизвестная команда \(command)", bundle: .onwinctl))
    }
}
