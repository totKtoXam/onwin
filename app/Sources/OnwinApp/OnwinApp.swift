import AppKit
import SwiftUI
import OnwinCore

@main
struct OnwinApp: App {
    @NSApplicationDelegateAdaptor(OnwinAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("onwin") {
            OnwinRootView()
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            OnwinCommands()
        }

        SwiftUI.Settings {
            PreferencesView()
                .environment(AppModel.shared)
                .tint(OnwinTheme.accent)
        }
    }
}

/// Root of the main window: injects the model and receives opened files.
@MainActor
struct OnwinRootView: View {
    var body: some View {
        ContentView()
            .environment(AppModel.shared)
            .tint(OnwinTheme.accent)
            .onwinRosettaCheck()   // Views/RosettaCheck.swift
            .onwinUserRecipes()    // recipe editor «Мои приложения» (AppModel+UserRecipes.swift)
            .onOpenURL { url in
                AppModel.shared.handleOpened([url])   // onwin:// launchers, .onwinspace, .onwinrecipe, exe/msi/lnk
            }
    }
}

/// App delegate: makes a bare SwiftPM executable behave like a normal app and handles
/// .exe / .msi / .lnk files opened with onwin (Finder "Open With", `open -a`, drag onto the Dock icon).
@MainActor
final class OnwinAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Without an Info.plist (swift run / .build/debug/Onwin) the process would start as a
        // background-only app with no Dock icon, menu bar or key window.
        NSApplication.shared.setActivationPolicy(.regular)
        // Before anything can start Wine: an Onwin.app downloaded in a browser (the DMG) carries the
        // quarantine flag on every file of the bundled engine (Engine.swift).
        EngineManager.clearQuarantineOfBundledEngine()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        UpdateController.shared.checkAtLaunchIfNeeded()   // Views/UpdateViews.swift
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.handleOpened(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Menu bar commands.
struct OnwinCommands: Commands {
    var body: some Commands {
        let model = AppModel.shared

        CommandGroup(replacing: .appInfo) {
            Button("О программе onwin") {
                // The standard panel, with the beta mark next to the version («0.1.0 (бета)»).
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .applicationVersion: OnwinVersion.displayString,
                ])
            }
            Button("Проверить обновления…") {
                Task { await UpdateController.shared.check(userInitiated: true) }   // Views/UpdateViews.swift
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Новое пространство…") {
                model.showNewSpaceSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.hasEngine)

            Button("Запустить программу…") {
                model.chooseAndRun(in: model.selectedSpace)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.hasEngine)

            Divider()

            Button("Восстановить пространство из архива…") {
                model.restoreInteractively()
            }
        }

        CommandMenu("Пространство") {
            Button("Рабочий стол") {
                model.selection = .desktop   // Views/DesktopView.swift
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Установить из каталога…") {
                model.selection = .catalog
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Настройки пространства…") {
                if let space = model.selectedSpace { model.settingsSpaceID = space.id }
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
            .disabled(model.selectedSpace == nil)

            Button("Выполнить команду…") {
                if let space = model.selectedSpace { ProgramDialogs.shared.request = .runCommand(space.id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedSpace == nil || !model.hasEngine)

            Button("Удалить программу…") {
                if let space = model.selectedSpace { ProgramDialogs.shared.request = .uninstall(space.id) }
            }
            .disabled(model.selectedSpace == nil)

            Menu("Инструменты Windows") {
                ForEach(WineTool.allCases) { tool in
                    Button(tool.title) {
                        if let space = model.selectedSpace { model.runTool(tool, in: space) }
                    }
                }
            }
            .disabled(model.selectedSpace == nil || !model.hasEngine)

            Button("Показать в Finder") {
                if let space = model.selectedSpace { model.revealInFinder(space.url) }
            }
            .disabled(model.selectedSpace == nil)

            Divider()

            Button("Завершить все программы пространства") {
                if let space = model.selectedSpace {
                    Task { await model.quitAll(in: space) }
                }
            }
            .disabled(model.selectedSpace == nil)

            Divider()

            Button("Установить D3DMetal…") {
                Task { @MainActor in await model.fetchD3DMetal() }
            }

            Button("Импортировать D3DMetal из папки…") {
                model.importD3DMetalInteractively()
            }

            Button("Обновить") {
                model.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
