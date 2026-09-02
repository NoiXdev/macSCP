import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d).
///
/// Each of the five `sshd-hostkey-*` rig services restricts
/// `HostKeyAlgorithms` to exactly one type (docker/test-server/README.md's
/// "SSH host-key-types rig" table), so a successful connect to a given port
/// pins the client to having actually negotiated that type — not merely
/// accepted whatever ed25519 key the multi-type `sshd`/`sshd2` services
/// would have offered instead.
///
/// A suite-level `.enabled(if:)` trait disables every contained test
/// regardless of that test's own traits (see the note above
/// `JumpFromSavedSessionChainGuardTests` in
/// `CitadelFileSystemIntegrationTests.swift`), so this lives as its own
/// top-level gated suite rather than nested inside another one.
@Suite(
    "Host-key type negotiation against the rig's per-type services",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct HostKeyTypeIntegrationTests {
    private func connect(port: Int, knownHosts: KnownHostsStore) async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: port, username: "testuser",
            auth: .password("testpass"))
        return try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: knownHosts,
                onUnknownHostKey: .asking { _ in true })
        }
    }

    /// The four types the client's host-key algorithm list
    /// (NIOSSH's `bundledServerHostKeyAlgorithms`) can negotiate — ed25519
    /// and the three NIST curves. Each row connects fresh (a new
    /// `KnownHostsStore` in its own temp dir), disconnects, and checks the
    /// key type TOFU actually recorded matches the rig service's own
    /// restricted `HostKeyAlgorithms`.
    ///
    /// `ssh-rsa` is deliberately NOT a row here: the client has no
    /// registered RSA host-key algorithm to offer (see
    /// `rsaHostKeyIsRejectedForWantOfANegotiableAlgorithm` below), so a
    /// connect to port 2235 cannot reach the point of recording anything.
    @Test(arguments: [
        (port: 2231, expectedKeyType: "ssh-ed25519"),
        (port: 2232, expectedKeyType: "ecdsa-sha2-nistp256"),
        (port: 2233, expectedKeyType: "ecdsa-sha2-nistp384"),
        (port: 2234, expectedKeyType: "ecdsa-sha2-nistp521"),
    ])
    func connectingPinsTheNegotiatedKeyType(port: Int, expectedKeyType: String) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-hostkeytype-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)

        let fs = try await connect(port: port, knownHosts: store)
        await fs.disconnect()

        #expect(try store.find(host: "127.0.0.1", port: port)?.keyType == expectedKeyType)
    }

    /// Measured 2026-09-02 against `sshd-hostkey-rsa` (port 2235, which
    /// restricts `HostKeyAlgorithms` to `rsa-sha2-512,rsa-sha2-256`): the
    /// client offers no RSA host-key algorithm during key exchange at all
    /// (NIOSSH's `bundledServerHostKeyAlgorithms` is ed25519 + the three
    /// NIST curves; Citadel registers only what a caller passes in
    /// `SSHAlgorithms.publicKeyAlgorihtms` — through
    /// `NIOSSHAlgorithms.register(publicKey:signature:)`, Client.swift — and
    /// macSCP passes no `SSHAlgorithms` at all, so nothing is registered; and
    /// Citadel's only RSA type is `ssh-rsa` over SHA-1), so key exchange itself fails
    /// before any host key is ever presented to `TOFUHostKeyValidator` —
    /// the connect throws `RemoteFSError.connectionFailed(reason:
    /// "NIOSSHError.keyExchangeNegotiationFailure")` (captured verbatim via
    /// `String(describing:)`/`String(reflecting:)` against the live rig;
    /// `reflecting` additionally carries the `macSCPCore.` module prefix),
    /// and `store.find` afterwards finds nothing because nothing was ever
    /// recorded.
    ///
    /// Expected once the fork can negotiate rsa-sha2-256/512: this test
    /// turns red then, and the assertion flips.
    @Test func rsaHostKeyIsRejectedForWantOfANegotiableAlgorithm() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-hostkeytype-rsa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)

        // Matched on macSCP's own case plus the NIOSSH reason as a substring,
        // not on the exact string: a fork bump that merely renames the NIOSSH
        // case must fail this test for THAT reason (the `contains` line), not
        // look like RSA had started to negotiate. A connect that succeeds is
        // the flip this test waits for, and lands in the `Issue.record`.
        do {
            _ = try await connect(port: 2235, knownHosts: store)
            Issue.record("an RSA-only host key negotiated — the fork can do RSA now; flip this test")
        } catch RemoteFSError.connectionFailed(let reason) {
            let isKeyExchangeFailure = reason.contains("keyExchangeNegotiationFailure")
            #expect(isKeyExchangeFailure, "unexpected connect failure reason: \(reason)")
        }
        #expect(try store.find(host: "127.0.0.1", port: 2235) == nil)
    }

    /// Mismatch on a non-ed25519 type that DID pass above
    /// (ecdsa-sha2-nistp256, port 2232): mirrors
    /// `tamperedKnownKeyFailsHardWithMismatch` in
    /// `CitadelFileSystemIntegrationTests` — a tampered key of that same
    /// type is seeded, so the handshake presents a real
    /// `ecdsa-sha2-nistp256` key against a stored fingerprint that can
    /// never match it. Both halves of the hard stop are checked here, as
    /// in the mirrored test: the connect fails with `.mismatch`, and the
    /// `asking` closure records an `Issue` if it is ever invoked — proving
    /// the decider is never consulted. Proves the hard-stop mismatch path
    /// isn't an ed25519-only code path.
    @Test func tamperedEcdsa256KeyFailsHardWithMismatch() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-hostkeytype-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2232,
            keyType: "ecdsa-sha2-nistp256", publicKeyBase64: "QUJDREVG"))   // deliberately wrong
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2232, username: "testuser",
            auth: .password("testpass"))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in
                    Issue.record("mismatch must NEVER ask the decider")
                    return true
                })
            Issue.record("expected mismatch")
        } catch let error as HostKeyError {
            guard case .mismatch = error else {
                Issue.record("expected mismatch, was: \(error)")
                return
            }
        }
    }
}
