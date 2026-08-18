import Foundation
import Testing
@testable import macSCPCore

/// Pins `SnippetListPlan.build`, the flat-list projection behind the
/// terminal panel's snippet picker (P3d, Task 1). It consumes the same
/// `SnippetMenuModel` the menu surfaces do, but — unlike `SnippetMenuPlan`
/// (`MacSCPAppKit`) — collapses a two-tag snippet to a single row instead of
/// duplicating it per group. See the type's doc comment for why; this suite
/// is where that claim, and every other doc-comment claim on the type, is
/// actually observed.
@Suite("SnippetListPlan")
struct SnippetListPlanTests {
    private func snippet(_ name: String, tags: [String] = []) -> Snippet {
        Snippet(name: name, command: "echo \(name)", tags: tags)!
    }

    @Test func emptyModelProducesNoSections() {
        let model = SnippetMenuModel.build(snippets: [], isConnected: true, supportsShell: true)
        #expect(SnippetListPlan.build(model: model).isEmpty)
    }

    @Test func untaggedSnippetProducesOneSectionWithNilTag() {
        let a = snippet("a")
        let model = SnippetMenuModel.build(snippets: [a], isConnected: true, supportsShell: true)

        let sections = SnippetListPlan.build(model: model)
        #expect(sections.map(\.tag) == [nil])
        #expect(sections[0].rows.map(\.snippet.id) == [a.id])
    }

    @Test func taggedSnippetProducesASectionCarryingThatTag() {
        let a = snippet("a", tags: ["Docker"])
        let model = SnippetMenuModel.build(snippets: [a], isConnected: true, supportsShell: true)

        let sections = SnippetListPlan.build(model: model)
        #expect(sections.map(\.tag) == ["Docker"])
    }

    @Test func rowCarriesTheSnippetAndItsDisplayName() {
        let a = snippet("Restart nginx")
        let model = SnippetMenuModel.build(snippets: [a], isConnected: true, supportsShell: true)

        let row = SnippetListPlan.build(model: model).flatMap(\.rows).first
        #expect(row?.snippet == a)
        #expect(row?.displayName == "Restart nginx")
    }

    /// The one deliberate divergence from `SnippetMenuPlan`: a snippet
    /// carrying two tags appears in TWO groups in `SnippetMenuModel`, but a
    /// scrollable flat list has no submenu boundary to explain why the same
    /// name and command would appear twice, so this projection keeps only
    /// ONE row per snippet.
    @Test func aSnippetWithTwoTagsProducesExactlyOneRow() {
        let dual = snippet("dual", tags: ["Alpha", "Beta"])
        let model = SnippetMenuModel.build(snippets: [dual], isConnected: true, supportsShell: true)
        // Sanity: the model itself still duplicates across two groups —
        // otherwise this test would not exercise the dedup at all.
        #expect(model.groups.count == 2)

        let rows = SnippetListPlan.build(model: model).flatMap(\.rows)
        #expect(rows.map(\.snippet.id) == [dual.id])
    }

    /// The kept row lands under the snippet's FIRST section in
    /// `model.groups`' own order (tag-sorted alphabetically, untagged
    /// last) — "Alpha" sorts before "Beta", so the row surfaces there.
    @Test func aSnippetWithTwoTagsKeepsItsFirstSectionInModelOrder() {
        let dual = snippet("dual", tags: ["Beta", "Alpha"])
        let model = SnippetMenuModel.build(snippets: [dual], isConnected: true, supportsShell: true)
        #expect(model.groups.map(\.tag) == ["Alpha", "Beta"])

        let sections = SnippetListPlan.build(model: model)
        #expect(sections.map(\.tag) == ["Alpha"])
    }

    /// If dedup empties out every row a later section would have had (its
    /// one snippet already surfaced under an earlier tag), that section
    /// must not appear at all — an empty tag heading with nothing under it
    /// would be exactly the kind of view-body bug this task exists to
    /// prevent (see P3a's vanishing empty groups).
    @Test func aSectionEmptiedEntirelyByDedupDoesNotAppear() {
        let dual = snippet("dual", tags: ["Alpha", "Beta"])
        let alphaOnly = snippet("alpha-only", tags: ["Alpha"])
        let model = SnippetMenuModel.build(
            snippets: [dual, alphaOnly], isConnected: true, supportsShell: true)
        #expect(model.groups.map(\.tag) == ["Alpha", "Beta"])

        let sections = SnippetListPlan.build(model: model)
        #expect(sections.map(\.tag) == ["Alpha"])
        #expect(sections[0].rows.map(\.snippet.id) == [dual.id, alphaOnly.id])
    }

    /// The projection preserves `model.groups`' own section order — tags
    /// sorted alphabetically, the untagged section always last — rather
    /// than deriving some order of its own.
    @Test func sectionOrderMatchesTheModelsGroupOrderUntaggedLast() {
        let untagged = snippet("untagged")
        let tagged = snippet("tagged", tags: ["Zebra"])
        let model = SnippetMenuModel.build(
            snippets: [untagged, tagged], isConnected: true, supportsShell: true)
        // Sanity: the model puts the tagged group first, untagged last.
        #expect(model.groups.map(\.tag) == ["Zebra", nil])

        let sections = SnippetListPlan.build(model: model)
        #expect(sections.map(\.tag) == ["Zebra", nil])
    }

    @Test func noDisabledReasonMeansEveryRowIsActionable() {
        let model = SnippetMenuModel.build(
            snippets: [snippet("a")], isConnected: true, supportsShell: true)

        let rows = SnippetListPlan.build(model: model).flatMap(\.rows)
        #expect(rows.allSatisfy { $0.isDisabled == false })
    }

    @Test func notConnectedDisablesEveryRow() {
        let model = SnippetMenuModel.build(
            snippets: [snippet("a"), snippet("b", tags: ["Work"])],
            isConnected: false, supportsShell: true)

        let rows = SnippetListPlan.build(model: model).flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.isDisabled == true })
    }

    @Test func backendHasNoShellDisablesEveryRow() {
        let model = SnippetMenuModel.build(
            snippets: [snippet("a")], isConnected: true, supportsShell: false)

        let rows = SnippetListPlan.build(model: model).flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.isDisabled == true })
    }
}
