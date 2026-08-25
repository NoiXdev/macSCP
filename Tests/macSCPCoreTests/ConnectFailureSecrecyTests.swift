import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// The failed-connect surface gains a details dialog showing the FULL
/// technical message — the first surface in the product to render a raw
/// error text rather than a fixed catalog key. This suite pins what that
/// text may contain: whatever the user typed or stored (host, port, user
/// name) and never a secret, not even inside an embedded library error.
///
/// Everything here works on errors the product actually throws. A
/// hand-built `RemoteFSError.connectionFailed(reason: "...")` would prove
/// nothing about the strings the dial path really produces — the risk lives
/// exactly in the parts nobody writes by hand: `String(describing:)` over a
/// foreign type, and an `NSError`'s `userInfo` dump.
///
/// The assertion target is `ConnectionViewModel.failedState`, which is the
/// whole of the mapping from a thrown error to the published
/// `.failed(message:field:)` — `connect()`'s `catch` reaches it through
/// `jumpAwareFailedState` and adds nothing to the text. Driving `connect()`
/// itself would additionally require a resolved form, and resolving a form
/// means a secret store; these tests deliberately touch none.
@Suite("Connect failure secrecy")
struct ConnectFailureSecrecyTests {
    /// Values that must never appear in a failure text. Each one is handed
    /// to the code that throws, in the field that really carries it.
    private enum Secret {
        static let password = "sentinel-target-password-4f1a"
        static let jumpPassword = "sentinel-jump-password-9c3e"
        static let passphrase = "sentinel-key-passphrase-7b2d"
        static let wrongPassphrase = "sentinel-wrong-passphrase-1e8f"
        static let webdavPassword = "sentinel-webdav-password-6a4c"
        static let urlPassword = "sentinel-url-password-2d9b"
        static let s3SecretAccessKey = "sentinel-s3-secret-key-5e7a"
        static let s3SessionToken = "sentinel-s3-session-token-8f2c"
        static let keyMaterial = "sentinel-key-material-3c6e"

        static let all: [String] = [
            password, jumpPassword, passphrase, wrongPassphrase, webdavPassword,
            urlPassword, s3SecretAccessKey, s3SessionToken, keyMaterial,
        ]
    }

    /// A dead loopback port: nothing listens on port 1, so every backend's
    /// dial fails immediately with a real transport error and no test needs
    /// a server, a network, or a gate.
    private static let deadPort = 1

    /// Checks both halves of the claim, because only one of them is about
    /// the display: the error's OWN textual form (what a log, a `print`, or
    /// the CLI's stderr fallback would render) and the message the connect
    /// form publishes from it.
    @MainActor
    private func expectNoSecret(
        in error: Error, jumpEnabled: Bool = false,
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let raw = String(describing: error)
        guard case .failed(let message, _) = ConnectionViewModel.failedState(
            for: error, jumpEnabled: jumpEnabled)
        else {
            Issue.record("\(what): failedState did not publish a failure", sourceLocation: sourceLocation)
            return
        }
        for secret in Secret.all {
            #expect(!raw.contains(secret),
                    "\(what): the error itself carries \(secret)", sourceLocation: sourceLocation)
            #expect(!message.contains(secret),
                    "\(what): the published message carries \(secret)", sourceLocation: sourceLocation)
        }
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-secrecy-\(UUID().uuidString)")
    }

    /// An ed25519 key generated at runtime — never checked in, same as
    /// `SSHPrivateKeyLoaderTests`.
    private func makeEncryptedKey(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appendingPathComponent("id_ed25519")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
            "-N", Secret.passphrase, "-q", "-C", "macscp-secrecy-test",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return keyURL.path(percentEncoded: false)
    }

    // MARK: - SSH

    @Test("a refused SSH dial reports the transport, not the password")
    func sshDialFailureCarriesNoSecret() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: Self.deadPort, username: "tester",
            auth: .password(Secret.password))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(5),
                knownHosts: KnownHostsStore(directory: directory),
                onUnknownHostKey: { _ in false })
            Issue.record("expected the SSH dial to fail")
        } catch {
            // Positive half: the dial really failed on the transport, which
            // is the arm that stringifies a foreign NIO error.
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure, got \(error)")
                return
            }
            await expectNoSecret(in: error, "refused SSH dial")
        }
    }

    /// Both hops carry their own, DIFFERENT password, so a text that echoed
    /// either one fails — the jump hop's error takes a separate mapping
    /// path (`mapStageAware`) from the target's.
    @Test("a refused jump-hop dial reports the transport, not either password")
    func sshJumpDialFailureCarriesNoSecret() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: Self.deadPort, username: "tester",
            auth: .password(Secret.password),
            jump: .init(host: "127.0.0.1", port: Self.deadPort, username: "jumper",
                        auth: .password(Secret.jumpPassword)))
        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(5),
                knownHosts: KnownHostsStore(directory: directory),
                onUnknownHostKey: { _ in false })
            Issue.record("expected the jump-hop dial to fail")
        } catch {
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure, got \(error)")
                return
            }
            await expectNoSecret(in: error, jumpEnabled: true, "refused jump dial")
        }
    }

    /// The passphrase is CORRECT here, so the key is decrypted and held in
    /// memory by the time the transport fails — the arrangement where a
    /// stringified error would have the material to leak.
    @Test("a refused private-key dial reports the transport, not the passphrase")
    func sshPrivateKeyDialFailureCarriesNoSecret() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = try makeEncryptedKey(in: directory)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: Self.deadPort, username: "tester",
            auth: .privateKey(keyPath: keyPath, passphrase: Secret.passphrase))
        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(5),
                knownHosts: KnownHostsStore(directory: directory),
                onUnknownHostKey: { _ in false })
            Issue.record("expected the private-key dial to fail")
        } catch {
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure, got \(error)")
                return
            }
            await expectNoSecret(in: error, "refused private-key dial")
        }
    }

    /// The three key-load refusals, each produced by the real loader
    /// against a real ssh-keygen key or a real file. The last one matters
    /// most: `unsupportedFormat(reason:)` is the one macSCP error whose
    /// payload is a stringified THIRD-PARTY error, produced while the
    /// parser has the file's bytes and the passphrase in hand.
    @Test("every private-key load refusal reports the condition, not the material")
    func privateKeyLoadFailuresCarryNoSecret() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = try makeEncryptedKey(in: directory)

        func loadExpectingFailure(_ path: String, passphrase: String?, _ what: String) async {
            do {
                _ = try SSHPrivateKeyLoader.authentication(
                    username: "tester", keyPath: path, passphrase: passphrase)
                Issue.record("\(what): expected the load to fail")
            } catch {
                guard error is SSHKeyError else {
                    Issue.record("\(what): expected an SSHKeyError, got \(error)")
                    return
                }
                await expectNoSecret(in: error, what)
            }
        }

        await loadExpectingFailure(keyPath, passphrase: Secret.wrongPassphrase, "wrong passphrase")
        await loadExpectingFailure(keyPath, passphrase: nil, "missing passphrase")

        // A file shaped like an OpenSSH key whose body is the sentinel: the
        // parser fails deep inside Citadel with the material in scope.
        let unparsable = directory.appendingPathComponent("unparsable")
        try Data("""
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(Secret.keyMaterial)
            -----END OPENSSH PRIVATE KEY-----

            """.utf8).write(to: unparsable)
        await loadExpectingFailure(
            unparsable.path(percentEncoded: false), passphrase: Secret.passphrase,
            "unparsable key")
    }

    // MARK: - WebDAV

    /// The regression this suite was written for. `URLSession` reports a
    /// failed request as an `NSError` whose `description` dumps its whole
    /// `userInfo`, and Foundation puts the failing URL there verbatim —
    /// userinfo component included. A base URL of the form
    /// `https://user:password@host/dav` is ordinary user input, nothing in
    /// the WebDAV schema strips it, and while `WebDAVFileSystem.connect`
    /// rethrew that `NSError` unchanged the password went straight into the
    /// published message. The fix wraps at the throw site, so neither the
    /// error nor the message can carry it.
    @Test("a refused WebDAV dial reports the transport, not the URL's credentials")
    func webdavDialFailureCarriesNoSecret() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = WebDAVConnectionConfig(
            baseURL: "http://inurl:\(Secret.urlPassword)@127.0.0.1:\(Self.deadPort)/dav",
            username: "tester", useNextcloudPath: false,
            password: Secret.webdavPassword)
        do {
            _ = try await WebDAVFileSystem.connect(
                config, trustStore: TrustedCertificateStore(directory: directory),
                decider: { _ in false })
            Issue.record("expected the WebDAV dial to fail")
        } catch {
            // Positive half, and the shape half in one: a foreign `NSError`
            // no longer escapes, so this is a typed connection failure and
            // not the catch-all "unexpected error" arm.
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure, got \(error)")
                return
            }
            await expectNoSecret(in: error, "refused WebDAV dial")
        }
    }

    // MARK: - S3

    @Test("a refused S3 dial reports the transport, not the secret key")
    func s3DialFailureCarriesNoSecret() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "AKIASENTINEL", secretAccessKey: Secret.s3SecretAccessKey,
            region: "us-east-1", endpoint: "http://127.0.0.1:\(Self.deadPort)",
            bucket: "bucket", usePathStyle: true, sessionToken: Secret.s3SessionToken)
        do {
            _ = try await S3FileSystem.connect(config)
            Issue.record("expected the S3 dial to fail")
        } catch {
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure, got \(error)")
                return
            }
            await expectNoSecret(in: error, "refused S3 dial")
        }
    }

    // MARK: - Pre-dial refusal

    /// `failedState` also maps the refusals raised BEFORE anything is
    /// dialled, and it is the same function, so a config rejection is
    /// checked here too even though the details surface is reserved for
    /// post-dial failures. The config being rejected holds a real password.
    @Test("a rejected configuration reports the field, not the password")
    func configRejectionCarriesNoSecret() async {
        do {
            _ = try SSHConnectionConfig(
                host: "127.0.0.1", port: 70000, username: "tester",
                auth: .password(Secret.password))
            Issue.record("expected the configuration to be rejected")
        } catch {
            guard case SSHConnectionConfig.ConfigError.invalidPort = error else {
                Issue.record("expected invalidPort, got \(error)")
                return
            }
            await expectNoSecret(in: error, "rejected configuration")
        }
    }
}
