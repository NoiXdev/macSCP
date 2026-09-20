import Foundation

/// Reads an iTerm2 colour file (`.itermcolors`) into a `TerminalTheme`.
///
/// The format is a property list whose top level maps a colour's name to a
/// dictionary of components: `Red Component`, `Green Component` and
/// `Blue Component`, each a number from 0 to 1. The names this reads are
/// `Ansi 0 Color` through `Ansi 15 Color`, `Background Color`,
/// `Foreground Color` and `Cursor Color`. Verified against files written by
/// hand for `Tests/macSCPCoreTests/Fixtures/` — no third-party theme file
/// is committed here, so nothing in the tree carries somebody else's
/// licence.
///
/// **What a real export carries beyond that, and what happens to it**
/// (measured for fix round 1 against the structure of a published scheme,
/// and written into `Fixtures/ITermColors/nightingale.itermcolors` in that
/// shape):
///
/// - **Three keys per colour** — the plain name, `… (Dark)` and
///   `… (Light)`. The plain key wins; the variants are the fallback, in
///   that order, for a file that carries only them. A theme here is one
///   global setting with no appearance to switch on, so `(Dark)` is
///   preferred over `(Light)`: the terminal is a dark surface by default.
/// - **Eight more colours** — `Badge Color`, `Bold Color`,
///   `Cursor Guide Color`, `Cursor Text Color`, `Link Color`,
///   `Match Background Color`, `Selected Text Color`, `Selection Color`.
///   A `TerminalTheme` has nowhere to put them, so they are ignored.
/// - **`Alpha Component`** in every entry. IGNORED: every colour here is
///   opaque. A terminal surface that let the desktop through is not
///   something this app offers, and a half-transparent ANSI colour is not
///   something the emulator's palette can express.
/// - **`Color Space`**, typically `P3`. Ignored: the components are read
///   as sRGB. Measured cost (review of 2026-09-20): zero for neutrals,
///   ΔE00 ≈ 1.5–5 for mid-saturation entries, and nothing at all for
///   fully saturated ones, whose correct conversion clamps back to the
///   values already being read.
///
/// The reader takes only the names above and looks at nothing else, so a
/// key it has never heard of costs nothing.
///
/// **Nothing in the file is trusted.** It is a document a user picked out
/// of a download folder, so:
///
/// - it is read only as an immutable property list, never unarchived, so
///   no object graph the file names is instantiated;
/// - it is refused before it is read at all when it is larger than
///   `maximumFileSize` (a real theme file is a few kilobytes);
/// - a component that is not a number — including a boolean, which a
///   property list bridges to `NSNumber` — is refused rather than coerced;
/// - a component outside 0...1 is CLAMPED, not refused: a file exported
///   from a wide-gamut colour space legitimately carries components a
///   little outside that range, and clamping is the reading of it that
///   cannot produce a colour the user did not ask for. A non-finite
///   component has nothing to clamp to and is refused.
///
/// Every refusal is one of `Refusal`'s cases — a closed set that carries no
/// text from the file and no parser message. The App maps all of them to
/// one fixed sentence (task brief: "never a raw parser error"); the cases
/// exist so this file's tests can say WHICH refusal a given file earns.
public enum ITermColorsImport {
    /// Largest file this will read, in bytes. Files iTerm2 exports are a
    /// few kilobytes; a megabyte is three orders of magnitude of headroom
    /// and still a bound, which is the point — a property list parser
    /// handed an arbitrarily large document is an arbitrarily large amount
    /// of work.
    public static let maximumFileSize = 1 << 20

    /// Why a file was refused. No case carries text: neither a parser
    /// message nor anything read out of the file can reach a user through
    /// this type.
    public enum Refusal: String, Error, Equatable, Sendable, CaseIterable {
        /// Larger than `maximumFileSize`, or unreadable.
        case unreadable
        /// Not a property list at all.
        case notAPropertyList
        /// A property list, but not a dictionary of colours.
        case notADictionary
        /// A colour the theme needs is absent.
        case missingColor
        /// A colour is present but is not three numeric components.
        case malformedColor
    }

    // MARK: - Reading a file

    /// Reads `url` and parses it. The size is checked BEFORE the bytes are
    /// read, so an oversized file is refused without being loaded.
    public static func theme(contentsOf url: URL) throws(Refusal) -> TerminalTheme {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        guard let size = (attributes?[.size] as? NSNumber)?.intValue, size <= maximumFileSize
        else { throw .unreadable }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try theme(from: data)
    }

    /// The name to store beside an imported theme, taken from the FILE's
    /// name rather than from its contents — the file cannot choose what
    /// macSCP calls it.
    ///
    /// The extension is dropped, every control character becomes a space
    /// (a space, not nothing: removing them outright would glue two words
    /// into one that the file never spelled), runs of whitespace collapse
    /// to one space, and the result is trimmed and cut to 60 characters.
    /// `nil` when nothing is left, so the App can fall back to a
    /// translated word instead of showing an empty row.
    public static func themeName(forFileNamed fileName: String) -> String? {
        // `deletingPathExtension` leaves a dot-leading name whole — a file
        // called exactly ".itermcolors" is a hidden file with no extension
        // by that rule — so the extension this reader is for is taken off
        // first, by name.
        let stem: String
        if let range = fileName.range(
            of: ".itermcolors", options: [.caseInsensitive, .backwards, .anchored],
            range: nil, locale: nil)
        {
            stem = String(fileName[fileName.startIndex..<range.lowerBound])
        } else {
            stem = (fileName as NSString).deletingPathExtension
        }
        let stripped = String(
            String.UnicodeScalarView(
                stem.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) ? " " : $0
                }))
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(collapsed.prefix(60)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The parser

    /// Parses the bytes of an `.itermcolors` file. Pure: no file system, no
    /// settings, nothing observable but the value it returns.
    public static func theme(from data: Data) throws(Refusal) -> TerminalTheme {
        guard data.count <= maximumFileSize else { throw .unreadable }
        var format = PropertyListSerialization.PropertyListFormat.xml
        // `options: []` is the immutable reading — no mutable containers
        // are built, and no archived object graph is instantiated.
        guard
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &format)
        else { throw .notAPropertyList }
        guard let entries = parsed as? [String: Any] else { throw .notADictionary }

        var ansi: [TerminalColor] = []
        ansi.reserveCapacity(TerminalTheme.ansiColorCount)
        for index in 0..<TerminalTheme.ansiColorCount {
            ansi.append(try color(named: "Ansi \(index) Color", in: entries))
        }
        let background = try color(named: "Background Color", in: entries)
        let foreground = try color(named: "Foreground Color", in: entries)
        // The only optional colour: iTerm2 writes it, but a file trimmed by
        // hand may not, and the foreground is what a terminal draws a
        // cursor with when it is told nothing else.
        let cursor = (try? color(named: "Cursor Color", in: entries)) ?? foreground

        guard
            let theme = TerminalTheme(
                background: background, foreground: foreground, cursor: cursor, ansi: ansi)
        else {
            // Unreachable: the loop above appends exactly
            // `ansiColorCount` colours or throws. Spelled rather than
            // force-unwrapped, so a later change to either side becomes a
            // refusal instead of a crash.
            throw .malformedColor
        }
        return theme
    }

    /// One colour by name, preferring the plain key and falling back to
    /// the `(Dark)` and then the `(Light)` variant a real export writes
    /// beside it. All three are looked up before anything is read, so a
    /// file that carries only variants is read rather than refused; the
    /// FIRST key that is present is the one used, and if that one is
    /// malformed the file is refused rather than quietly falling through
    /// to the next — a half-read colour is not better than a refusal.
    private static func color(
        named name: String, in entries: [String: Any]
    ) throws(Refusal) -> TerminalColor {
        let candidates = [name, "\(name) (Dark)", "\(name) (Light)"]
        guard let raw = candidates.lazy.compactMap({ entries[$0] }).first else {
            throw .missingColor
        }
        guard let components = raw as? [String: Any] else { throw .malformedColor }
        let red = try component(components["Red Component"])
        let green = try component(components["Green Component"])
        let blue = try component(components["Blue Component"])
        guard let color = TerminalColor(red: red, green: green, blue: blue) else {
            throw .malformedColor
        }
        return color
    }

    /// One component, as a finite number. A boolean is rejected before the
    /// `NSNumber` cast can turn it into 1: a property list's `<true/>`
    /// bridges to `NSNumber`, so the cast alone would read it as a fully
    /// saturated channel.
    private static func component(_ value: Any?) throws(Refusal) -> Double {
        guard let value else { throw .malformedColor }
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
            let number = value as? NSNumber
        else { throw .malformedColor }
        let raw = number.doubleValue
        guard raw.isFinite else { throw .malformedColor }
        return raw
    }
}
