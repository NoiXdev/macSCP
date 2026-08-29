import Foundation
import Testing
@testable import MacSCPAppKit

/// The rule the management sheets' three-dot menu exists to hold
/// (backlog 2026-08-20, point 5): **selection actions stay visible, file
/// actions move under the menu.** New/Edit/Delete act on the row selected
/// in the list; Export/Import act on a file on disk. "Delete…" would save
/// footer width too, but hiding a destructive action is the wrong economy.
///
/// This suite pins the half of the rule that a type can carry:
/// `SheetOverflowAction` is the complete vocabulary the menu renders, and it
/// admits nothing but file actions — so a destructive entry has no
/// representation to reach the menu with. The other half (that the visible
/// footer keeps its destructive button, and that the symbol-only menu
/// carries both a help text and an accessibility label) is a property of the
/// two sheets and of `SheetOverflowMenu.swift`, pinned by
/// `SheetOverflowMenuWiringGuardTests`.
@Suite("Sheet overflow menu")
struct SheetOverflowMenuTests {
    // MARK: - What the menu offers

    @Test func bothFileActionsAreOfferedWhenBothArePossible() {
        #expect(SheetOverflowAction.offered(canExport: true, canImport: true) == [.export, .import])
    }

    /// "Show only what is possible" — an export with nothing to export is
    /// ABSENT, not greyed out. This is the login sheet's live case: a search
    /// that matches nothing leaves nothing exportable.
    @Test func anImpossibleExportIsAbsentRatherThanDisabled() {
        #expect(SheetOverflowAction.offered(canExport: false, canImport: true) == [.import])
    }

    @Test func anImpossibleImportIsAbsentRatherThanDisabled() {
        #expect(SheetOverflowAction.offered(canExport: true, canImport: false) == [.export])
    }

    /// Nothing possible means no entries at all — and `SheetOverflowMenu`
    /// draws nothing for an empty list, rather than an empty menu.
    @Test func nothingPossibleMeansNoEntriesAtAll() {
        #expect(SheetOverflowAction.offered(canExport: false, canImport: false).isEmpty)
    }

    // MARK: - What the menu cannot offer

    /// The structural half of the rule. `SheetOverflowMenu` renders
    /// `[SheetOverflowAction]` and nothing else, so this enumeration IS the
    /// menu's vocabulary: two cases, both file actions, counted here.
    /// Adding "Delete…" to the menu is not an edit to a footer — it is an
    /// edit to this type, which this assertion reports.
    @Test func theVocabularyIsTwoFileActionsAndNothingElse() {
        #expect(SheetOverflowAction.allCases == [.export, .import])
    }

    // MARK: - The labels exist

    /// Every label the menu can draw is declared in the English catalog —
    /// keys read off the type, never spelled here, so a rename moves both
    /// together or this fails. `LocalizationParityTests` carries each key
    /// from English into de/fr/pl.
    @Test func everyActionLabelIsDeclaredInTheEnglishCatalog() throws {
        let catalog = try Self.englishCatalog()
        for action in SheetOverflowAction.allCases {
            #expect(catalog.contains("\"\(action.labelKey)\""), """
                \(action.labelKey) is not declared in the English catalog, so \
                every language falls back to the hardcoded default.
                """)
        }
    }

    /// The symbol-only menu's own label: one key serving both the tooltip
    /// and VoiceOver, following the house form at `SettingsView`'s
    /// remove-rule button.
    @Test func theMenuLabelIsDeclaredInTheEnglishCatalog() throws {
        let catalog = try Self.englishCatalog()
        #expect(catalog.contains("\"\(SheetOverflowMenu.menuLabelKey)\""), """
            \(SheetOverflowMenu.menuLabelKey) is not declared in the English \
            catalog — a symbol-only control would then announce a hardcoded \
            English word in every language.
            """)
    }

    // MARK: - Catalog access

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SheetOverflowMenuTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func englishCatalog() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8)
    }
}
