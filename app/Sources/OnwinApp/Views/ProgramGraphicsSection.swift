import SwiftUI
import OnwinCore

/// "Графика для этой программы" in the program properties sheet (SpaceDetailView).
///
/// The choice is saved as `ProgramEntry.overrides.graphicsBackend` and written to the space's
/// compat rules (CompatRules), so onwincompat applies it to this exe inside Wine, also when a
/// launcher starts it. "Автоматически" = onwin's built-in rule for the exe (CompatDB: launchers
/// and their web helpers → WineD3D), otherwise the space's backend.
@MainActor
struct ProgramGraphicsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: GraphicsBackend
    let space: Space
    let windowsPath: String

    var body: some View {
        let engine = model.engine(for: space)
        Section {
            Picker("Графика", selection: $selection) {
                ForEach(GraphicsBackend.allCases) { backend in
                    let reason = unavailableReason(backend, engine: engine)
                    Text(verbatim: reason == nil ? title(for: backend) : "\(title(for: backend)) — недоступно")
                        .tag(backend)
                        .disabled(reason != nil && backend != selection)
                }
            }
        } header: {
            Text("Графика для этой программы")
        } footer: {
            Text(verbatim: footer(engine: engine))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(for backend: GraphicsBackend) -> String {
        backend == .auto ? "Автоматически" : backend.displayName
    }

    private func unavailableReason(_ backend: GraphicsBackend, engine: Engine?) -> String? {
        SettingsBackendAvailability.unavailableReason(backend, engine: engine,
                                                      d3dmetalInstalled: model.isD3DMetalInstalled)
    }

    private func footer(engine: Engine?) -> String {
        guard let engine else { return "Сначала установите движок Wine." }
        let spaceBackend = GraphicsSupport.resolve(space.config.graphicsBackend, engine: engine)
        if selection == .auto {
            if let rule = CompatDB.rule(forExecutable: windowsPath), let backend = rule.backend,
               backend != .auto, GraphicsSupport.isAvailable(backend, engine: engine) {
                return "Сейчас: \(backend.displayName). Для лаунчеров и их веб-окон onwin выбирает его сам: на Metal-трансляторах эти окна отображаются с ошибками. Игры, которые лаунчер запускает, получают графику пространства (\(spaceBackend.displayName))."
            }
            return "Сейчас: \(spaceBackend.displayName), как у пространства."
        }
        if let reason = unavailableReason(selection, engine: engine) {
            return "\(selection.displayName) недоступен: \(reason). Программа получит \(spaceBackend.displayName)."
        }
        return "\(selection.summary). Выбор привязан к этому exe: он действует и тогда, когда программу запускает лаунчер. При запуске отсюда тот же бэкенд получат и программы, которые она откроет."
    }
}
