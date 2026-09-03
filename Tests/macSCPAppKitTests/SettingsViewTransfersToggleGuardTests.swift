import Foundation
import Testing

/// Guards the Settings → Transfers wiring for "Always show full paths"
/// (dev-build follow-up, 2026-09-03): the toggle must exist in
/// `TransfersSettingsTab`, bound to `SettingsStore.transfersShowFullPaths`,
/// labelled through the `settings.transfers.showFullPaths` catalogue key --
/// not a hardcoded string a translation cannot reach.
///
/// Same shape and same shared scanner as `TransferQueueBarCancelGuardTests`
/// (`declarationBodyRange(of:in:)`/`declarationBody(of:in:)`), reused rather
/// than copied. `TransfersSettingsTab` is a `struct`, not a function, but the
/// scanner only looks for the declaration text and its first balanced `{`,
/// so it works unchanged over a struct body.
///
/// Every scan here reads STRIPPED source. Structural claims (the binding) are
/// made against the view with comments AND string literals blanked; the
/// catalogue-key claim is about a literal, so it reads the view that blanks
/// comments only.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view -- nothing here
/// confirms the toggle actually appears on screen or actually flips the
/// stored value; `SettingsStoreTests` pins the property's own round trip.
@Suite("Settings — Transfers full-paths toggle wiring")
struct SettingsViewTransfersToggleGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    private static let tabDeclaration = "private struct TransfersSettingsTab: View {"

    private static let toggleKey = "\"settings.transfers.showFullPaths\""

    private static func views() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: settingsViewFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func tabBodies() throws -> (code: String, withLiterals: String) {
        let all = try views()
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.tabDeclaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    // MARK: - The guard

    @Test func theToggleIsBoundToTheStoresPropertyAndLabelledThroughTheCatalogueKey() throws {
        let bodies = try Self.tabBodies()
        #expect(bodies.code.contains("Toggle("), """
            TransfersSettingsTab no longer contains a Toggle( -- the "Always \
            show full paths" control is gone from Settings → Transfers.
            """)
        #expect(bodies.code.contains("store.transfersShowFullPaths"), """
            The tab must read/write store.transfersShowFullPaths -- a toggle \
            bound to a different or local property would silently stop \
            reflecting or controlling the setting TransferQueueBar reads.
            """)
        #expect(bodies.withLiterals.contains(Self.toggleKey), """
            The toggle must take its label from the \
            settings.transfers.showFullPaths catalogue key, not a hardcoded \
            string a translation cannot reach.
            """)
    }

    /// Positive anchor for the check above: the strict view must actually be
    /// reaching the tab's own declaration, or an unreadable/empty read would
    /// make the `contains` checks above pass trivially over nothing.
    @Test func theStrictViewStillContainsTheTransfersTab() throws {
        let code = try Self.views().code
        #expect(code.contains("private struct TransfersSettingsTab: View"), """
            the strict view of SettingsView.swift no longer contains the \
            Transfers tab's own declaration -- the stripper or the path is \
            wrong, and the check above is reading something other than the \
            tab it names
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let all = try Self.views()
        #expect(all.code.contains("store.transfersShowFullPaths"), """
            the binding needle names an expression SettingsView.swift does not \
            contain, so scannerSeesAToggleBoundToADifferentProperty would be \
            satisfied by any body at all
            """)
        #expect(all.withLiterals.contains(Self.toggleKey), """
            the catalogue-key needle names a literal SettingsView.swift does \
            not contain
            """)
    }

    @Test func scannerSeesAToggleBoundToADifferentProperty() throws {
        let source = """
            \(Self.tabDeclaration)
                var store: SettingsStore
                var body: some View {
                    Form {
                        Toggle(
                            L10n.string("settings.transfers.showFullPaths", "Always show full paths"),
                            isOn: Binding(
                                get: { store.showHiddenFiles },
                                set: { store.showHiddenFiles = $0 }
                            ))
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.tabDeclaration, in: code)
        // Positive first: a toggle really is there, so the negative below
        // reports the wrong binding rather than an empty read.
        #expect(body.contains("Toggle("))
        #expect(!body.contains("store.transfersShowFullPaths"), """
            the scanner must report a toggle bound to a different property as \
            not wiring transfersShowFullPaths, not wave it through because a \
            Toggle with the right label is present
            """)
    }

    @Test func scannerSeesAHardcodedLabelInsteadOfTheCatalogueKey() throws {
        let source = """
            \(Self.tabDeclaration)
                var store: SettingsStore
                var body: some View {
                    Form {
                        Toggle(
                            "Always show full paths",
                            isOn: Binding(
                                get: { store.transfersShowFullPaths },
                                set: { store.transfersShowFullPaths = $0 }
                            ))
                    }
                }
            }
            """
        let all = (code: try SwiftSource.blankingCommentsAndStrings(source),
                   withLiterals: try SwiftSource.blankingComments(source))
        let body = (
            code: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.tabDeclaration, in: all.code),
            withLiterals: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.tabDeclaration, in: all.withLiterals))
        // Positive first: the binding IS correct, so the negative below
        // reports the missing catalogue key rather than an empty read.
        #expect(body.code.contains("store.transfersShowFullPaths"))
        #expect(!body.withLiterals.contains(Self.toggleKey), """
            the scanner must report a hardcoded label as missing the catalogue \
            key, not accept it because the binding underneath is correct
            """)
    }

    @Test func scannerFailsClosedWhenTheTabIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.tabDeclaration, in: source)
        }
    }
}
