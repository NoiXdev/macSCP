import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// Pins `SnippetMenuPlan.build`, the decision layer behind `SnippetMenuItems`
/// (Terminal-Snippets milestone, Task 6): which entries get a ⌃⌘n INSERT
/// shortcut, and which are disabled. Neither of these is observable by the
/// constant-return probe or by any pixel harness (this project has none for
/// AppKit-backed menu content) — this suite is the only place they are
/// checked.
@Suite("SnippetMenuPlan")
struct SnippetMenuItemsTests {
    private func snippet(_ name: String, tags: [String] = []) -> Snippet {
        Snippet(name: name, command: "echo \(name)", tags: tags)!
    }

    @Test func firstThreeSnippetsInStoreOrderGetInsertShortcuts() {
        let a = snippet("a")
        let b = snippet("b")
        let c = snippet("c")
        let d = snippet("d")
        let storeOrder = [a, b, c, d]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        let entries = groups.flatMap(\.entries)
        // `compactMap` here, not a `[String: Int?]` dictionary: a plain
        // `dict[key] == nil` check is ambiguous once the value type is
        // itself optional (a PRESENT key holding `nil` also reads back as
        // `nil` through the double-optional subscript), so an absent key
        // and a present-but-unassigned one become indistinguishable. This
        // shape makes "no shortcut" mean "not in the dictionary", period.
        let digitByName = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.insertShortcutDigit.map { (entry.snippet.name, $0) }
        })

        #expect(digitByName["a"] == 1)
        #expect(digitByName["b"] == 2)
        #expect(digitByName["c"] == 3)
        #expect(digitByName["d"] == nil)
    }

    /// The shortcut promise is about STORE order, not the tag-sorted order
    /// `SnippetMenuModel.groups` presents. A tag beginning with "A" sorts
    /// before an untagged group, which would reorder these snippets in the
    /// rendered menu — the shortcut digits must still follow the store, not
    /// that render order.
    @Test func shortcutOrderIsStoreOrderNotTheModelsGroupOrder() {
        let untaggedFirst = snippet("untagged-first")
        let taggedSecond = snippet("tagged-second", tags: ["Aardvark"])
        let storeOrder = [untaggedFirst, taggedSecond]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        // Sanity: the model itself puts the tagged group before the
        // untagged one (untagged is always last), which is the opposite of
        // store order — otherwise this test would not exercise anything.
        #expect(model.groups.first?.tag == "Aardvark")

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        let entries = groups.flatMap(\.entries)
        let digitByName = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.insertShortcutDigit.map { (entry.snippet.name, $0) }
        })

        #expect(digitByName["untagged-first"] == 1)
        #expect(digitByName["tagged-second"] == 2)
    }

    /// A snippet with two tags appears in two groups (`SnippetMenuModel`
    /// duplicates it by design). If it qualifies for a shortcut, only its
    /// FIRST occurrence may carry the digit — two `Insert` buttons with the
    /// same ⌃⌘n key equivalent in one `NSMenu` would be ambiguous.
    @Test func aSnippetWithTwoTagsGetsTheShortcutOnlyOnce() {
        let dual = snippet("dual", tags: ["Alpha", "Beta"])
        let storeOrder = [dual]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)
        #expect(model.groups.count == 2)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        let digits = groups.flatMap(\.entries).map(\.insertShortcutDigit)

        #expect(digits.compactMap { $0 }.count == 1, "the shortcut must appear on exactly one of the two occurrences")
        #expect(digits.contains(1))
    }

    @Test func emptyShortcutOrderAssignsNoShortcutsAtAll() {
        let storeOrder = [snippet("a"), snippet("b")]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: [])
        #expect(groups.flatMap(\.entries).allSatisfy { $0.insertShortcutDigit == nil })
    }

    @Test func noDisabledReasonMeansEveryEntryIsEnabled() {
        let storeOrder = [snippet("a")]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        #expect(groups.flatMap(\.entries).allSatisfy { $0.isDisabled == false })
    }

    @Test func notConnectedDisablesEveryEntry() {
        let storeOrder = [snippet("a"), snippet("b", tags: ["Work"])]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: false, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        #expect(groups.flatMap(\.entries).allSatisfy { $0.isDisabled == true })
    }

    @Test func backendHasNoShellDisablesEveryEntry() {
        let storeOrder = [snippet("a")]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: false)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        #expect(groups.flatMap(\.entries).allSatisfy { $0.isDisabled == true })
    }

    @Test func groupTagPassesThroughUnchanged() {
        let storeOrder = [snippet("a", tags: ["Docker"])]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        #expect(groups.map(\.tag) == ["Docker"])
    }

    @Test func untaggedGroupHasANilTag() {
        let storeOrder = [snippet("a")]
        let model = SnippetMenuModel.build(snippets: storeOrder, isConnected: true, supportsShell: true)

        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: storeOrder)
        #expect(groups.map(\.tag) == [nil])
    }

    @Test func emptyModelProducesNoGroups() {
        let model = SnippetMenuModel.build(snippets: [], isConnected: true, supportsShell: true)
        #expect(SnippetMenuPlan.build(model: model, shortcutOrder: []).isEmpty)
    }
}
