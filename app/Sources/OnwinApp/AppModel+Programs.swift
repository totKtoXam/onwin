import AppKit
import Foundation
import Observation
import OnwinCore

// Steam games, "Запустить с параметрами…", "Выполнить команду…" and removing programs
// (parity doc P1 #6, #7, #12). Views: SteamGamesSection.swift, RunOptionsSheet.swift, UninstallSheet.swift.
//
//   ProgramDialogs.shared.request = .runWithOptions(spaceID, .program(p))   presents the sheet
//   (the sheets are attached to SpaceDetailView with `.programDialogs(spaceID:)`)
//   AppModel.run(_ target: RunTarget, in:, request:) / runCommandLine(_:in:request:)
//   AppModel.launchSteamGame(_:in:) / openSteamURL(_:in:) / uninstall(_:quietly:in:)

/// What "Запустить с параметрами…" starts.
enum RunTarget: Hashable {
    case program(SpaceProgram)
    case steamGame(SteamGame)
    case file(URL)

    var title: String {
        switch self {
        case .program(let p): return p.name
        case .steamGame(let g): return g.name
        case .file(let url): return url.deletingPathExtension().lastPathComponent
        }
    }
}

/// Settings of one run chosen in the dialog.
struct RunRequest {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var overrides = RunOverrides()
    /// Non-nil: also pin the program with these settings under this name.
    var saveAs: String?
}

/// Which program dialog is shown (one at a time).
@MainActor
@Observable
final class ProgramDialogs {
    static let shared = ProgramDialogs()

    enum Request: Identifiable {
        case runWithOptions(UUID, RunTarget)
        case runCommand(UUID)
        case uninstall(UUID)

        var id: String {
            switch self {
            case .runWithOptions(let b, let t): return "run-\(b)-\(t.hashValue)"
            case .runCommand(let b): return "command-\(b)"
            case .uninstall(let b): return "uninstall-\(b)"
            }
        }

        var spaceID: UUID {
            switch self {
            case .runWithOptions(let b, _), .runCommand(let b), .uninstall(let b): return b
            }
        }
    }

    var request: Request?
}

extension AppModel {
    // MARK: Run with options

    @discardableResult
    func run(_ target: RunTarget, in space: Space, request: RunRequest) -> RunningProgram? {
        guard hasEngine else { report(AppModel.noEngineMessage); return nil }
        let current = self.space(id: space.id) ?? space
        // Programs and files: components first when needed (AppModel+AutoComponents.swift).
        let file: URL?
        switch target {
        case .program(let p): file = p.executable ?? p.launchFile
        case .file(let url): file = url
        case .steamGame: file = nil
        }
        if let file {
            if let name = request.saveAs { save(target, as: name, request: request, in: current) }
            return launchPreparing(file, in: current, title: target.title) { [weak self] b in
                self?.start(target, in: b, request: request)
            }
        }
        return start(target, in: current, request: request)
    }

    private func start(_ target: RunTarget, in current: Space, request: RunRequest) -> RunningProgram? {
        do {
            let runner = try WineRunner(space: current.applying(request.overrides))
            let program: RunningProgram
            switch target {
            case .program(let p):
                program = try runner.launch(p.launchFile, arguments: request.arguments, title: p.name,
                                            extraEnvironment: request.environment)
            case .file(let url):
                program = try runner.launch(url, arguments: request.arguments, extraEnvironment: request.environment)
            case .steamGame(let game):
                guard let steam = Steam.installation(in: current) else {
                    report("В пространстве «\(current.name)» больше нет Steam.")
                    return nil
                }
                program = try runner.launch(wineArguments: Steam.launchArguments(for: game.appID, steam: steam, extra: request.arguments),
                                            title: game.name, workingDirectory: steam.root,
                                            extraEnvironment: request.environment)
            }
            if case .steamGame = target, let name = request.saveAs { save(target, as: name, request: request, in: current) }
            return program
        } catch {
            report(error)
            return nil
        }
    }

    /// "Выполнить команду…": a Windows command line (`"C:\Games\x.exe" -windowed`, `notepad`, `msiexec /i …`).
    @discardableResult
    func runCommandLine(_ line: String, in space: Space, request: RunRequest) -> RunningProgram? {
        guard hasEngine else { report(AppModel.noEngineMessage); return nil }
        let current = self.space(id: space.id) ?? space
        guard let resolved = WindowsCommandLine.resolve(line, in: current) else {
            report("Введите команду, например: notepad или \"C:\\Games\\game.exe\" -windowed")
            return nil
        }
        do {
            let program: RunningProgram?
            let arguments = resolved.arguments + request.arguments
            if let file = resolved.unixPath {
                // Components first when needed (AppModel+AutoComponents.swift).
                program = launchPreparing(file, in: current, title: file.deletingPathExtension().lastPathComponent) { [weak self] b in
                    do {
                        return try WineRunner(space: b.applying(request.overrides))
                            .launch(file, arguments: arguments, extraEnvironment: request.environment)
                    } catch {
                        self?.report(error)
                        return nil
                    }
                }
            } else {
                let runner = try WineRunner(space: current.applying(request.overrides))
                program = try runner.launch(wineArguments: [resolved.program] + arguments,
                                            title: resolved.program, extraEnvironment: request.environment)
            }
            if let name = request.saveAs {
                if let file = resolved.unixPath {
                    var r = request
                    r.arguments = arguments
                    save(.file(file), as: name, request: r, in: current)
                } else {
                    report("«\(resolved.program)» не найден как файл в пространстве, поэтому его нельзя сохранить как программу. Укажите полный путь (C:\\…\\program.exe).")
                }
            }
            return program
        } catch {
            report(error)
            return nil
        }
    }

    /// Pins the target with the dialog's settings (a pinned program is updated in place).
    private func save(_ target: RunTarget, as name: String, request: RunRequest, in space: Space) {
        let overrides = request.overrides.differences(from: space.config)
        let stored: RunOverrides? = overrides.isEmpty ? nil : overrides
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var windowsPath: String
        var arguments = request.arguments
        switch target {
        case .program(let p):
            if case .pinned(let id) = p.source {
                updateConfig(of: space.id) { config in
                    guard let i = config.programs.firstIndex(where: { $0.id == id }) else { return }
                    if !title.isEmpty { config.programs[i].name = title }
                    config.programs[i].arguments = request.arguments
                    config.programs[i].environment = request.environment
                    config.programs[i].overrides = stored
                }
                return
            }
            windowsPath = space.windowsPath(forUnixPath: p.executable.flatMap { OnwinPaths.exists($0) ? $0 : nil } ?? p.launchFile)
        case .file(let url):
            windowsPath = space.windowsPath(forUnixPath: url)
        case .steamGame(let game):
            guard let steam = Steam.installation(in: space) else { return }
            windowsPath = space.windowsPath(forUnixPath: steam.steamExe)
            arguments = ["-applaunch", String(game.appID)] + request.arguments
        }
        let entry = ProgramEntry(name: title.isEmpty ? target.title : title, windowsPath: windowsPath,
                                 arguments: arguments, environment: request.environment, overrides: stored)
        updateConfig(of: space.id) { config in config.programs.append(entry) }
        refreshPrograms(of: space.id)
    }

    // MARK: Steam

    @discardableResult
    func launchSteamGame(_ game: SteamGame, in space: Space) -> RunningProgram? {
        // `steam.exe -applaunch` becomes the Steam client itself when Steam is not running yet, and then
        // stays alive after the game exits. Start Steam as its own «Steam» program first, so the handoff
        // process ends right away and the game's state comes from its real process (WineProcesses).
        if !ProcessTracker.shared.running(in: space.id).contains(where: { $0.title == "Steam" }) {
            openSteam(in: space)
        }
        return run(.steamGame(game), in: space, request: RunRequest())
    }

    /// steam.exe with a `steam://` URL (install, validate, uninstall, store page…); starts Steam if needed.
    func openSteamURL(_ url: String, title: String, in space: Space) {
        guard hasEngine else { report(AppModel.noEngineMessage); return }
        let current = self.space(id: space.id) ?? space
        guard let steam = Steam.installation(in: current) else {
            report("В пространстве «\(current.name)» нет Steam: установите его из каталога.")
            return
        }
        do {
            _ = try WineRunner(space: current).launch(wineArguments: Steam.urlArguments(url, steam: steam),
                                                       title: title, workingDirectory: steam.root)
        } catch {
            report(error)
        }
    }

    func openSteam(in space: Space) {
        let current = self.space(id: space.id) ?? space
        guard let steam = Steam.installation(in: current) else { return }
        do {
            _ = try WineRunner(space: current).launch(steam.steamExe, title: "Steam")
        } catch {
            report(error)
        }
    }

    // MARK: Uninstall

    /// Starts the program's uninstaller (its own window, or silently when `quietly`).
    @discardableResult
    func uninstall(_ app: InstalledApplication, quietly: Bool, in space: Space) -> RunningProgram? {
        guard hasEngine else { report(AppModel.noEngineMessage); return nil }
        let current = self.space(id: space.id) ?? space
        guard let arguments = UninstallRegistry.command(for: app, quiet: quietly, in: current) else {
            report("Не удалось разобрать команду удаления «\(app.displayName)»: \(app.uninstallString ?? "нет UninstallString")")
            return nil
        }
        do {
            return try WineRunner(space: current).launch(wineArguments: arguments, title: "Удаление «\(app.displayName)»")
        } catch {
            report(error)
            return nil
        }
    }
}
