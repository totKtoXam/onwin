import Foundation
import OnwinCore

// `onwinctl d3dmetal-fetch`: the terminal cannot show Apple's sign-in page (WebKit lives in the app,
// and the app's Apple session is kept in the app's own web data store), so the CLI only uses a
// Game Porting Toolkit image that is already on disk or mounted — ~/Downloads, onwin's download
// cache (where the app puts it), /Volumes — and otherwise explains how to get it.

/// Returns where D3DMetal was imported from.
@discardableResult
func d3dmetalFetch(_ arguments: [String]) async throws -> URL {
    var rest = arguments
    var options = D3DMetalImporter.Options()
    if let minutes = option("--timeout", in: &rest).flatMap(Double.init) { options.timeout = minutes * 60 }
    if let dir = option("--downloads", in: &rest) { options.downloadDirectories = [URL(fileURLWithPath: dir, isDirectory: true)] }
    let wait = rest.contains("--wait") || rest.contains("--browser")
    options.openBrowser = rest.contains("--browser")

    if let found = D3DMetalImporter.find(options: options) {
        print(String(localized: "Нашёл \(found.url.path)", bundle: .onwinctl))
        try await D3DMetalImporter.importFound(found, progress: printProgress)
        return found.url
    }
    guard wait else {
        print(String(localized: """
        Game Porting Toolkit не найден ни в «Загрузках», ни в кэше onwin, ни среди подключённых дисков.
        Apple отдаёт его только после входа с Apple ID, а вход возможен только в приложении:
          onwin → Каталог → D3DMetal → «Установить D3DMetal» (вход, загрузка и установка — внутри onwin).
        Или скачайте .dmg сами (\(Catalog.gameportingToolkitURL.absoluteString)) и запустите
          onwinctl d3dmetal-fetch            — onwin найдёт его в «Загрузках»
          onwinctl d3dmetal-fetch --wait     — ждать появления .dmg (--browser — ещё и открыть страницу Apple)
        """, bundle: .onwinctl))
        exit(1)
    }
    let found = try await D3DMetalImporter.run(options: options, progress: printProgress)
    return found.url
}
