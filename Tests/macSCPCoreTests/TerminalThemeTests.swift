import Foundation
import Testing

@testable import macSCPCore

/// Terminal themes (plan of 2026-09-19, "The answered wishes", Task 3):
/// what is shipped, how a colour round-trips, the order a theme resolves
/// in, and that a chosen theme survives a restart.
///
/// Known blind spot: nothing here renders anything. That a theme reaches
/// the emulator is `TerminalThemeWiringGuardTests`' (App, source-scanning);
/// that SwiftTerm paints the sixteen colours it is handed is SwiftTerm's.
@Suite("Terminal themes", .timeLimit(.minutes(1)))
struct TerminalThemeTests {
    // MARK: - Colour

    @Test func aPackedValueSplitsIntoItsThreeChannels() {
        let color = TerminalColor(0x0F1E2B)
        #expect(color.red == 0x0F)
        #expect(color.green == 0x1E)
        #expect(color.blue == 0x2B)
    }

    @Test func aColourRoundTripsThroughItsHexSpelling() {
        for packed: UInt32 in [0x000000, 0xFFFFFF, 0x0F1E2B, 0x7BD88F, 0x010203] {
            let color = TerminalColor(packed)
            #expect(TerminalColor(hexString: color.hexString) == color)
        }
        #expect(TerminalColor(0x0F1E2B).hexString == "#0F1E2B")
    }

    /// Tolerant about the `#` and about case; strict about everything else.
    @Test func aHexSpellingIsReadLooselyButNotCarelessly() {
        #expect(TerminalColor(hexString: "0f1e2b") == TerminalColor(0x0F1E2B))
        #expect(TerminalColor(hexString: "#0f1e2b") == TerminalColor(0x0F1E2B))
        for bad in ["", "#", "0F1E2", "0F1E2BB", "#0F1E2G", "rgb(1,2,3)", "  0F1E2B"] {
            #expect(TerminalColor(hexString: bad) == nil, "accepted \"\(bad)\"")
        }
    }

    @Test func componentsOutsideZeroToOneClampAndNonFiniteOnesAreRefused() {
        // Spelled packed on the right: with both an 8-bit and a 0...1
        // initializer in scope, three integer literals in an optional
        // context would bind to the 0...1 one and clamp themselves.
        #expect(TerminalColor(red: -0.5, green: 1.5, blue: 0.2) == TerminalColor(0x00FF33))
        #expect(TerminalColor(red: .nan, green: 0, blue: 0) == nil)
        #expect(TerminalColor(red: 0, green: .infinity, blue: 0) == nil)
        #expect(TerminalColor(red: 0, green: 0, blue: -.infinity) == nil)
    }

    // MARK: - What is shipped

    /// The offered list is a decision, pinned so that adding a preset is a
    /// deliberate change rather than an enum case slipped in. Order is the
    /// picker's order.
    @Test func theShippedPresetsAreExactlyThree() {
        #expect(TerminalThemePreset.allCases.map(\.rawValue) == ["macSCP", "midnight", "paper"])
    }

    @Test func theDefaultPresetIsTheLookTheTerminalAlwaysHad() {
        #expect(TerminalThemePreset.default == .macSCP)
        // The two `DesignTokens` constants the App painted the terminal
        // with before this setting existed.
        #expect(TerminalThemePreset.macSCP.theme.background == TerminalColor(0x0F1E2B))
        #expect(TerminalThemePreset.macSCP.theme.foreground == TerminalColor(0x7BD88F))
        #expect(TerminalThemePreset.macSCP.theme.cursor == TerminalColor(0x7BD88F))
    }

    /// The emulator installs a palette only when it is handed exactly
    /// sixteen colours, so a preset with a different count would silently
    /// keep the previous palette.
    @Test func everyPresetCarriesSixteenAnsiColours() {
        for preset in TerminalThemePreset.allCases {
            #expect(preset.theme.ansi.count == TerminalTheme.ansiColorCount, "\(preset.rawValue)")
        }
    }

    @Test func aThemeWithTheWrongNumberOfAnsiColoursCannotBeBuilt() {
        let black = TerminalColor(0)
        for count in [0, 8, 15, 17, 256] {
            #expect(
                TerminalTheme(
                    background: black, foreground: black, cursor: black,
                    ansi: Array(repeating: black, count: count)) == nil,
                "accepted \(count) ANSI colours")
        }
    }

    /// One dark preset besides `macSCP`, and one light one — the brief's
    /// requirement, measured rather than asserted by name: a light theme's
    /// background is brighter than its text, a dark one's is darker.
    @Test func theThreePresetsAreTwoDarkAndOneLight() {
        func isLight(_ theme: TerminalTheme) -> Bool {
            func luminance(_ color: TerminalColor) -> Double {
                0.2126 * Double(color.red) + 0.7152 * Double(color.green)
                    + 0.0722 * Double(color.blue)
            }
            return luminance(theme.background) > luminance(theme.foreground)
        }
        #expect(isLight(TerminalThemePreset.macSCP.theme) == false)
        #expect(isLight(TerminalThemePreset.midnight.theme) == false)
        #expect(isLight(TerminalThemePreset.paper.theme) == true)
    }

    /// No two presets are the same colours under different names.
    @Test func thePresetsAreDistinct() {
        let themes = TerminalThemePreset.allCases.map(\.theme)
        #expect(Set(themes).count == themes.count)
    }

    // MARK: - The choice

    /// `imported` is a sentinel in the same string field the presets are
    /// written to. A preset that took that name would make the two
    /// indistinguishable on disk.
    @Test func noPresetIsNamedLikeTheImportedSentinel() {
        for preset in TerminalThemePreset.allCases {
            #expect(preset.rawValue != TerminalThemeChoice.importedRawValue)
        }
    }

    @Test func aChoiceRoundTripsThroughItsRawValue() {
        let choices: [TerminalThemeChoice] =
            TerminalThemePreset.allCases.map(TerminalThemeChoice.preset) + [.imported]
        for choice in choices {
            #expect(TerminalThemeChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(TerminalThemeChoice(rawValue: "solarized-from-a-later-build") == nil)
        #expect(TerminalThemeChoice(rawValue: "") == nil)
    }

    // MARK: - Resolution

    @Test func aPresetResolvesToItsOwnColours() {
        for preset in TerminalThemePreset.allCases {
            #expect(
                TerminalTheme.resolved(choice: .preset(preset), imported: nil) == preset.theme)
        }
    }

    @Test func theImportedThemeWinsWhenItIsTheOneChosen() throws {
        let imported = try #require(Self.sampleImportedTheme)
        #expect(TerminalTheme.resolved(choice: .imported, imported: imported) == imported)
    }

    /// A stored import that is NOT chosen changes nothing.
    @Test func anImportedThemeThatIsNotChosenIsNotUsed() throws {
        let imported = try #require(Self.sampleImportedTheme)
        #expect(
            TerminalTheme.resolved(choice: .preset(.paper), imported: imported)
                == TerminalThemePreset.paper.theme)
    }

    /// Choosing `imported` with nothing imported — a hand-edited
    /// `settings.json`, or an import that was removed — falls back to the
    /// default preset rather than leaving the terminal without colours.
    @Test func choosingTheImportWithoutOneFallsBackToTheDefaultPreset() {
        #expect(
            TerminalTheme.resolved(choice: .imported, imported: nil)
                == TerminalThemePreset.default.theme)
    }

    @Test func noChoiceAtAllIsTheDefaultPreset() {
        #expect(
            TerminalTheme.resolved(choice: nil, imported: nil)
                == TerminalThemePreset.default.theme)
        #expect(
            TerminalTheme.resolved(choice: nil, imported: Self.sampleImportedTheme)
                == TerminalThemePreset.default.theme)
    }

    /// Every combination at once, so a resolver that got two of the cases
    /// right by coincidence of the values chosen above is still red.
    @Test func everyCombinationResolvesTheSameWay() throws {
        let imported = try #require(Self.sampleImportedTheme)
        let choices: [TerminalThemeChoice?] =
            [nil, .imported] + TerminalThemePreset.allCases.map { .preset($0) }
        for choice in choices {
            for stored in [TerminalTheme?.none, imported] {
                let expected: TerminalTheme
                switch choice ?? .preset(.default) {
                case .imported: expected = stored ?? TerminalThemePreset.default.theme
                case .preset(let preset): expected = preset.theme
                }
                #expect(TerminalTheme.resolved(choice: choice, imported: stored) == expected)
            }
        }
    }

    // MARK: - Storage

    @MainActor
    private func freshStore() throws -> (SettingsStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SettingsStore(directory: directory), directory)
    }

    @Test @MainActor func anUntouchedInstallationIsOnTheDefaultPreset() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.terminalThemeChoice == .preset(.default))
        #expect(store.importedTerminalTheme == nil)
        #expect(store.importedTerminalThemeName == nil)
        #expect(store.resolvedTerminalTheme == TerminalThemePreset.default.theme)
    }

    /// The whole point of storing it: a second `SettingsStore` over the
    /// same directory — which is what the next launch builds — reads back
    /// exactly what was chosen.
    @Test @MainActor func anImportedThemeSurvivesARestart() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try #require(Self.sampleImportedTheme)
        store.importedTerminalTheme = imported
        store.importedTerminalThemeName = "Harbour"
        store.terminalThemeChoice = .imported

        let restarted = SettingsStore(directory: directory)
        #expect(restarted.terminalThemeChoice == .imported)
        #expect(restarted.importedTerminalTheme == imported)
        #expect(restarted.importedTerminalThemeName == "Harbour")
        #expect(restarted.resolvedTerminalTheme == imported)
    }

    @Test @MainActor func aChosenPresetSurvivesARestart() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.terminalThemeChoice = .preset(.paper)

        let restarted = SettingsStore(directory: directory)
        #expect(restarted.terminalThemeChoice == .preset(.paper))
        #expect(restarted.resolvedTerminalTheme == TerminalThemePreset.paper.theme)
    }

    @Test @MainActor func removingTheImportLeavesNothingBehind() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.importedTerminalTheme = Self.sampleImportedTheme
        store.importedTerminalThemeName = "Harbour"
        store.importedTerminalTheme = nil
        store.importedTerminalThemeName = nil

        let restarted = SettingsStore(directory: directory)
        #expect(restarted.importedTerminalTheme == nil)
        #expect(restarted.importedTerminalThemeName == nil)
        let text = try String(
            contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!text.contains("terminalImportedTheme"))
    }

    /// The stored shape is hex strings, so whoever opens `settings.json`
    /// can read what is in there.
    @Test @MainActor func theStoredThemeIsWrittenAsHexStrings() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.importedTerminalTheme = TerminalThemePreset.macSCP.theme
        let text = try String(
            contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(text.contains("\"#0F1E2B\""))
        #expect(text.contains("\"#7BD88F\""))
    }

    /// Hand-edited or half-written values read as "nothing stored" rather
    /// than as a partial theme — the same tolerance every other accessor
    /// on this store has.
    @Test @MainActor func aDamagedStoredThemeReadsAsNoneAndTheDefaultApplies() throws {
        let (_, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Fifteen good colours and one that is not a colour at all.
        let fifteenGood = (0..<15).map { "\"#\(String(format: "%06X", $0 * 0x111111))\"" }
        let oneBad = (fifteenGood + ["\"not a colour\""]).joined(separator: ",")
        let sixteenGood = (fifteenGood + ["\"#FFFFFF\""]).joined(separator: ",")
        let damaged = [
            // A missing key.
            "{\"background\":\"#101820\"}",
            // No ANSI colours.
            "{\"background\":\"#101820\",\"foreground\":\"#CCCCCC\",\"cursor\":\"#FF9933\",\"ansi\":[]}",
            // Sixteen entries, one of which is not a colour.
            "{\"background\":\"#101820\",\"foreground\":\"#CCCCCC\",\"cursor\":\"#FF9933\""
                + ",\"ansi\":[\(oneBad)]}",
            // A background that is not a colour.
            "{\"background\":\"rgb(16,24,32)\",\"foreground\":\"#CCCCCC\""
                + ",\"cursor\":\"#FF9933\",\"ansi\":[\(sixteenGood)]}",
            // The array is not an array.
            "{\"background\":\"#101820\",\"foreground\":\"#CCCCCC\",\"cursor\":\"#FF9933\",\"ansi\":\"#000000\"}",
            // The whole value is not an object.
            "\"a string, not an object\"",
        ]
        for value in damaged {
            let json = "{\"terminalTheme\":\"imported\",\"terminalImportedTheme\":" + value + "}"
            try json.write(
                to: directory.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
            let reloaded = SettingsStore(directory: directory)
            #expect(reloaded.importedTerminalTheme == nil, "accepted \(value)")
            #expect(reloaded.resolvedTerminalTheme == TerminalThemePreset.default.theme)
        }

        // Positive beside those negatives: the same shape, undamaged, IS
        // read back — otherwise the loop above could be passing because
        // nothing at all is ever read.
        let good = "{\"background\":\"#101820\",\"foreground\":\"#CCCCCC\""
            + ",\"cursor\":\"#FF9933\",\"ansi\":[\(sixteenGood)]}"
        try ("{\"terminalTheme\":\"imported\",\"terminalImportedTheme\":" + good + "}").write(
            to: directory.appendingPathComponent("settings.json"), atomically: true,
            encoding: .utf8)
        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.importedTerminalTheme?.background == TerminalColor(0x101820))
        #expect(reloaded.resolvedTerminalTheme == reloaded.importedTerminalTheme)
    }

    /// A preset name this build does not know — a later build's, or a hand
    /// edit — reads as the default instead of propagating nothing.
    @Test @MainActor func anUnknownStoredChoiceReadsAsTheDefault() throws {
        let (_, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "{\"terminalTheme\":\"solarized-from-a-later-build\"}".write(
            to: directory.appendingPathComponent("settings.json"), atomically: true,
            encoding: .utf8)
        let store = SettingsStore(directory: directory)
        #expect(store.terminalThemeChoice == .preset(.default))
        #expect(store.resolvedTerminalTheme == TerminalThemePreset.default.theme)
    }

    // MARK: - A theme to import

    /// Colours that are none of the presets', so a test that expects the
    /// imported one cannot pass by resolving to a preset.
    static let sampleImportedTheme = TerminalTheme(
        background: TerminalColor(0x101820),
        foreground: TerminalColor(0xCCCCCC),
        cursor: TerminalColor(0xFF9933),
        ansi: (0..<16).map { TerminalColor(UInt32($0) * 0x111111) })
}
