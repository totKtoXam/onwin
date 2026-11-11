import SwiftUI
import OnwinCore

/// Program context-menu items: «Создать ярлык в Launchpad» or, when the launcher exists,
/// «Показать ярлык в Finder» / «Удалить ярлык из Launchpad».
@MainActor
struct LauncherMenuItems: View {
    @Environment(AppModel.self) private var model
    let program: SpaceProgram
    let space: Space

    var body: some View {
        if let launcher = model.launcher(for: program, in: space) {
            Button {
                model.revealInFinder(launcher.url)
            } label: {
                Label("Показать ярлык в Finder", systemImage: "app.badge")
            }
            Button {
                model.removeLauncher(for: program, in: space)
            } label: {
                Label("Удалить ярлык из Launchpad", systemImage: "minus.square")
            }
        } else {
            Button {
                model.createLauncher(for: program, in: space)
            } label: {
                Label("Создать ярлык в Launchpad", systemImage: "plus.app")
            }
        }
    }
}

/// Space settings section «Ярлыки в Launchpad».
@MainActor
struct LauncherSettingsSection: View {
    @Environment(AppModel.self) private var model
    let space: Space

    private var isOn: Binding<Bool> {
        Binding(get: { model.space(id: space.id)?.config.autoLaunchers ?? false },
                set: { model.setAutoLaunchers($0, for: space.id) })
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Создавать ярлыки автоматически")
                    Text("Для каждой программы из меню «Пуск» onwin сделает приложение — его можно найти в Launchpad и Spotlight и закрепить в Dock. Ярлыки удалённых программ исчезнут сами")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let launchers = model.launchers(of: space.id)
            LabeledContent("Ярлыки") {
                HStack(spacing: 10) {
                    Text(launchers.isEmpty ? String(localized: "нет", comment: "Number of launchers: none") : "\(launchers.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Показать в Finder") {
                        model.revealInFinder(launchers.first?.url.deletingLastPathComponent()
                                             ?? LauncherBuilder.directory(for: space))
                    }
                    .disabled(launchers.isEmpty)
                }
            }
        } header: {
            Text("Ярлыки в Launchpad")
        } footer: {
            Text("Ярлыки лежат в ~/Applications/onwin/\(space.name). Создать ярлык для одной программы можно в её контекстном меню.")
        }
    }
}
