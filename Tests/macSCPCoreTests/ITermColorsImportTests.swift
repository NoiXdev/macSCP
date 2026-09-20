import Foundation
import Testing

@testable import macSCPCore

/// The iTerm2 colour-file reader (plan of 2026-09-19, "The answered
/// wishes", Task 3).
///
/// The files under `Fixtures/ITermColors/` were WRITTEN FOR THIS SUITE, by
/// hand, from the format the task brief describes — a property list whose
/// entries carry `Red Component`, `Green Component` and `Blue Component` as
/// numbers from 0 to 1, under names such as `Ansi 0 Color`, `Background
/// Color`, `Foreground Color` and `Cursor Color`. No theme file from
/// anybody's collection is committed here, so nothing in this tree carries
/// somebody else's licence. `harbour.itermcolors` also carries the
/// `Color Space`, `Cursor Text Color`, `Selected Text Color` and
/// `Selection Color` entries iTerm2 writes, so the reader is measured
/// against a file with more in it than it reads.
///
/// Known blind spot: no file exported by a real iTerm2 was available to
/// read here. What is verified is the SHAPE described above, against files
/// this suite authored and `plutil -lint` accepted — not that iTerm2's own
/// export is byte-identical to them.
@Suite("iTerm2 colour import", .timeLimit(.minutes(1)))
struct ITermColorsImportTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ITermColors/\(name)")
        return try Data(contentsOf: url)
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ITermColors/\(name)")
    }

    /// Serializes a property list the way a file would carry it, so a test
    /// can hand the parser a shape no committed fixture needs to exist for.
    private static func plist(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .xml)
        throws -> Data
    {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    /// A complete, well-formed entry set, as a dictionary a test can
    /// damage one key of.
    private static func wellFormedEntries() -> [String: Any] {
        var entries: [String: Any] = [:]
        for index in 0..<16 {
            entries["Ansi \(index) Color"] = components(red: 0.2, green: 0.4, blue: 0.6)
        }
        entries["Background Color"] = components(red: 0, green: 0, blue: 0)
        entries["Foreground Color"] = components(red: 0.8, green: 0.8, blue: 0.8)
        entries["Cursor Color"] = components(red: 1, green: 0.6, blue: 0.2)
        return entries
    }

    private static func components(red: Double, green: Double, blue: Double) -> [String: Any] {
        ["Red Component": red, "Green Component": green, "Blue Component": blue]
    }

    // MARK: - A file that parses

    /// The colours of `harbour.itermcolors`, spelled here so the
    /// expectation is independent of the arithmetic the reader does.
    private static let harbourAnsi: [UInt32] = [
        0x101820, 0xC74B4B, 0x6FB86F, 0xD2A24C, 0x5B8FD0, 0xA878C8, 0x55B3B3, 0xC8C8C8,
        0x555F6A, 0xE06C6C, 0x8FD48F, 0xE8C070, 0x7FA9E0, 0xC49AE0, 0x7FD0D0, 0xF0F0F0,
    ]

    @Test func aWellFormedFileYieldsEveryColourItCarries() throws {
        let theme = try ITermColorsImport.theme(from: Self.fixture("harbour.itermcolors"))
        #expect(theme.ansi == Self.harbourAnsi.map(TerminalColor.init))
        #expect(theme.background == TerminalColor(0x101820))
        #expect(theme.foreground == TerminalColor(0xCCCCCC))
        #expect(theme.cursor == TerminalColor(0xFF9933))
    }

    @Test func theSameFileReadsTheSameThroughItsURL() throws {
        let fromData = try ITermColorsImport.theme(from: Self.fixture("harbour.itermcolors"))
        let fromURL = try ITermColorsImport.theme(
            contentsOf: Self.fixtureURL("harbour.itermcolors"))
        #expect(fromData == fromURL)
    }

    /// The colours the reader does NOT take (`Selection Color`,
    /// `Cursor Text Color`, `Selected Text Color`, `Color Space`) are in
    /// that fixture and are simply ignored — a positive statement about
    /// the file, beside the negative "they do not appear in the theme".
    @Test func theEntriesTheReaderDoesNotUseArePresentAndIgnored() throws {
        let data = try Self.fixture("harbour.itermcolors")
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        let entries = try #require(parsed as? [String: Any])
        for name in ["Selection Color", "Cursor Text Color", "Selected Text Color"] {
            #expect(entries[name] != nil, "\(name) is not in the fixture at all")
        }
        let theme = try ITermColorsImport.theme(from: data)
        // `Selection Color` is #2A3A4A in that file and must appear
        // nowhere in what was read.
        let selection = TerminalColor(0x2A3A4A)
        let reached =
            theme.ansi.contains(selection) || theme.background == selection
            || theme.foreground == selection || theme.cursor == selection
        #expect(reached == false)
    }

    /// The cursor is the only optional colour: a file without it draws the
    /// cursor in the foreground colour.
    @Test func aFileWithoutACursorColourUsesItsForeground() throws {
        var entries = Self.wellFormedEntries()
        entries["Cursor Color"] = nil
        let theme = try ITermColorsImport.theme(from: Self.plist(entries))
        #expect(theme.cursor == theme.foreground)
        #expect(theme.foreground == TerminalColor(0xCCCCCC))
    }

    @Test func aBinaryPropertyListIsReadTheSameWayAnXMLOneIs() throws {
        let entries = Self.wellFormedEntries()
        let xml = try ITermColorsImport.theme(from: Self.plist(entries, format: .xml))
        let binary = try ITermColorsImport.theme(from: Self.plist(entries, format: .binary))
        #expect(xml == binary)
    }

    // MARK: - Components out of range

    /// Clamped, not refused: a wide-gamut export legitimately carries
    /// components a little outside 0...1, and clamping cannot produce a
    /// colour the file did not ask for.
    @Test func componentsOutsideZeroToOneAreClamped() throws {
        let theme = try ITermColorsImport.theme(from: Self.fixture("out-of-range.itermcolors"))
        // Ansi 0 in that file is red -0.3, green 1.4, blue 0.5.
        #expect(theme.ansi[0] == TerminalColor(0x00FF80))
        // Background is red -0.02, green 1.0000001, blue 0.12549…, and
        // declares the P3 colour space, which is ignored.
        #expect(theme.background == TerminalColor(0x00FF20))
    }

    @Test func aNonFiniteComponentIsRefused() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            var entries = Self.wellFormedEntries()
            entries["Ansi 3 Color"] = Self.components(red: bad, green: 0, blue: 0)
            let data = try Self.plist(entries, format: .binary)
            #expect(throws: ITermColorsImport.Refusal.malformedColor) {
                try ITermColorsImport.theme(from: data)
            }
        }
    }

    // MARK: - Files that are refused

    @Test func bytesThatAreNotAPropertyListAreRefused() {
        let data = Data("this is not a property list, it is a sentence".utf8)
        #expect(throws: ITermColorsImport.Refusal.notAPropertyList) {
            try ITermColorsImport.theme(from: data)
        }
        #expect(throws: ITermColorsImport.Refusal.notAPropertyList) {
            try ITermColorsImport.theme(from: Data())
        }
    }

    @Test func aPropertyListThatIsNotADictionaryIsRefused() throws {
        let data = try Self.fixture("not-a-dictionary.itermcolors")
        #expect(throws: ITermColorsImport.Refusal.notADictionary) {
            try ITermColorsImport.theme(from: data)
        }
    }

    @Test func everyColourTheThemeNeedsMustBeThere() throws {
        let required =
            (0..<16).map { "Ansi \($0) Color" } + ["Background Color", "Foreground Color"]
        for name in required {
            var entries = Self.wellFormedEntries()
            entries[name] = nil
            let data = try Self.plist(entries)
            #expect(throws: ITermColorsImport.Refusal.missingColor, "\(name) was not required") {
                try ITermColorsImport.theme(from: data)
            }
        }
    }

    @Test func aColourThatIsNotThreeNumbersIsRefused() throws {
        let broken: [Any] = [
            "#FF0000",
            ["Red Component": 1.0, "Green Component": 0.0],
            ["Red Component": "1.0", "Green Component": 0.0, "Blue Component": 0.0],
            ["Red Component": [1.0], "Green Component": 0.0, "Blue Component": 0.0],
            [1.0, 0.0, 0.0],
        ]
        for value in broken {
            var entries = Self.wellFormedEntries()
            entries["Ansi 9 Color"] = value
            let data = try Self.plist(entries)
            #expect(throws: ITermColorsImport.Refusal.malformedColor, "accepted \(value)") {
                try ITermColorsImport.theme(from: data)
            }
        }
    }

    /// A property list bridges `<true/>` to `NSNumber`, so a cast alone
    /// would read a boolean as a fully saturated channel instead of
    /// refusing the file.
    @Test func aBooleanComponentIsRefusedRatherThanReadAsOne() throws {
        var entries = Self.wellFormedEntries()
        entries["Ansi 1 Color"] = [
            "Red Component": true, "Green Component": false, "Blue Component": false,
        ]
        let data = try Self.plist(entries)
        #expect(throws: ITermColorsImport.Refusal.malformedColor) {
            try ITermColorsImport.theme(from: data)
        }
    }

    // MARK: - A hostile file

    /// The shape of an archived object graph, offered under the same
    /// extension. Nothing is unarchived, so the file is simply a
    /// dictionary without the colours — refused, with no object in it
    /// instantiated.
    @Test func anArchivedObjectGraphIsJustAFileWithoutColours() throws {
        let data = try Self.fixture("archived-object-graph.itermcolors")
        #expect(throws: ITermColorsImport.Refusal.missingColor) {
            try ITermColorsImport.theme(from: data)
        }
    }

    /// A bound, so a document of arbitrary size is not arbitrary work.
    @Test func aFileLargerThanTheBoundIsRefusedBeforeItIsParsed() {
        let data = Data(repeating: 0x20, count: ITermColorsImport.maximumFileSize + 1)
        #expect(throws: ITermColorsImport.Refusal.unreadable) {
            try ITermColorsImport.theme(from: data)
        }
    }

    /// Positive beside that negative: a document right AT the bound is not
    /// refused for its size — it reaches the parser and is refused for what
    /// it contains instead. (A blank document parses: the OpenStep property
    /// list format reads it as an empty dictionary, which is a dictionary
    /// with no colours in it.)
    @Test func aFileAtTheBoundIsNotRefusedForItsSize() {
        let data = Data(repeating: 0x20, count: ITermColorsImport.maximumFileSize)
        do {
            _ = try ITermColorsImport.theme(from: data)
            Issue.record("a blank document was accepted as a theme")
        } catch {
            #expect(error != .unreadable, "a document at the bound was refused for its size")
        }
    }

    @Test func aFileThatIsNotThereIsRefused() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-absent-\(UUID().uuidString).itermcolors")
        #expect(throws: ITermColorsImport.Refusal.unreadable) {
            try ITermColorsImport.theme(contentsOf: url)
        }
    }

    /// An oversized file is refused without its bytes being read: the size
    /// is taken from the file system first.
    @Test func anOversizedFileOnDiskIsRefusedByItsSizeAlone() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-large-\(UUID().uuidString).itermcolors")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: ITermColorsImport.maximumFileSize + 1).write(to: url)
        #expect(throws: ITermColorsImport.Refusal.unreadable) {
            try ITermColorsImport.theme(contentsOf: url)
        }
    }

    /// Every refusal this reader can produce is one of a closed set, and
    /// no case of it carries text — which is what lets the App show one
    /// fixed sentence for all of them without ever quoting a file.
    @Test func theRefusalsAreAClosedSetThatCarriesNoText() {
        #expect(
            Set(ITermColorsImport.Refusal.allCases.map(\.rawValue)) == [
                "unreadable", "notAPropertyList", "notADictionary", "missingColor",
                "malformedColor",
            ])
    }

    // MARK: - The name

    @Test func theNameComesFromTheFileName() {
        #expect(ITermColorsImport.themeName(forFileNamed: "Harbour.itermcolors") == "Harbour")
        #expect(ITermColorsImport.themeName(forFileNamed: "Solarized Dark.itermcolors")
            == "Solarized Dark")
        #expect(ITermColorsImport.themeName(forFileNamed: "no-extension") == "no-extension")
    }

    @Test func aFileNameWithNothingUsableInItYieldsNoName() {
        #expect(ITermColorsImport.themeName(forFileNamed: ".itermcolors") == nil)
        #expect(ITermColorsImport.themeName(forFileNamed: "   .itermcolors") == nil)
        #expect(ITermColorsImport.themeName(forFileNamed: "") == nil)
    }

    /// The name is shown in a picker row, so control characters and
    /// newlines are removed and the length is bounded — a file cannot
    /// paint a row with them.
    @Test func aNameIsStrippedAndBounded() throws {
        let noisy = "Ha\u{0}rb\nou\tr\u{7}"
        #expect(ITermColorsImport.themeName(forFileNamed: noisy + ".itermcolors") == "Ha rb ou r")
        let long = String(repeating: "x", count: 500)
        let bounded = try #require(ITermColorsImport.themeName(forFileNamed: long + ".itermcolors"))
        #expect(bounded.count == 60)
    }
}
