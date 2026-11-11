import Foundation

/// Public web addresses used by the app and onwinctl. One place, so a link changes in one commit.
public enum OnwinLinks {
    /// The project's site (GitHub Pages).
    public static let site = URL(string: "https://totktoxam.github.io/onwin/")!

    /// Documentation on the site (sidebar link «Документация», Help menu).
    public static let documentation = URL(string: "https://totktoxam.github.io/onwin/docs.html")!

    /// «Что делать, если не работает» on the site: opened by «Сообщить о проблеме» while there is no chat yet.
    public static let troubleshooting = URL(string: "https://totktoxam.github.io/onwin/docs.html#troubleshooting")!

    /// Invite link of the support chat: the Telegram group «onwin — помощь».
    /// Leave it empty to fall back to the troubleshooting page.
    public static let supportChat = "https://t.me/+KGkGUTbpk0ZjNDEy"

    /// Where «Скопировать и открыть чат поддержки» goes: the chat, or the troubleshooting page while
    /// `supportChat` is empty.
    public static var supportDestination: URL {
        let trimmed = supportChat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed) { return url }
        return troubleshooting
    }

    /// True when `supportDestination` is a real chat (not the fallback page).
    public static var hasSupportChat: Bool { supportDestination != troubleshooting }

    /// GitHub repository of onwin ("owner/name"): releases, the updater's onwin-release.json.
    public static let repository = "totKtoXam/onwin"
}
