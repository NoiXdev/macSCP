import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetVariableMemoryStore")
struct SnippetVariableMemoryStoreTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a remembered value comes back")
    func rememberAndRead() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let id = UUID()
        try store.remember("kunden db", snippetID: id, name: "DB")
        #expect(store.value(snippetID: id, name: "DB") == "kunden db")
    }

    @Test("an unknown variable has no value")
    func unknownIsNil() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        #expect(store.value(snippetID: UUID(), name: "DB") == nil)
    }

    @Test("values survive a reopen")
    func survivesReopen() throws {
        let directory = try makeDirectory()
        let id = UUID()
        try SnippetVariableMemoryStore(directory: directory)
            .remember("x", snippetID: id, name: "DB")
        let reopened = try SnippetVariableMemoryStore(directory: directory)
        #expect(reopened.value(snippetID: id, name: "DB") == "x")
    }

    /// Deleting a snippet must take its remembered values with it — the same
    /// coupling deleting a session has with its keychain entry. Otherwise a
    /// value outlives the thing that explains what it was for.
    @Test("forgetting a snippet drops all its values")
    func forgetDropsEverything() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let id = UUID()
        try store.remember("a", snippetID: id, name: "ONE")
        try store.remember("b", snippetID: id, name: "TWO")
        try store.forget(snippetID: id)
        #expect(store.value(snippetID: id, name: "ONE") == nil)
        #expect(store.value(snippetID: id, name: "TWO") == nil)
    }

    @Test("forgetting one snippet leaves another alone")
    func forgetIsScoped() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let kept = UUID()
        let dropped = UUID()
        try store.remember("keep", snippetID: kept, name: "DB")
        try store.remember("drop", snippetID: dropped, name: "DB")
        try store.forget(snippetID: dropped)
        #expect(store.value(snippetID: kept, name: "DB") == "keep")
    }
}
