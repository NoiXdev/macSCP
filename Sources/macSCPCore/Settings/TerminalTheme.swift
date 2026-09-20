import Foundation

/// One sRGB colour of a terminal theme, in 8 bits per channel.
///
/// Eight bits is what the sources this type is built from carry: a
/// `DesignTokens` constant is written as two hex digits per channel, and an
/// `.itermcolors` component is a 0...1 float that is rounded to a byte on
/// the way in. The emulator's own colour type is 16 bits per channel, so
/// the App widens each component when it hands a theme to SwiftTerm — Core
/// knows nothing about that type.
public struct TerminalColor: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From one 24-bit value, `0xRRGGBB` — how the presets below are
    /// written, so a palette reads as a column of hex.
    public init(_ packed: UInt32) {
        self.red = UInt8((packed >> 16) & 0xFF)
        self.green = UInt8((packed >> 8) & 0xFF)
        self.blue = UInt8(packed & 0xFF)
    }

    /// From three components in 0...1, each clamped and rounded to a byte.
    /// A non-finite component has no byte to round to, so it yields `nil`
    /// rather than a silently substituted one — `ITermColorsImport` refuses
    /// such a file.
    public init?(red: Double, green: Double, blue: Double) {
        guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
        func byte(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: byte(red), green: byte(green), blue: byte(blue))
    }

    /// `#RRGGBB`, upper case — what `settings.json` carries, so a stored
    /// theme is legible to whoever opens that file.
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// The inverse of `hexString`, tolerant of a missing `#` and of lower
    /// case, and strict about everything else: exactly six hex digits, or
    /// `nil`.
    public init?(hexString: String) {
        var digits = Substring(hexString)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit),
            let packed = UInt32(digits, radix: 16)
        else { return nil }
        self.init(packed)
    }
}

/// A terminal theme: the surface's background, the default text colour, the
/// cursor, and the sixteen ANSI colours programs on the server address by
/// number.
///
/// Colours only — no name. A preset is named by `TerminalThemePreset` (and
/// labelled in the App's catalogues); an imported theme's name is stored
/// beside it in `SettingsStore.importedTerminalThemeName`, because it comes
/// from the file the user picked rather than from this type.
public struct TerminalTheme: Equatable, Hashable, Sendable {
    public let background: TerminalColor
    public let foreground: TerminalColor
    public let cursor: TerminalColor
    /// Exactly `ansiColorCount` entries, in ANSI order: black, red, green,
    /// yellow, blue, magenta, cyan, white, then the same eight bright.
    public let ansi: [TerminalColor]

    /// How many ANSI colours a theme carries. The emulator installs a
    /// palette only when it is handed exactly this many (SwiftTerm's
    /// `Terminal.installPalette(colors:)` returns without doing anything
    /// otherwise), so every construction below goes through an initializer
    /// that refuses a different count.
    public static let ansiColorCount = 16

    /// `nil` unless `ansi` has exactly `ansiColorCount` entries.
    public init?(
        background: TerminalColor, foreground: TerminalColor, cursor: TerminalColor,
        ansi: [TerminalColor]
    ) {
        guard ansi.count == Self.ansiColorCount else { return nil }
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }
}

/// The themes macSCP ships with (plan of 2026-09-19, "The answered wishes",
/// Task 3; maintainer's answer on the backlog row: presets plus an
/// `.itermcolors` import, no editor).
///
/// Three, deliberately: the look the terminal has always had, a second dark
/// one for people who do not want a coloured background, and a light one.
/// Anything else is imported.
public enum TerminalThemePreset: String, CaseIterable, Sendable {
    /// The colours the terminal had before this setting existed.
    case macSCP
    /// A neutral dark theme — near-black surface, plain grey text.
    case midnight
    /// A light theme, for a bright room or a bright screenshot.
    case paper

    /// The preset used when nothing else is chosen: today's look, so an
    /// untouched installation looks exactly as it did.
    public static let `default`: TerminalThemePreset = .macSCP

    public var theme: TerminalTheme {
        switch self {
        case .macSCP: return Self.macSCPTheme
        case .midnight: return Self.midnightTheme
        case .paper: return Self.paperTheme
        }
    }

    /// Deep sea `#0F1E2B` with phosphor `#7BD88F` text — the two
    /// `DesignTokens` constants the terminal was painted with before themes
    /// existed, and, for the sixteen ANSI colours, the palette SwiftTerm
    /// installs by default (`Color.terminalAppColors` at the pinned
    /// revision, which is macOS Terminal's own palette). macSCP never
    /// called `installColors` before this task, so those sixteen values ARE
    /// what the terminal rendered; spelling them here is what keeps this
    /// preset the unchanged look rather than a new one wearing its name.
    private static let macSCPTheme = TerminalTheme(
        background: TerminalColor(0x0F1E2B),
        foreground: TerminalColor(0x7BD88F),
        cursor: TerminalColor(0x7BD88F),
        ansi: [
            0x000000, 0xC23621, 0x25BC24, 0xADAD27,
            0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
            0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
            0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
        ].map(TerminalColor.init))!

    private static let midnightTheme = TerminalTheme(
        background: TerminalColor(0x1B1D1E),
        foreground: TerminalColor(0xD8D8D8),
        cursor: TerminalColor(0xD8D8D8),
        ansi: [
            0x1B1D1E, 0xD65F5F, 0x8FBF5F, 0xD9B35F,
            0x5F8FD9, 0xB98FD9, 0x5FBFBF, 0xC8C8C8,
            0x5A5F62, 0xF07A7A, 0xA9D97A, 0xF0CE7A,
            0x7AA9F0, 0xD2A9F0, 0x7AD9D9, 0xF2F2F2,
        ].map(TerminalColor.init))!

    /// Light. Index 7 and index 15 stay the lightest two entries, as they
    /// are in every light theme of this kind: programs pick 15 for
    /// "brightest", and reordering them here to keep them readable on
    /// paper would break that expectation everywhere else.
    private static let paperTheme = TerminalTheme(
        background: TerminalColor(0xFBFAF7),
        foreground: TerminalColor(0x2E2E2E),
        cursor: TerminalColor(0x2E2E2E),
        ansi: [
            0x2E2E2E, 0xB03030, 0x3F7F3F, 0x8A6D1F,
            0x30528F, 0x7A3F8F, 0x2F7F7F, 0xA8A49B,
            0x6B6B6B, 0xD04A4A, 0x4F9F4F, 0xB08A28,
            0x4A72BF, 0x9F55AF, 0x3F9F9F, 0xE8E6E1,
        ].map(TerminalColor.init))!
}

/// What the terminal-theme setting holds: one of the shipped presets, or
/// the theme that was imported from an `.itermcolors` file.
///
/// Global, with no per-session override — decided for the maintainer in the
/// task brief, because the backlog row left it open. The terminal TYPE has
/// a per-session override; a per-session theme can follow if it is asked
/// for.
public enum TerminalThemeChoice: RawRepresentable, Equatable, Hashable, Sendable {
    case preset(TerminalThemePreset)
    case imported

    /// The spelling `settings.json` carries. `imported` is a name no preset
    /// may take; `TerminalThemeTests` holds the presets to that.
    public static let importedRawValue = "imported"

    public var rawValue: String {
        switch self {
        case .preset(let preset): return preset.rawValue
        case .imported: return Self.importedRawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == Self.importedRawValue {
            self = .imported
        } else if let preset = TerminalThemePreset(rawValue: rawValue) {
            self = .preset(preset)
        } else {
            return nil
        }
    }

    public static let `default`: TerminalThemeChoice = .preset(.default)
}

extension TerminalTheme {
    /// The theme the terminal is painted with: the imported one when that
    /// is what was chosen AND one has been imported, otherwise the chosen
    /// preset, otherwise the default preset.
    ///
    /// The middle case is the one worth spelling: choosing "imported" and
    /// then removing the imported theme (or a `settings.json` that names
    /// `imported` with nothing stored under it) must not leave the terminal
    /// without colours. It falls back to the default preset — the look the
    /// terminal has always had — rather than to whatever the emulator would
    /// default to.
    public static func resolved(
        choice: TerminalThemeChoice?, imported: TerminalTheme?
    ) -> TerminalTheme {
        switch choice ?? .default {
        case .imported: return imported ?? TerminalThemePreset.default.theme
        case .preset(let preset): return preset.theme
        }
    }

    // MARK: - Settings backing

    /// The `settings.json` shape: every colour as `#RRGGBB`, the sixteen
    /// ANSI colours as an array in ANSI order.
    var settingsValue: JSONValue {
        .object([
            "background": .string(background.hexString),
            "foreground": .string(foreground.hexString),
            "cursor": .string(cursor.hexString),
            "ansi": .array(ansi.map { .string($0.hexString) }),
        ])
    }

    /// Reads a theme back out of that shape, or `nil` — a missing key, a
    /// colour that is not six hex digits, or the wrong number of ANSI
    /// entries all read as "no theme stored" rather than as a partial one.
    /// Same tolerance as every other accessor on `SettingsStore`: a
    /// hand-edited file degrades to the default instead of crashing.
    init?(settingsValue: JSONValue) {
        guard case .object(let fields) = settingsValue,
            case .string(let background)? = fields["background"],
            case .string(let foreground)? = fields["foreground"],
            case .string(let cursor)? = fields["cursor"],
            case .array(let rawAnsi)? = fields["ansi"],
            let backgroundColor = TerminalColor(hexString: background),
            let foregroundColor = TerminalColor(hexString: foreground),
            let cursorColor = TerminalColor(hexString: cursor)
        else { return nil }
        var ansi: [TerminalColor] = []
        ansi.reserveCapacity(rawAnsi.count)
        for value in rawAnsi {
            guard case .string(let hex) = value, let color = TerminalColor(hexString: hex) else {
                return nil
            }
            ansi.append(color)
        }
        self.init(
            background: backgroundColor, foreground: foregroundColor, cursor: cursorColor,
            ansi: ansi)
    }
}
