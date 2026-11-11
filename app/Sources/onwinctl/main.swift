import Foundation
import OnwinCore

// onwinctl — command-line front end for onwin.

setvbuf(stdout, nil, _IONBF, 0)

let usage = [
    String(localized: "onwinctl \(OnwinVersion.displayString) — запуск Windows-программ на Mac", bundle: .onwinctl),
    String(localized: """
Движки и графика:
  onwinctl engines                         список движков Wine
  onwinctl engine-install <папка>          установить собранный движок
  onwinctl d3dmetal-import <путь к GPTK>   импортировать D3DMetal из Game Porting Toolkit (.dmg или том)
  onwinctl d3dmetal-fetch [--wait] [--browser] [--timeout минуты] [--downloads папка]
                                           импортировать уже скачанный Game Porting Toolkit (.dmg из «Загрузок»
                                           или кэша onwin); вход с Apple ID и загрузка — в приложении onwin
  onwinctl status                          что установлено
  onwinctl update [--check] [--version X]  обновить onwin и движок до последнего выпуска (--check — только
                                           проверить, --version — поставить определённую версию)
""", bundle: .onwinctl),
    String(localized: """
Пространства:
  onwinctl spaces                         список пространств
  onwinctl create <имя> [--win win10] [--backend auto|d3dmetal|dxmt|dxvk|wined3d]
  onwinctl delete <имя>                    в корзину
  onwinctl info <имя>                      настройки пространства
  onwinctl set <имя> <параметр> <значение> [--restart]
                                           backend, win, msync, retina, hud, avx, dxr, metalfx,
                                           debug, launchers, autocomponents (on|off|default), env:ИМЯ, dll:ИМЯ. msync и retina в запущенном
                                           пространстве меняются только с --restart (перезапуск пространства)
                                           mac-folders on|off — «Документы», «Загрузки», «Музыка», «Изображения»
                                           и «Видео» пространства ведут в папки Mac (macOS спросит доступ) или
                                           свои (по умолчанию в новых); меняется, только когда пространство не запущено
  onwinctl env <имя>                       переменные окружения запуска
  onwinctl archive <имя> <файл.onwinspace>
  onwinctl restore <файл.onwinspace> [имя]
""", bundle: .onwinctl),
    String(localized: """
Программы:
  onwinctl run [--no-auto-components] <пространство> <файл.exe|.msi|.lnk> [аргументы...]
                                           запустить и ждать. Перед первым запуском программы onwin сам
                                           ставит нужные ей компоненты (Visual C++, DirectX, .NET…), а если
                                           она не запустилась из-за нехватки библиотеки — ставит их и
                                           запускает ещё раз. --no-auto-components — без этого
  onwinctl wine <пространство> <команда wine...>              например: winecfg, regedit, cmd
  onwinctl shutdown <пространство> [--timeout с]  мягко закрыть программы (как «Завершить всё»),
                                           через 10 с — принудительно
  onwinctl kill <пространство>             принудительно завершить все программы (wineserver -k)
  onwinctl running <пространство>          запущено ли пространство (код 0 — да, 1 — нет)
  onwinctl programs <пространство>         найденные программы
  onwinctl pin <пространство> <путь> [имя]  закрепить программу (C:\\... или путь на Mac)
  onwinctl unpin <пространство> <программа>  открепить
""", bundle: .onwinctl),
    String(localized: """
Ярлыки (.app для Launchpad и Dock, ~/Applications/onwin/<пространство>/):
  onwinctl launcher <пространство> <программа> [--dir папка]   создать ярлык (программа: имя или id)
  onwinctl launcher-remove <пространство> <программа> [--dir папка]
  onwinctl launchers [пространство] [--dir папка]               список ярлыков
  onwinctl launchers-sync <пространство> [--rescan] [--dir папка]  ярлыки для меню «Пуск» (set … launchers on)
  onwinctl open-url <onwin://run?...>      запустить программу ярлыка и ждать
  onwinctl catalog                         каталог приложений и компонентов
  onwinctl install <приложение> [--space имя]                 например: steam
""", bundle: .onwinctl),
    String(localized: """
Компоненты:
  onwinctl components [пространство]       список компонентов (✓ — установлен в пространстве)
  onwinctl component <пространство> <компонент>[,компонент...]  установить, например: vcrun2026,directx-jun2010
  onwinctl component-info <компонент>      что скачивается, что делается, какие DLL даёт
  onwinctl component-files <компонент> <папка>                 скачать и распаковать DLL без Wine (проверка)
  onwinctl advise <пространство|-> <файл.exe> [--no-folder] [--wine-dlls папка]...
                                           каких компонентов не хватает программе (по таблице импорта)
  onwinctl advise-log <журнал.log> [--space имя]             что советует журнал неудачного запуска
""", bundle: .onwinctl),
    String(localized: """
Поддержка:
  onwinctl report <пространство> [программа.exe] [--log журнал.log] [--no-log] [--output файл]
                                           отчёт о проблеме для чата поддержки: Mac, движок, настройки
                                           пространства и конец последнего журнала запуска (без личных данных)
""", bundle: .onwinctl),
].joined(separator: "\n\n")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("onwinctl: \(message)\n".utf8))
    exit(1)
}

func space(_ name: String) -> Space {
    guard let b = SpaceManager.find(name) else { fail(String(localized: "нет пространства «\(name)». Список: onwinctl spaces", bundle: .onwinctl)) }
    return b
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func parseBool(_ s: String) -> Bool {
    ["1", "on", "yes", "true", "да", "вкл"].contains(s.lowercased())
}

@Sendable func printProgress(_ p: InstallProgress) {
    guard !p.message.isEmpty else { return }
    if let f = p.fraction { print(String(format: "[%3.0f%%] %@", f * 100, p.message)) } else { print("       \(p.message)") }
}

func printSuggestions(_ list: [Suggestion]) {
    if list.isEmpty {
        print(String(localized: "Ничего не нужно: все найденные зависимости покрыты Wine, пространством или файлами игры.",
                     bundle: .onwinctl))
        return
    }
    for s in list {
        let target = s.componentID.map { String(localized: "onwinctl component <пространство> \($0)", bundle: .onwinctl) } ?? String(localized: "подсказка", bundle: .onwinctl, comment: "A suggestion without a component to install")
        print(String(localized: "• \(s.title)  [\(s.componentID ?? "—")]  приоритет \(s.priority)", bundle: .onwinctl))
        print("  \(s.reason)")
        for e in s.evidence { print("    \(e)") }
        print("  → \(target)")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

do {
    switch command {
    case "help", "-h", "--help":
        print(usage + "\n\n" + programCommandsUsage + "\n\n" + recipeCommandsUsage)

    case "status":
        let engines = EngineManager.installedEngines()
        print(String(localized: "Данные:   \(OnwinPaths.root.path)", bundle: .onwinctl))
        let rosetta = HostSupport.isRosettaInstalled()
        print("Mac:      \(HostSupport.isAppleSilicon ? "Apple Silicon" : "Intel"), macOS \(HostSupport.macOSVersion)\(HostSupport.gpuName.map { ", \($0)" } ?? "")")
        if !HostSupport.isAppleSilicon {
            print(String(localized: "Rosetta:  не нужна", bundle: .onwinctl))
        } else if rosetta {
            print(String(localized: "Rosetta:  установлена", bundle: .onwinctl))
        } else {
            print(String(localized: "Rosetta:  НЕ УСТАНОВЛЕНА — без неё Wine не запустится: softwareupdate --install-rosetta --agree-to-license (macOS может запросить пароль)", bundle: .onwinctl))
        }
        let yes = String(localized: "есть", bundle: .onwinctl, comment: "Status value: the part is present")
        let no = String(localized: "нет", bundle: .onwinctl, comment: "Status value: the part is absent")
        let supported = String(localized: "да", bundle: .onwinctl, comment: "Status value: supported")
        if engines.isEmpty {
            print(String(localized: "Движки:   нет", bundle: .onwinctl))
        } else {
            let list = engines.map { "\($0.id) (\($0.info.wineVersion))" }.joined(separator: ", ")
            print(String(localized: "Движки:   \(list)", bundle: .onwinctl))
        }
        if let e = engines.first {
            print("DXMT:     \(e.hasDXMT ? yes : no)")
            print("DXVK:     \(e.hasDXVK ? yes : no)  MoltenVK: \(e.hasMoltenVK ? yes : no)")
        }
        print(GraphicsSupport.isD3DMetalInstalled ? String(localized: "D3DMetal: импортирован", bundle: .onwinctl)
                                                  : String(localized: "D3DMetal: не импортирован (onwinctl d3dmetal-fetch)", bundle: .onwinctl))
        for backend in [GraphicsBackend.d3dmetal, .dxmt] {
            if let reason = HostSupport.unsupportedReason(backend) {
                print(String(localized: "\(backend.displayName): не поддерживается этим Mac — \(reason)", bundle: .onwinctl))
            }
        }
        print("DLSS→MetalFX: D3DMetal — \(HostSupport.metalFXUnsupportedReason(.d3dmetal) ?? supported), DXMT — \(HostSupport.metalFXUnsupportedReason(.dxmt) ?? supported)")
        print("DXR:      \(HostSupport.raytracingUnsupportedReason(.d3dmetal) ?? supported + " (D3DMetal)")")
        if let cabextract = HostTools.cabextract {
            print("cabextract: \(cabextract.path)")
        } else {
            print(String(localized: "cabextract: не найден (scripts/build-cabextract.sh)", bundle: .onwinctl))
        }
        print(String(localized: "Пространства: \(SpaceManager.list().count)", bundle: .onwinctl))

    case "engines":
        let engines = EngineManager.installedEngines()
        if engines.isEmpty { print(String(localized: "Движков нет. Соберите: engine/build.sh", bundle: .onwinctl)) }
        for e in engines {
            print("\(e.id)\t\(e.info.displayName)\tWine \(e.info.wineVersion)\t\(e.root.path)")
        }

    case "engine-install":
        guard let path = args.first else { fail(String(localized: "укажите папку движка", bundle: .onwinctl)) }
        let e = try EngineManager.install(from: URL(fileURLWithPath: path))
        print(String(localized: "Установлен движок \(e.id) → \(e.root.path)", bundle: .onwinctl))

    case "d3dmetal-import":
        guard let path = args.first else { fail(String(localized: "укажите путь к Game Porting Toolkit", bundle: .onwinctl)) }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "dmg" {
            try await D3DMetalImporter.importFound(.diskImage(url), progress: printProgress)
        } else {
            // A folder or a mounted volume (the outer GPTK volume holds only the inner image).
            try await D3DMetalImporter.importFound(.mountedVolume(url), progress: printProgress)
        }
        print(String(localized: "D3DMetal импортирован в \(OnwinPaths.d3dmetal.path)", bundle: .onwinctl))

    case "d3dmetal-fetch":
        let source = try await d3dmetalFetch(args)
        print(String(localized: "D3DMetal импортирован из \(source.path) → \(OnwinPaths.d3dmetal.path)", bundle: .onwinctl))

    case "spaces":
        for b in SpaceManager.list() {
            print("\(b.name)\t\(b.config.windowsVersion.displayName)\t\(b.config.graphicsBackend.rawValue)\t\(b.url.path)")
        }

    case "create":
        var rest = args
        let win = option("--win", in: &rest).flatMap(WindowsVersion.init(rawValue:)) ?? .win10
        let backend = option("--backend", in: &rest).flatMap(GraphicsBackend.init(rawValue:)) ?? .auto
        guard let name = rest.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        let b = try await SpaceManager.create(name: name, windowsVersion: win, backend: backend, log: { print($0, terminator: "") })
        print(String(localized: "Пространство «\(b.name)» создано: \(b.url.path)", bundle: .onwinctl))

    case "delete":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        try await SpaceManager.delete(space(name))
        print(String(localized: "Пространство «\(name)» перемещено в корзину", bundle: .onwinctl))

    case "info":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        let b = space(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(b.config), as: UTF8.self))

    case "set":
        let restart = args.contains("--restart")
        args.removeAll { $0 == "--restart" }
        guard args.count >= 3 else { fail(String(localized: "использование: onwinctl set <пространство> <параметр> <значение> [--restart]", bundle: .onwinctl)) }
        var b = space(args[0])
        if args[1] == "mac-folders",
           !["on", "off", "1", "0", "yes", "no", "true", "false", "да", "нет", "вкл", "выкл"].contains(args[2].lowercased()) {
            fail(String(localized: "mac-folders: on (связать с папками Mac) или off (свои папки пространства)", bundle: .onwinctl))
        }
        if ["msync", "retina", "mac-folders"].contains(args[1]) {
            let runner = try WineRunner(space: b)
            if runner.isServerRunning {
                // A running wineserver keeps the old sync mode / DPI: mixed state until it exits.
                guard restart else {
                    fail(String(localized: "пространство «\(b.name)» запущено. \(args[1]) применится только после перезапуска пространства: все его программы будут закрыты. Повторите с --restart", bundle: .onwinctl))
                }
                let outcome = try await runner.shutdown(onOutput: { print($0, terminator: "") })
                if outcome == .refused {
                    fail(String(localized: "программа в пространстве отказалась завершаться; закройте её сами или: onwinctl kill \(b.name)", bundle: .onwinctl))
                }
                print(outcome == .forced ? String(localized: "Пространство завершено принудительно", bundle: .onwinctl)
                                         : String(localized: "Пространство завершено", bundle: .onwinctl))
            }
        }
        if args[1] == "mac-folders" {
            let linked = parseBool(args[2])
            let (updated, outcome) = try SpaceManager.setMacFoldersLinked(b, linked)
            if linked {
                print(String(localized: "Папки пространства «\(updated.name)» связаны с папками Mac. Когда Windows-программа откроет их, macOS спросит разрешение.", bundle: .onwinctl))
                if let message = outcome.keptMessage { print(message) }
            } else {
                print(String(localized: "У пространства «\(updated.name)» теперь свои папки «Документы», «Загрузки», «Музыка», «Изображения» и «Видео». Папки Mac не изменены.", bundle: .onwinctl))
                if !outcome.unlinked.isEmpty {
                    let list = outcome.unlinked.map(\.title).joined(separator: ", ")
                    print(String(localized: "Убраны ссылки: \(list)", bundle: .onwinctl))
                }
            }
            exit(0)
        }
        let key = args[1], value = args[2]
        var needsRegistry = false, needsWinver = false
        switch key {
        case "backend":
            guard let v = GraphicsBackend(rawValue: value) else { fail("backend: auto|d3dmetal|dxmt|dxvk|wined3d") }
            b.config.graphicsBackend = v
        case "win":
            guard let v = WindowsVersion(rawValue: value) else { fail("win: " + WindowsVersion.allCases.map(\.rawValue).joined(separator: "|")) }
            b.config.windowsVersion = v; needsWinver = true
        case "msync": b.config.msync = parseBool(value)
        case "retina": b.config.highResolution = parseBool(value); needsRegistry = true
        case "hud": b.config.metalHUD = parseBool(value)
        case "avx": b.config.advertiseAVX = parseBool(value)
        case "dxr": b.config.dxrRaytracing = parseBool(value)
        case "metalfx": b.config.metalFX = parseBool(value)
        case "debug": b.config.debugLogging = parseBool(value)
        case "launchers": b.config.autoLaunchers = parseBool(value)
        case "autocomponents":
            b.config.autoInstallComponents = ["default", "auto", "по умолчанию"].contains(value.lowercased()) ? nil : parseBool(value)
        default:
            if key.hasPrefix("env:") {
                let name = String(key.dropFirst(4))
                if value.isEmpty { b.config.environment.removeValue(forKey: name) } else { b.config.environment[name] = value }
            } else if key.hasPrefix("dll:") {
                let name = String(key.dropFirst(4))
                if value == "default" { b.config.dllOverrides.removeValue(forKey: name) } else { b.config.dllOverrides[name] = value }
            } else {
                fail(String(localized: "неизвестный параметр \(key)", bundle: .onwinctl))
            }
        }
        try b.save()
        if needsWinver { try await SpaceSetup.applyWindowsVersion(b, log: { print($0, terminator: "") }) }
        if needsRegistry { try await SpaceSetup.applyRegistrySettings(b, log: { print($0, terminator: "") }) }
        print(String(localized: "Готово", bundle: .onwinctl, comment: "The setting is saved"))

    case "env":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        let runner = try WineRunner(space: space(name))
        for (k, v) in runner.environment().sorted(by: { $0.key < $1.key })
        where k.hasPrefix("WINE") || k.hasPrefix("ONWIN") || k.hasPrefix("DYLD") || k.hasPrefix("CX_") ||
              k.hasPrefix("D3DM") || k.hasPrefix("DXVK") || k.hasPrefix("DXMT") || k.hasPrefix("MTL") || k.hasPrefix("ROSETTA") ||
              k.hasPrefix("MVK") || k.hasPrefix("GST") || k == "PATH" {
            print("\(k)=\(v)")
        }

    case "archive":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl archive <пространство> <файл>", bundle: .onwinctl)) }
        try await SpaceManager.archive(space(args[0]), to: URL(fileURLWithPath: args[1]))
        print(String(localized: "Архив: \(args[1])", bundle: .onwinctl))

    case "restore":
        guard let file = args.first else { fail(String(localized: "укажите архив", bundle: .onwinctl)) }
        let b = try await SpaceManager.restore(from: URL(fileURLWithPath: file), name: args.count > 1 ? args[1] : nil)
        print(String(localized: "Восстановлено пространство «\(b.name)»", bundle: .onwinctl))

    case "run":
        // The flag is taken only before the program's own arguments (space, file, then arguments).
        var rest = args
        var autoComponents = true
        while let i = rest.prefix(3).firstIndex(of: "--no-auto-components") { rest.remove(at: i); autoComponents = false }
        guard rest.count >= 2 else { fail(String(localized: "использование: onwinctl run [--no-auto-components] <пространство> <файл> [аргументы]", bundle: .onwinctl)) }
        let status = try await runWithAutoComponents(space: space(rest[0]), file: URL(fileURLWithPath: rest[1]),
                                                     arguments: Array(rest.dropFirst(2)), auto: autoComponents)
        exit(status)

    case "wine":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl wine <пространство> <команда>", bundle: .onwinctl)) }
        let runner = try WineRunner(space: space(args[0]))
        let r = try await runner.runAndWait(Array(args.dropFirst()), onOutput: { print($0, terminator: "") })
        exit(r.status)

    case "shutdown":
        var rest = args
        let timeout = option("--timeout", in: &rest).flatMap(Double.init) ?? 10
        guard let name = rest.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        switch try await WineRunner(space: space(name)).shutdown(timeout: timeout, onOutput: { print($0, terminator: "") }) {
        case .notRunning: print(String(localized: "Пространство «\(name)» не запущено", bundle: .onwinctl))
        case .clean: print(String(localized: "Все программы пространства «\(name)» закрыты", bundle: .onwinctl))
        case .forced: print(String(localized: "Пространство «\(name)» завершено принудительно (не всё закрылось за \(Int(timeout)) с)", bundle: .onwinctl))
        case .refused: fail(String(localized: "программа отказалась завершаться (например, ждёт ответа «Сохранить?»). Принудительно: onwinctl kill \(name)", bundle: .onwinctl))
        }

    case "running":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        if let pid = try WineRunner(space: space(name)).serverPID {
            print(String(localized: "запущено (wineserver \(Int(pid)))", bundle: .onwinctl)); exit(0)
        }
        print(String(localized: "не запущено", bundle: .onwinctl, comment: "The space is not running")); exit(1)

    case "kill":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        try await WineRunner(space: space(name)).killAll()
        print(String(localized: "Все программы пространства «\(name)» завершены", bundle: .onwinctl))

    case "programs":
        guard let name = args.first else { fail(String(localized: "укажите имя пространства", bundle: .onwinctl)) }
        for p in ProgramScanner.programs(in: space(name)) {
            print("\(p.name)\t\(p.executable?.path ?? p.launchFile.path)")
        }

    case "pin", "unpin", "launcher", "launcher-remove", "launchers", "launchers-sync", "open-url":
        try await launcherCommand(command, args)

    case "catalog":
        print(String(localized: "Приложения:", bundle: .onwinctl))
        for a in Catalog.apps { print("  \(a.id)\t\(a.name) — \(a.summary)") }
        print(String(localized: "Компоненты:", bundle: .onwinctl))
        for c in Catalog.listedComponents { print("  \(c.id)\t\(c.name) — \(c.summary) (\(c.sizeDescription))") }

    case "install":
        var rest = args
        let into = option("--space", in: &rest)
        guard let id = rest.first, let recipe = Catalog.app(id) else { fail(String(localized: "укажите приложение из onwinctl catalog", bundle: .onwinctl)) }
        if recipe.category == .user, let user = UserRecipes.recipe(recipe.id) {   // RecipeCommands.swift
            try await installUserRecipe(user, into: into.map { space($0) })
            break
        }
        let b = try await Installer.install(recipe: recipe, into: into.map { space($0) }, progress: printProgress)
        print(String(localized: "Установлено в пространство «\(b.name)»", bundle: .onwinctl))

    case "recipe":
        try await recipeCommand(args)   // RecipeCommands.swift

    case "components":
        let b = args.first.map { space($0) }
        for category in Component.Category.allCases {
            let list = Catalog.listedComponents.filter { $0.category == category }
            guard !list.isEmpty else { continue }
            print("\(category.title):")
            for c in list {
                let mark = b.map { c.isInstalled(in: $0.config) ? "✓" : " " } ?? (c.kind == .global && c.isInstalled(in: SpaceConfig(name: "")) ? "✓" : " ")
                print("  \(mark) \(c.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.name) — \(c.sizeDescription)")
            }
        }

    case "component-info":
        guard let id = args.first, let c = Catalog.component(id) else { fail(String(localized: "укажите компонент из onwinctl components", bundle: .onwinctl)) }
        print("\(c.name) [\(c.id)] — \(c.summary)")
        print(c.kind == .global ? String(localized: "Размер: \(c.sizeDescription), общий для всех пространств", bundle: .onwinctl)
                                : String(localized: "Размер: \(c.sizeDescription)", bundle: .onwinctl))
        if !c.requires.isEmpty {
            print(String(localized: "Сначала ставится: \(c.requires.joined(separator: ", "))", bundle: .onwinctl))
        }
        if !c.providesDLLs.isEmpty { print(String(localized: "Даёт: \(c.providesDLLs.joined(separator: ", "))", bundle: .onwinctl)) }
        if !c.satisfiesImports.isEmpty {
            print(String(localized: "Покрывает импорт: \(c.satisfiesImports.joined(separator: " "))", bundle: .onwinctl))
        }
        for d in c.downloads {
            let check: String
            switch d.verification {
            case .sha256(let h): check = "sha256 \(h)"
            case .portableExecutable: check = String(localized: "проверка PE (ссылка aka.ms меняется)", bundle: .onwinctl)
            case .cabinet: check = String(localized: "проверка заголовка CAB", bundle: .onwinctl)
            }
            print("  ↓ \(d.url.absoluteString)\n      \(d.fileName), \(check)")
        }
        for a in c.actions { print("  • \(a.summary)") }
        if !c.dllOverrides.isEmpty {
            print("DLL overrides: " + c.dllOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if !c.notes.isEmpty { print(c.notes) }

    case "component-files":
        guard args.count >= 2, let c = Catalog.component(args[0]) else { fail(String(localized: "использование: onwinctl component-files <компонент> <папка>", bundle: .onwinctl)) }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        let written = try await ComponentInstaller.extractFiles(of: c, into: dir, progress: printProgress)
        for file in written {
            let info = PEImage.read(file).map { " (\($0.machine.displayName))" } ?? ""
            print("  \(file.path)\(info)")
        }
        print(String(localized: "Файлов: \(written.count)", bundle: .onwinctl))

    case "component":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl component <пространство> <компонент>[,компонент...]", bundle: .onwinctl)) }
        var b = space(args[0])
        for id in args[1].split(separator: ",").map(String.init) {
            guard let c = Catalog.component(id) else { fail(String(localized: "нет компонента \(id). Список: onwinctl components", bundle: .onwinctl)) }
            if c.kind == .global {
                try await d3dmetalFetch([])
                continue
            }
            b = try await Installer.install(component: c, into: b, progress: printProgress)
        }

    case "advise":
        var rest = args
        var wineDirs: [URL] = []
        while let dir = option("--wine-dlls", in: &rest) { wineDirs.append(URL(fileURLWithPath: dir, isDirectory: true)) }
        let scanFolder = !rest.contains("--no-folder")
        rest.removeAll { $0 == "--no-folder" }
        guard rest.count >= 2 else { fail(String(localized: "использование: onwinctl advise <пространство|-> <файл.exe>", bundle: .onwinctl)) }
        let b: Space? = rest[0] == "-" ? nil : space(rest[0])
        var exe = URL(fileURLWithPath: rest[1])
        if exe.pathExtension.lowercased() == "lnk", let b, let target = ShellLink.parse(exe)?.targetPath,
           let unix = b.unixPath(forWindowsPath: target) {
            exe = unix
        } else if let b, rest[1].contains(":\\") || rest[1].contains(":/"), let unix = b.unixPath(forWindowsPath: rest[1]) {
            exe = unix
        }
        guard let image = PEImage.read(exe) else { fail(String(localized: "\(exe.path) — не PE-файл Windows", bundle: .onwinctl)) }
        print("\(exe.lastPathComponent): \(image.machine.displayName)\(image.isDotNet ? ", .NET" : "")\(image.isDLL ? ", DLL" : "")")
        print(String(localized: "Импорт: \(image.imports.joined(separator: " "))", bundle: .onwinctl))
        if !image.delayImports.isEmpty {
            print(String(localized: "Отложенный импорт: \(image.delayImports.joined(separator: " "))", bundle: .onwinctl))
        }
        print("")
        printSuggestions(DependencyAdvisor.analyze(executable: exe, space: b, scanFolder: scanFolder,
                                                   wineDLLDirectories: wineDirs.isEmpty ? nil : wineDirs))

    case "advise-log":
        var rest = args
        let b = option("--space", in: &rest).map { space($0) }
        guard let path = rest.first else { fail(String(localized: "использование: onwinctl advise-log <журнал.log> [--space имя]", bundle: .onwinctl)) }
        printSuggestions(DependencyAdvisor.analyze(log: URL(fileURLWithPath: path), space: b))

    case "report":
        var rest = args
        let output = option("--output", in: &rest)
        let logPath = option("--log", in: &rest)
        let includeLog = !rest.contains("--no-log")
        rest.removeAll { $0 == "--no-log" }
        guard let name = rest.first else {
            fail(String(localized: "использование: onwinctl report <пространство> [программа.exe] [--log журнал.log] [--no-log] [--output файл]", bundle: .onwinctl))
        }
        let b = space(name)
        let program = rest.count > 1 ? rest[1] : nil
        let log = logPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ProblemReport.latestLog(in: b, program: program)
        if let program, logPath == nil, log == nil {
            let message = String(localized: "журнала запуска «\(program)» в «\(b.name)» нет — отчёт без журнала", bundle: .onwinctl)
            FileHandle.standardError.write(Data("onwinctl: \(message)\n".utf8))
        }
        let text = ProblemReport.build(.init(space: b, logURL: log, programFile: program), includeLog: includeLog)
        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try text.write(to: url, atomically: true, encoding: .utf8)
            print(String(localized: "Отчёт сохранён: \(ProblemReport.redact(url.path))", bundle: .onwinctl))
        } else {
            print(text, terminator: "")
        }

    default:
        if try await runProgramCommand(command, args) { break }   // ProgramCommands.swift
        if try await runUpdateCommand(command, args) { break }    // UpdateCommands.swift
        if await runIconCommand(command, args) { break }           // IconCommands.swift
        if runDesktopCommand(command, args) { break }               // DesktopCommands.swift
        fail(String(localized: "неизвестная команда \(command)", bundle: .onwinctl) + "\n\n"
             + [usage, programCommandsUsage, recipeCommandsUsage, iconCommandsUsage, desktopCommandsUsage].joined(separator: "\n\n"))
    }
} catch {
    fail(error.localizedDescription)
}
