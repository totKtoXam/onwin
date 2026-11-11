import AppKit
import SwiftUI
import OnwinCore

// "Launch the app I installed" in one click, wherever the user is:
//
//   ProgramLaunchHistory.shared            when each program of a space was last started (AppModel.run(program:in:)
//                                          records it); kept in UserDefaults, per Mac user
//   model.mainProgram(in: space)          first pinned program, else the most recently launched, else the first one
//   model.launchablePrograms(in: space)   the pinned programs offered by the dropdown next to the main button
//   SpaceMainProgramButton                big «▶ Запустить <Program>» under the space title (SpaceDetailView)
//   Space.hasInstalled(recipe)            the recipe's launchPath exists in the space (catalog cards, recipe sheet)
//   model.launchInstalled(recipe, in:)     runs it: the pinned entry (its arguments, e.g. Steam's -cef-disable-gpu…)
//                                          or the file itself with the recipe's launchArguments
//   InstallFollowUp.shared / InstallFollowUpBar
//                                          after a successful catalog install, TaskProgressSheet offers
//                                          «Запустить <Program>» and «Открыть пространство»

// MARK: - Launch history

@MainActor
@Observable
final class ProgramLaunchHistory {
    static let shared = ProgramLaunchHistory()

    private static let defaultsKey = "onwin.programLaunchHistory"

    /// space id → program id (`SpaceProgram.id`) → last start.
    private(set) var dates: [UUID: [String: Date]]

    private init() {
        var loaded: [UUID: [String: Date]] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: ProgramLaunchHistory.defaultsKey) as? [String: [String: Double]] {
            for (space, programs) in raw {
                guard let id = UUID(uuidString: space) else { continue }
                loaded[id] = programs.mapValues { Date(timeIntervalSince1970: $0) }
            }
        }
        dates = loaded
    }

    func record(_ program: SpaceProgram, in spaceID: UUID) {
        dates[spaceID, default: [:]][program.id] = Date()
        save()
    }

    func lastLaunch(of program: SpaceProgram, in spaceID: UUID) -> Date? {
        dates[spaceID]?[program.id]
    }

    private func save() {
        var raw: [String: [String: Double]] = [:]
        for (space, programs) in dates {
            raw[space.uuidString] = programs.mapValues { $0.timeIntervalSince1970 }
        }
        UserDefaults.standard.set(raw, forKey: ProgramLaunchHistory.defaultsKey)
    }
}

// MARK: - Main program and installed recipes

extension AppModel {
    /// Pinned programs of the space (in the order of its config).
    func launchablePrograms(in space: Space) -> [SpaceProgram] {
        programs(in: space).filter { SpaceDetailView.pinnedEntryID(of: $0) != nil }
    }

    /// What the space is "for": the first pinned program, else the most recently launched, else the first one.
    func mainProgram(in space: Space) -> SpaceProgram? {
        let all = programs(in: space)
        if let pinned = all.first(where: { SpaceDetailView.pinnedEntryID(of: $0) != nil }) { return pinned }
        let history = ProgramLaunchHistory.shared
        let recent = all.compactMap { program in history.lastLaunch(of: program, in: space.id).map { (program, $0) } }
            .max { $0.1 < $1.1 }
        return recent?.0 ?? all.first
    }

    /// Spaces in which the recipe's program is present on disk.
    func spacesWithInstalled(_ recipe: AppRecipe) -> [Space] {
        spaces.filter { $0.hasInstalled(recipe) }
    }

    /// The installed program of the space that corresponds to the recipe (its pinned entry), if any.
    func program(for recipe: AppRecipe, in space: Space) -> SpaceProgram? {
        guard let path = recipe.launchPath else { return nil }
        let current = self.space(id: space.id) ?? space
        let entryIDs = current.config.programs
            .filter { $0.windowsPath.caseInsensitiveCompare(path) == .orderedSame }
            .map { $0.id.uuidString }
        return programs(in: current).first { entryIDs.contains($0.id) }
    }

    /// Starts the recipe's program in the space: its pinned entry when there is one (with the arguments
    /// saved there), otherwise the file itself with the recipe's launch arguments and environment.
    @discardableResult
    func launchInstalled(_ recipe: AppRecipe, in space: Space) -> Bool {
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return false
        }
        let current = self.space(id: space.id) ?? space
        if let program = program(for: recipe, in: current) {
            return run(program: program, in: current) != nil || isPreparingLaunch(in: current.id)
        }
        guard let path = recipe.launchPath, let file = current.unixPath(forWindowsPath: path), OnwinPaths.exists(file) else {
            report(String(localized: "\(recipe.name) не найден в пространстве «\(current.name)»."))
            return false
        }
        var request = RunRequest()
        request.arguments = recipe.launchArguments
        request.environment = recipe.launchEnvironment
        return run(.file(file), in: current, request: request) != nil || isPreparingLaunch(in: current.id)
    }
}

extension Space {
    /// The recipe's program (`launchPath`) exists in this space.
    func hasInstalled(_ recipe: AppRecipe) -> Bool {
        guard let path = recipe.launchPath, let file = unixPath(forWindowsPath: path) else { return false }
        return OnwinPaths.exists(file)
    }
}

// MARK: - Main program button (space page)

/// «▶ Запустить Steam» with the program's own icon; a dropdown with the other pinned programs next to it.
@MainActor
struct SpaceMainProgramButton: View {
    @Environment(AppModel.self) private var model
    let space: Space
    let program: SpaceProgram
    /// Pinned programs; the dropdown appears when there are several.
    let alternatives: [SpaceProgram]
    let isRunning: Bool
    let onRun: (SpaceProgram) -> Void

    var body: some View {
        let enabled = model.hasEngine && space.isInitialized
        HStack(spacing: 6) {
            Button {
                onRun(program)
            } label: {
                HStack(spacing: 10) {
                    AppIconView(subject: .program(program, space: space), size: 30) {
                        RoundedRectangle(cornerRadius: 30 * 0.24, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                            .overlay(
                                Image(systemName: "app.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            )
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Запустить \(program.name)")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 320, alignment: .leading)
                    if isRunning {
                        OnwinRunningDot(size: 7)
                            .padding(.leading, 2)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 18)
                .frame(height: 46)
                .fixedSize()
            }
            .buttonStyle(MainProgramButtonStyle())
            .disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help(isRunning
                  ? String(localized: "\(program.name) уже работает — повторный запуск обычно выводит окно программы вперёд (⌘↩)")
                  : String(localized: "Запустить \(program.name) в пространстве «\(space.name)» (⌘↩)"))

            if alternatives.count > 1 {
                Menu {
                    ForEach(alternatives) { other in
                        Button {
                            onRun(other)
                        } label: {
                            Label(other.name, systemImage: other.id == program.id ? "star.fill" : "play.fill")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .fixedSize()
                .disabled(!enabled)
                .help("Другие закреплённые программы пространства")
            }
        }
    }
}

/// Teal gradient capsule-ish button of the main program (onwin's accent, white text).
private struct MainProgramButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .foregroundStyle(Color.white)
            .background(OnwinTheme.accentGradient, in: shape)
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.16 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: OnwinTheme.accent.opacity(isEnabled ? 0.35 : 0), radius: 6, y: 2)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - After a catalog install

/// What TaskProgressSheet offers once a catalog / user recipe installation finished successfully.
@MainActor
@Observable
final class InstallFollowUp {
    static let shared = InstallFollowUp()

    struct Offer: Equatable {
        var taskID: UUID
        var spaceID: UUID
        var recipe: AppRecipe
    }

    var offer: Offer?

    /// Called by `AppModel.install(recipe:into:)` after the run (the task sheet is still open).
    func present(after task: TaskState?, recipe: AppRecipe, space: Space) {
        guard let task, task.isFinished, task.error == nil else { offer = nil; return }
        offer = Offer(taskID: task.id, spaceID: space.id, recipe: recipe)
    }
}

/// «Готово» card inside TaskProgressSheet: «Открыть пространство» and «▶ Запустить <Program>».
@MainActor
struct InstallFollowUpBar: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        if task.isFinished, task.error == nil,
           let offer = InstallFollowUp.shared.offer, offer.taskID == task.id,
           let space = model.space(id: offer.spaceID) {
            let canLaunch = space.hasInstalled(offer.recipe)
            HStack(spacing: 12) {
                AppIconView(subject: .recipe(offer.recipe, spaces: [space]), symbol: offer.recipe.symbol, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(offer.recipe.name) установлен")
                        .font(.headline)
                    (canLaunch ? Text("в пространстве «\(space.name)» — можно запускать")
                               : Text("в пространстве «\(space.name)»"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Открыть пространство") {
                    model.selection = .space(space.id)
                    close()
                }
                if canLaunch {
                    Button {
                        if model.launchInstalled(offer.recipe, in: space) {
                            model.selection = .space(space.id)
                            close()
                        }
                    } label: {
                        Label("Запустить \(offer.recipe.name)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasEngine)
                }
            }
            .padding(12)
            .background(OnwinTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OnwinTheme.accent.opacity(0.35), lineWidth: 1))
        }
    }

    private func close() {
        InstallFollowUp.shared.offer = nil
        model.dismissTask()
    }
}

// MARK: - Catalog card buttons (installed apps)

/// «▶ Запустить» on the catalog card of an installed app (built-in and user recipes).
@MainActor
struct CatalogLaunchButton: View {
    let name: String
    let space: Space
    let canLaunch: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Запустить", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canLaunch)
        .help("Запустить \(name) в пространстве «\(space.name)»")
    }
}

/// Small «установить ещё раз» icon button next to «Запустить».
@MainActor
struct CatalogReinstallButton: View {
    let canInstall: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(!canInstall)
        .help("Установить ещё раз…")
        .accessibilityLabel("Установить ещё раз")
    }
}
