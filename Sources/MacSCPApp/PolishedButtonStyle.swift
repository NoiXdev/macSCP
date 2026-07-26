import SwiftUI

/// Mockup button style (M5k): radius 7, 5x14 padding, 12.5pt type.
/// `prominent` fills with the CI primary blue (white semibold label);
/// the secondary variant sits on the card surface with a hairline border.
/// System chrome (toolbar, alerts, sheets) deliberately keeps the system
/// button styles — this style is for in-content forms only.
struct PolishedButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        PolishedButtonBody(prominent: prominent, configuration: configuration)
    }
}

/// Split out so the style can read environment values (M6a focus ring).
private struct PolishedButtonBody: View {
    let prominent: Bool
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : DesignTokens.inkSecondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? DesignTokens.remoteBlue : DesignTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(DesignTokens.hairline, lineWidth: prominent ? 0 : 1)
            )
            // Full Keyboard Access: custom button styles suppress the system
            // focus ring, so draw one — 2pt remote blue, slightly outset so
            // it never collides with the secondary variant's hairline (M6a).
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(DesignTokens.remoteBlue, lineWidth: isFocused ? 2 : 0)
                    .padding(-3)
            )
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension ButtonStyle where Self == PolishedButtonStyle {
    /// Secondary form button: card surface, hairline border.
    static var polished: PolishedButtonStyle { .init(prominent: false) }
    /// Primary form button: filled in the CI remote blue.
    static var polishedProminent: PolishedButtonStyle { .init(prominent: true) }
}
