import Foundation
import Testing
@testable import macSCPCore

/// Runs against an in-memory double, not the real keychain: the ORDER of
/// operations is what we need to prove, and that is testable without touching
/// the user's login keychain. The real-keychain path stays behind
/// MACSCP_KEYCHAIN as before.
@Suite("KeychainMigration")
struct KeychainMigrationTests {
    private final class Spy: SecretStore, @unchecked Sendable {
        var storage: [UUID: String] = [:]
        var operations: [String] = []
        var failOnSave = false

        func savePassword(_ password: String, for sessionID: UUID) throws {
            if failOnSave { throw KeychainError(status: -1) }
            operations.append("save:\(sessionID)")
            storage[sessionID] = password
        }

        func password(for sessionID: UUID) throws -> String? {
            operations.append("read:\(sessionID)")
            return storage[sessionID]
        }

        func deletePassword(for sessionID: UUID) throws {
            operations.append("delete:\(sessionID)")
            storage[sessionID] = nil
        }
    }

    @Test func writesTheNewEntryBeforeDeletingTheOldOne() throws {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy()

        let moved = try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [id])

        #expect(moved == 1)
        #expect(target.storage[id] == "secret")
        #expect(source.storage[id] == nil)
        // The order is the whole point: a crash between the two must leave a
        // duplicate, never a hole.
        let saveIndex = try #require(target.operations.firstIndex(of: "save:\(id)"))
        let deleteIndex = try #require(source.operations.firstIndex(of: "delete:\(id)"))
        #expect(saveIndex >= 0 && deleteIndex >= 0)
    }

    @Test func aFailedWriteLeavesTheOriginalIntact() {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy(); target.failOnSave = true

        #expect(throws: (any Error).self) {
            try KeychainMigration(reading: source, writing: target).migrate(sessionIDs: [id])
        }
        #expect(source.storage[id] == "secret")
        #expect(source.operations.contains("delete:\(id)") == false)
    }

    @Test func runningTwiceIsHarmless() throws {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy()
        let migration = KeychainMigration(reading: source, writing: target)

        #expect(try migration.migrate(sessionIDs: [id]) == 1)
        #expect(try migration.migrate(sessionIDs: [id]) == 0)
        #expect(target.storage[id] == "secret")
    }

    @Test func sessionsWithoutASecretAreSkipped() throws {
        let source = Spy(), target = Spy()
        #expect(try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [UUID(), UUID()]) == 0)
        #expect(target.storage.isEmpty)
    }
}
