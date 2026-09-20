import AppKit
import SwiftTerm
import SwiftUI
import macSCPCore

/// What the terminal-theme picker shows for each shipped preset (plan of
/// 2026-09-19, "The answered wishes", Task 3).
///
/// The key is derived from the preset, so a preset added to
/// `TerminalThemePreset` gets a key without anyone typing it a second time;
/// the catalogue guard (`TerminalThemeWiringGuardTests`) walks
/// `TerminalThemePreset.allCases` through `key(for:)` and asks all four
/// catalogues for each. Same shape as `TerminalTypeLabel`.
enum TerminalThemeLabel {
    static func key(for preset: TerminalThemePreset) -> String {
        "terminal.theme.\(preset.rawValue)"
    }

    static func text(for preset: TerminalThemePreset) -> String {
        L10n.string(key(for: preset), englishText(for: preset))
    }

    /// The English text, as the lookup's fallback. The catalogue guard asks
    /// that the lookup never needs it.
    private static func englishText(for preset: TerminalThemePreset) -> String {
        switch preset {
        case .macSCP: return "macSCP (dark)"
        case .midnight: return "Midnight (dark)"
        case .paper: return "Paper (light)"
        }
    }

    /// The catalogue key for the imported row's fallback word. Exposed
    /// like `key(for:)` above so the catalogue guard can READ it rather
    /// than spell it a second time — a literal there is a copy of a name,
    /// waiting for a rename (CLAUDE.md, "Guards that name what they
    /// watch").
    static let importedKey = "terminal.theme.imported"

    /// The row for the imported theme: its file's name, or a translated
    /// word when the file's name yielded nothing usable
    /// (`ITermColorsImport.themeName(forFileNamed:)` answers `nil` then).
    static func importedText(name: String?) -> String {
        name ?? L10n.string(importedKey, "Imported theme")
    }
}

extension TerminalColor {
    /// The same colour as an AppKit colour, in sRGB — the space the stored
    /// components are in.
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// Spelled `SwiftUI.Color` because this file also names SwiftTerm's
    /// `Color` below, and the two are ambiguous here.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: nsColor)
    }

    /// The same colour as SwiftTerm's, whose components are 16 bits per
    /// channel. `× 257` is what maps 0...255 onto 0...65535 exactly (0xFF
    /// × 0x101 = 0xFFFF), which is how SwiftTerm's own 8-bit initializer
    /// widens its palettes — that one is not public at the pinned
    /// revision, so the multiplication is spelled here.
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }
}

/// The one place a `TerminalTheme` is handed to SwiftTerm.
///
/// Both surfaces that paint a live terminal go through it —
/// `SSHTerminalView.makeNSView` on the first render and
/// `SSHTerminalView.updateNSView` when the resolved theme changed — so the
/// order below is written once. That order matters: the background and
/// foreground are set BEFORE the palette, because `installColors` rebuilds
/// the 256-colour palette and, under the emulator's non-default palette
/// strategies, reads the background and foreground as its anchors while
/// doing so.
///
/// `layer?.backgroundColor` is assigned separately because SwiftTerm sets
/// the layer's colour only in its own setup (`setupOptions`), so a later
/// background change would otherwise leave the layer painted with the old
/// one.
enum TerminalThemeInstaller {
    @MainActor
    static func apply(_ theme: TerminalTheme, to terminal: TerminalView) {
        terminal.nativeBackgroundColor = theme.background.nsColor
        terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.caretColor = theme.cursor.nsColor
        terminal.layer?.backgroundColor = theme.background.nsColor.cgColor
        terminal.installColors(theme.ansi.map(\.swiftTermColor))
    }
}
