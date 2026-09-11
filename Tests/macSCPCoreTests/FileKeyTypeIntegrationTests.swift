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

    // MARK: - The cells: 5 types × 2, 3 PEM containers × 2, 6 producer cells — 22

    /// One `ssh-keygen` shape. `bits` is `nil` where the type has only one
    /// size (ed25519) and the curve size otherwise. `format` is appended to
    /// the `ssh-keygen` argument list verbatim — empty for the container
    /// ssh-keygen writes by default, `["-m", "PEM"]` / `["-m", "PKCS8"]` for
    /// the PEM shapes below.
    struct KeyShape: Sendable, CustomStringConvertible {
        let type: String
        let bits: Int?
        let format: [String]

        init(type: String, bits: Int?, format: [String] = []) {
            self.type = type
            self.bits = bits
            self.format = format
        }

        var description: String {
            let size = bits.map { "\(type)-\($0)" } ?? type
            return format.isEmpty ? size : "\(size) \(format.joined(separator: " "))"
        }

        /// The five private key types `SSHPrivateKeyLoader` claims to load —
        /// one per `SSHKeyType` case, which is what makes five the right
        /// number for THIS list and not a round one. It counts `all` alone;
        /// `pem` below is a second list with its own reason, and neither the
        /// five nor the types they name change when it grows.
        static let all: [KeyShape] = [
            KeyShape(type: "ed25519", bits: nil),
            KeyShape(type: "rsa", bits: 2048),
            KeyShape(type: "ecdsa", bits: 256),
            KeyShape(type: "ecdsa", bits: 384),
            KeyShape(type: "ecdsa", bits: 521),
        ]

        /// The PEM shapes (PEM private keys plan, Task 3). Not one per key
        /// type: what varies here is the CONTAINER, and the three that exist
        /// on this machine are legacy PKCS#1 (`-m PEM` on RSA), legacy SEC1
        /// with explicit curve parameters (`-m PEM` on ECDSA) and PKCS#8
        /// (`-m PKCS8`) — ssh-keygen 10.3 refuses `-m PEM` for ed25519
        /// entirely (design table, 2026-09-10).
        static let pem: [KeyShape] = [
            KeyShape(type: "rsa", bits: 2048, format: ["-m", "PEM"]),
            KeyShape(type: "ecdsa", bits: 256, format: ["-m", "PEM"]),
            KeyShape(type: "rsa", bits: 2048, format: ["-m", "PKCS8"]),
        ]
    }

    /// Five key types × {unencrypted, passphrase-protected} — the shapes of
    /// `KeyShape.all`, each one a real key file generated for this run and
    /// authorized on the rig. What it does with them is
    /// `authenticateAndList` below.
    @Test("every private key type authenticates, with and without a passphrase",
          arguments: KeyShape.all, [false, true])
    func fileKeyAuthenticatesThroughMacSCP(shape: KeyShape, encrypted: Bool) async throws {
        try await authenticateAndList(shape: shape, encrypted: encrypted)
    }

    /// The same measurement over the PEM containers (PEM private keys plan,
    /// Task 3). Before this task every cell here failed in the loader — the
    /// boundary check refused the file unread and nothing dialled at all
    /// (measured 2026-09-10: six red cells). It is the same rig, the same
    /// `CitadelFileSystem.connect`, the same listing; only the container the
    /// key sits in differs, which is exactly what the task changed.
    @Test("PEM file keys authenticate through macSCP",
          arguments: KeyShape.pem, [false, true])
    func pemFileKeyAuthenticatesThroughMacSCP(shape: KeyShape, encrypted: Bool) async throws {
        try await authenticateAndList(shape: shape, encrypted: encrypted)
    }

    // MARK: - The producer cells: files no `ssh-keygen -t` run writes

    /// An Ed25519 key in a PKCS#8 container, plain and PBES2-encrypted.
    ///
    /// Neither producer on this machine writes this file: ssh-keygen 10.3
    /// refuses `-m PKCS8` for ed25519 and LibreSSL 3.3.6 writes no encrypted
    /// Ed25519 PKCS#8 at all (design table, 2026-09-10), so both halves are
    /// built here — the plain one by `PEMFixtures.ed25519PKCS8PEM`, the
    /// encrypted one by wrapping that file's DER with `PEMFixtures.pbes2PEM`.
    /// Until this cell the shape was measured only against the decoder; what
    /// it adds is the rest of the path — loader, Citadel, the rig's sshd.
    ///
    /// The public key line is COMPUTED from the seed rather than derived by
    /// `ssh-keygen -y`, which answers "invalid format" for an Ed25519 PKCS#8
    /// file (measured 2026-09-11, OpenSSH 10.3p1).
    ///
    /// Nothing in this cell proves the encrypted half's file is actually
    /// encrypted — it authenticates either way if `PEMFixtures.pbes2PEM`
    /// silently wrote a plain container. That layout is pinned instead by
    /// `refusesAnAbsurdIterationCount` in `PEMPrivateKeyDecoderTests`, which
    /// reads the same builder's output back and asserts its PBES2 shape.
    @Test("an Ed25519 PKCS#8 key authenticates", arguments: [false, true])
    func ed25519PKCS8FileAuthenticates(encrypted: Bool) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let plain = PEMFixtures.ed25519PKCS8PEM(seed: seed)
        let passphrase = encrypted ? "itest-\(UUID().uuidString)" : nil

        let text: String
        if let passphrase {
            let plainDER = try #require(PEMFixtures.der(ofPEM: plain))
            text = try PEMFixtures.pbes2PEM(pkcs8DER: plainDER, passphrase: passphrase)
        } else {
            text = plain
        }
        let keyPath = dir.appendingPathComponent("id_ed25519_pkcs8")
            .path(percentEncoded: false)
        try text.write(toFile: keyPath, atomically: true, encoding: .utf8)
        try PEMFixtures.restrict(keyPath)

        try await installAuthorizedKey(
            publicKeyLine: PEMFixtures.ed25519PublicKeyLine(seed: seed, comment: "macscp-itest"))
        try await expectLogin(keyPath: keyPath, passphrase: passphrase)
    }

    /// A legacy PKCS#1 file encrypted the way `openssl rsa` encrypts it —
    /// `Proc-Type: 4,ENCRYPTED` with `DEK-Info: AES-256-CBC` — rather than
    /// the way ssh-keygen does. `KeyShape.pem` covers ssh-keygen's own
    /// `-m PEM` output; this covers openssl's, which is the file people
    /// actually have on disk from an `openssl rsa` run.
    ///
    /// The key material is the same in both files, so the plain key's `.pub`
    /// is what the rig must authorize.
    @Test("openssl's encrypted legacy RSA file authenticates")
    func opensslEncryptedLegacyRSAFileAuthenticates() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let passphrase = "itest-\(UUID().uuidString)"
        let plainPath = try await PEMFixtures.sshKeygen(
            type: "rsa", bits: 2048, format: .pem, passphrase: nil, in: dir)
        let keyPath = dir.appendingPathComponent("id_rsa_aes256").path(percentEncoded: false)
        try await PEMFixtures.openssl([
            "rsa", "-in", plainPath, "-aes256", "-passout", "pass:\(passphrase)", "-out", keyPath,
        ])
        try PEMFixtures.restrict(keyPath)

        try await installAuthorizedKey(publicKeyLine: try publicKeyLine(besideKeyAt: plainPath))
        try await expectLogin(keyPath: keyPath, passphrase: passphrase)
    }

    /// A SEC1 file whose curve is a NAMED one — `openssl ecparam -genkey`
    /// writes the curve as an OID in the key's own `parameters [0]` field,
    /// where ssh-keygen's `-m PEM` ECDSA output carries an explicit-parameter
    /// block instead. Same container, different way of saying which curve,
    /// and only the second was measured before this cell.
    ///
    /// `ssh-keygen -y` DOES read this file (measured 2026-09-11), so the
    /// public key line comes from the external oracle rather than from a
    /// second computation here.
    @Test("openssl's named-curve SEC1 key authenticates")
    func opensslNamedCurveSEC1KeyAuthenticates() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id_ecdsa_sec1").path(percentEncoded: false)
        try await PEMFixtures.openssl([
            "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyPath,
        ])
        try PEMFixtures.restrict(keyPath)

        let derived = try await PEMFixtures.publicKeyLine(ofKeyAt: keyPath, passphrase: nil)
        try await installAuthorizedKey(publicKeyLine: derived + " macscp-itest")
        try await expectLogin(keyPath: keyPath, passphrase: nil)
    }

    /// The one variant the reader REFUSES, in both containers openssl can put
    /// it in: `openssl rsa -des3` writes `DEK-Info: DES-EDE3-CBC` into a
    /// legacy PKCS#1 file, `openssl pkcs8 -topk8 -v2 des3` writes the
    /// `des-ede3-cbc` OID into a PBES2 scheme. The decoder names both the
    /// same way — `.cipher("DES-EDE3-CBC")` — and this cell measures that the
    /// refusal survives all the way out of `CitadelFileSystem.connect`
    /// unwrapped, which is what lets the app offer the Convert remedy.
    ///
    /// No `connectWithRetry` around the refusing dial: the retry exists to
    /// cushion the rig's reconnect throttling for connects that are SUPPOSED
    /// to succeed, and this one throws in the key loader before anything
    /// reaches the wire.
    ///
    /// Then the remedy itself, end to end: `SSHKeyConverter.copyAsOpenSSH`
    /// rewrites a COPY, and the copy logs in against the same
    /// `authorized_keys` line — which is the proof that the conversion kept
    /// the key rather than merely producing a well-formed file.
    enum DESContainer: CaseIterable, CustomStringConvertible {
        case legacy, pbes2

        var description: String {
            switch self {
            case .legacy: return "legacy"
            case .pbes2: return "pbes2"
            }
        }
    }

    @Test("a DES-EDE3 key is refused by the dial and logs in once converted",
          arguments: DESContainer.allCases)
    func desEDE3KeyIsRefusedThenConverted(container: DESContainer) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let passphrase = "itest-\(UUID().uuidString)"
        let plainPath = try await PEMFixtures.sshKeygen(
            type: "rsa", bits: 2048, format: .pem, passphrase: nil, in: dir)
        let keyPath = dir.appendingPathComponent("id_rsa_des3").path(percentEncoded: false)
        let arguments: [String]
        switch container {
        case .legacy:
            arguments = ["rsa", "-in", plainPath, "-des3", "-passout", "pass:\(passphrase)", "-out", keyPath]
        case .pbes2:
            arguments = ["pkcs8", "-topk8", "-in", plainPath, "-v2", "des3",
                         "-passout", "pass:\(passphrase)", "-out", keyPath]
        }
        try await PEMFixtures.openssl(arguments)
        try PEMFixtures.restrict(keyPath)

        try await installAuthorizedKey(publicKeyLine: try publicKeyLine(besideKeyAt: plainPath))

        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-des3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .privateKey(keyPath: keyPath, passphrase: passphrase))
        // Caught into a local rather than `#expect(throws:)`, so a red here
        // prints both sides (the idiom `PEMPrivateKeyDecoderTests.swift:326`
        // uses for the same decoder-level refusal) instead of only "an error
        // was expected but none was thrown".
        var caught: SSHKeyError?
        do {
            let fs = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30),
                knownHosts: KnownHostsStore(directory: khDir),
                onUnknownHostKey: .asking { _ in true })
            // No leaked connection on the branch that should not exist: a
            // regression that lets the dial through must not also leave a
            // live SSH session parked past this test.
            await fs.disconnect()
        } catch let error as SSHKeyError {
            caught = error
        }
        #expect(caught == .pemNotReadable(.cipher("DES-EDE3-CBC")))

        let converted = dir.appendingPathComponent("converted")
        let didConvert = try await SSHKeyConverter.copyAsOpenSSH(
            from: URL(fileURLWithPath: keyPath), to: converted, passphrase: passphrase)
        #expect(didConvert)
        try await expectLogin(keyPath: converted.path(percentEncoded: false),
                              passphrase: passphrase)
    }

    // MARK: - The body every cell above shares

    /// The generate-install-login body of the two `KeyShape` cell tests,
    /// extracted rather than copied: the two differ only in the shape list
    /// they walk, and a second copy of the connect would be a second thing to
    /// keep true. The producer cells above build their own files, so they
    /// call `expectLogin` directly.
    ///
    /// The passphrase is generated per cell and never written down: it is not
    /// a test argument (argument values are printed in test names and failure
    /// output), not an expectation's source text, and not a log line. It
    /// reaches exactly two places — `ssh-keygen -N`, the documented
    /// exception, and the `SSHConnectionConfig` the connect consumes.
    private func authenticateAndList(shape: KeyShape, encrypted: Bool) async throws {
        let passphrase = encrypted ? "itest-\(UUID().uuidString)" : nil
        let (dir, keyPath) = try await makeInstalledKey(
            type: shape.type, bits: shape.bits, passphrase: passphrase,
            extraKeygenArguments: shape.format)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await expectLogin(keyPath: keyPath, passphrase: passphrase)
    }

    /// Logs in with the key file at `keyPath` and lists the rig's seed
    /// directory. Every cell in this file ends here.
    ///
    /// The key is used through macSCP's OWN connect path —
    /// `CitadelFileSystem.connect` with
    /// `SSHConnectionConfig.AuthMethod.privateKey`, which is the same code
    /// the app runs. Nothing here reaches into Citadel directly; that is
    /// Step 0's job.
    ///
    /// The listing at the end is what makes a green cell mean authentication:
    /// a connect that returned without a usable session would fail here
    /// rather than pass quietly.
    private func expectLogin(keyPath: String, passphrase: String?) async throws {
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

    /// The `<key>.pub` line `ssh-keygen` wrote beside a key it generated.
    /// Used where the file under measurement is a re-encryption of that key
    /// and therefore carries the same public half.
    private func publicKeyLine(besideKeyAt path: String) throws -> String {
        try String(contentsOfFile: path + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
