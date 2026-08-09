import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("KeyboardShortcutsCatalog")
struct KeyboardShortcutsCatalogTests {
    /// The catalog is a HAND-MAINTAINED mirror of bindings that live at six
    /// other sites, so its failure mode is quiet drift. These tests cannot
    /// detect a binding that changed elsewhere — nothing can, short of a
    /// central registry — but they do catch the catalog rotting on its own.
    @Test func everyGroupHasATitleAndRows() {
        for group in KeyboardShortcutsCatalog.groups {
            #expect(group.titleKey.isEmpty == false)
            #expect(group.titleDefault.isEmpty == false)
            #expect(group.rows.isEmpty == false)
        }
    }

    /// Every row must carry a key, an English default and a glyph. An empty
    /// glyph renders as a blank cell in the settings table.
    @Test func everyRowIsComplete() {
        for row in KeyboardShortcutsCatalog.groups.flatMap(\.rows) {
            #expect(row.labelKey.isEmpty == false)
            #expect(row.labelDefault.isEmpty == false)
            #expect(row.shortcut.isEmpty == false)
        }
    }

    /// Every label and group title must resolve through the catalog. This is
    /// the check that would have caught a typo'd key, which previously
    /// rendered as English and looked correct.
    @Test func everyLabelKeyResolves() {
        for group in KeyboardShortcutsCatalog.groups {
            #expect(
                L10n.string(group.titleKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                "group title key does not resolve: \(group.titleKey)")
            for row in group.rows {
                #expect(
                    L10n.string(row.labelKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                    "row label key does not resolve: \(row.labelKey)")
            }
        }
    }

    /// Two rows may legitimately share a glyph across contexts (⎋ cancels in
    /// several places, ⏎ confirms in several), but the same LABEL KEY twice
    /// inside one group is a copy-paste slip.
    @Test func noGroupRepeatsALabelKey() {
        for group in KeyboardShortcutsCatalog.groups {
            let keys = group.rows.map(\.labelKey)
            #expect(Set(keys).count == keys.count, "duplicate label key in group \(group.titleKey)")
        }
    }
}
