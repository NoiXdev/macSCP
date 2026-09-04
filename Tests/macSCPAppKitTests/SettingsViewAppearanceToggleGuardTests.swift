import Foundation
import Testing

/// Guards the Settings → View (Appearance) wiring for "Compact sidebar"
/// (sidebar-polish plan, Task 2): the toggle must exist in
/// `AppearanceSettingsSection`, bound to `SettingsStore.sidebarCompact`,
/// labelled through the `settings.appearance.sidebarCompact` catalogue key —
/// not a hardcoded string a translation cannot reach.
///
/// Same shape and same shared scanner as
/// `SettingsViewTransfersToggleGuardTests` (`declarationBodyRange(of:in:)`/
/// `declarationBody(of:in:)`, `TransferQueueBarCancelGuardTests`), reused
/// rather than copied. `AppearanceSettingsSection` is a `struct`, not a
/// function, but the scanner only looks for the declaration text and its
/// first balanced `{`, so it works unchanged over a struct body.
///
/// Every scan here reads STRIPPED source. Structural claims (the binding) are
/// made against the view with comments AND string literals blanked; the
/// catalogue-key claim is about a literal, so it reads the view that blanks
/// comments only.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view -- nothing here
/// confirms the toggle actually appears on screen or actually flips the
/// stored value; `SettingsStoreTests` pins the property's own round trip.
@Suite("Settings — Appearance compact-sidebar toggle wiring")
struct SettingsViewAppearanceToggleGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    /// No trailing `{` — same reason `SettingsViewTransfersToggleGuardTests`
    /// spells its own declaration this way: `declarationBodyRange` opens its
    /// span at the first `{` found AFTER the declaration text, and the real
    /// file writes the struct declaration and its brace on one line.
    private static let sectionDeclaration = "private struct AppearanceSettingsSection: View"

    private static let toggleKey = "\"settings.appearance.sidebarCompact\""

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

    @Test func theToggleIsBoundToTheStoresPropertyAndLabelledThroughTheCatalogueKey() throws {
        let bodies = try Self.sectionBodies()
        #expect(bodies.code.contains("Toggle("), """
            AppearanceSettingsSection no longer contains a Toggle( -- the \
            "Compact sidebar" control is gone from Settings → View.
            """)
        #expect(bodies.code.contains("store.sidebarCompact"), """
            The section must read/write store.sidebarCompact -- a toggle \
            bound to a different or local property would silently stop \
            reflecting or controlling the setting SessionSidebar reads.
            """)
        #expect(bodies.withLiterals.contains(Self.toggleKey), """
            The toggle must take its label from the \
            settings.appearance.sidebarCompact catalogue key, not a \
            hardcoded string a translation cannot reach.
            """)
    }

    /// Positive anchor for the check above: the strict view must actually be
    /// reaching the section's own declaration, or an unreadable/empty read
    /// would make the `contains` checks above pass trivially over nothing.
    @Test func theStrictViewStillContainsTheAppearanceSection() throws {
        let code = try Self.views().code
        #expect(code.contains("private struct AppearanceSettingsSection: View"), """
            the strict view of SettingsView.swift no longer contains the \
            Appearance section's own declaration -- the stripper or the \
            path is wrong, and the check above is reading something other \
            than the section it names
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let all = try Self.views()
        #expect(all.code.contains("store.sidebarCompact"), """
            the binding needle names an expression SettingsView.swift does \
            not contain, so scannerSeesAToggleBoundToADifferentProperty \
            would be satisfied by any body at all
            """)
        #expect(all.withLiterals.contains(Self.toggleKey), """
            the catalogue-key needle names a literal SettingsView.swift \
            does not contain
            """)
    }

    @Test func scannerSeesAToggleBoundToADifferentProperty() throws {
        // The opening `{` is written out here, on `sectionDeclaration`'s own
        // line, matching the real file's shape (the struct declaration and
        // its brace on one line) now that `sectionDeclaration` itself omits
        // it.
        let source = """
            \(Self.sectionDeclaration) {
                var store: SettingsStore
                var body: some View {
                    Form {
                        Toggle(
                            L10n.string("settings.appearance.sidebarCompact", "Compact sidebar"),
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
            of: Self.sectionDeclaration, in: code)
        // Positive first: a toggle really is there, so the negative below
        // reports the wrong binding rather than an empty read.
        #expect(body.contains("Toggle("))
        #expect(!body.contains("store.sidebarCompact"), """
            the scanner must report a toggle bound to a different property \
            as not wiring sidebarCompact, not wave it through because a \
            Toggle with the right label is present
            """)
    }

    @Test func scannerSeesAHardcodedLabelInsteadOfTheCatalogueKey() throws {
        // Same explicit brace as `scannerSeesAToggleBoundToADifferentProperty`
        // above, for the same reason.
        let source = """
            \(Self.sectionDeclaration) {
                var store: SettingsStore
                var body: some View {
                    Form {
                        Toggle(
                            "Compact sidebar",
                            isOn: Binding(
                                get: { store.sidebarCompact },
                                set: { store.sidebarCompact = $0 }
                            ))
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
        // reports the missing catalogue key rather than an empty read.
        #expect(body.code.contains("store.sidebarCompact"))
        #expect(!body.withLiterals.contains(Self.toggleKey), """
            the scanner must report a hardcoded label as missing the \
            catalogue key, not accept it because the binding underneath is \
            correct
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
