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

    /// Terminal-Hintergrund: Tiefsee (#0F1E2B) — bewusst NICHT dynamisch,
    /// das Terminal ist in Hell wie Dunkel eine "dunkle Konsole".
    static let terminalBackground = NSColor(
        srgbRed: 0x0F / 255, green: 0x1E / 255, blue: 0x2B / 255, alpha: 1)
    /// Terminal-Text/Caret: Phosphor (#7BD88F).
    static let terminalText = NSColor(
        srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)
}
