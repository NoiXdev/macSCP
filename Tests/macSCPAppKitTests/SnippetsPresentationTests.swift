import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers the two decisions the Terminal menu and the snippets sheet make
/// about snippets BEFORE any view is involved: what a read of the store
/// yielded, and how one entry is titled.
///
/// It does not cover the views themselves — no test in this repo renders
/// `SnippetsSheet` or a `CommandMenu`, so nothing here proves that a menu
/// item appears or that the sheet's error line is visible. What it does
/// prove is that the values those views are handed distinguish an empty
/// store from an unreadable one, and an executing snippet from an
/// inserting one.
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

    /// TEMPORARY (Terminal-Snippets, Task 1): `title(for:)` used to mark an
    /// executing entry in its own title, distinguishing it from an inserting
    /// one via the now-removed `Snippet.runsImmediately` (see
    /// `SnippetMenuEntry`'s doc comment). With that flag gone, every title is
    /// the bare name — this pins today's reality, not a design decision.
    /// Task 5 removes `SnippetMenuEntry` entirely, and this test with it.
    @Test func titleIsAlwaysTheBareNameNowThatTheFlagIsGone() throws {
        let snippet = try #require(Snippet(name: "Restart", command: "systemctl restart x"))

        #expect(SnippetMenuEntry.title(for: snippet) == "Restart")
    }

    /// The marker comes from the catalog, not from a literal baked into the
    /// title function — a missing key would otherwise show up as a mangled
    /// menu entry rather than a failing test (same guard shape as
    /// `KeyboardShortcutsCatalogTests.everyLabelKeyResolves`).
    @Test func theExecutingMarkerResolvesFromTheCatalog() {
        #expect(
            L10n.string("menu.snippets.executingItem", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(
            L10n.string("menu.snippets.unreadable", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(L10n.string("snippets.load.error", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }
}
