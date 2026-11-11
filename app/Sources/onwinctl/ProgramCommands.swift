import Foundation
import OnwinCore

// Steam, uninstall and "run with options" commands of onwinctl (see `programCommandsUsage`).
// main.swift hands unknown commands to `runProgramCommand`.

let programCommandsUsage = """

Steam, удаление программ, запуск с параметрами:
  onwinctl steam-games <пространство>      игры Steam в пространстве (appmanifest_*.acf)
  onwinctl steam-launch <пространство> <appid|название> [аргументы...]  steam.exe -applaunch <appid>
  onwinctl steam-install <пространство> <appid> открыть steam://install/<appid> в Steam пространства
  onwinctl vdf <файл.vdf|.acf> [ключ/ключ...]   разобрать файл Valve KeyValues (проверка)
  onwinctl uninstall-list <пространство>   программы из реестра (…\\CurrentVersion\\Uninstall)
  onwinctl uninstall <пространство> <название|ключ> [--quiet] [--dry-run]
                                           запустить удаление; --quiet — тихо (QuietUninstallString, msiexec /qn)
  onwinctl run-command <пространство> [--backend b] [--hud on|off] [--no-avx] [--avx] [--winedebug каналы]
                       [--env ИМЯ=ЗНАЧЕНИЕ]... [--dry-run] <командная строка Windows>
                                           выполнить команду с параметрами одного запуска и ждать
  onwinctl reboot <пространство>           «перезагрузить Windows» (wineboot --restart)
"""

/// Runs a command from this file; false when `command` is not one of them.
func runProgramCommand(_ command: String, _ args: [String]) async throws -> Bool {
    switch command {
    case "steam-games":
        guard let name = args.first else { fail("укажите пространство") }
        let b = space(name)
        guard let steam = Steam.installation(in: b) else { print("В пространстве «\(b.name)» нет Steam"); return true }
        print("Steam: \(steam.root.path)")
        for lib in Steam.libraryFolders(of: steam, in: b) { print("Библиотека: \(lib.path)") }
        let games = Steam.games(of: steam, in: b)
        if games.isEmpty { print("Установленных игр нет") }
        for g in games {
            let state = g.isBusy ? (g.isFullyInstalled ? "нужно обновление (StateFlags \(g.stateFlags))" : "загружается (StateFlags \(g.stateFlags))") : "установлена"
            print("\(g.appID)\t\(g.name)\t\(state)\t\(g.installDirectory.path)")
        }

    case "steam-launch":
        guard args.count >= 2 else { fail("использование: onwinctl steam-launch <пространство> <appid|название>") }
        let b = space(args[0])
        guard let steam = Steam.installation(in: b) else { fail("в пространстве «\(b.name)» нет Steam") }
        let games = Steam.games(of: steam, in: b)
        guard let game = Int(args[1]).flatMap({ id in games.first { $0.appID == id } })
                ?? games.first(where: { $0.name.localizedCaseInsensitiveContains(args[1]) }) else {
            fail("нет игры «\(args[1])». Список: onwinctl steam-games \(b.name)")
        }
        let program = try await MainActor.run {
            try WineRunner(space: b).launch(wineArguments: Steam.launchArguments(for: game.appID, steam: steam,
                                                                                  extra: Array(args.dropFirst(2))),
                                             title: game.name, workingDirectory: steam.root)
        }
        print("Запущено через Steam: \(game.name) (\(game.appID)). Журнал: \(await program.logURL.path)")

    case "steam-install":
        guard args.count >= 2, let appID = Int(args[1]) else { fail("использование: onwinctl steam-install <пространство> <appid>") }
        let program = try await Steam.requestInstall(appID: appID, name: "App \(appID)", in: space(args[0]), progress: printProgress)
        print("Журнал: \(await program.logURL.path)")

    case "vdf":
        guard let path = args.first else { fail("укажите файл") }
        var node = try KeyValues.parse(contentsOf: URL(fileURLWithPath: path))
        for key in args.dropFirst().flatMap({ $0.split(separator: "/").map(String.init) }) {
            guard let next = node[key] else { fail("нет ключа «\(key)»") }
            node = next
        }
        printKeyValues(node, indent: 0)

    case "uninstall-list":
        guard let name = args.first else { fail("укажите пространство") }
        let apps = UninstallRegistry.applications(in: space(name))
        if apps.isEmpty { print("Программ для удаления нет") }
        for a in apps {
            var line = "\(a.displayName)"
            if let v = a.displayVersion { line += " \(v)" }
            line += "\t[\(a.scope.displayName)] \(a.keyName)"
            print(line)
            if let p = a.publisher { print("    издатель: \(p)") }
            if a.isWindowsInstaller { print("    MSI: msiexec /x \(a.keyName)") }
            if let u = a.uninstallString { print("    UninstallString: \(u)") }
            if let q = a.quietUninstallString { print("    QuietUninstallString: \(q)") }
        }

    case "uninstall":
        var rest = args
        let quiet = rest.contains("--quiet"), dryRun = rest.contains("--dry-run")
        rest.removeAll { $0 == "--quiet" || $0 == "--dry-run" }
        guard rest.count >= 2 else { fail("использование: onwinctl uninstall <пространство> <название|ключ> [--quiet] [--dry-run]") }
        let b = space(rest[0])
        let query = rest.dropFirst().joined(separator: " ")
        let matches = UninstallRegistry.find(query, in: UninstallRegistry.applications(in: b))
        guard let app = matches.first else { fail("нет программы «\(query)». Список: onwinctl uninstall-list \(b.name)") }
        if matches.count > 1, !matches.allSatisfy({ $0.displayName == app.displayName }) {
            fail("«\(query)» подходит к нескольким программам: \(matches.map(\.displayName).joined(separator: ", "))")
        }
        if quiet && !UninstallRegistry.canUninstallQuietly(app) {
            fail("у «\(app.displayName)» нет тихого удаления (QuietUninstallString); без --quiet откроется окно деинсталлятора")
        }
        guard let wineArgs = UninstallRegistry.command(for: app, quiet: quiet, in: b) else {
            fail("не удалось разобрать команду удаления «\(app.uninstallString ?? "")»")
        }
        print("Удаляю «\(app.displayName)»: wine \(WindowsCommandLine.join(wineArgs))")
        if dryRun { return true }
        let runner = try WineRunner(space: b)
        let r = try await runner.runAndWait(wineArgs, onOutput: { print($0, terminator: "") })
        try await runner.waitForServer()   // wineserver writes the registry files when it exits
        let still = UninstallRegistry.applications(in: b).contains { $0.id == app.id }
        print(still ? "Код \(r.status); запись в реестре осталась (удаление отменено или не завершено)"
                    : "Код \(r.status); «\(app.displayName)» удалена")
        exit(r.status)

    case "run-command":
        var rest = args
        var overrides = RunOverrides()
        var env: [String: String] = [:]
        if let v = option("--backend", in: &rest) {
            guard let b = GraphicsBackend(rawValue: v) else { fail("backend: auto|d3dmetal|dxmt|dxvk|wined3d") }
            overrides.graphicsBackend = b
        }
        if let v = option("--hud", in: &rest) { overrides.metalHUD = parseBool(v) }
        if let v = option("--winedebug", in: &rest) { overrides.wineDebug = v }
        while let pair = option("--env", in: &rest) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { fail("--env ИМЯ=ЗНАЧЕНИЕ") }
            env[parts[0]] = parts[1]
        }
        if rest.contains("--no-avx") { overrides.advertiseAVX = false }
        if rest.contains("--avx") { overrides.advertiseAVX = true }
        let dryRun = rest.contains("--dry-run")
        rest.removeAll { ["--no-avx", "--avx", "--dry-run"].contains($0) }
        guard rest.count >= 2 else { fail("использование: onwinctl run-command <пространство> [параметры] <командная строка>") }
        let b = space(rest[0]).applying(overrides)
        let line = rest.dropFirst().joined(separator: " ")
        guard let resolved = WindowsCommandLine.resolve(line, in: b) else { fail("пустая команда") }
        let wineArgs = resolved.unixPath.map { WineRunner.command(for: $0, arguments: resolved.arguments) } ?? resolved.wineArguments
        let runner = try WineRunner(space: b)
        if dryRun {
            print("wine \(WindowsCommandLine.join(wineArgs))")
            if let u = resolved.unixPath { print("файл: \(u.path)") }
            for (k, v) in runner.environment(extraEnvironment: env).sorted(by: { $0.key < $1.key })
            where k.hasPrefix("WINEDEBUG") || k.hasPrefix("ONWIN") || k.hasPrefix("MTL") || k.hasPrefix("ROSETTA") ||
                  k.hasPrefix("DXVK") || k.hasPrefix("D3DM") || env[k] != nil {
                print("\(k)=\(v)")
            }
            return true
        }
        // Same as `runAndWait`, but with this run's variables.
        runner.prepareProfileFolders()
        let r = try await ProcessRunner.run(runner.engine.wine, arguments: wineArgs,
                                            environment: runner.environment(extraEnvironment: env),
                                            currentDirectory: resolved.unixPath?.deletingLastPathComponent()
                                                ?? (OnwinPaths.isDirectory(b.driveC) ? b.driveC : b.url),
                                            onOutput: { print($0, terminator: "") })
        exit(r.status)

    case "reboot":
        guard let name = args.first else { fail("укажите пространство") }
        let runner = try WineRunner(space: space(name))
        let r = try await runner.runAndWait(["wineboot", "--restart"], onOutput: { print($0, terminator: "") })
        print("wineboot --restart: код \(r.status)")

    default:
        return false
    }
    return true
}

func printKeyValues(_ node: KeyValues, indent: Int) {
    let pad = String(repeating: "  ", count: indent)
    switch node {
    case .string(let s): print("\(pad)\(s)")
    case .section(let entries):
        for e in entries {
            switch e.value {
            case .string(let s): print("\(pad)\(e.key) = \(s)")
            case .section:
                print("\(pad)\(e.key) {")
                printKeyValues(e.value, indent: indent + 1)
                print("\(pad)}")
            }
        }
    }
}
