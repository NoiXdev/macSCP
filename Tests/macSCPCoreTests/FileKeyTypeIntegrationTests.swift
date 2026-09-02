import Citadel
import Crypto
import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d).
///
/// The rig's `sshd` keeps OpenSSH's default `PubkeyAcceptedAlgorithms`, so
/// `ssh-rsa` (SHA-1) is refused and `rsa-sha2-256`/`-512` accepted. That is
/// what makes it the right server for these tests: an RSA key that
/// authenticates here authenticated with a SHA-2 signature, because the
/// SHA-1 one would have been rejected.
///
/// A suite-level `.enabled(if:)` trait disables every contained test
/// regardless of that test's own traits (see the note above
/// `JumpFromSavedSessionChainGuardTests` in
/// `CitadelFileSystemIntegrationTests.swift`), so this is its own top-level
/// gated suite.
@Suite(
    "Private key FILES of every type, against the rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct FileKeyTypeIntegrationTests {
    // MARK: - Rig helpers

    /// A known-hosts store that already holds the rig's host key, so a
    /// connect made through raw Citadel can use macSCP's own
    /// `TOFUHostKeyValidator` and take its `.accept` branch. Seeding happens
    /// through macSCP's ordinary password connect — there is no
    /// accept-anything validator anywhere in this suite.
    private func knownHostsSeededForRig(
        directory: URL, port: Int = 2222
    ) async throws -> KnownHostsStore {
        let store = KnownHostsStore(directory: directory)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: port, username: "testuser",
            auth: .password("testpass"))
        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
        await fs.disconnect()
        return store
    }

    /// The rig's `sshd` log, tail-end, for the report. Read AFTER the
    /// connect under measurement, and filtered to the lines that name the
    /// public-key exchange.
    private func sshdAuthLogTail(lines: Int = 30) async -> String {
        let result = try? await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            arguments: [
                "exec", "macscp-test-sshd", "sh", "-c",
                "tail -n \(lines) /config/logs/openssh/current",
            ])
        return result?.stdoutText ?? ""
    }

    // MARK: - Step 0: does the server accept the blob type this fork writes?

    /// The one measurement the whole task depends on, made through raw
    /// Citadel so that no macSCP code sits between the key file and the
    /// wire.
    ///
    /// RFC 8332 §3 keeps a public-key blob typed `ssh-rsa` while only the
    /// userauth algorithm-name field becomes `rsa-sha2-512`. Until
    /// swift-nio-ssh 0.3.10 NIOSSH wrote both from one `publicKeyPrefix`, so
    /// the fork's `rsaSHA2` offer put `rsa-sha2-512` in BOTH places (fork
    /// review I-1) — and this test measured that OpenSSH accepts that too,
    /// which is why an RSA key file was usable at all. 0.3.10 added the
    /// userauth algorithm name beside the blob prefix (the mirror of the
    /// `hostKeyAlgorithmNames` split 0.3.9 added for host keys) and Citadel
    /// `0.12.1-noix.3` took it up, so the offer this test now makes is the
    /// RFC's: `pkalg = rsa-sha2-512` around an `ssh-rsa` blob.
    ///
    /// A green run here is therefore evidence about the SERVER, not about
    /// macSCP — and it is the row that would go red if only the blob type had
    /// been changed, since OpenSSH's `sshkey_check_sigtype` requires the
    /// signature's algorithm name to equal `pkalg`.
    @Test("Step 0: OpenSSH accepts the RFC 8332 public key offer")
    func rigAcceptsTheForksRSASHA2Offer() async throws {
        let (dir, keyPath) = try await makeInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-step0-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = try await knownHostsSeededForRig(directory: khDir)

        let contents = try String(contentsOfFile: keyPath, encoding: .utf8)
        let key = try Insecure.RSA.PrivateKey(sshRsa: contents)

        let validator = TOFUHostKeyValidator(
            host: "127.0.0.1", port: 2222, knownHosts: store,
            box: TOFUHostKeyValidator.Box())
        do {
            let client = try await SSHClient.connect(
                host: "127.0.0.1", port: 2222,
                authenticationMethod: .rsaSHA2(username: "testuser", privateKey: key),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(30))
            try await client.close()
        } catch {
            Issue.record("""
                Step 0 FAILED — the rig refused the fork's rsa-sha2 offer.
                error: \(String(reflecting: error))
                sshd log tail:
                \(await sshdAuthLogTail())
                """)
            throw error
        }
    }

    // MARK: - The ten cells

    /// One `ssh-keygen` shape. `bits` is `nil` where the type has only one
    /// size (ed25519) and the curve size otherwise.
    struct KeyShape: Sendable, CustomStringConvertible {
        let type: String
        let bits: Int?

        var description: String { bits.map { "\(type)-\($0)" } ?? type }

        /// The five private key types `SSHPrivateKeyLoader` claims to load —
        /// one per `SSHKeyType` case, which is what makes five the right
        /// number here and not a round one.
        static let all: [KeyShape] = [
            KeyShape(type: "ed25519", bits: nil),
            KeyShape(type: "rsa", bits: 2048),
            KeyShape(type: "ecdsa", bits: 256),
            KeyShape(type: "ecdsa", bits: 384),
            KeyShape(type: "ecdsa", bits: 521),
        ]
    }

    /// Five key types × {unencrypted, passphrase-protected}, each one a real
    /// key file generated for this run, authorized on the rig, and used
    /// through macSCP's OWN connect path — `CitadelFileSystem.connect` with
    /// `SSHConnectionConfig.AuthMethod.privateKey`, which is the same code
    /// the app runs. Nothing here reaches into Citadel directly; that is
    /// Step 0's job.
    ///
    /// The passphrase is generated per cell and never written down: it is not
    /// a test argument (argument values are printed in test names and failure
    /// output), not an expectation's source text, and not a log line. It
    /// reaches exactly two places — `ssh-keygen -N`, the documented
    /// exception, and the `SSHConnectionConfig` the connect consumes.
    ///
    /// The listing at the end is what makes a green cell mean authentication:
    /// a connect that returned without a usable session would fail here
    /// rather than pass quietly.
    @Test("every private key type authenticates, with and without a passphrase",
          arguments: KeyShape.all, [false, true])
    func fileKeyAuthenticatesThroughMacSCP(shape: KeyShape, encrypted: Bool) async throws {
        let passphrase = encrypted ? "itest-\(UUID().uuidString)" : nil
        let (dir, keyPath) = try await makeInstalledKey(
            type: shape.type, bits: shape.bits, passphrase: passphrase)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .privateKey(keyPath: keyPath, passphrase: passphrase))
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-filekey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)

        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }
}
