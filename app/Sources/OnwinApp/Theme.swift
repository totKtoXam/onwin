import SwiftUI
import OnwinCore

/// onwin's own visual language: calm, dark-friendly, teal accent, rounded "library" cards on system materials.
enum OnwinTheme {
    static let accent = Color.teal
    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let running = Color.green

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color.teal, Color.teal.opacity(0.6)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Rounded card on a system material with a hairline border.
struct OnwinCardModifier: ViewModifier {
    var padding: CGFloat = OnwinTheme.cardPadding
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? OnwinTheme.accent : Color.primary.opacity(0.08),
                                  lineWidth: highlighted ? 2 : 1)
            )
    }
}

extension View {
    func onwinCard(padding: CGFloat = OnwinTheme.cardPadding, highlighted: Bool = false) -> some View {
        modifier(OnwinCardModifier(padding: padding, highlighted: highlighted))
    }
}

/// Square teal tile with an SF Symbol — the "cover" of a space in lists and grids.
@MainActor
struct OnwinSpaceIcon: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(OnwinTheme.accentGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(Color.white)
            )
            .shadow(color: Color.black.opacity(0.15), radius: size * 0.06, y: size * 0.03)
    }
}

/// Small green dot shown next to spaces that have running programs.
@MainActor
struct OnwinRunningDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(OnwinTheme.running)
            .frame(width: size, height: size)
            .shadow(color: OnwinTheme.running.opacity(0.6), radius: 3)
            .accessibilityLabel("Запущено")
    }
}

extension Space {
    /// SF Symbol for the space: the catalog recipe's symbol if the space came from one, otherwise a box.
    var onwinSymbol: String {
        if let recipe = Catalog.apps.first(where: { $0.spaceName.caseInsensitiveCompare(name) == .orderedSame }) {
            return recipe.symbol
        }
        let lower = name.lowercased()
        if lower.contains("game") || lower.contains("игр") { return "gamecontroller.fill" }
        return "shippingbox.fill"
    }
}
