import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionStore")
struct FileActionStoreTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-actions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anAbsentFileReadsAsNoActions() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try FileActionStore(directory: dir).all().isEmpty)
    }

    @Test func savedActionsSurviveAReload() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let action = FileAction(name: "Count", command: "wc -l {{PATH}}")
        try store.save(action)
        #expect(try FileActionStore(directory: dir).all() == [action])
    }

    /// Replacing in place, not removing and appending: the menu lists
    /// actions in this order, so an edit must not move one to the end.
    @Test func savingAnEditedActionKeepsItsPlaceInTheList() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let first = FileAction(name: "A", command: "wc -l {{PATH}}")
        let second = FileAction(name: "B", command: "ls {{PATH}}")
        try store.save(first)
        try store.save(second)
        var edited = first
        edited.name = "A edited"
        try store.save(edited)
        #expect(try store.all().map(\.name) == ["A edited", "B"])
    }

    @Test func removingAnActionLeavesTheOthers() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let first = FileAction(name: "A", command: "wc -l {{PATH}}")
        let second = FileAction(name: "B", command: "ls {{PATH}}")
        try store.save(first)
        try store.save(second)
        try store.remove(id: first.id)
        #expect(try store.all().map(\.name) == ["B"])
    }

    /// Its own file, so a snippet store can never be read as actions. The
    /// positive beside that: the actions file IS the one that appeared.
    @Test func theStoreWritesItsOwnFileAndNotTheSnippetsOne() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileActionStore(directory: dir).save(FileAction(name: "A", command: "ls {{PATH}}"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(names.contains("file-actions.json"))
        #expect(names.contains("snippets.json") == false)
    }
}
