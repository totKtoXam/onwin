import SwiftUI
import OnwinCore

// "Игре может понадобиться: …" — shown on the space page (SpaceDetailView) above the program grid.
// Suggestions come from AppModel+Components.swift: the import tables of the space's programs (static)
// and the Wine log of the last run that exited with an error (dynamic, listed first).

@MainActor
struct ComponentSuggestionsBanner: View {
    @Environment(AppModel.self) private var model
    let space: Space
    let suggestions: [Suggestion]
    @State private var expanded = false

    private static let collapsedCount = 3

    var body: some View {
        let failure = model.failureAdvice(for: space.id)
        let visible = expanded ? suggestions : Array(suggestions.prefix(Self.collapsedCount))
        let installable = suggestions.compactMap(\.component).filter { $0.kind == .space }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: failure != nil ? "stethoscope" : "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(failure != nil ? Color.orange : OnwinTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(failure: failure))
                        .font(.headline)
                    Text(subtitle(failure: failure))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let failure {
                    Button {
                        model.open(failure.logURL)
                    } label: {
                        Label("Журнал", systemImage: "doc.text.magnifyingglass")
                    }
                    .help(failure.logURL.lastPathComponent)
                    Button {
                        model.reportProblem(space: space, log: failure.logURL, title: failure.programTitle,
                                            exitStatus: failure.exitStatus)
                    } label: {
                        Label("Сообщить о проблеме", systemImage: "ladybug")
                    }
                    .help("Собрать сведения для чата поддержки вместе с журналом запуска")
                    Button {
                        model.clearFailureAdvice(for: space.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Скрыть советы по этому запуску")
                }
            }

            VStack(spacing: 0) {
                ForEach(visible) { suggestion in
                    SuggestionRow(suggestion: suggestion,
                                  canInstall: canInstall(suggestion),
                                  onInstall: { install(suggestion) },
                                  onDismiss: { model.dismissSuggestion(suggestion, in: space.id) })
                    if suggestion.id != visible.last?.id {
                        Divider().padding(.leading, 42)
                    }
                }
            }

            HStack(spacing: 10) {
                if suggestions.count > Self.collapsedCount {
                    Button(expanded ? String(localized: "Свернуть")
                                    : String(localized: "Ещё \(suggestions.count - Self.collapsedCount)…")) {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
                if installable.count > 1 {
                    Button {
                        let target = space
                        Task { @MainActor in await model.installComponents(installable, into: target) }
                    } label: {
                        Label("Установить всё (\(installable.count))", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasEngine || !space.isInitialized)
                    .help(installable.map(\.name).joined(separator: ", "))
                }
            }
        }
        .onwinCard(padding: 14)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(failure != nil ? Color.orange : OnwinTheme.accent)
                .frame(width: 3)
                .padding(.vertical, 14)
        }
    }

    private func title(failure: FailureAdvice?) -> String {
        if let failure { return String(localized: "«\(failure.programTitle)» не запустилась — вот что может помочь") }
        return String(localized: "Игре может понадобиться")
    }

    private func subtitle(failure: FailureAdvice?) -> String {
        let names = suggestions.prefix(4).map(\.title).joined(separator: ", ")
        if failure != nil { return String(localized: "По журналу запуска: \(names)") }
        if model.autoInstallsComponents(in: space) {
            return String(localized: "onwin поставит их сам при первом запуске программы, но можно и сейчас: \(names)")
        }
        return String(localized: "onwin посмотрел, какие библиотеки загружают программы этого пространства: \(names)")
    }

    private func canInstall(_ suggestion: Suggestion) -> Bool {
        guard let component = suggestion.component else { return false }
        if component.kind == .global { return true }
        return model.hasEngine && space.isInitialized
    }

    private func install(_ suggestion: Suggestion) {
        let target = space
        Task { @MainActor in await model.install(suggestion: suggestion, in: target) }
    }
}

@MainActor
private struct SuggestionRow: View {
    let suggestion: Suggestion
    let canInstall: Bool
    let onInstall: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let component = suggestion.component {
                OnwinSpaceIcon(symbol: component.symbol, size: 30)
            } else {
                Image(systemName: "lightbulb")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.yellow)
                    .frame(width: 30, height: 30)
                    .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.body.weight(.medium))
                    if let component = suggestion.component {
                        Text(component.sizeDescription)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if suggestion.source == .log {
                        Text("из журнала")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                }
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(suggestion.evidence.joined(separator: "\n"))
            Spacer(minLength: 8)
            if let component = suggestion.component {
                Button(component.kind == .global ? String(localized: "Установить D3DMetal") : String(localized: "Установить"),
                       action: onInstall)
                    .buttonStyle(.bordered)
                    .disabled(!canInstall)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Не сейчас")
        }
        .padding(.vertical, 8)
    }
}
