import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the terminal's one keyboard setting (plan of
/// 2026-10-09): the SwiftUI wrapper handing `optionAsMetaKey` to the view,
/// the GATE that keeps SwiftTerm's own `Option+Command+O` chord effective,
/// and the Settings tab binding the toggle through the catalogue keys.
///
/// Structural claims read the source with comments AND string literals
/// blanked (`SourceCorpus.code`), so a comment quoting a line of code
/// cannot satisfy them. Catalogue-key claims are claims about literals and
/// read the comments-blanked view (`SourceCorpus.commentFree`).
///
/// EVERY check here is POSITIVE: a `contains` that fails the moment the
/// thing it names moves, or a count that must match. There is no
/// `!contains` and no filter expected to come back empty — the only kind
/// of check that can go stale in silence — so none of these needs a
/// positive check propping it up. The one claim that reads as a
/// prohibition, "there is no second, ungated assignment", is written as a
/// count for exactly that reason.
///
/// Known blind spot, and it is the load-bearing one: SOURCE TEXT only.
/// That the gate really leaves a pressed `Option+Command+O` standing is
/// NOT established here. It needs a running app, which this project does
/// not launch from a session; the plan of 2026-10-09 assigns that check to
/// the maintainer by hand.
@Suite("Terminal keyboard setting wiring guard")
struct TerminalKeyboardWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static let wrapperFile = "Sources/MacSCPAppKit/SSHTerminalView.swift"
    private static let settingsViewFile = "Sources/MacSCPAppKit/SettingsView.swift"
    private static let settingsTab = "private struct TerminalSettingsTab: View"

    private static let keys = [
        "settings.terminal.optionAsMeta",
        "settings.terminal.optionAsMeta.footer",
    ]

    private static func views(_ relative: String) throws -> (code: String, withLiterals: String) {
        (try SourceCorpus.code(of: path(relative)),
         try SourceCorpus.commentFree(of: path(relative)))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let relative = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: path(relative))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// OCCURRENCES, not lines. `grep -c` counts lines and would report 1
    /// where the count is 2; this project has a rule about that, and the
    /// rule binds a test as much as a record.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The SwiftUI wrapper

    /// `makeNSView` hands the setting over once, and records what it handed
    /// over on the coordinator.
    @Test func theWrapperAppliesTheSettingWhenItBuildsTheView() throws {
        let code = try Self.views(Self.wrapperFile).code
        let make = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func makeNSView(", in: code)
        #expect(make.contains("terminal.optionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
        #expect(make.contains(
            "context.coordinator.appliedOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
    }

    /// `updateNSView` writes only through the gate. Four anchors spell the
    /// gate, and the count forbids a second assignment beside it: one that
    /// read the store directly would defeat the gate while every anchor
    /// above still matched.
    @Test func theWrapperWritesTheSettingOnlyThroughTheGate() throws {
        let code = try Self.views(Self.wrapperFile).code
        let update = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func updateNSView(", in: code)
        #expect(update.contains(
            "let desiredOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
        #expect(update.contains(
            "if context.coordinator.appliedOptionAsMetaKey != desiredOptionAsMetaKey"))
        #expect(update.contains("terminal.optionAsMetaKey = desiredOptionAsMetaKey"))
        #expect(update.contains(
            "context.coordinator.appliedOptionAsMetaKey = desiredOptionAsMetaKey"))
        #expect(Self.occurrences(of: "terminal.optionAsMetaKey =", in: update) == 1)
    }

    // MARK: - Settings tab

    @Test func theSettingsTabBindsTheToggleThroughTheCatalogueKeys() throws {
        let views = try Self.views(Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.settingsTab, in: views.code)
        let code = TransferQueueBarCancelGuardTests.slice(range, of: views.code)
        let literals = TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals)
        #expect(code.contains("$store.terminalOptionAsMetaKey"))
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "TerminalSettingsTab does not use \(key)")
        }
    }

    @Test func bothKeysAreInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                #expect(entries[key] != nil, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theGermanFooterAddressesTheUserAsDu() throws {
        let footer = try #require(
            try Self.catalog("de")["settings.terminal.optionAsMeta.footer"])
        #expect(footer.contains(" du "))
    }

    /// The footer exists largely to say the chord out loud: it works today
    /// and the UI mentions it nowhere. All four catalogues name it.
    ///
    /// A weak anchor, deliberately: `-O` is what survives translating
    /// "Option-Command-O" into four languages, and it would also match a
    /// hyphen before any word starting with O. It pins that the chord was
    /// not dropped in translation, not that the sentence around it is the
    /// right sentence — that one is the reviewer's to read.
    @Test func everyFooterNamesTheChord() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let footer = try #require(
                try Self.catalog(locale)["settings.terminal.optionAsMeta.footer"])
            #expect(footer.contains("-O"), "\(locale) footer does not name the chord")
        }
    }
}
