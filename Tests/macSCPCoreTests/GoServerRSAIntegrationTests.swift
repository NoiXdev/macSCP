import Crypto
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
/// macSCP wrote `rsa-sha2-512` in all three places until this commit, and
/// SFTPGo refused both RSA rows below for it — measured at `513e34e`, the
/// refusal being `ssh: unknown key algorithm: rsa-sha2-512` with the
/// connection dropped before any authentication was attempted. They are
/// accepted since: swift-nio-ssh `0.3.10` separated the algorithm name from
/// the blob type on the user-auth path, Citadel `0.12.1-noix.3` typed its RSA
/// key blobs `ssh-rsa` again, and `AgentAlgorithm.RSASha512` does the same
/// for the agent path.
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

    /// SFTPGo's own log, from `moment` onwards. The service runs at
    /// `SFTPGO_LOG_LEVEL=debug`, so a refused offer is named there and not
    /// merely counted.
    ///
    /// Scoped by time rather than by a line count, because the container's log
    /// is its whole life: a `--tail 200` reaches back into earlier runs, and a
    /// check for the ABSENCE of a refusal read that way is a check on the
    /// rig's history instead of on this connect. `--since` takes unix seconds,
    /// which sidesteps the container clock being UTC while the host is not.
    private func sftpGoLog(since moment: Date) async -> String {
        let result = try? await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            arguments: [
                "logs", SFTPGoRig.containerName,
                "--since", String(Int(moment.timeIntervalSince1970)),
            ])
        // `docker logs` interleaves stdout and stderr; the runner keeps them
        // apart, so both are stitched back together the way the single pipe
        // used to deliver them.
        guard let result else { return "" }
        return result.stdoutText + result.stderrText
    }

    // MARK: - The rig itself

    @Test("an ed25519 file key logs in to SFTPGo and lists the home directory")
    func ed25519FileKeyConnects() async throws {
        let (dir, keyPath, _) = try await makeSFTPGoInstalledKey(type: "ed25519")
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

    // MARK: - The measurement

    /// The refusal these two tests pinned until this commit, kept as the
    /// history the assertions below replaced.
    ///
    /// At `513e34e`, with the key blob typed `rsa-sha2-512`, both rows failed
    /// with `RemoteFSError.connectionFailed(reason: "Disconnected()")` —
    /// `connectionFailed`, NOT `authenticationFailed`, because Go's
    /// `x/crypto/ssh` could not PARSE the blob and aborted the connection
    /// instead of answering the userauth request; SFTPGo logged
    /// `ssh: unknown key algorithm: rsa-sha2-512` with `login_type:
    /// no_auth_tried`. The full record is
    /// `.superpowers/sdd/2026-09-02-rsa-blob-typing-rfc8332/task-1-report.md`.
    ///
    /// What the fix has to keep true is that this string is ABSENT from the
    /// log of a run — a negative check, so it never stands alone: the
    /// fingerprint check beside it is the positive, SFTPGo's own log naming
    /// THIS key as logged in, which no refusal can satisfy.
    static let refusalBeforeTheFix = "ssh: unknown key algorithm: rsa-sha2-512"

    /// The shared body of both measurements: connect, list, and hold the
    /// listing AND SFTPGo's own account of the login against the key that was
    /// installed.
    ///
    /// The fingerprint is computed from the generated public key rather than
    /// spelled, so the check names the key under test and not merely "some
    /// login happened": a run in which a different identity authenticated
    /// fails it.
    private func expectAcceptedLogin(
        forPublicKey publicKey: String,
        connecting connect: () async throws -> CitadelFileSystem
    ) async throws {
        let fingerprint = try Self.sha256Fingerprint(ofPublicKeyLine: publicKey)
        // One second of slack: `docker logs --since` is second-granular, so a
        // line written in the same second as this timestamp would otherwise be
        // outside the window.
        let start = Date().addingTimeInterval(-1)
        let fs: CitadelFileSystem
        do {
            fs = try await connect()
        } catch {
            Issue.record("""
                SFTPGo refused the RSA login.
                error: \(String(reflecting: error))
                SFTPGo log since the connect:
                \(await sftpGoLog(since: start))
                """)
            throw error
        }
        // The rig suites' shape: a `list` that throws must not leave the
        // connection and its event-loop group alive for the rest of the
        // process.
        defer { Task { await fs.disconnect() } }
        let items = try await fs.list(path: "/")

        #expect(items.contains { $0.name == "hello.txt" })
        let log = await sftpGoLog(since: start)
        #expect(log.contains(fingerprint))
        #expect(log.contains(Self.refusalBeforeTheFix) == false)
    }

    /// OpenSSH's `SHA256:` fingerprint of a public key line: the base64 blob's
    /// SHA-256, base64-encoded without padding. It is what SFTPGo writes into
    /// its `logged in with "publickey: SHA256:…"` line.
    private static func sha256Fingerprint(ofPublicKeyLine line: String) throws -> String {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw FingerprintError.notAPublicKeyLine(line)
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    private enum FingerprintError: Error {
        case notAPublicKeyLine(String)
    }

    /// An RSA key FILE, through macSCP's own connect path. The same key type
    /// authenticates against the rig's OpenSSH `sshd` on 2222 — that is the ten
    /// -cell matrix in `FileKeyTypeIntegrationTests`. The only difference here
    /// is the server, and until this commit that difference decided the
    /// outcome: refused at `513e34e`, accepted since.
    @Test("an RSA file key logs in to SFTPGo")
    func rsaFileKeyConnects() async throws {
        let (dir, keyPath, publicKey) = try await makeSFTPGoInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, khDir) = freshKnownHosts("sftpgo-rsa-file")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let config = try config(auth: .privateKey(keyPath: keyPath, passphrase: nil))

        try await expectAcceptedLogin(forPublicKey: publicKey) {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
    }

    /// The same RSA key offered through a test-owned ssh-agent instead of from
    /// a file — macSCP's `AgentBackedPrivateKey` path, which types its blob in
    /// its own code rather than in Citadel's. `agentAuthConnectsRSA` proves
    /// this route green against OpenSSH; this is the Go-server half of the
    /// same fact, refused at `513e34e` and accepted since.
    @Test("an RSA agent identity logs in to SFTPGo")
    func rsaAgentIdentityConnects() async throws {
        let (dir, keyPath, publicKey) = try await makeSFTPGoInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try await spawnAgent()
        defer { killAgent(agent) }
        try await addKey(atPath: keyPath, to: agent)
        let (store, khDir) = freshKnownHosts("sftpgo-rsa-agent")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let config = try config(auth: .agent)

        try await withAgentEnv(agent) {
            try await expectAcceptedLogin(forPublicKey: publicKey) {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store,
                    onUnknownHostKey: .asking { _ in true })
            }
        }
    }
}
