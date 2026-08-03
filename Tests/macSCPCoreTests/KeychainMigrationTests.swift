import Foundation
import Testing
@testable import macSCPCore

/// Runs against an in-memory double, not the real keychain: the ORDER of
/// operations is what we need to prove, and that is testable without touching
/// the user's login keychain. The real-keychain path stays behind
/// MACSCP_KEYCHAIN as before.
@Suite("KeychainMigration")
struct KeychainMigrationTests {
    /// A single ordered log shared by BOTH doubles in a test, so that a
    /// save recorded by one store and a delete recorded by the other land
    /// in one sequence. Two separate per-store logs cannot express relative
    /// ordering at all — this is what makes the ordering assertion real.
    private final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var entries: [String] = []

        func record(_ entry: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }
    }

    private final class Spy: SecretStore, @unchecked Sendable {
        private let label: String
        private let timeline: Timeline?
        var storage: [UUID: String] = [:]
        var operations: [String] = []
        var failOnSave = false

        init(label: String, timeline: Timeline? = nil) {
            self.label = label
            self.timeline = timeline
        }

        func savePassword(_ password: String, for sessionID: UUID) throws {
            if failOnSave { throw KeychainError(status: -1) }
            operations.append("save:\(sessionID)")
            timeline?.record("\(label) save:\(sessionID)")
            storage[sessionID] = password
        }

        func password(for sessionID: UUID) throws -> String? {
            operations.append("read:\(sessionID)")
            timeline?.record("\(label) read:\(sessionID)")
            return storage[sessionID]
        }

        func deletePassword(for sessionID: UUID) throws {
            operations.append("delete:\(sessionID)")
            timeline?.record("\(label) delete:\(sessionID)")
            storage[sessionID] = nil
        }
    }

    /// A target whose write always "succeeds" but whose read-back disagrees
    /// with what was just stored — the shape of a keychain that reports
    /// success yet lies about the value (e.g. a sync race). This is the
    /// only way to reach `migrate`'s verification-mismatch branch, since a
    /// well-behaved double always returns what it stored.
    private final class MismatchingReadBackSpy: SecretStore, @unchecked Sendable {
        private(set) var wroteValue: String?
        private(set) var deleteWasCalled = false

        func savePassword(_ password: String, for sessionID: UUID) throws {
            wroteValue = password
        }

        func password(for sessionID: UUID) throws -> String? {
            "a-value-that-was-never-written"
        }

        func deletePassword(for sessionID: UUID) throws {
            deleteWasCalled = true
        }
    }

    @Test func writesTheNewEntryBeforeDeletingTheOldOne() throws {
        let id = UUID()
        let timeline = Timeline()
        let source = Spy(label: "source", timeline: timeline); source.storage[id] = "secret"
        let target = Spy(label: "target", timeline: timeline)

        let moved = try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [id])

        #expect(moved == 1)
        #expect(target.storage[id] == "secret")
        #expect(source.storage[id] == nil)
        // The order is the whole point: a crash between the two must leave a
        // duplicate, never a hole. Both stores record into ONE shared
        // timeline, so these indices are directly comparable — unlike two
        // separate per-store logs, which cannot express relative order.
        let saveIndex = try #require(timeline.entries.firstIndex(of: "target save:\(id)"))
        let deleteIndex = try #require(timeline.entries.firstIndex(of: "source delete:\(id)"))
        #expect(saveIndex < deleteIndex)
    }

    @Test func aFailedWriteLeavesTheOriginalIntact() {
        let id = UUID()
        let source = Spy(label: "source"); source.storage[id] = "secret"
        let target = Spy(label: "target"); target.failOnSave = true

        #expect(throws: (any Error).self) {
            try KeychainMigration(reading: source, writing: target).migrate(sessionIDs: [id])
        }
        #expect(source.storage[id] == "secret")
        #expect(source.operations.contains("delete:\(id)") == false)
    }

    @Test func aVerificationMismatchThrowsAndLeavesTheSourceIntact() throws {
        let id = UUID()
        let source = Spy(label: "source"); source.storage[id] = "secret"
        let target = MismatchingReadBackSpy()

        #expect(throws: KeychainVerificationMismatch.self) {
            try KeychainMigration(reading: source, writing: target).migrate(sessionIDs: [id])
        }
        // The point: a failed verification must never cost the credential.
        #expect(source.storage[id] == "secret")
        #expect(source.operations.contains("delete:\(id)") == false)
        #expect(target.deleteWasCalled == false)
    }

    @Test func runningTwiceIsHarmless() throws {
        let id = UUID()
        let source = Spy(label: "source"); source.storage[id] = "secret"
        let target = Spy(label: "target")
        let migration = KeychainMigration(reading: source, writing: target)

        #expect(try migration.migrate(sessionIDs: [id]) == 1)
        #expect(try migration.migrate(sessionIDs: [id]) == 0)
        #expect(target.storage[id] == "secret")
    }

    @Test func sessionsWithoutASecretAreSkipped() throws {
        let source = Spy(label: "source"), target = Spy(label: "target")
        #expect(try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [UUID(), UUID()]) == 0)
        #expect(target.storage.isEmpty)
    }
}
