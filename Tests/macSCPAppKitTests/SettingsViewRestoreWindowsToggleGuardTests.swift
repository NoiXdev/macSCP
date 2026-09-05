import Foundation
import Testing

/// Guards the Settings → General wiring for "Restore windows at launch"
/// (Detachable Tabs plan, Task 5): the toggle must exist in
/// `GeneralSettingsSection`, bound to `SettingsStore.restoresWindows`,
/// labelled and footnoted through the two catalogue keys — not hardcoded
/// strings a translation cannot reach.
///
/// Same shape and same shared scanner as
/// `SettingsViewAppearanceToggleGuardTests`
/// (`TransferQueueBarCancelGuardTests.declarationBodyRange(of:in:)`),
/// reused rather than copied.
///
/// Structural claims (the binding) read the view with comments AND string
/// literals blanked; the catalogue-key claims are claims ABOUT literals,
/// so they read the view that blanks comments only.
///
/// Known blind spot, the same one every guard in this target carries:
/// SOURCE TEXT only. Nothing here confirms the toggle appears on screen or
/// flips the stored value — `SettingsStoreTests` pins the property's own
/// round trip, and the maintainer's sight check is the first look at the
/// rendered pane.
@Suite("Settings — General restore-windows toggle wiring")
struct SettingsViewRestoreWindowsToggleGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    /// No trailing `{`, for the reason
    /// `SettingsViewAppearanceToggleGuardTests` states about its own
    /// declaration: the body range opens at the first `{` found AFTER this
    /// text, and the real file writes the declaration and its brace on one
    /// line.
    private static let sectionDeclaration = "private struct GeneralSettingsSection: View"

    private static let toggleKey = "\"settings.general.restoreWindows\""
    private static let footerKey = "\"settings.general.restoreWindows.footer\""

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(catalogPath(locale)))
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: String]
        else {
            throw CatalogError.unreadable(catalogPath(locale))
        }
        return plist
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path): "\(path) could not be parsed as a property list"
            }
        }
    }

    private static func views() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: settingsViewFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func sectionBodies() throws -> (code: String, withLiterals: String) {
        let all = try views()
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.sectionDeclaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    // MARK: - The guard

    @Test func theToggleIsBoundToTheStoresPropertyAndLabelledThroughTheCatalogueKeys() throws {
        let bodies = try Self.sectionBodies()
        #expect(bodies.code.contains("store.restoresWindows"), """
            GeneralSettingsSection must read/write store.restoresWindows -- a \
            toggle bound to a different or local property would silently stop \
            reflecting or controlling the setting the launch path reads.
            """)
        #expect(bodies.withLiterals.contains(Self.toggleKey), """
            The toggle must take its label from the \
            settings.general.restoreWindows catalogue key, not a hardcoded \
            string a translation cannot reach.
            """)
        #expect(bodies.withLiterals.contains(Self.footerKey), """
            The toggle must carry its footer from the \
            settings.general.restoreWindows.footer catalogue key -- the \
            footer is what says the restored windows come back \
            disconnected, which is the whole promise of the setting.
            """)
    }

    /// Positive anchor for the checks above: the strict view really is
    /// reaching the General section's own declaration, so an unreadable or
    /// empty read cannot satisfy them trivially.
    @Test func theStrictViewStillContainsTheGeneralSection() throws {
        let code = try Self.views().code
        #expect(code.contains(Self.sectionDeclaration), """
            the strict view of SettingsView.swift no longer contains the \
            General section's own declaration -- the stripper or the path is \
            wrong, and the checks above are reading something other than the \
            section they name
            """)
    }

    // MARK: - Catalogue parity

    @Test func bothKeysAreInAllFourCatalogues() throws {
        for locale in Self.catalogLocales {
            let entries = try Self.catalog(locale)
            for key in ["settings.general.restoreWindows",
                        "settings.general.restoreWindows.footer"] {
                #expect(entries[key] != nil, """
                    \(Self.catalogPath(locale)) has no \(key) entry — the \
                    control would render as its key text in that language.
                    """)
            }
        }
    }

    /// The German catalogs address the user as `du` (CLAUDE.md). The
    /// footer is a sentence about what the user does, so it is one of the
    /// places that rule can be broken.
    @Test func theGermanFooterAddressesTheUserAsDu() throws {
        let german = try Self.catalog("de")["settings.general.restoreWindows.footer"]
        let footer = try #require(german)
        #expect(footer.contains(" du "), """
            the German footer for settings.general.restoreWindows no longer \
            addresses the user as du — the German catalogs use the du form \
            throughout (CLAUDE.md), and GermanAddressFormTests holds the \
            rest of them to it.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let all = try Self.views()
        #expect(all.code.contains("store.restoresWindows"), """
            the binding needle names an expression SettingsView.swift does \
            not contain, so scannerSeesAToggleBoundToADifferentProperty \
            would be satisfied by any body at all
            """)
        #expect(all.withLiterals.contains(Self.toggleKey), """
            the label needle names a literal SettingsView.swift does not \
            contain
            """)
        #expect(all.withLiterals.contains(Self.footerKey), """
            the footer needle names a literal SettingsView.swift does not \
            contain
            """)
    }

    @Test func scannerSeesAToggleBoundToADifferentProperty() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var store: SettingsStore
                var body: some View {
                    Form {
                        Toggle(
                            L10n.string("settings.general.restoreWindows", "Restore windows at launch"),
                            isOn: $store.menuBarEnabled)
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: code)
        // Positive first: a toggle really is there, so the negative below
        // reports the wrong binding rather than an empty read.
        #expect(body.contains("Toggle("))
        #expect(!body.contains("store.restoresWindows"), """
            the scanner must report a toggle bound to a different property \
            as not wiring restoresWindows, not wave it through because a \
            Toggle with the right label is present
            """)
    }

    @Test func scannerSeesAHardcodedFooterInsteadOfTheCatalogueKey() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var store: SettingsStore
                var body: some View {
                    Form {
                        Section {
                            Toggle(
                                L10n.string("settings.general.restoreWindows", "Restore windows at launch"),
                                isOn: $store.restoresWindows)
                        } footer: {
                            Text("Windows and their tabs come back as they were.")
                        }
                    }
                }
            }
            """
        let all = (code: try SwiftSource.blankingCommentsAndStrings(source),
                   withLiterals: try SwiftSource.blankingComments(source))
        let body = (
            code: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: all.code),
            withLiterals: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: all.withLiterals))
        // Positive first: the binding IS correct, so the negative below
        // reports the missing footer key rather than an empty read.
        #expect(body.code.contains("store.restoresWindows"))
        #expect(!body.withLiterals.contains(Self.footerKey), """
            the scanner must report a hardcoded footer as missing the \
            catalogue key, not accept it because the label above it is \
            resolved correctly
            """)
    }

    @Test func scannerFailsClosedWhenTheSectionIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: source)
        }
    }
}
