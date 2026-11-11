import AppKit
import Foundation

// onwin-launcher — main executable of the per-program .app bundles that LauncherBuilder makes
// (~/Applications/onwin/<space>/<program>.app). It reads `OnwinLauncher` from its own Info.plist
// and hands `onwin://run?...` to onwin.app, which starts and tracks the program. Without onwin.app
// it runs `onwinctl open-url <url>` and waits for the program to exit.
//
//   launcher --print     show what would be done, do nothing (for tests)

let appBundleIdentifier = "app.onwin.Onwin"
let dryRun = CommandLine.arguments.dropFirst().contains("--print")

func say(_ text: String) {
    FileHandle.standardError.write(Data("onwin-launcher: \(text)\n".utf8))
}

func alert(_ title: String, _ message: String) -> Never {
    say("\(title): \(message)")
    if !dryRun {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    exit(1)
}

// The launcher has no resource bundle (it is copied alone into every launcher .app), so its few
// messages are translated here. Russian for Russian, otherwise the first supported preferred
// language, English when there is none.
let language: String = {
    for id in Locale.preferredLanguages {
        let preferred = Locale.Language(identifier: id)
        switch preferred.languageCode?.identifier {
        case "ru": return "ru"
        case "en": return "en"
        case "kk": return "kk"
        case "zh" where preferred.maximalIdentifier.hasPrefix("zh-Hans"): return "zh-Hans"
        default: continue
        }
    }
    return "en"
}()

func text(ru: String, en: String, zh: String, kk: String) -> String {
    switch language {
    case "ru": return ru
    case "zh-Hans": return zh
    case "kk": return kk
    default: return en
    }
}

let info = Bundle.main.infoDictionary?["OnwinLauncher"] as? [String: Any] ?? [:]
let programName = Bundle.main.infoDictionary?["CFBundleName"] as? String
    ?? text(ru: "Программа", en: "Program", zh: "程序", kk: "Бағдарлама")
guard let urlString = info["URL"] as? String, let url = URL(string: urlString) else {
    alert(text(ru: "Ярлык повреждён", en: "The shortcut is damaged", zh: "快捷方式已损坏", kk: "Жарлық зақымдалған"),
          text(ru: "В Info.plist ярлыка «\(programName)» нет адреса onwin://. Создайте ярлык заново в onwin.",
               en: "The Info.plist of the shortcut “\(programName)” has no onwin:// address. Create the shortcut again in onwin.",
               zh: "快捷方式“\(programName)”的 Info.plist 中没有 onwin:// 地址。请在 onwin 中重新创建快捷方式。",
               kk: "«\(programName)» жарлығының Info.plist файлында onwin:// мекенжайы жоқ. Жарлықты onwin ішінде қайта жасаңыз."))
}

// 1. onwin.app: it runs the program itself (log, «Запущенные», error messages).
let onwinApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
if let onwinApp {
    if dryRun {
        print("open \(url.absoluteString) with \(onwinApp.path)")
        exit(0)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var error: Error? }
    let box = Box()
    NSWorkspace.shared.open([url], withApplicationAt: onwinApp, configuration: configuration) { _, error in
        box.error = error
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .success, box.error == nil { exit(0) }
    say("onwin.app не открыл ярлык: \(box.error?.localizedDescription ?? "нет ответа"); пробую onwinctl")
}

// 2. onwinctl (onwin.app not installed or did not answer).
let home = FileManager.default.homeDirectoryForCurrentUser.path
var candidates: [String] = []
if let recorded = info["Onwinctl"] as? String { candidates.append(recorded) }
if let onwinApp { candidates.append(onwinApp.appendingPathComponent("Contents/MacOS/onwinctl").path) }
candidates += ["/Applications/Onwin.app/Contents/MacOS/onwinctl", "\(home)/Applications/Onwin.app/Contents/MacOS/onwinctl",
               "/usr/local/bin/onwinctl", "/opt/homebrew/bin/onwinctl", "\(home)/.local/bin/onwinctl"]
guard let ctl = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    alert(text(ru: "onwin не найден", en: "onwin was not found", zh: "未找到 onwin", kk: "onwin табылмады"),
          text(ru: "Чтобы запустить «\(programName)», установите onwin в папку «Программы».",
               en: "To open “\(programName)”, install onwin in the Applications folder.",
               zh: "要运行“\(programName)”，请将 onwin 安装到“应用程序”文件夹。",
               kk: "«\(programName)» бағдарламасын іске қосу үшін onwin-ді «Қолданбалар» қалтасына орнатыңыз."))
}
if dryRun {
    print("\(ctl) open-url \(url.absoluteString)")
    exit(0)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: ctl)
process.arguments = ["open-url", url.absoluteString]
process.standardInput = FileHandle.nullDevice
do {
    try process.run()
} catch {
    alert(text(ru: "Не удалось запустить «\(programName)»", en: "Could not open “\(programName)”",
               zh: "无法启动“\(programName)”", kk: "«\(programName)» іске қосылмады"),
          error.localizedDescription)
}
process.waitUntilExit()
exit(process.terminationStatus)
