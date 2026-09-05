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
@Suite("Connect failure secrecy", .timeLimit(.minutes(1)))
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
        static let agentKeyMaterial = "sentinel-agent-key-material-0b5d"

        /// The agent hands key material over as bytes, and anything that
        /// rendered it would most likely base64 it on the way — so the
        /// encoded form is a sentinel of its own, not a variant of the
        /// plain one.
        ///
        /// THREE of them, and that is the whole point. Base64 encodes
        /// three bytes at a time, so what `base64(buffer)` looks like
        /// around the material depends on WHERE in that buffer the
        /// material starts: only when it starts on a three-byte boundary
        /// does its own encoding appear verbatim. A single encoded
        /// sentinel is therefore blind to two alignments out of three,
        /// and which one a fixture happens to hit is an accident of how
        /// long a type name is. That accident silenced this guard once
        /// already — measured, with a real leak left green.
        ///
        /// So the guard carries the encoding at all three alignments and
        /// no byte position can silence it again.
        /// `encodedAtEveryAlignment` says how each one is derived, and
        /// `base64SentinelsCatchEveryAlignment` proves the derivation.
        static let agentKeyMaterialBase64: [String] =
            encodedAtEveryAlignment(Data(agentKeyMaterial.utf8))

        /// The material's base64 as it appears when it begins at a byte
        /// offset congruent to 0, 1 and 2 modulo three.
        ///
        /// Each entry is built from the COMPLETE four-character groups
        /// that fall entirely inside the material at that alignment.
        /// Every such group is determined by the material's own bytes and
        /// by nothing around it, which is exactly what makes it a
        /// substring of the encoding of ANY buffer holding the material
        /// at that alignment — whatever precedes or follows it.
        static func encodedAtEveryAlignment(_ material: Data) -> [String] {
            (0..<3).compactMap { phase in
                let padded = Data(repeating: 0x5f, count: phase) + material
                    + Data(repeating: 0x5f, count: 3)
                let encoded = Array(padded.base64EncodedString())
                // First byte offset at or after `phase` that starts a group,
                // and the end of the last group lying wholly in the material.
                let firstByte = ((phase + 2) / 3) * 3
                let endByte = ((phase + material.count) / 3) * 3
                guard endByte > firstByte else { return nil }
                return String(encoded[(firstByte / 3) * 4 ..< (endByte / 3) * 4])
            }
        }

        static let all: [String] = [
            password, jumpPassword, passphrase, wrongPassphrase, webdavPassword,
            urlPassword, s3SecretAccessKey, s3SessionToken, keyMaterial,
            agentKeyMaterial,
        ] + agentKeyMaterialBase64
    }

    /// Proves the sentinel construction rather than trusting it — the
    /// guard it feeds is the one that was silently dead, and a guard whose
    /// derivation nobody checked is how that happened.
    ///
    /// Sweeps the material across every alignment inside surrounding bytes
    /// that are themselves noise, and requires one of the three encoded
    /// sentinels to appear every time. The second half is the control: the
    /// same surrounding noise WITHOUT the material must match none of
    /// them, otherwise the guard would be a smoke alarm that is always on.
    @Test("the base64 sentinels catch the material at every byte alignment")
    func base64SentinelsCatchEveryAlignment() {
        let material = Data(Secret.agentKeyMaterial.utf8)
        var generator = SystemRandomNumberGenerator()

        for offset in 0..<64 {
            let prefix = Data((0..<offset).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let suffix = Data((0..<17).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let encoded = (prefix + material + suffix).base64EncodedString()
            #expect(Secret.agentKeyMaterialBase64.contains { encoded.contains($0) },
                    "material at offset \(offset) escaped every base64 sentinel")
        }

        for length in 40..<160 {
            let noise = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let encoded = noise.base64EncodedString()
            #expect(!Secret.agentKeyMaterialBase64.contains { encoded.contains($0) },
                    "a buffer of \(length) random bytes matched a base64 sentinel")
        }
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
    private func makeEncryptedKey(in directory: URL) async throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appendingPathComponent("id_ed25519")
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: [
                "-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                "-N", Secret.passphrase, "-q", "-C", "macscp-secrecy-test",
            ])
        #expect(result.status == 0)
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
                onUnknownHostKey: .refusing)
            Issue.record("expected the SSH dial to fail")
        } catch {
            // Positive half: the dial really failed on the transport, which
            // is the arm that reduces a foreign NIO error to text
            // (`CitadelFileSystem.connectFailureText(for:)`).
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
                onUnknownHostKey: .refusing)
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
        let keyPath = try await makeEncryptedKey(in: directory)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: Self.deadPort, username: "tester",
            auth: .privateKey(keyPath: keyPath, passphrase: Secret.passphrase))
        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(5),
                knownHosts: KnownHostsStore(directory: directory),
                onUnknownHostKey: .refusing)
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
        let keyPath = try await makeEncryptedKey(in: directory)

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
                decider: .refusing)
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

    /// Every OTHER WebDAV operation, held to the same thing as the dial.
    ///
    /// Review round 1 measured the fix above sitting on `connect` alone.
    /// The credential is not in the dial, it is in the base URL, so it is
    /// in every request this backend ever makes — and `list`, `stat`,
    /// `readStream`, `delete`, `createDirectory`, `rename` and `write` all
    /// reached `URLSession` with no `catch` between them and the surface.
    /// A timeout or a dropped connection mid-session was enough; the
    /// resulting `URLError` went to the CLI's stderr, to the transfer
    /// failure text and to the browse error text, each of which
    /// stringifies.
    ///
    /// Driven against a dead loopback port through a REAL
    /// `URLSessionHTTPTransport`, for the same reason the dial test is: the
    /// risk lives in Foundation's own `userInfo` dump, and a hand-built
    /// error would prove nothing about it. Nothing listens on port 1, so
    /// every one of these fails immediately without a network, a server or
    /// a gate.
    @Test(
        "every WebDAV operation reports the transport, not the URL's credentials",
        arguments: WebDAVOperation.allCases)
    func webdavOperationFailureCarriesNoSecret(operation: WebDAVOperation) async {
        let config = WebDAVConnectionConfig(
            baseURL: "http://inurl:\(Secret.urlPassword)@127.0.0.1:\(Self.deadPort)/dav",
            username: "tester", useNextcloudPath: false,
            password: Secret.webdavPassword)
        let fs = WebDAVFileSystem(
            config: config,
            transport: URLSessionHTTPTransport(
                session: URLSession(configuration: .ephemeral)))
        do {
            try await operation.run(on: fs)
            Issue.record("expected \(operation.rawValue) to fail against a dead port")
        } catch {
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("expected a connection failure from \(operation.rawValue), got \(error)")
                return
            }
            await expectNoSecret(in: error, "WebDAV \(operation.rawValue)")
        }
    }

    /// The half of `readStream` that is not the call: a download that dies
    /// after the response headers have already arrived throws from INSIDE
    /// the body stream, long after `readStream` returned. That error
    /// reaches the same transfer-failure text as any other, so it is
    /// wrapped in the same place.
    ///
    /// The error is a real `URLError` carrying a real `userInfo`, built the
    /// way Foundation builds it — a fake transport is used only to decide
    /// WHEN it arrives, which is the one thing a dead port cannot arrange.
    @Test("a WebDAV download that dies mid-body reports the transport, not the URL")
    func webdavStreamFailureCarriesNoSecret() async {
        let failingURL = "http://inurl:\(Secret.urlPassword)@127.0.0.1:\(Self.deadPort)/dav/big.bin"
        let midStream = URLError(
            .networkConnectionLost,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: failingURL,
                NSLocalizedDescriptionKey: "The network connection was lost.",
            ])
        #expect(String(describing: midStream).contains(Secret.urlPassword), """
            the fixture no longer carries the secret it was built to carry, so this test \
            would pass against an unwrapped stream too.
            """)

        var thrown: Error?
        do {
            for try await _ in WebDAVFileSystem.surfacing(
                AsyncThrowingStream { $0.finish(throwing: midStream) })
            {
                Issue.record("the stream yielded a chunk it was never given")
            }
        } catch {
            thrown = error
        }

        let error = thrown
        guard case .some(RemoteFSError.connectionFailed) = error else {
            Issue.record("expected a connection failure from the body stream, got \(String(describing: error))")
            return
        }
        await expectNoSecret(in: error!, "WebDAV mid-body failure")
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

    // MARK: - ssh-agent

    /// `AgentError` is the one type on this path whose every value was
    /// cleared by reading rather than by measurement, and reading is what
    /// this task exists to replace. `CitadelFileSystem.AgentClientFactory`
    /// is a `@TaskLocal` seam, so each of these is a real error from the
    /// real codec — no prepared `SSH_AUTH_SOCK` agent, no rig.
    ///
    /// The two `protocolError` cases matter most: their `reason` is the
    /// only free text `AgentError` carries, and the bytes the codec chokes
    /// on ARE the sentinel, so a parser that echoed its buffer would be
    /// caught here.
    ///
    /// The identity case is the one where key material is genuinely in
    /// hand: the agent answers with a well-formed identity whose blob is
    /// the sentinel, `listIdentities` parses it, and the dial then fails on
    /// the transport with those identities live.
    ///
    /// Every case but the socket one puts the sentinel into the agent's
    /// answer, including where the codec ignores it — a shape check whose
    /// secrecy half runs over a buffer with nothing secret in it proves
    /// nothing about secrecy, and reads as though it did. The socket case
    /// says at its own site why it is the exception.
    @Test("every ssh-agent refusal reports the condition, not the key material")
    func agentFailuresCarryNoSecret() async throws {
        let material = Array(Secret.agentKeyMaterial.utf8)

        try await withTemporaryAuthSock("/tmp/macscp-secrecy-\(UUID().uuidString).sock") {
            // An agent that is reachable and holds nothing. The sentinel
            // rides along AFTER the zero count, where the codec stops
            // reading, so the case keeps its shape while still putting the
            // material in the parser's buffer.
            //
            // `.noIdentities` carries no string, so this case cannot leak
            // through its own error at all — a leak here has to change the
            // error's TYPE, which is why the sweep runs even when the
            // shape check fails. Measured that way: a codec that turns an
            // empty listing into a `protocolError` carrying the buffer is
            // caught in both halves.
            await expectAgentDialFails(
                answering: Self.agentFrame(type: 12, payload: Self.uint32BE(0) + material),
                as: { if case AgentError.noIdentities = $0 { return true }; return false },
                "empty agent")
            // SSH_AGENT_FAILURE, with a payload the type byte makes the
            // codec ignore — same arrangement, and `.refused` is likewise
            // payload-free, so the same reasoning applies.
            await expectAgentDialFails(
                answering: Self.agentFrame(type: 5, payload: material),
                as: { if case AgentError.refused = $0 { return true }; return false },
                "agent refusal")
            // A frame whose declared length lies about its body, with the
            // sentinel as that body.
            await expectAgentDialFails(
                answering: Data(Self.uint32BE(4) + [12] + material),
                as: { if case AgentError.protocolError = $0 { return true }; return false },
                "malformed agent frame")
            // A well-formed frame whose inner string overruns it.
            await expectAgentDialFails(
                answering: Self.agentFrame(
                    type: 12, payload: Self.uint32BE(1) + Self.uint32BE(9999) + material),
                as: { if case AgentError.protocolError = $0 { return true }; return false },
                "overrunning agent string")
            // A usable identity whose blob is the sentinel: the listing
            // succeeds, and the failure comes from the dead port afterwards.
            //
            // The type name is free. It decides where in the blob the
            // material lands — after two length prefixes and the name
            // itself — and that offset used to decide whether a
            // base64-encoded leak was caught at all, because a single
            // encoded sentinel only matches when the material starts on a
            // three-byte boundary. The guard now carries all three
            // alignments (`Secret.agentKeyMaterialBase64`), so the offset
            // decides nothing any more; this reads `ssh-ed25519` again
            // because that is the ordinary key type, not because 19 is a
            // useful number. Any type `AgentPrivateKeyFactory` supports
            // gives the same case.
            let blob = Self.sshString(Array("ssh-ed25519".utf8)) + Self.sshString(material)
            await expectAgentDialFails(
                answering: Self.agentFrame(
                    type: 12,
                    payload: Self.uint32BE(1) + Self.sshString(blob) + Self.sshString(Array("comment".utf8))),
                as: { if case RemoteFSError.connectionFailed = $0 { return true }; return false },
                "dial failure with agent identities held")
        }

        // No agent at all — the guard before the factory is ever consulted.
        // The one case here whose secrecy half cannot be given anything to
        // find, and it is worth naming why rather than leaving it looking
        // like an oversight: the refusal is raised before a single agent
        // byte exists, so the only string in scope is `SSH_AUTH_SOCK`
        // itself, and it has to be EMPTY for this arm to be the one taken.
        // A path carrying a sentinel would be a non-empty path, which is a
        // different case entirely. This one is a shape check and nothing
        // more.
        try await withTemporaryAuthSock("") {
            await expectAgentDialFails(
                answering: nil,
                as: { if case AgentError.socketUnavailable = $0 { return true }; return false },
                "no agent socket")
        }
    }

    // MARK: - WebDAV, credential rejected

    /// A mistyped WebDAV password used to read "Connection failed:
    /// cancelled". `WebDAVSessionDelegate` declines the repeated challenge,
    /// `URLSession` abandons the request as cancelled, and the 401 that
    /// caused it never reaches `mapStatus` — so the surface reported the
    /// symptom instead of the cause, in the sentence the details dialog
    /// will show in large type.
    ///
    /// The challenge is raised by `URLSession` itself, below the
    /// `HTTPTransport` seam the other WebDAV tests stub, so this needs
    /// something that really speaks HTTP: a loopback socket serving one
    /// canned 401, never a remote host and never the rig.
    @Test("a rejected WebDAV password says so, and says nothing else")
    func webdavRejectedPasswordIsReportedAsAuthenticationFailure() async throws {
        let stub = try LoopbackHTTPStub(response: LoopbackHTTPStub.basicAuthAlwaysRejects)
        defer { stub.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = WebDAVConnectionConfig(
            baseURL: "http://127.0.0.1:\(stub.port)/dav", username: "tester",
            useNextcloudPath: false, password: Secret.webdavPassword)
        do {
            _ = try await WebDAVFileSystem.connect(
                config, trustStore: TrustedCertificateStore(directory: directory),
                decider: .refusing)
            Issue.record("expected the rejected credential to fail the connect")
        } catch {
            guard case RemoteFSError.authenticationFailed = error else {
                Issue.record("expected authenticationFailed, got \(error)")
                return
            }
            await expectNoSecret(in: error, "rejected WebDAV password")
        }
    }

    /// The leak this suite is named for, on the one path where the secret
    /// leaves over the wire rather than in a message: `URLSession` follows
    /// redirects itself, and it raises the redirect TARGET's authentication
    /// challenge on the very same delegate. Before the origin guard, a
    /// server answering `302 Location: http://other/` had the user's WebDAV
    /// password sent to `other` — worse over plain http, where anyone on
    /// the path can inject the redirect.
    ///
    /// Two stubs, because one cannot show this: the first redirects, the
    /// second challenges, and the assertion is about what the second never
    /// saw. `sawAuthorizationHeader` is the whole test — the error shape
    /// below only pins that the refusal is reported as itself rather than
    /// as URLSession's cancellation, or as a rejected password nobody
    /// rejected.
    @Test("a redirected login challenge is refused, and the other host gets no credentials")
    func webdavRedirectedChallengeNeverReachesTheOtherHost() async throws {
        let elsewhere = try LoopbackHTTPStub(response: LoopbackHTTPStub.basicAuthAlwaysRejects)
        defer { elsewhere.stop() }
        let configured = try LoopbackHTTPStub(
            response: LoopbackHTTPStub.movedTemporarily(
                to: "http://127.0.0.1:\(elsewhere.port)/elsewhere"))
        defer { configured.stop() }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = WebDAVConnectionConfig(
            baseURL: "http://127.0.0.1:\(configured.port)/dav", username: "tester",
            useNextcloudPath: false, password: Secret.webdavPassword)
        var thrown: Error?
        do {
            _ = try await WebDAVFileSystem.connect(
                config, trustStore: TrustedCertificateStore(directory: directory),
                decider: .refusing)
        } catch {
            thrown = error
        }

        // Both stubs record on their own accept thread, after writing the
        // response, so `connect` can return before either append happens.
        // Wait for the record rather than racing it — see
        // `waitForRequests`. Without this the emptiness check below failed
        // roughly one run in five on a loaded machine, and the credential
        // checks could have answered "no header" for the wrong reason.
        try await elsewhere.waitForRequests(atLeast: 1)
        try await configured.waitForRequests(atLeast: 1)

        // The credential question first, and reached unconditionally: the
        // error analysis below has early returns in it, and this is the
        // assertion the test exists for. That the second host was reached
        // at all is asserted too — otherwise "it saw no credentials" would
        // hold for the trivial reason that the redirect never happened.
        #expect(!elsewhere.requests.isEmpty)
        #expect(elsewhere.sawAuthorizationHeader == false)
        #expect(configured.sawAuthorizationHeader == false)

        guard let thrown else {
            Issue.record("expected the redirected challenge to fail the connect")
            return
        }
        // Not `authenticationFailed`: nobody rejected anything, and telling
        // the user to check their password would send them after a
        // credential that never left the machine.
        guard case RemoteFSError.connectionFailed(let reason) = thrown else {
            Issue.record("expected a connection failure, got \(thrown)")
            return
        }
        #expect(reason.contains("the password was not sent"))
        await expectNoSecret(in: thrown, "redirected WebDAV challenge")
    }

    /// The Critical this arm was reopened for. A certificate is public
    /// material, so nothing leaks here — the danger is the STATE CHANGE.
    /// The attacker writes the `Location` header, so the attacker chooses
    /// which host the TOFU question is asked about and which host a pin is
    /// written under, INCLUDING the configured host's own name on 443.
    /// A pin outlives the failed connect: once one exists for a host,
    /// `ServerCertificateValidation` sees a known certificate for it and
    /// `.mismatch` — this project's hard stop — can never fire for that
    /// host again. Plaintext base URL, one injected redirect, one accepted
    /// prompt, and the next correctly configured https connect accepts a
    /// planted certificate in silence.
    ///
    /// Measured the way it was broken: a plaintext stub redirects to a
    /// real TLS stub with a self-signed certificate. The decider says YES
    /// to everything it is asked, so if the arm ran at all, a pin would be
    /// written and the assertions below would fail.
    @Test("a redirected certificate challenge is refused, and nothing is pinned")
    func webdavRedirectedCertificateChallengePinsNothing() async throws {
        let tls = try await LoopbackTLSStub.make(response: LoopbackHTTPStub.basicAuthAlwaysRejects)
        defer { tls.stop() }
        let configured = try LoopbackHTTPStub(
            response: LoopbackHTTPStub.movedTemporarily(
                to: "https://127.0.0.1:\(tls.port)/elsewhere"))
        defer { configured.stop() }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)
        let asked = TestBox(false)
        let config = WebDAVConnectionConfig(
            baseURL: "http://127.0.0.1:\(configured.port)/dav", username: "tester",
            useNextcloudPath: false, password: Secret.webdavPassword)

        var thrown: Error?
        do {
            // Accepts anything it is asked about. The refusal has to come
            // from the origin check, not from a decider that says no.
            _ = try await WebDAVFileSystem.connect(
                config, trustStore: store,
                decider: .asking { _ in asked.value = true; return true })
        } catch {
            thrown = error
        }

        // The three assertions the ruling names, reached unconditionally.
        #expect(asked.value == false)
        #expect(try store.find(host: "127.0.0.1", port: tls.port) == nil)
        #expect(try store.allCertificates().isEmpty)

        // And the consequence spelled out: a later connect configured FOR
        // that host still has to ask. A planted pin is exactly what would
        // make this stop asking, so this is the assertion that would have
        // caught the original hole even without a trust store to inspect.
        // Its own flag, not the one above — sharing one would let the
        // first phase's YES satisfy this check for free.
        let askedAgain = TestBox(false)
        let laterDelegate = WebDAVSessionDelegate(
            baseURL: URL(string: "https://127.0.0.1:\(tls.port)")!,
            username: "tester", password: Secret.webdavPassword,
            trustStore: store, decider: .asking { _ in askedAgain.value = true; return false })
        _ = await laterDelegate.decideCertificate(ServerCertificateCandidate(
            host: "127.0.0.1", port: tls.port, derBase64: "QUJD",
            subject: "CN=127.0.0.1", issuer: "CN=127.0.0.1", notAfter: nil))
        #expect(askedAgain.value == true)

        guard let thrown else {
            Issue.record("expected the redirected certificate challenge to fail the connect")
            return
        }
        guard case RemoteFSError.connectionFailed(let reason) = thrown else {
            Issue.record("expected a connection failure, got \(thrown)")
            return
        }
        #expect(reason.contains("neither trusted nor remembered"))
        // Both origins named WITH their schemes. Host and port alone would
        // print two names that differ only in a number here, and would be
        // outright identical for the plain upgrade case.
        #expect(reason.contains("https://127.0.0.1:\(tls.port)"))
        #expect(reason.contains("http://127.0.0.1:\(configured.port)"))
        await expectNoSecret(in: thrown, "redirected WebDAV certificate challenge")
    }

    // MARK: - known_hosts write

    /// The premise behind wrapping the known-hosts write, measured rather
    /// than asserted: a real store failure is an `NSError`, and
    /// `String(describing:)` on one prints its entire `userInfo` table
    /// while `localizedDescription` prints the sentence a person can read.
    /// The bare `try` that used to sit on that write handed the first form
    /// to the same catch-all arm this whole commit is about.
    ///
    /// What this does NOT reach is the accept arm itself: getting there
    /// needs a server presenting a host key for a person to accept, which
    /// means the gated rig. This pins the difference the wrap relies on;
    /// the wrap's own placement is read, not measured.
    @Test("a real known-hosts write failure has a readable form and a dumping one")
    func knownHostsWriteFailureHasAReadableForm() throws {
        let occupied = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: occupied) }
        // A FILE where the store wants its directory, so `createDirectory`
        // fails for a real reason rather than a simulated one.
        try Data("occupied".utf8).write(to: occupied)
        let store = KnownHostsStore(directory: occupied.appendingPathComponent("inside"))
        do {
            try store.upsert(KnownHostKey(
                host: "example.test", port: 22, keyType: "ssh-ed25519",
                publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAA"))
            Issue.record("expected the known-hosts write to fail")
        } catch {
            #expect(String(describing: error).contains("UserInfo="))
            #expect(!error.localizedDescription.contains("UserInfo="))
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    // MARK: - ssh-agent helpers

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
         UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    /// The agent protocol's `string`: a big-endian length then the bytes.
    private static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        uint32BE(UInt32(bytes.count)) + bytes
    }

    private static func agentFrame(type: UInt8, payload: [UInt8] = []) -> Data {
        let body = [type] + payload
        return Data(uint32BE(UInt32(body.count)) + body)
    }

    /// `SSH_AUTH_SOCK` is process-global, and a second suite
    /// (`AgentAuthTests`) mutates it too — `AgentEnvLock` is the
    /// cross-suite lock that keeps the two from interleaving.
    private func withTemporaryAuthSock(
        _ value: String, _ body: () async throws -> Void
    ) async throws {
        try await AgentEnvLock.shared.run {
            let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            setenv("SSH_AUTH_SOCK", value, 1)
            defer {
                if let original {
                    setenv("SSH_AUTH_SOCK", original, 1)
                } else {
                    unsetenv("SSH_AUTH_SOCK")
                }
            }
            try await body()
        }
    }

    /// Dials the dead port with `.agent` auth, optionally with the agent
    /// client factory answering `answer`, and checks the resulting error
    /// against `shape` before sweeping it for sentinels.
    private func expectAgentDialFails(
        answering answer: Data?, as shape: (Error) -> Bool, _ what: String
    ) async {
        // Applied to every case, here rather than case by case, so a case
        // added later is held to it without anybody remembering to. The
        // claim is that IF this case's bytes were base64-leaked, the
        // sweep would catch them — which is what stopped being true once
        // a type name moved the material off a three-byte boundary.
        //
        // Both the whole frame and its body, because a leak could plausibly
        // render either, and the four-byte length prefix between them puts
        // the material at two different alignments.
        if let answer {
            for (label, buffer) in [("frame", answer), ("body", Data(answer.dropFirst(4)))] {
                let encoded = buffer.base64EncodedString()
                #expect(Secret.agentKeyMaterialBase64.contains { encoded.contains($0) },
                        "\(what): a base64 leak of this case's \(label) would go unnoticed")
            }
        }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let config = try SSHConnectionConfig(
                host: "127.0.0.1", port: Self.deadPort, username: "tester", auth: .agent)
            let dial = {
                _ = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(5),
                    knownHosts: KnownHostsStore(directory: directory),
                    onUnknownHostKey: .refusing)
            }
            if let answer {
                try await CitadelFileSystem.AgentClientFactory.$override.withValue({ _ in
                    SSHAgentClient(transport: MockAgentTransport(response: answer))
                }) { try await dial() }
            } else {
                try await dial()
            }
            Issue.record("\(what): expected the dial to fail")
        } catch {
            if !shape(error) {
                Issue.record("\(what): unexpected error \(error)")
            }
            // Swept even when the shape is wrong. A leak that ALSO changes
            // the error's type — the only way the payload-free cases could
            // ever leak, since `.noIdentities` and `.refused` carry no
            // string to leak into — must not be able to hide behind an
            // early return in the shape check.
            await expectNoSecret(in: error, what)
        }
    }
}

/// The WebDAV operations `webdavOperationFailureCarriesNoSecret` drives.
///
/// Seven cases, counted while writing this sentence: the five
/// `RemoteFileSystem` reads and writes that reach the network through
/// `transport.send`, the streaming read, and the streaming write. The list
/// is the point — the round-1 fix covered the dial and left exactly these
/// behind, so what is enumerated here is "every way this backend can touch
/// the network after it is connected", not a sample of them.
///
/// `deleteTree` and `homeDirectoryPath` are deliberately absent:
/// `deleteTree` reaches the network through the same `simple(...)` as
/// `delete` and `createDirectory`, one argument apart, and
/// `homeDirectoryPath` never touches it at all.
enum WebDAVOperation: String, CaseIterable, Sendable {
    case list, stat, readStream, delete, createDirectory, rename, write

    func run(on fs: WebDAVFileSystem) async throws {
        switch self {
        case .list: _ = try await fs.list(path: "/")
        case .stat: _ = try await fs.stat(path: "/file.txt")
        case .readStream: _ = try await fs.readStream(path: "/file.txt", fromOffset: 0)
        case .delete: try await fs.delete(path: "/file.txt")
        case .createDirectory: try await fs.createDirectory(at: "/folder")
        case .rename: try await fs.rename(from: "/a.txt", to: "/b.txt")
        case .write:
            try await fs.write(
                path: "/a.txt", mode: .overwrite,
                contents: AsyncThrowingStream { continuation in
                    continuation.yield(Data("hello".utf8))
                    continuation.finish()
                })
        }
    }
}
