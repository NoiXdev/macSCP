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

    /// What goes in comes back out unchanged, including the flag that
    /// decides whether the snippet executes.
    @Test func aSavedSnippetSurvivesTheRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: true))

        try store.save(snippet)

        #expect(try store.all() == [snippet])
    }

    /// Saving the same id twice replaces rather than duplicating.
    @Test func savingTheSameIdTwiceReplaces() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: false))
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
        var first = try #require(Snippet(name: "First", command: "uptime", runsImmediately: false))
        let second = try #require(Snippet(name: "Second", command: "whoami", runsImmediately: false))
        try store.save(first)
        try store.save(second)
        first.name = "First, renamed"

        try store.save(first)

        #expect(try store.all().map(\.name) == ["First, renamed", "Second"])
    }

    @Test func removingAnIdLeavesTheOthers() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = try #require(Snippet(name: "Keep", command: "uptime", runsImmediately: false))
        let drop = try #require(Snippet(name: "Drop", command: "whoami", runsImmediately: false))
        try store.save(keep)
        try store.save(drop)

        try store.remove(id: drop.id)

        #expect(try store.all() == [keep])
    }

    /// A command with an embedded line break is refused. Without this,
    /// "insert" would be a lie: every line but the last would run the
    /// moment it was inserted, with nobody pressing Return.
    @Test func aCommandWithALineBreakIsRefused() {
        #expect(Snippet(name: "Two", command: "echo a\necho b", runsImmediately: false) == nil)
        #expect(Snippet(name: "CR", command: "echo a\recho b", runsImmediately: false) == nil)
    }

    /// The rule is the MODEL's, not the form's: a hand-edited store file
    /// must not smuggle a multi-line command past it either.
    @Test func aHandEditedMultiLineCommandDoesNotDecode() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID().uuidString)","name":"x","command":"a\nb","runsImmediately":false}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("snippets.json"))

        #expect(throws: (any Error).self) { try store.all() }
    }
}
