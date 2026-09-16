import Foundation
import Testing
@testable import macSCPCore

/// `SessionListViewModel.resolvedJumpEndpoint(for:)` — the jump resolution
/// the connection form's session-mode summary row reads on every render
/// (fix round 1 of the technical backlog's Task 5).
///
/// The row shows host, port, user and auth kind and never a secret, so its
/// resolution must read no Keychain item at all: neither the slot the hop is
/// bound to nor, through the managed-key fallback the connect path uses, the
/// key's own slot. What it shows and which refusals it raises must be exactly
/// `resolvedJump(for:)`'s.
@Suite("Jump endpoint resolution")
@MainActor
struct JumpEndpointResolutionTests {
    private static let managedPassphrase = "managed-slot-value"
    private static let bastionPassphrase = "bastion-slot-value"

    /// Counts every read, forwarding to an in-memory store.
    private final class ReadCountingSecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private let inner = InMemorySecretStore()
        private var reads = 0
        var readCount: Int {
            lock.lock(); defer { lock.unlock() }
            return reads
        }
        func resetReads() {
            lock.lock(); defer { lock.unlock() }
            reads = 0
        }
        func savePassword(_ password: String, for sessionID: UUID) throws {
            try inner.savePassword(password, for: sessionID)
        }
        func password(for sessionID: UUID) throws -> String? {
            lock.lock(); reads += 1; lock.unlock()
            return try inner.password(for: sessionID)
        }
        func deletePassword(for sessionID: UUID) throws {
            try inner.deletePassword(for: sessionID)
        }
    }

    private func makeVM() throws -> (SessionListViewModel, ReadCountingSecretStore, URL, String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jumpendpoint-\(UUID().uuidString)")
        let secrets = ReadCountingSecretStore()
        let keys = ManagedKeyStore(directory: dir)
        let key = ManagedKey(
            name: "hop-key", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "hopkey")
        try keys.add(key)
        try secrets.savePassword(Self.managedPassphrase, for: key.id)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)
        return (vm, secrets, dir, keys.keyDirectory.appendingPathComponent("hopkey").path)
    }

    private func referencing(_ sessionID: UUID) -> StoredSession {
        StoredSession(
            name: "", kind: .ssh,
            ssh: StoredSSHConfig(
                host: "", username: "", jump: .init(host: "", username: "", sessionID: sessionID)))
    }

    /// Both slot shapes: a bastion whose own slot is empty (the connect path
    /// would read it, then the managed key's), and one whose slot holds a
    /// passphrase (the connect path reads it).
    @Test(arguments: [false, true])
    func theEndpointShowsWhatTheJumpResolvesToAndReadsNoSecret(bastionHasASlot: Bool) throws {
        let (vm, secrets, dir, keyPath) = try makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = try #require(vm.save(
            name: "bastion",
            values: sshValues(
                host: "bastion.invalid", port: 2200, username: "hop-user",
                authKind: .privateKey, keyPath: keyPath),
            password: bastionHasASlot ? Self.bastionPassphrase : ""))
        if !bastionHasASlot { vm.dropSessionSecret(for: bastion.id) }
        let synthetic = referencing(bastion.id)

        secrets.resetReads()
        let endpoint = try #require(try vm.resolvedJumpEndpoint(for: synthetic))
        #expect(secrets.readCount == 0, "the summary's resolution read the Keychain")
        let carriesNoSecret = endpoint.login.secret == nil
        #expect(carriesNoSecret)

        let full = try #require(try vm.resolvedJump(for: synthetic))
        #expect(endpoint.host == full.host)
        #expect(endpoint.port == full.port)
        #expect(endpoint.login.username == full.login.username)
        #expect(endpoint.login.authKind == full.login.authKind)
        #expect(endpoint.login.keyPath == full.login.keyPath)
        // The positive beside the zero: the connect path's resolution does
        // read, so a counter that never counts is not what made it zero.
        #expect(secrets.readCount > 0, "the read counter counted nothing on the connect path")
    }

    @Test func theEndpointRaisesTheConnectPathsRefusals() throws {
        let (vm, _, dir, _) = try makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = referencing(UUID())
        #expect(throws: LoginResolveError.missingJumpSession) { try vm.resolvedJumpEndpoint(for: missing) }

        let bucket = try #require(vm.save(
            name: "bucket", values: BackendDescriptor.descriptor(for: .s3).defaultValues,
            password: "", kind: .s3))
        #expect(throws: LoginResolveError.jumpSessionNotSSH) {
            try vm.resolvedJumpEndpoint(for: referencing(bucket.id))
        }

        let noJump = StoredSession(name: "plain", kind: .ssh, ssh: StoredSSHConfig(host: "h", username: "u"))
        #expect(try vm.resolvedJumpEndpoint(for: noJump) == nil)
    }
}
