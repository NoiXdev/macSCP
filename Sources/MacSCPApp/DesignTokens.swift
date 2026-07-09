import AppKit
import SwiftUI

/// Marken-Duo aus docs/design/ci.md: Bernstein = Lokal, Ozeanblau = Remote.
/// Dynamisch für Hell/Dunkel. Nur semantisch einsetzen (Pane-Badges,
/// später Transferrichtung) — der Rest der App bleibt bei Systemfarben.
enum DesignTokens {
    static let localAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 232 / 255, green: 166 / 255, blue: 60 / 255, alpha: 1) // #E8A63C
            : NSColor(srgbRed: 222 / 255, green: 148 / 255, blue: 38 / 255, alpha: 1) // #DE9426
    })

    static let remoteBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 78 / 255, green: 146 / 255, blue: 214 / 255, alpha: 1) // #4E92D6
            : NSColor(srgbRed: 45 / 255, green: 113 / 255, blue: 184 / 255, alpha: 1) // #2D71B8
    })

    /// Phosphor aus docs/design/ci.md: Verbunden-Status, Terminal-Grün.
    static let statusPhosphor = Color(nsColor: NSColor(
        srgbRed: 123 / 255, green: 216 / 255, blue: 143 / 255, alpha: 1)) // #7BD88F
}
