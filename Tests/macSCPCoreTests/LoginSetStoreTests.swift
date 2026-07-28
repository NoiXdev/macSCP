import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginSetStore")
struct LoginSetStoreTests {
    private func makeStore() -> (LoginSetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-loginsets-\(UUID().uuidString)")
        return (LoginSetStore(directory: dir), dir)
    }

    @Test func upsertAndAllRoundtrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let web = LoginSet(name: "Web", username: "deploy", authKind: .password, keyPath: nil)
        let admin = LoginSet(name: "Admin", username: "root", authKind: .privateKey, keyPath: "/k")
        try store.upsert(web)
        try store.upsert(admin)

        let all = try store.all()
        #expect(all.map(\.name) == ["Admin", "Web"])
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        #expect(byName["Web"]?.username == "deploy")
        #expect(byName["Web"]?.authKind == .password)
        #expect(byName["Web"]?.keyPath == nil)
        #expect(byName["Admin"]?.username == "root")
        #expect(byName["Admin"]?.authKind == .privateKey)
        #expect(byName["Admin"]?.keyPath == "/k")
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var set = LoginSet(name: "Web", username: "deploy")
        try store.upsert(set)
        set.name = "Web (renamed)"
        try store.upsert(set)

        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Web (renamed)")
    }

    @Test func deleteRemovesOnlyMatch() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = LoginSet(name: "Web", username: "deploy")
        let second = LoginSet(name: "Admin", username: "root")
        try store.upsert(first)
        try store.upsert(second)

        try store.delete(id: first.id)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.id == second.id)

        // Deleting an unknown id must not throw.
        try store.delete(id: UUID())
    }

    @Test func emptyDirectoryReadsEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.all() == [])
    }

    /// M10d guard: `.agent` became a KNOWN authKind (raw "agent") in this
    /// milestone, so this forward-compat fixture must exercise a DIFFERENT,
    /// still-unknown raw value ("future-x", a placeholder for whatever the
    /// NEXT auth kind ends up being called) — otherwise this test would
    /// silently stop testing forward compatibility and instead just re-test
    /// `.agent`'s own (now normal) round trip.
    @Test func unknownAuthKindIsHiddenButPreserved() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let futureID = UUID()
        let keepID = UUID()
        let deleteMeID = UUID()
        let fileURL = dir.appendingPathComponent("logins.json")
        try Data("""
        {
          "sets": [
            {"id": "\(futureID.uuidString)", "name": "Future Set", "username": "a", "authKind": "future-x"},
            {"id": "\(keepID.uuidString)", "name": "Keep", "username": "keep", "authKind": "password"},
            {"id": "\(deleteMeID.uuidString)", "name": "DeleteMe", "username": "gone", "authKind": "password"}
          ],
          "ignoredMergeGroups": []
        }
        """.utf8).write(to: fileURL)

        // The unknown-authKind record must never surface via all().
        let visible = try store.all()
        #expect(visible.map(\.name).sorted() == ["DeleteMe", "Keep"])

        // Upsert a new set and delete one of the known ones...
        try store.upsert(LoginSet(name: "NewOne", username: "n"))
        try store.delete(id: deleteMeID)

        // ...the "future-x" record must still be present in the raw file.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(raw.contains("future-x"))
        let stillVisible = try store.all()
        #expect(stillVisible.map(\.name).sorted() == ["Keep", "NewOne"])
    }

    @Test func ignoredMergeGroupsRoundtrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.ignoredMergeGroups() == [])

        let a = UUID()
        let b = UUID()
        try store.addIgnoredMergeGroup([a, b])
        #expect(try store.ignoredMergeGroups() == [Set([a, b])])

        let c = UUID()
        let d = UUID()
        try store.addIgnoredMergeGroup([c, d])
        let groups = try store.ignoredMergeGroups()
        #expect(groups.count == 2)
        #expect(groups.contains(Set([a, b])))
        #expect(groups.contains(Set([c, d])))
    }
}
