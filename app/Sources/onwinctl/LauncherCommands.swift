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
        fail("в пространстве «\(b.name)» нет программы «\(query)». Список: onwinctl programs \(b.name)")
    }
    return found
}

func launcherCommand(_ command: String, _ arguments: [String]) async throws {
    var args = arguments
    let root = option("--dir", in: &args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? LauncherBuilder.defaultRoot

    switch command {
    case "pin":
        guard args.count >= 2 else { fail("использование: onwinctl pin <пространство> <путь> [имя]") }
        var b = space(args[0])
        let path = args[1]
        let windowsPath: String
        if path.count >= 2, path[path.index(after: path.startIndex)] == ":" {
            windowsPath = path
        } else {
            windowsPath = b.windowsPath(forUnixPath: URL(fileURLWithPath: path))
        }
        guard let unix = b.unixPath(forWindowsPath: windowsPath), OnwinPaths.exists(unix) else {
            fail("файл не найден: \(windowsPath)")
        }
        if let existing = b.config.programs.first(where: { $0.windowsPath.caseInsensitiveCompare(windowsPath) == .orderedSame }) {
            print("Уже закреплена: \(existing.name)\t\(existing.id.uuidString)")
            return
        }
        let name = args.count > 2 ? args[2] : unix.deletingPathExtension().lastPathComponent
        let entry = ProgramEntry(name: name, windowsPath: windowsPath)
        b.config.programs.append(entry)
        try b.save()
        print("Закреплена: \(name)\t\(entry.id.uuidString)")

    case "unpin":
        guard args.count >= 2 else { fail("использование: onwinctl unpin <пространство> <программа>") }
        var b = space(args[0])
        let program = findProgram(args[1], in: b)
        guard case .pinned(let entryID) = program.source else { fail("«\(program.name)» не закреплена") }
        b.config.programs.removeAll { $0.id == entryID }
        try b.save()
        print("Откреплена: \(program.name)")

    case "launcher":
        guard args.count >= 2 else { fail("использование: onwinctl launcher <пространство> <программа> [--dir папка]") }
        let b = space(args[0])
        let program = findProgram(args[1], in: b)
        let app = try LauncherBuilder.create(for: program, in: b, root: root)
        print("Ярлык: \(app.path)")

    case "launcher-remove":
        guard args.count >= 2 else { fail("использование: onwinctl launcher-remove <пространство> <программа> [--dir папка]") }
        let b = space(args[0])
        let program = findProgram(args[1], in: b)
        guard let launcher = LauncherBuilder.launcher(for: program, in: b, root: root) else {
            fail("у программы «\(program.name)» нет ярлыка в \(root.path)")
        }
        try LauncherBuilder.remove(launcher)
        print("Ярлык перемещён в корзину: \(launcher.url.path)")

    case "launchers":
        let list = args.first.map { LauncherBuilder.launchers(for: space($0).id, root: root) } ?? LauncherBuilder.launchers(root: root)
        if list.isEmpty { print("Ярлыков нет (\(root.path))") }
        for l in list {
            print("\(l.name)\t\(l.isAutomatic ? "авто" : "вручную")\t\(l.url.path)")
        }

    case "launchers-sync":
        guard let name = args.first(where: { !$0.hasPrefix("--") }) else {
            fail("использование: onwinctl launchers-sync <пространство> [--rescan] [--dir папка]")
        }
        let b = space(name)
        if !b.config.autoLaunchers {
            print("В пространстве «\(b.name)» выключено «Создавать ярлыки автоматически» (onwinctl set \(b.name) launchers on): только перенос ярлыков")
        }
        if args.contains("--rescan") {
            print("winemenubuilder --cx-all-menus…")
            try await StartMenuHook.rescan(b)
        }
        let result = LauncherBuilder.sync(b, root: root)
        for url in result.created { print("создан: \(url.path)") }
        for url in result.removed { print("удалён: \(url.path)") }
        for url in result.moved { print("перенесён: \(url.path)") }
        for error in result.errors { print("ошибка: \(error)") }
        if !result.changed && result.errors.isEmpty { print("Ярлыки в порядке") }

    case "open-url":
        guard let text = args.first, let url = URL(string: text), let request = LaunchRequest(url: url) else {
            fail("использование: onwinctl open-url 'onwin://run?space=<id>&program=<id>'")
        }
        let (b, program) = try request.resolve()
        let runner = try WineRunner(space: b)
        let result = try await ProcessRunner.run(runner.engine.wine,
                                                 arguments: WineRunner.command(for: program.launchFile, arguments: program.arguments),
                                                 environment: runner.environment(extraEnvironment: program.environment),
                                                 currentDirectory: program.launchFile.deletingLastPathComponent(),
                                                 onOutput: { print($0, terminator: "") })
        exit(result.status)

    default:
        fail("неизвестная команда \(command)")
    }
}
