import AppKit
import SwiftUI
import OnwinCore

// "Перезапустить пространство": asked when MSync, Retina mode or the Mac folders setting is switched while
// the space runs (the running wineserver would not pick the change up, see WineRunner.restart; the
// profile folders must not be replaced under running programs, see MacFolders).
// Used by SpaceSettingsForm: it holds back such a change and sets `pending`; this modifier asks.

extension View {
    func spaceRestartPrompt(_ pending: Binding<RestartSensitiveChange?>, space: Space) -> some View {
        modifier(SpaceRestartPromptModifier(pending: pending, space: space))
    }
}

@MainActor
private struct SpaceRestartPromptModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: RestartSensitiveChange?
    let space: Space

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Пространство «\(space.name)» сейчас работает",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { change in
            Button(change.actionTitle, role: .destructive) {
                pending = nil
                Task { @MainActor in await model.restartSpace(space.id, applying: change) }
            }
            Button("Отмена", role: .cancel) { pending = nil }
        } message: { change in
            Text(verbatim: message(for: change))
        }
    }

    private func message(for change: RestartSensitiveChange) -> String {
        var text = String(localized: "Эта настройка начнёт действовать только после перезапуска пространства: все его программы будут закрыты. Программы смогут сохранить данные, но если какая-то не закроется за 10 секунд, её завершат принудительно и несохранённое пропадёт.")
        if change.msync == true {
            text += "\n\n" + String(localized: "Некоторые Windows-программы с MSync работают неправильно.")
        }
        if change.linkMacFolders != nil {
            text += "\n\n" + String(localized: "Папки «Документы», «Загрузки» и другие можно поменять, только пока в пространстве ничего не запущено.")
        }
        if change.highResolution == true {
            text += "\n\n" + String(localized: "Многие Windows-программы в режиме Retina выглядят неправильно.")
            if let note = DisplayScaleInfo.retinaNote { text += " " + note }
        }
        return text
    }
}

/// Retina / non-Retina screens, for the notes shown when Retina mode is turned on.
enum DisplayScaleInfo {
    @MainActor
    static var retinaNote: String? {
        let scales = NSScreen.screens.map(\.backingScaleFactor)
        guard !scales.isEmpty else { return nil }
        let retina = scales.filter { $0 > 1.5 }.count
        if retina == 0 {
            return String(localized: "У этого Mac нет экранов Retina: в этом режиме картинка станет только размытой.")
        }
        if retina < scales.count {
            return String(localized: "Экраны разные: на Retina картинка станет чётче, на обычных — хуже.")
        }
        return nil
    }
}
