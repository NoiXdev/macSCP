import Foundation
@testable import macSCPCore

/// Test double: secrets held in memory, thread-safe via NSLock.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }

    /// Reads the slot WITHOUT going through the failable API — how a test
    /// checks what actually happened to a secret in a store whose own read
    /// path is rigged to fail.
    func peek(_ sessionID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    /// Every id this store currently holds a secret for. The real
    /// `SecretStore` protocol has no enumeration (`SecretStore.swift`) — a
    /// deliberate Keychain limit, not an oversight — so this exists only on
    /// the test double, for the one thing a lookup by id cannot prove: that
    /// NO secret was left behind anywhere, not just under the one id a test
    /// thought to check.
    var storedIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.keys)
    }
}

/// Test double for a Keychain that is THERE but not answering — a locked
/// keychain, a denied prompt, a transient `errSecInteractionNotAllowed`.
/// Each path can fail independently, because the failures mean different
/// things: a failing READ must never be mistaken for "there is no secret"
/// (M19 finding 4), while a failing DELETE is the one case where a stale
/// credential really can survive a replace and the user has to be told.
final class UnreliableSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    let failsReads: Bool
    let failsDeletes: Bool

    init(failsReads: Bool = false, failsDeletes: Bool = false) {
        self.failsReads = failsReads
        self.failsDeletes = failsDeletes
    }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        if failsReads { throw KeychainError(status: -25308) }
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        if failsDeletes { throw KeychainError(status: -25308) }
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }

    /// See `InMemorySecretStore.peek`.
    func peek(_ sessionID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }
}
