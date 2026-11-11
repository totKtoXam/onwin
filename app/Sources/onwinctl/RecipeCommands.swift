import Foundation
import OnwinCore

// `onwinctl recipe ...`: the user's own recipes ("Мои приложения", OnwinCore/UserRecipes.swift), and the
// user-recipe branch of `onwinctl install` (installs with detection of what the installer added).

let recipeCommandsUsage = """

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
"""

private func printJSON(_ recipe: UserRecipe) throws {
    print(String(decoding: try UserRecipes.encode(recipe), as: UTF8.self))
}

private func userRecipe(_ id: String) -> UserRecipe {
    guard let r = UserRecipes.recipe(id) else { fail("нет своего рецепта «\(id)». Список: onwinctl recipe list") }
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
        if all.isEmpty { print("Своих рецептов нет. Добавить: onwinctl recipe add <файл.json>") }
        for r in all {
            let source: String
            if let url = r.installer?.url { source = url }
            else if let file = r.installer?.file { source = r.isMissingInstallerFile ? "\(file) (файла нет!)" : file }
            else { source = "без установщика" }
            print("\(r.id)\t\(r.name)\tпространство «\(r.spaceName)»\t\(source)")
        }

    case "show":
        guard let id = args.first else { fail("использование: onwinctl recipe show <id>") }
        let r = userRecipe(id)
        try printJSON(r)
        if let local = r.localInstallerURL { print("Установщик: \(local.path)\(r.isMissingInstallerFile ? " — НЕТ ФАЙЛА" : "")") }
        let problems = UserRecipes.validate(r)
        print(problems.isEmpty ? "Проверка: всё в порядке" : "Проблемы:\n" + problems.map { "  • \($0)" }.joined(separator: "\n"))

    case "add":
        guard let path = args.first else { fail("использование: onwinctl recipe add <файл.json> [--replace]") }
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
                fail("нет файла установщика «\(raw)» (путь в installer.file — абсолютный или относительно \(file.lastPathComponent))")
            }
            installerFile = url.standardizedFileURL
        }
        if r.id.isEmpty { r.id = UserRecipes.makeID(for: r.name) }
        if UserRecipes.recipe(r.id) != nil, !replace { fail("рецепт «\(r.id)» уже есть; заменить: --replace") }
        if Catalog.builtinApps.contains(where: { $0.id.caseInsensitiveCompare(r.id) == .orderedSame }) {
            fail("id «\(r.id)» занят встроенным рецептом каталога — выберите другой")
        }
        let problems = UserRecipes.validate(r, checkFiles: false)
        if !problems.isEmpty { fail("рецепт не сохранён:\n" + problems.map { "  • \($0)" }.joined(separator: "\n")) }
        let saved = try UserRecipes.save(r, installerFile: installerFile)
        print("Рецепт «\(saved.name)» сохранён: \(saved.id)")

    case "remove":
        guard let id = args.first else { fail("использование: onwinctl recipe remove <id>") }
        let r = userRecipe(id)
        try UserRecipes.remove(r.id)
        print("Рецепт «\(r.name)» удалён (пространства, установленные по нему, остались)")

    case "export":
        guard args.count >= 2 else { fail("использование: onwinctl recipe export <id> <файл.onwinrecipe>") }
        let r = userRecipe(args[0])
        var path = args[1]
        if (path as NSString).pathExtension.isEmpty { path += ".\(UserRecipe.fileExtension)" }
        try UserRecipes.export(r.id, to: URL(fileURLWithPath: path))
        print("Экспортировано: \(path)")
        if let note = UserRecipes.exportNote(for: r) { print(note) }

    case "import":
        guard let path = args.first else { fail("использование: onwinctl recipe import <файл.onwinrecipe>") }
        let r = try UserRecipes.importFile(URL(fileURLWithPath: path), replace: replace)
        print("Импортирован рецепт «\(r.name)»: \(r.id). Ничего не установлено — установка: onwinctl install \(r.id)")
        if r.isMissingInstallerFile {
            print("Внимание: нет файла установщика «\(r.installer?.file ?? "")». Положите его рядом с файлом рецепта и импортируйте снова или выберите файл в onwin: Каталог → Мои приложения → Изменить.")
        }
        let problems = UserRecipes.validate(r)
        if !problems.isEmpty { print("Проблемы:\n" + problems.map { "  • \($0)" }.joined(separator: "\n")) }

    default:
        fail("неизвестная команда recipe \(sub)\n\(recipeCommandsUsage)")
    }
}

/// `onwinctl install <user recipe>`: installs, prints what the installer added, and records the found
/// program as the recipe's launch path when it has none.
func installUserRecipe(_ user: UserRecipe, into: Space?) async throws {
    let problems = UserRecipes.validate(user)
    if !problems.isEmpty { fail("рецепт «\(user.id)» не готов:\n" + problems.map { "  • \($0)" }.joined(separator: "\n")) }
    let result = try await RecipeInstaller.install(recipe: user.appRecipe, into: into, progress: printProgress)
    print("Установлено в пространство «\(result.space.name)»")
    let d = result.detection
    for app in d.newApplications {
        print("Новая программа в реестре: \(app.displayName)\(app.displayVersion.map { " \($0)" } ?? "")")
    }
    for folder in d.newProgramFolders { print("Новая папка: \(result.space.windowsPath(forUnixPath: folder))") }
    for lnk in d.newShortcuts { print("Новый ярлык: \(lnk.lastPathComponent)") }
    if d.candidates.isEmpty {
        if user.launchPath == nil {
            print("Новых программ для запуска не найдено — укажите путь запуска в рецепте (Каталог → Мои приложения → Изменить)")
        }
        return
    }
    print("Найдено для запуска:")
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
    print("Путь запуска записан в рецепт и программа закреплена в пространстве: \(best.windowsPath)")
}
