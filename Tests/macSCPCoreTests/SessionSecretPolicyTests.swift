import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionSecretPolicy")
struct SessionSecretPolicyTests {
    private func emptyStores() throws -> (ManagedKeyStore, InMemorySecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ManagedKeyStore(directory: dir), InMemorySecretStore())
    }

    /// A password login has no managed key involved at all, so its own
    /// secret is what gets persisted.
    @Test func aPasswordLoginPersistsItsOwnSecret() throws {
        let (keys, secrets) = try emptyStores()

        let value = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "s3cret", kind: .ssh, authChoice: .password,
            keyPath: "", keys: keys, secrets: secrets)

        let matches = value == "s3cret"
        #expect(matches)
    }

    /// An agent login holds no secret at all; nothing is written.
    @Test func anAgentLoginPersistsNothing() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "", kind: .ssh, authChoice: .agent,
            keyPath: "", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty)
    }

    /// A private-key login whose key is NOT managed here still persists its
    /// own passphrase — the exemption is only for keys whose passphrase this
    /// app already keeps under the key's own identifier.
    @Test func anUnmanagedKeyPersistsItsOwnPassphrase() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "passphrase", kind: .ssh, authChoice: .privateKey,
            keyPath: "/nowhere/id_ed25519", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty == false)
    }

    /// The whitespace around a pasted path must not decide the answer — a
    /// trailing space would otherwise make a managed key look unmanaged and
    /// duplicate its passphrase into a second keychain slot.
    @Test func aPaddedKeyPathAnswersLikeItsTrimmedForm() throws {
        let (keys, secrets) = try emptyStores()

        let padded = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "  /nowhere/id_ed25519  ",
            keys: keys, secrets: secrets)
        let trimmed = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "/nowhere/id_ed25519",
            keys: keys, secrets: secrets)

        #expect(padded == trimmed)
    }
}
