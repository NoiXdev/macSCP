import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d).
///
/// Each of the five `sshd-hostkey-*` rig services restricts
/// `HostKeyAlgorithms` to exactly one type (docker/test-server/README.md's
/// "SSH host-key-types rig" table), so a successful connect to a given port
/// pins the client to having actually negotiated that algorithm — not merely
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
    /// The rig's RSA service (port 2235) is deliberately NOT a row here, and
    /// the reason changed when `RSASHA2HostKey` arrived: it now connects, but
    /// it is the one service whose negotiated algorithm name and recorded key
    /// type are DIFFERENT strings, so the sentence above would be false for
    /// it. It has its own test below.
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

    /// Port 2235 restricts `HostKeyAlgorithms` to `rsa-sha2-512,rsa-sha2-256`,
    /// so reaching a host key at all means the client offered an RSA name —
    /// which it does only because `HostKeyAlgorithms.registerOnce()` put
    /// `RSASHA2HostKey` into NIOSSH's registry before the dial.
    ///
    /// What a completed connect proves, beyond negotiation:
    ///
    ///  - the key blob parsed (`RSASHA2HostKey.read(from:)`),
    ///  - the re-serialization matched byte for byte — the exchange hash
    ///    covers the server's own encoding of `K_S`, and NIOSSH recomputes
    ///    that from `write(to:)`, so a single differing byte fails the
    ///    handshake, and
    ///  - the server's `rsa-sha2-512` signature over that hash verified.
    ///
    /// This test therefore cannot pass while any of those three is wrong,
    /// which is why there is nothing here that inspects them separately;
    /// `RSASHA2HostKeyTests` takes each apart on its own, without Docker.
    ///
    /// The recorded key type is the BLOB prefix, not the negotiated name:
    /// RFC 8332 types every RSA key blob `ssh-rsa` whatever digest was
    /// negotiated, and `known_hosts` records what OpenSSH would record.
    ///
    /// (This test used to assert the opposite — that key exchange failed for
    /// want of a negotiable algorithm. Its own note said it would turn red
    /// the day the fork could do RSA, and on 2026-09-02 it did.)
    @Test func rsaHostKeyNegotiatesUnderTheSHA2NameAndIsRecordedUnderItsBlobPrefix() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-hostkeytype-rsa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)

        let fs = try await connect(port: 2235, knownHosts: store)
        await fs.disconnect()

        let recorded = try store.find(host: "127.0.0.1", port: 2235)
        // Read off the type as well as spelled out: the derived form ties the
        // record to the type that produced it, the literal pins what actually
        // goes into `known_hosts` even if that type were renamed.
        #expect(recorded?.keyType == RSASHA2HostKey.publicKeyPrefix)
        #expect(recorded?.keyType == "ssh-rsa")
        #expect(recorded?.publicKeyBase64.isEmpty == false)
    }

    /// The hard stop on the RSA path, mirroring
    /// `tamperedEcdsa256KeyFailsHardWithMismatch` below: a wrong `ssh-rsa`
    /// key is seeded for port 2235, so the handshake presents a real RSA key
    /// against a stored fingerprint that can never match it. A custom
    /// host-key algorithm is a new way INTO `TOFUHostKeyValidator`, and this
    /// checks it lands on the same stop as every bundled type — the connect
    /// fails with `.mismatch`, and the decider is never consulted.
    @Test func tamperedRsaKeyFailsHardWithMismatch() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-hostkeytype-rsa-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2235,
            keyType: RSASHA2HostKey.publicKeyPrefix,
            publicKeyBase64: "QUJDREVG"))   // deliberately wrong
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2235, username: "testuser",
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
