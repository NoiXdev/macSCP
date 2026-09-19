import macSCPCore

/// What the two terminal-type pickers show for each `TerminalType` — the
/// Settings row and the session editor's override (plan of 2026-09-19,
/// Task 4).
///
/// The key is derived from the type, so a name added to `TerminalType` gets
/// a key without anyone typing it a second time; the catalogue guard
/// (`TerminalTypeWiringGuardTests`) walks `TerminalType.allCases` through
/// `key(for:)` and asks all four catalogues for each. Every label starts
/// with the name itself, untranslated — it is what the server sees and what
/// a person looks up — followed by a short, translated note on colours.
enum TerminalTypeLabel {
    static func key(for type: TerminalType) -> String {
        "terminal.type.\(type.rawValue)"
    }

    static func text(for type: TerminalType) -> String {
        L10n.string(key(for: type), englishText(for: type))
    }

    /// The English text, as the lookup's fallback. The catalogue guard
    /// asks that the lookup never needs it.
    private static func englishText(for type: TerminalType) -> String {
        switch type {
        case .xterm256Color: return "xterm-256color (256 colors)"
        case .xterm: return "xterm (8 colors)"
        case .vt100: return "vt100 (no colors)"
        }
    }
}
