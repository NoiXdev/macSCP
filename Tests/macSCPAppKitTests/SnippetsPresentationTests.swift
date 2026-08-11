import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers the decisions the Terminal menu and the snippets sheet make about
/// snippets BEFORE any view is involved: what a read of the store yielded,
/// which snippets a tag filter chip passes, and when the sheet counts as
/// "filtered" for its empty-state wording.
///
/// It does not cover the views themselves — no test in this repo renders
/// `SnippetsSheet` or a `CommandMenu`, so nothing here proves that a menu
/// item appears or that the sheet's error line is visible. What it does
/// prove is that the values those views are handed distinguish an empty
/// store from an unreadable one, and route the right snippets to the right
/// filter chip.
@Suite("Snippets presentation")
struct SnippetsPresentationTests {
    private func makeStore() -> (SnippetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippets-app-\(UUID().uuidString)")
        return (SnippetStore(directory: dir), dir)
    }

    @Test func aMissingStoreLoadsAsAnEmptyList() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let load = SnippetsLoad(reading: store)

        #expect(load == .loaded([]))
        #expect(!load.isUnreadable)
    }

    @Test func aSavedSnippetLoads() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        try store.save(snippet)

        #expect(SnippetsLoad(reading: store) == .loaded([snippet]))
    }

    /// The whole point: a file that exists and cannot be decoded is NOT an
    /// empty list. One hand-edited multi-line command is enough to get there
    /// — the same file shape `aHandEditedMultiLineCommandDoesNotDecode`
    /// makes `SnippetStore.all()` throw on.
    @Test func anUndecodableStoreIsUnreadableRatherThanEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID().uuidString)","name":"x","command":"a\nb","runsImmediately":false}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("snippets.json"))

        let load = SnippetsLoad(reading: store)

        #expect(load == .unreadable)
        #expect(load.isUnreadable)
        // Still empty to list — a caller that only enumerates needs no case.
        #expect(load.snippets.isEmpty)
        #expect(load != .loaded([]))
    }

    /// The Terminal menu's remaining two snippet-related notices come from
    /// the catalog, not from a literal baked into a view — a missing key
    /// would otherwise show up as a mangled menu entry rather than a failing
    /// test (same guard shape as
    /// `KeyboardShortcutsCatalogTests.everyLabelKeyResolves`).
    ///
    /// TEMPORARY (Terminal-Snippets, Task 1 → Task 5): this used to also
    /// cover `menu.snippets.executingItem`, the marker for an executing
    /// snippet's `SnippetMenuEntry.title(for:)` — both that key and that
    /// type are gone now (see `Snippet`'s doc comment on why the
    /// insert-or-execute decision moved to the trigger; `SnippetMenuEntry`
    /// had no purpose left once every title was the bare name).
    @Test func theTerminalMenuNoticesResolveFromTheCatalog() {
        #expect(
            L10n.string("menu.snippets.unreadable", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(L10n.string("snippets.load.error", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: - SnippetTagFilter

    @Test func allMatchesEverySnippetRegardlessOfTags() throws {
        let tagged = try #require(Snippet(name: "a", command: "a", tags: ["x"]))
        let untagged = try #require(Snippet(name: "b", command: "b"))

        #expect(SnippetTagFilter.all.matches(tagged))
        #expect(SnippetTagFilter.all.matches(untagged))
    }

    @Test func tagMatchesOnlyASnippetCarryingThatExactTag() throws {
        let docker = try #require(Snippet(name: "a", command: "a", tags: ["Docker"]))
        let other = try #require(Snippet(name: "b", command: "b", tags: ["compose"]))

        #expect(SnippetTagFilter.tag("Docker").matches(docker))
        #expect(!SnippetTagFilter.tag("Docker").matches(other))
    }

    /// `Snippet.tags` keeps case exactly as typed (see that type's doc
    /// comment) — a filter chip built from one stored tag must not also
    /// match a differently-cased tag that happens to be a different snippet
    /// entirely as far as the store is concerned.
    @Test func tagComparesCaseSensitively() throws {
        let lowercase = try #require(Snippet(name: "a", command: "a", tags: ["docker"]))

        #expect(!SnippetTagFilter.tag("Docker").matches(lowercase))
    }

    @Test func untaggedMatchesOnlyASnippetWithNoTagsAtAll() throws {
        let untagged = try #require(Snippet(name: "a", command: "a"))
        let tagged = try #require(Snippet(name: "b", command: "b", tags: ["x"]))

        #expect(SnippetTagFilter.untagged.matches(untagged))
        #expect(!SnippetTagFilter.untagged.matches(tagged))
    }

    // MARK: - snippetsAreFiltered

    @Test func neitherSearchNorTagFilterActiveIsNotFiltered() {
        #expect(!snippetsAreFiltered(searchText: "", tagFilter: .all))
    }

    @Test func nonEmptySearchTextCountsAsFiltered() {
        #expect(snippetsAreFiltered(searchText: "df", tagFilter: .all))
    }

    @Test func aNonAllTagFilterCountsAsFilteredEvenWithNoSearchText() {
        #expect(snippetsAreFiltered(searchText: "", tagFilter: .tag("Docker")))
        #expect(snippetsAreFiltered(searchText: "", tagFilter: .untagged))
    }
}
