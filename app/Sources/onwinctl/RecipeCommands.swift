import Foundation
import OnwinCore

// `onwinctl recipe ...`: the user's own recipes ("Мои приложения", OnwinCore/UserRecipes.swift), and the
// user-recipe branch of `onwinctl install` (installs with detection of what the installer added).

let recipeCommandsUsage = String(localized: """
Мои приложения (свои рецепты, ~/Library/Application Support/onwin/Recipes):
  onwinctl recipe list                     список своих рецептов
  onwinctl recipe show <id>                рецепт (JSON) и его проверка
  onwinctl recipe add <файл.json> [--replace]
                                           добавить рецепт; installer.file — путь к установщику на Mac
                                           (файл копируется к рецепту)
  onwinctl recipe remove <id>              удалить рецепт (пространства остаются)
  onwinctl recipe export <id> <файл.onwinrecipe>
  onwinctl recipe import <файл.onwinrecipe> [--replace]   импорт ничего не запускает
  onwinctl install <id> [--space имя]     ставит и свой рецепт; без пути запуска onwin предложит
                                           найденную программу и запишет её в рецепт
""", bundle: .onwinctl)

private func printJSON(_ recipe: UserRecipe) throws {
    print(String(decoding: try UserRecipes.encode(recipe), as: UTF8.self))
}

private func userRecipe(_ id: String) -> UserRecipe {
    guard let r = UserRecipes.recipe(id) else { fail(String(localized: "нет своего рецепта «\(id)». Список: onwinctl recipe list", bundle: .onwinctl)) }
    return r
}

func recipeCommand(_ arguments: [String]) async throws {
    var args = arguments
    let replace = args.contains("--replace")
    args.removeAll { $0 == "--replace" }
    guard let sub = args.first else { print(recipeCommandsUsage); return }
    args.removeFirst()

    switch sub {
    case "list":
        let all = UserRecipes.all()
        if all.isEmpty { print(String(localized: "Своих рецептов нет. Добавить: onwinctl recipe add <файл.json>", bundle: .onwinctl)) }
        for r in all {
            let source: String
            if let url = r.installer?.url { source = url }
            else if let file = r.installer?.file { source = r.isMissingInstallerFile ? String(localized: "\(file) (файла нет!)", bundle: .onwinctl) : file }
            else { source = String(localized: "без установщика", bundle: .onwinctl) }
            let spaceText = String(localized: "пространство «\(r.spaceName)»", bundle: .onwinctl)
            print("\(r.id)\t\(r.name)\t\(spaceText)\t\(source)")
        }

    case "show":
        guard let id = args.first else { fail(String(localized: "использование: onwinctl recipe show <id>", bundle: .onwinctl)) }
        let r = userRecipe(id)
        try printJSON(r)
        if let local = r.localInstallerURL {
            print(r.isMissingInstallerFile ? String(localized: "Установщик: \(local.path) — НЕТ ФАЙЛА", bundle: .onwinctl)
                                           : String(localized: "Установщик: \(local.path)", bundle: .onwinctl))
        }
        let problems = UserRecipes.validate(r)
        let list = problems.map { "  • \($0)" }.joined(separator: "\n")
        print(problems.isEmpty ? String(localized: "Проверка: всё в порядке", bundle: .onwinctl)
                               : String(localized: "Проблемы:\n\(list)", bundle: .onwinctl))

    case "add":
        guard let path = args.first else { fail(String(localized: "использование: onwinctl recipe add <файл.json> [--replace]", bundle: .onwinctl)) }
        let file = URL(fileURLWithPath: path)
        var r = try UserRecipes.read(file).recipe
        var installerFile: URL?
        // installer.file: absolute, ~/..., or relative to the JSON file.
        if r.installer?.isLocalFile == true,
           let raw = try UserRecipes.decode(Data(contentsOf: file)).installer?.file {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: expanded, relativeTo: file.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: url.path) else {
                fail(String(localized: "нет файла установщика «\(raw)» (путь в installer.file — абсолютный или относительно \(file.lastPathComponent))", bundle: .onwinctl))
            }
            installerFile = url.standardizedFileURL
        }
        if r.id.isEmpty { r.id = UserRecipes.makeID(for: r.name) }
        if UserRecipes.recipe(r.id) != nil, !replace { fail(String(localized: "рецепт «\(r.id)» уже есть; заменить: --replace", bundle: .onwinctl)) }
        if Catalog.builtinApps.contains(where: { $0.id.caseInsensitiveCompare(r.id) == .orderedSame }) {
            fail(String(localized: "id «\(r.id)» занят встроенным рецептом каталога — выберите другой", bundle: .onwinctl))
        }
        let problems = UserRecipes.validate(r, checkFiles: false)
        if !problems.isEmpty {
            let list = problems.map { "  • \($0)" }.joined(separator: "\n")
            fail(String(localized: "рецепт не сохранён:\n\(list)", bundle: .onwinctl))
        }
        let saved = try UserRecipes.save(r, installerFile: installerFile)
        print(String(localized: "Рецепт «\(saved.name)» сохранён: \(saved.id)", bundle: .onwinctl))

    case "remove":
        guard let id = args.first else { fail(String(localized: "использование: onwinctl recipe remove <id>", bundle: .onwinctl)) }
        let r = userRecipe(id)
        try UserRecipes.remove(r.id)
        print(String(localized: "Рецепт «\(r.name)» удалён (пространства, установленные по нему, остались)", bundle: .onwinctl))

    case "export":
        guard args.count >= 2 else { fail(String(localized: "использование: onwinctl recipe export <id> <файл.onwinrecipe>", bundle: .onwinctl)) }
        let r = userRecipe(args[0])
        var path = args[1]
        if (path as NSString).pathExtension.isEmpty { path += ".\(UserRecipe.fileExtension)" }
        try UserRecipes.export(r.id, to: URL(fileURLWithPath: path))
        print(String(localized: "Экспортировано: \(path)", bundle: .onwinctl))
        if let note = UserRecipes.exportNote(for: r) { print(note) }

    case "import":
        guard let path = args.first else { fail(String(localized: "использование: onwinctl recipe import <файл.onwinrecipe>", bundle: .onwinctl)) }
        let r = try UserRecipes.importFile(URL(fileURLWithPath: path), replace: replace)
        print(String(localized: "Импортирован рецепт «\(r.name)»: \(r.id). Ничего не установлено — установка: onwinctl install \(r.id)", bundle: .onwinctl))
        if r.isMissingInstallerFile {
            let file = r.installer?.file ?? ""
            print(String(localized: "Внимание: нет файла установщика «\(file)». Положите его рядом с файлом рецепта и импортируйте снова или выберите файл в onwin: Каталог → Мои приложения → Изменить.", bundle: .onwinctl))
        }
        let problems = UserRecipes.validate(r)
        if !problems.isEmpty {
            let list = problems.map { "  • \($0)" }.joined(separator: "\n")
            print(String(localized: "Проблемы:\n\(list)", bundle: .onwinctl))
        }

    default:
        fail(String(localized: "неизвестная команда recipe \(sub)", bundle: .onwinctl) + "\n\n" + recipeCommandsUsage)
    }
}

/// `onwinctl install <user recipe>`: installs, prints what the installer added, and records the found
/// program as the recipe's launch path when it has none.
func installUserRecipe(_ user: UserRecipe, into: Space?) async throws {
    let problems = UserRecipes.validate(user)
    if !problems.isEmpty {
        let list = problems.map { "  • \($0)" }.joined(separator: "\n")
        fail(String(localized: "рецепт «\(user.id)» не готов:\n\(list)", bundle: .onwinctl))
    }
    let result = try await RecipeInstaller.install(recipe: user.appRecipe, into: into, progress: printProgress)
    print(String(localized: "Установлено в пространство «\(result.space.name)»", bundle: .onwinctl))
    let d = result.detection
    for app in d.newApplications {
        let name = app.displayName + (app.displayVersion.map { " \($0)" } ?? "")
        print(String(localized: "Новая программа в реестре: \(name)", bundle: .onwinctl))
    }
    for folder in d.newProgramFolders {
        print(String(localized: "Новая папка: \(result.space.windowsPath(forUnixPath: folder))", bundle: .onwinctl))
    }
    for lnk in d.newShortcuts { print(String(localized: "Новый ярлык: \(lnk.lastPathComponent)", bundle: .onwinctl)) }
    if d.candidates.isEmpty {
        if user.launchPath == nil {
            print(String(localized: "Новых программ для запуска не найдено — укажите путь запуска в рецепте (Каталог → Мои приложения → Изменить)", bundle: .onwinctl))
        }
        return
    }
    print(String(localized: "Найдено для запуска:", bundle: .onwinctl))
    for (i, c) in d.candidates.enumerated() {
        print("  \(i + 1). \(c.windowsPath)\t\(c.name) — \(c.source.displayName)")
    }
    guard user.launchPath == nil, let best = d.candidates.first else { return }
    var updated = user
    updated.launchPath = best.windowsPath
    updated.launchArguments = best.arguments
    try UserRecipes.save(updated)
    var b = result.space
    if !b.config.programs.contains(where: { $0.windowsPath.caseInsensitiveCompare(best.windowsPath) == .orderedSame }) {
        b.config.programs.append(ProgramEntry(name: user.name, windowsPath: best.windowsPath, arguments: best.arguments,
                                              environment: user.environment))
        try b.save()
    }
    print(String(localized: "Путь запуска записан в рецепт и программа закреплена в пространстве: \(best.windowsPath)", bundle: .onwinctl))
}
