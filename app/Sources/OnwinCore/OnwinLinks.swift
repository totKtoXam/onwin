import Foundation

/// Public web addresses used by the app and onwinctl. One place, so a link changes in one commit.
public enum OnwinLinks {
    /// The project's site (GitHub Pages).
    public static let site = URL(string: "https://totktoxam.github.io/onwin/")!

    /// «Что делать, если не работает» on the site: opened by «Сообщить о проблеме» while there is no chat yet.
    public static let troubleshooting = URL(string: "https://totktoxam.github.io/onwin/docs.html#troubleshooting")!

    /// Invite link of the support chat (a Telegram group).
    // TODO: put the Telegram group's invite link here once the group exists (e.g. "https://t.me/…").
    public static let supportChat = ""

    /// Where «Скопировать и открыть чат поддержки» goes: the chat, or the troubleshooting page while
    /// `supportChat` is empty.
    public static var supportDestination: URL {
        let trimmed = supportChat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed) { return url }
        return troubleshooting
    }

    /// True when `supportDestination` is a real chat (not the fallback page).
    public static var hasSupportChat: Bool { supportDestination != troubleshooting }
}
