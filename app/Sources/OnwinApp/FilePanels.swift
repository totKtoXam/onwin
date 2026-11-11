import AppKit
import UniformTypeIdentifiers
import OnwinCore

/// Open/save panels used by the app (modal, main thread).
@MainActor
enum OnwinPanels {
    static var runnableTypes: [UTType] {
        WineFileTypes.runnableExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// .exe / .msi / .lnk / .bat files to run. Empty when cancelled.
    static func chooseRunnableFiles(allowsMultiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Запуск Windows-программы")
        panel.message = String(localized: "Выберите программу (.exe), установщик (.msi) или ярлык (.lnk)")
        panel.prompt = String(localized: "Запустить")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        let types = runnableTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(title: String, message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(title: String, message: String, prompt: String, extensions: [String] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// D3DMetal source: a mounted Game Porting Toolkit volume / its redist folder, or the .dmg itself.
    static func chooseD3DMetalSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт D3DMetal")
        panel.message = String(localized: "Выберите образ Game Porting Toolkit (.dmg), его смонтированный том или папку redist")
        panel.prompt = String(localized: "Импортировать")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let dmg = UTType(filenameExtension: "dmg") { panel.allowedContentTypes = [dmg, .folder, .volume] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Space archive (.onwinspace, a tar.gz).
    static func chooseArchive() -> URL? {
        chooseFile(title: String(localized: "Восстановление пространства"),
                   message: String(localized: "Выберите архив пространства (.onwinspace)"),
                   prompt: String(localized: "Восстановить"))
    }

    static func saveArchive(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Архивировать пространство")
        panel.message = String(localized: "Пространство будет упаковано в один файл — его можно перенести на другой Mac")
        panel.prompt = String(localized: "Архивировать")
        panel.nameFieldStringValue = "\(suggestedName).onwinspace"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
