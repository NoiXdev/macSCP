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

    /// `remove` couples to `SnippetVariableMemoryStore` internally (Task 4):
    /// deleting a snippet forgets any remembered variable values for it,
    /// the same coupling deleting a session has with its Keychain entry.
    /// A snippet not involved in the deletion keeps its own remembered
    /// values, proving the forget is scoped to the removed id and not a
    /// blanket wipe.
    @Test func removingASnippetForgetsItsRememberedVariables() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = Snippet(name: "Keep", command: "uptime")
        let drop = Snippet(name: "Drop", command: "whoami")
        try store.save(keep)
        try store.save(drop)
        let variables = try SnippetVariableMemoryStore(directory: dir)
        try variables.remember("kept db", snippetID: keep.id, name: "DB")
        try variables.remember("dropped db", snippetID: drop.id, name: "DB")

        let outcome = try store.remove(id: drop.id)

        #expect(outcome == .forgotten)
        let reopened = try SnippetVariableMemoryStore(directory: dir)
        #expect(reopened.value(snippetID: drop.id, name: "DB") == nil)
        #expect(reopened.value(snippetID: keep.id, name: "DB") == "kept db")
    }

    /// A corrupt `snippet-variables.json` must not block deleting a
    /// snippet. That file covers every snippet's remembered values, not
    /// just the one being removed, so letting
    /// `SnippetVariableMemoryStore.init`'s decode failure abort `remove`
    /// here — as it used to — would make ANY deletion impossible,
    /// including one for a snippet that never had a remembered value,
    /// until someone fixed an unrelated file. `ManagedKeyStore.remove`'s
    /// Keychain step does not have this shape: it touches exactly the one
    /// item for the id being removed, so its failure is specific to that
    /// id and is right to abort. Here the cleanup step is caught instead,
    /// and its failure comes back as `.skipped` rather than vanishing
    /// unreported — a swallowed read that only skips cleanup, never one
    /// that decides whether the deletion happens.
    @Test func removingASnippetSurvivesACorruptVariablesFile() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = Snippet(name: "Drop", command: "whoami")
        try store.save(snippet)
        try Data("not valid json".utf8)
            .write(to: dir.appendingPathComponent("snippet-variables.json"))

        let outcome = try store.remove(id: snippet.id)

        #expect(outcome == .skipped)
        #expect(try store.all().isEmpty)
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
