import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetStore")
struct SnippetStoreTests {
    private func makeStore() -> (SnippetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippets-\(UUID().uuidString)")
        return (SnippetStore(directory: dir), dir)
    }

    /// A store whose file does not exist yet is empty, not an error — the
    /// same promise `ManagedKeyStore` makes, and what every first launch
    /// hits.
    @Test func aMissingFileReadsAsAnEmptyList() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try store.all().isEmpty)
    }

    /// What goes in comes back out unchanged, including its tags.
    @Test func aSavedSnippetSurvivesTheRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = Snippet(name: "Disk", command: "df -h", tags: ["disk"])

        try store.save(snippet)

        #expect(try store.all() == [snippet])
    }

    /// Saving the same id twice replaces rather than duplicating.
    @Test func savingTheSameIdTwiceReplaces() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snippet = Snippet(name: "Disk", command: "df -h")
        try store.save(snippet)
        snippet.name = "Disk usage"

        try store.save(snippet)

        #expect(try store.all().count == 1)
        #expect(try store.all().first?.name == "Disk usage")
    }

    /// Editing a snippet must not move it: the Terminal menu lists snippets
    /// in store order and gives the first three inserting ones ⌃⌘1–3, so a
    /// replace that appends would silently reassign those shortcuts.
    @Test func replacingAnExistingIdKeepsItsPosition() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first = Snippet(name: "First", command: "uptime")
        let second = Snippet(name: "Second", command: "whoami")
        try store.save(first)
        try store.save(second)
        first.name = "First, renamed"

        try store.save(first)

        #expect(try store.all().map(\.name) == ["First, renamed", "Second"])
    }

    @Test func removingAnIdLeavesTheOthers() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = Snippet(name: "Keep", command: "uptime")
        let drop = Snippet(name: "Drop", command: "whoami")
        try store.save(keep)
        try store.save(drop)

        try store.remove(id: drop.id)

        #expect(try store.all() == [keep])
    }

    /// A command with an embedded line break survives the store round trip
    /// unchanged — a command may now span lines (snippet editor, part 2);
    /// see `SnippetTests.multilineCommandSurvivesEncoding` for the model-level
    /// version of this guarantee.
    @Test func aCommandWithALineBreakSurvivesTheRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = Snippet(name: "Two", command: "echo a\necho b")

        try store.save(snippet)

        #expect(try store.all() == [snippet])
    }
}
