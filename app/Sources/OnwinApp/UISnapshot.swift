import AppKit

/// Testing aid: `ONWIN_UI_SNAPSHOT=<folder>` makes onwin open its settings window, save a PNG of every
/// window it shows (and of the large SwiftUI areas inside it) into <folder> and quit. Used to check the
/// interface translations without Screen Recording permission (onwin draws only its own windows):
///
///     ONWIN_HOME=$(mktemp -d) ONWIN_UI_SNAPSHOT=/tmp/shots \
///         build/app.noindex/Onwin.app/Contents/MacOS/Onwin -AppleLanguages '(en)'
///
/// (Put {"checkForUpdates": false} into $ONWIN_HOME/settings.json first, or the first-launch question
/// about update checks blocks the run.)
///
/// With ONWIN_UI_SNAPSHOT (or ONWIN_NO_ACTIVATE=1) onwin runs in the background: no Dock icon, never
/// activates itself or takes focus, and keeps its windows off-screen behind everything — a test run must
/// not interrupt what the user is doing (a game in full screen, for one).
@MainActor
enum UISnapshot {
    /// onwin must stay in the background (tests, snapshots).
    static let isBackground: Bool = {
        let env = ProcessInfo.processInfo.environment
        return !(env["ONWIN_UI_SNAPSHOT"] ?? "").isEmpty || env["ONWIN_NO_ACTIVATE"] == "1"
    }()

    private static var hiddenWindows = Set<ObjectIdentifier>()

    /// Keeps every window of a background run off-screen and behind other apps' windows; called before
    /// the first window appears (applicationWillFinishLaunching).
    static func keepWindowsInBackground() {
        guard isBackground else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApplication.shared.windows where !hiddenWindows.contains(ObjectIdentifier(window)) {
                    hiddenWindows.insert(ObjectIdentifier(window))
                    window.ignoresMouseEvents = true
                    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                    window.orderBack(nil)
                }
            }
        }
    }

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["ONWIN_UI_SNAPSHOT"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            openSettings()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            capture(into: folder)
            NSApplication.shared.terminate(nil)
        }
    }

    /// The app menu's «Настройки…» (⌘,), as if chosen by the user.
    private static func openSettings() {
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        appMenu.performActionForItem(at: index)
    }

    private static func capture(into folder: URL) {
        for (index, window) in NSApplication.shared.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let name = "\(index)-" + (window.title.isEmpty ? "window" : window.title).replacingOccurrences(of: "/", with: "-")
            save(view, to: folder.appending(path: "\(name).png"))
            // Split views (sidebar | detail) host their columns in nested SwiftUI views: save the large
            // ones separately too, in case the window-level image leaves them blank.
            var part = 0
            for nested in hostingViews(in: view) where nested.bounds.width > 200 && nested.bounds.height > 200 {
                part += 1
                save(nested, to: folder.appending(path: "\(name)-part\(part).png"))
            }
        }
    }

    private static func save(_ view: NSView, to file: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // Layer rendering also draws SwiftUI's layer-backed content, which cacheDisplay(in:to:) leaves blank.
        if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
            let cg = context.cgContext
            if layer.isGeometryFlipped {
                cg.translateBy(x: 0, y: view.bounds.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    private static func hostingViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        for subview in view.subviews {
            if String(describing: type(of: subview)).contains("HostingView") { found.append(subview) }
            found += hostingViews(in: subview)
        }
        return found
    }
}
