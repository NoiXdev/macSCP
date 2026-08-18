import AppKit
import SwiftUI

/// Brand duo from docs/design/ci.md: amber = local, ocean blue = remote.
/// Dynamic for light/dark. Use only semantically (pane badges, later transfer
/// direction) — the rest of the app stays on system colors.
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

    /// Third badge tint (M10d/T4): the login-sets editor's AGENT badge needs
    /// its own color, distinct from KEY's `remoteBlue` and PASS's
    /// `localAmber` — a muted sea green, echoing `statusPhosphor`'s
    /// "connected"/terminal association without reusing that fixed
    /// (non-dynamic) color verbatim on a light background.
    static let agentGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 123 / 255, green: 216 / 255, blue: 143 / 255, alpha: 1) // #7BD88F
            : NSColor(srgbRed: 46 / 255, green: 139 / 255, blue: 87 / 255, alpha: 1) // #2E8B57
    })

    /// Phosphor from docs/design/ci.md: connected status, terminal green.
    static let statusPhosphor = Color(nsColor: NSColor(
        srgbRed: 123 / 255, green: 216 / 255, blue: 143 / 255, alpha: 1)) // #7BD88F

    /// Terminal background: deep sea (#0F1E2B) — deliberately NOT dynamic,
    /// the terminal is a "dark console" in both light and dark mode.
    static let terminalBackground = NSColor(
        srgbRed: 0x0F / 255, green: 0x1E / 255, blue: 0x2B / 255, alpha: 1)
    /// Terminal text/caret: phosphor (#7BD88F).
    static let terminalText = NSColor(
        srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)

    /// Appearance-aware color from two sRGB hex values (light/dark) — the
    /// mockup's CSS custom properties, one Swift constant each.
    private static func dynamicNS(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255,
             CGFloat((hex >> 8) & 0xFF) / 255,
             CGFloat(hex & 0xFF) / 255)
        }
        return NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(dark) : rgb(light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
    }

    // Mockup surface/typography tokens (spec table, M5g). NS variants exist
    // because the AppKit file table consumes NSColor directly.
    static let hairlineNS = dynamicNS(light: 0xDAE3EB, dark: 0x24374A)
    static let hairline = Color(nsColor: hairlineNS)
    /// Row separators: the hairline at 45% opacity, baked into the provider
    /// so it stays a single dynamic color (withAlphaComponent on a dynamic
    /// color is avoided deliberately).
    static let hairlineFaintNS = dynamicNS(light: 0xDAE3EB, dark: 0x24374A, alpha: 0.45)
    static let inkNS = dynamicNS(light: 0x14212E, dark: 0xE8EFF5)
    /// SwiftUI wrappers alongside the NS variants — the file table consumes
    /// the NS colors directly, SwiftUI views the wrappers.
    static let ink = Color(nsColor: inkNS)
    static let inkSecondaryNS = dynamicNS(light: 0x4A5B6B, dark: 0xA7B7C5)
    static let inkSecondary = Color(nsColor: inkSecondaryNS)
    static let inkTertiaryNS = dynamicNS(light: 0x7E8FA0, dark: 0x6E8093)
    static let inkTertiary = Color(nsColor: inkTertiaryNS)
    static let remoteSoftNS = dynamicNS(light: 0xE3EEF9, dark: 0x142C42)
    static let remoteSoft = Color(nsColor: remoteSoftNS)
    static let localSoft = Color(nsColor: dynamicNS(light: 0xFBF1DF, dark: 0x2C2415))
    /// Soft background for the AGENT badge (M10d/T4) — same light/dark
    /// pairing shape as `remoteSoft`/`localSoft` above, tinted for
    /// `agentGreen`.
    static let agentSoft = Color(nsColor: dynamicNS(light: 0xE1F3E5, dark: 0x16301F))
    /// S3 login-set badge (M15): a muted violet, the 4th distinct badge hue
    /// after KEY's `remoteBlue`, AGENT's `agentGreen`, PASS's `localAmber`.
    static let s3Soft = Color(nsColor: dynamicNS(light: 0xEDE7F6, dark: 0x241B33))
    static let s3Violet = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xB3 / 255, green: 0x9D / 255, blue: 0xDB / 255, alpha: 1) // #B39DDB
            : NSColor(srgbRed: 0x6A / 255, green: 0x4C / 255, blue: 0xA5 / 255, alpha: 1) // #6A4CA5
    })

    // Surface hierarchy (mockup: card content surface on the window ground).
    // `paper` (the mockup's page ground) had no consumer after the polish
    // rounds and was dropped (M6a, YAGNI).
    static let card = Color(nsColor: dynamicNS(light: 0xFFFFFF, dark: 0x14212E))
    /// The mockup's sidebar tint: color-mix(card 70%, window ground — the
    /// mockup's "paper" #F4F7FA/#0D1720, dropped as a token in M6a),
    /// precomputed per appearance so it stays a single dynamic color.
    static let sidebarSurface = Color(nsColor: dynamicNS(light: 0xFCFDFE, dark: 0x121E2A))

    // MARK: - Terminal panel inset
    //
    // The one non-color pair in this file (Terminal-Fassung P2, Task 1).
    // `DesignTokens` otherwise holds only colors, but this measurement earns
    // a place here too, for the same reason the colors above do: it is a
    // value two independent views must agree on. `TerminalPanelHeader` and
    // the terminal surface in `terminalPanel(_:)`
    // (`Sources/MacSCPAppKit/ContentView+Detail.swift`) both read these two
    // constants, so they cannot quietly drift apart the way the header's
    // inset and the `.ended` state's own (separate, untouched) `14`/`8`
    // padding already had before this change. Not a general spacing scale —
    // just the one pair those two readers share.
    static let terminalPanelInsetHorizontal: CGFloat = 12
    static let terminalPanelInsetVertical: CGFloat = 6
}
