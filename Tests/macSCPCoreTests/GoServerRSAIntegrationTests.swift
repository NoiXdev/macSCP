import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d).
///
/// Every other SSH service in the rig is OpenSSH. This suite talks to the ONE
/// Go-based server there — SFTPGo on 2240, whose server side is
/// `golang.org/x/crypto/ssh` — because that library parses a user-auth
/// public-key blob's leading string as a KEY FORMAT and does not recognize
/// `rsa-sha2-512` there, where RFC 8332 §3 keeps the blob typed `ssh-rsa` and
/// puts the algorithm name only in `pkalg` and the signature.
///
/// macSCP writes `rsa-sha2-512` in all three places today (see
/// `docs/superpowers/specs/2026-09-01-backlog-rsa-agent-go-servers.md`). Until
/// 2026-09-02 that was measured against the library directly, never against a
/// server. These tests are that measurement.
///
/// A suite-level `.enabled(if:)` trait disables every contained test
/// regardless of that test's own traits (see the note above
/// `JumpFromSavedSessionChainGuardTests` in
/// `CitadelFileSystemIntegrationTests.swift`), so this is its own top-level
/// gated suite.
@Suite(
    "RSA against a Go-based SSH server (SFTPGo)",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct GoServerRSAIntegrationTests {
    // MARK: - Rig helpers

    private func config(auth: SSHConnectionConfig.AuthMethod) throws -> SSHConnectionConfig {
        try SSHConnectionConfig(
            host: "127.0.0.1", port: SFTPGoRig.sftpPort, username: SFTPGoRig.username,
            auth: auth)
    }

    private func freshKnownHosts(_ label: String) -> (store: KnownHostsStore, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(label)-\(UUID().uuidString)")
        return (KnownHostsStore(directory: dir), dir)
    }

    /// SFTPGo's own log, tail-end. The service runs at `SFTPGO_LOG_LEVEL=debug`
    /// so the refused offer is named, not merely counted.
    private func sftpGoLogTail(lines: Int = 20) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["logs", SFTPGoRig.containerName, "--tail", String(lines)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - The rig itself

    @Test("an ed25519 file key logs in to SFTPGo and lists the home directory")
    func ed25519FileKeyConnects() async throws {
        let (dir, keyPath) = try await makeSFTPGoInstalledKey(type: "ed25519")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, khDir) = freshKnownHosts("sftpgo-ed25519")
        defer { try? FileManager.default.removeItem(at: khDir) }

        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: try config(auth: .privateKey(keyPath: keyPath, passphrase: nil)),
                connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    // MARK: - The measurement, pinned

    /// What macSCP's connect throws today when SFTPGo refuses the offered RSA
    /// blob, copied verbatim from the run of 2026-09-02.
    ///
    /// It is `connectionFailed`, NOT `authenticationFailed` — worth reading
    /// twice, because the refusal is not "this key is not authorized". Go's
    /// `x/crypto/ssh` cannot PARSE the blob at all, so it aborts the whole
    /// connection rather than answering the userauth request with a failure;
    /// SFTPGo's own log calls the login type `no_auth_tried`. A user sees a
    /// dropped connection, not a rejected key.
    static let measuredRSAFailure =
        #"macSCPCore.RemoteFSError.connectionFailed(reason: "Disconnected()")"#

    /// The line SFTPGo writes for it, at `SFTPGO_LOG_LEVEL=debug`, quoted from
    /// the same run. The full record sits in
    /// `.superpowers/sdd/2026-09-02-rsa-blob-typing-rfc8332/task-1-report.md`;
    /// this is the substring the assertions below anchor on.
    static let measuredSFTPGoRefusal = "ssh: unknown key algorithm: rsa-sha2-512"

    /// The shared body of both measurements: run `connect`, and hold BOTH the
    /// error macSCP surfaces and the line SFTPGo logs against what 2026-09-02
    /// measured.
    ///
    /// A connect that SUCCEEDS is the interesting future: it means the blob is
    /// no longer typed `rsa-sha2-512`, so the refusal this pins is gone and the
    /// assertions below have to be rewritten into their positive form.
    private func expectTodaysRefusal(
        connecting connect: () async throws -> CitadelFileSystem
    ) async {
        do {
            let fs = try await connect()
            let items = try? await fs.list(path: "/")
            await fs.disconnect()
            // Expected once the key blob is typed ssh-rsa (RFC 8332): this test
            // turns red then, and the assertion flips.
            Issue.record("""
                SFTPGo ACCEPTED the RSA login (listing: \(items?.map(\.name) ?? [])).
                The refusal measured on 2026-09-02 is gone — flip this test to
                assert the successful listing instead.
                """)
        } catch {
            // Expected once the key blob is typed ssh-rsa (RFC 8332): this test
            // turns red then, and the assertion flips.
            #expect(String(reflecting: error) == Self.measuredRSAFailure)
            // A POSITIVE check, deliberately: it fails loudly the moment
            // SFTPGo stops writing this line, rather than going quiet.
            #expect(sftpGoLogTail().contains(Self.measuredSFTPGoRefusal))
        }
    }

    /// An RSA key FILE, through macSCP's own connect path. The same key type
    /// authenticates against the rig's OpenSSH `sshd` on 2222 — that is the ten
    /// -cell matrix in `FileKeyTypeIntegrationTests`, green since 2026-09-02.
    /// The only difference here is the server.
    @Test("an RSA file key is refused by SFTPGo, blob typing and all")
    func rsaFileKeyIsRefused() async throws {
        let (dir, keyPath) = try await makeSFTPGoInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, khDir) = freshKnownHosts("sftpgo-rsa-file")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let config = try config(auth: .privateKey(keyPath: keyPath, passphrase: nil))

        await expectTodaysRefusal {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
    }

    /// The same RSA key offered through a test-owned ssh-agent instead of from
    /// a file — macSCP's `AgentBackedPrivateKey` path, whose own RSA public key
    /// type spells the same prefix. `agentAuthConnectsRSA` proves this route
    /// green against OpenSSH; this is the Go-server half of the same fact.
    @Test("an RSA agent identity is refused by SFTPGo, blob typing and all")
    func rsaAgentIdentityIsRefused() async throws {
        let (dir, keyPath) = try await makeSFTPGoInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)
        let (store, khDir) = freshKnownHosts("sftpgo-rsa-agent")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let config = try config(auth: .agent)

        await withAgentEnv(agent) {
            await expectTodaysRefusal {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store,
                    onUnknownHostKey: .asking { _ in true })
            }
        }
    }
}
