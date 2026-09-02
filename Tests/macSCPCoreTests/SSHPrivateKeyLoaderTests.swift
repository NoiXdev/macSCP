import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import macSCPCore

/// Test keys are generated at RUNTIME (ssh-keygen) — never checked in.
@Suite("SSHPrivateKeyLoader")
struct SSHPrivateKeyLoaderTests {
    /// Generates a key of `type` in the temp directory; passphrase "" = unencrypted.
    /// `extra` is appended to the ssh-keygen argument list (e.g. `["-b", "384"]`,
    /// `["-m", "PEM"]`).
    private func makeKey(type: String = "ed25519", passphrase: String = "",
                         extra: [String] = []) throws -> (dir: URL, keyPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("id_\(type)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", type, "-f", keyURL.path(percentEncoded: false),
                             "-N", passphrase, "-q", "-C", "macscp-test"] + extra
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return (dir, keyURL.path(percentEncoded: false))
    }

    @Test func loadsUnencryptedKey() throws {
        let (dir, keyPath) = try makeKey(passphrase: "")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
    }

    @Test func loadsEncryptedKeyWithCorrectPassphrase() throws {
        let (dir, keyPath) = try makeKey(passphrase: "geheime-phrase")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: "geheime-phrase")
    }

    @Test func encryptedKeyWithoutPassphraseThrowsPassphraseRequired() throws {
        let (dir, keyPath) = try makeKey(passphrase: "geheime-phrase")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    @Test func encryptedKeyWithWrongPassphraseThrowsWrongPassphrase() throws {
        let (dir, keyPath) = try makeKey(passphrase: "geheime-phrase")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.wrongPassphrase) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: "falsch")
        }
    }

    @Test func missingFileThrowsFileNotFound() {
        let missing = "/tmp/macscp-kein-key-\(UUID().uuidString)"
        #expect(throws: SSHKeyError.fileNotFound(path: missing)) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: missing, passphrase: nil)
        }
    }

    @Test func garbageFileThrowsUnsupportedFormat() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("kaputt")
        try Data("kein key".utf8).write(to: garbage)

        do {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: garbage.path(percentEncoded: false), passphrase: nil)
            Issue.record("expected unsupportedFormat")
        } catch let error as SSHKeyError {
            guard case .unsupportedFormat = error else {
                Issue.record("expected unsupportedFormat, was: \(error)")
                return
            }
        }
    }

    @Test("an RSA key loads")
    func loadsRSAKey() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
    }

    @Test("an ECDSA key loads on each curve", arguments: [256, 384, 521])
    func loadsECDSAKey(bits: Int) throws {
        let (dir, keyPath) = try makeKey(type: "ecdsa", extra: ["-b", String(bits)])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
    }

    /// An ECDSA key file is dispatched by the curve its header names, not by
    /// trying all three parsers — so each curve has to reach ITS OWN
    /// `SSHAuthenticationMethod` factory. A wrong row here is a key that
    /// parses and is then offered under a curve name that is not its own.
    @Test("each ECDSA curve reaches its own offer",
          arguments: [(256, "ecdsa-sha2-nistp256"), (384, "ecdsa-sha2-nistp384"),
                      (521, "ecdsa-sha2-nistp521")])
    func ecdsaCurveReachesItsOwnOffer(bits: Int, expectedPrefix: String) async throws {
        let (dir, keyPath) = try makeKey(type: "ecdsa", extra: ["-b", String(bits)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
        let prefixes = try await offeredPublicKeyPrefixes(method)
        #expect(prefixes == [expectedPrefix])
    }

    /// The whole reason an RSA key FILE can be used at all is that the offer
    /// carries an RFC 8332 SHA-2 algorithm name. This reads the names back
    /// out of the SERIALIZED public key blobs the loader's method would put
    /// on the wire, the way NIOSSH does — not from a property that merely
    /// happens to agree with those bytes.
    ///
    /// The equality is the positive half: without it the `ssh-rsa` check
    /// below would pass against an empty list, which is the silent-negative
    /// shape `CLAUDE.md` names. Every name is read from a symbol rather than
    /// spelled, so a rename in Citadel fails here instead of going quiet.
    ///
    /// This is also the pin for the loader passing `includeSHA1Fallback:
    /// false` explicitly: with `true` the list gains a third entry and the
    /// equality fails.
    @Test("an RSA key is offered as rsa-sha2 only, never as ssh-rsa")
    func rsaKeyOffersSHA2Only() async throws {
        let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)

        let prefixes = try await offeredPublicKeyPrefixes(method)
        #expect(prefixes == [
            Insecure.RSA.SHA2PrivateKey<RSASHA2_512>.keyPrefix,
            Insecure.RSA.SHA2PrivateKey<RSASHA2_256>.keyPrefix,
        ])
        #expect(!prefixes.contains(Insecure.RSA.PrivateKey.keyPrefix))
    }

    /// The header is cleartext even when the private half is encrypted, so
    /// the key type is known before the passphrase is. What the fork changed
    /// is only the verdict: an encrypted RSA key now asks for its passphrase
    /// instead of being turned away for its type.
    @Test("an encrypted RSA key without a passphrase asks for one")
    func encryptedRSAKeyWithoutPassphraseThrowsPassphraseRequired() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    @Test("an encrypted RSA key with the wrong passphrase says so")
    func encryptedRSAKeyWithWrongPassphraseThrowsWrongPassphrase() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.wrongPassphrase) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: "falsch")
        }
        // The positive half: the same file opens with the right passphrase,
        // so the rejection above is about the passphrase and not the file.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: "geheime-phrase")
    }

    /// The fork's ECDSA arm throws the same shapes as the ed25519 one (Task
    /// 3's `testEncryptedKeyWithoutPassphraseFailsTheSameWayAsEd25519`), so
    /// the loader's `map` must reach the same two verdicts here.
    @Test("an encrypted ECDSA key maps the same two failures",
          arguments: [256, 384, 521])
    func encryptedECDSAKeyMapsPassphraseFailures(bits: Int) throws {
        let (dir, keyPath) = try makeKey(
            type: "ecdsa", passphrase: "geheime-phrase", extra: ["-b", String(bits)])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
        #expect(throws: SSHKeyError.wrongPassphrase) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: "falsch")
        }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: "geheime-phrase")
    }

    /// A key type `SSHKeyType` does not know at all is still NAMED rather
    /// than flattened into "invalid key", because the name is the one thing
    /// the person holding it can act on. `ssh-dss` is spelled here because
    /// there is no symbol to read it from: it is a wire name Citadel's
    /// detector hands back verbatim, not a member of any type macSCP or
    /// Citadel declares.
    ///
    /// The container is BUILT rather than generated, because no `ssh-keygen`
    /// on this platform will make one any more: OpenSSH removed DSA
    /// generation in 10.0, and macOS 15's own binary reports
    /// `unknown key type dsa` (measured 2026-09-02, OpenSSH_10.3p1). FIDO
    /// `sk-*` keys, the other member of this class, need hardware. Only the
    /// cleartext header is built — that is all `SSHKeyDetection` reads, and
    /// naming the type is the whole behaviour under test.
    @Test("an unmodelled key type is named, not called invalid")
    func unmodelledKeyTypeIsNamed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id_dsa").path(percentEncoded: false)
        try Data(Self.opensshContainerHeader(namingKeyType: "ssh-dss").utf8).write(
            to: URL(fileURLWithPath: keyPath))

        #expect(throws: SSHKeyError.typeNotLoadable(algorithm: "ssh-dss")) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    /// The positive half of the test above: the same builder, given a type
    /// `SSHKeyType` DOES model, gets past the naming guard — so a `ssh-dss`
    /// verdict is about the type and not about the hand-built container being
    /// rejected wholesale. It cannot reach a loaded key (there is no key
    /// material in the header), so the verdict is the parser's, not the
    /// detector's.
    @Test("the hand-built container is rejected for its type, not its shape")
    func handBuiltContainerPassesTheNamingGuardForAModelledType() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id_ed25519").path(percentEncoded: false)
        try Data(Self.opensshContainerHeader(
            namingKeyType: SSHKeyType.ed25519.rawValue).utf8).write(
                to: URL(fileURLWithPath: keyPath))

        do {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: nil)
            Issue.record("expected the truncated container to be rejected")
        } catch let error as SSHKeyError {
            guard case .unsupportedFormat = error else {
                Issue.record("expected unsupportedFormat, was: \(error)")
                return
            }
        }
    }

    /// An `openssh-key-v1` container carrying nothing but its cleartext
    /// header up to and including the public section's key-type string:
    /// magic, cipher `none`, KDF `none`, empty KDF options, one key, then the
    /// public blob whose first field is the type name. Everything after that
    /// is what `SSHKeyDetection.detectPrivateKeyType` never reads.
    private static func opensshContainerHeader(namingKeyType keyType: String) -> String {
        func sshString(_ text: String) -> Data {
            var data = Data()
            withUnsafeBytes(of: UInt32(text.utf8.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: text.utf8)
            return data
        }
        var blob = Data("openssh-key-v1\0".utf8)
        blob += sshString("none") + sshString("none") + sshString("")
        withUnsafeBytes(of: UInt32(1).bigEndian) { blob.append(contentsOf: $0) }
        let publicSection = sshString(keyType)
        withUnsafeBytes(of: UInt32(publicSection.count).bigEndian) { blob.append(contentsOf: $0) }
        blob += publicSection
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + blob.base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// Drives the delegate until it runs out of offers, and returns the
    /// algorithm name each offered public key puts on the wire.
    ///
    /// The offer list is private to `SSHAuthenticationMethod`, so the only
    /// way to observe it is the way NIOSSH does: ask for the next offer
    /// until the delegate refuses. The name is read back out of the
    /// SERIALIZED key blob, which begins with an SSH string holding the
    /// algorithm name — not from a property that merely happens to agree
    /// with those bytes. Adapted from the fork's own
    /// `RSASHA2Tests.offeredPublicKeyPrefixes`, with one change forced by
    /// this package's Swift 6 language mode: `NIOSSHUserAuthenticationOffer`
    /// is not `Sendable`, so it is never carried out of the completion
    /// callback — the name is extracted there and only a `String` crosses.
    ///
    /// Async on purpose, and every wait in it is an `await`: this helper
    /// runs on Swift Testing's cooperative thread pool, which is as wide as
    /// the machine has cores. Its first version blocked that pool twice —
    /// `futureResult.wait()` per offer and `syncShutdownGracefully()` in a
    /// `defer` — and on the three-core CI runner three parameterised cases
    /// occupied all three threads inside the shutdown semaphore, so no test
    /// in the whole suite could finish (measured 2026-09-02 with `sample`
    /// on the hung process; locally, with ten cores, it never showed).
    private func offeredPublicKeyPrefixes(
        _ method: SSHAuthenticationMethod,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [String] {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let prefixes = await collectOfferPrefixes(method, on: loop, sourceLocation: sourceLocation)
        try await group.shutdownGracefully()
        return prefixes
    }

    private func collectOfferPrefixes(
        _ method: SSHAuthenticationMethod, on loop: any EventLoop,
        sourceLocation: SourceLocation
    ) async -> [String] {

        var prefixes: [String] = []
        // The list is finite and short; the cap only stops a runaway loop
        // from hanging the suite if the delegate ever stops draining itself.
        for _ in 0..<16 {
            let offerPromise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            let namePromise = loop.makePromise(of: String.self)
            offerPromise.futureResult.whenComplete { result in
                switch result {
                case .failure(let error):
                    // The delegate is out of offers — this is the loop's exit.
                    namePromise.fail(error)
                case .success(let offer):
                    guard case .privateKey(let privateKey)? = offer?.offer else {
                        namePromise.fail(OfferShape.notAPrivateKey)
                        return
                    }
                    var buffer = ByteBuffer()
                    privateKey.publicKey.write(to: &buffer)
                    guard let length = buffer.readInteger(as: UInt32.self),
                          let prefix = buffer.readString(length: Int(length))
                    else {
                        namePromise.fail(OfferShape.noLeadingSSHString)
                        return
                    }
                    namePromise.succeed(prefix)
                }
            }
            method.nextAuthenticationType(
                availableMethods: .publicKey, nextChallengePromise: offerPromise)

            do {
                prefixes.append(try await namePromise.futureResult.get())
            } catch let shape as OfferShape {
                Issue.record("offer \(prefixes.count) is unreadable: \(shape)",
                             sourceLocation: sourceLocation)
                return prefixes
            } catch {
                return prefixes
            }
        }

        Issue.record("delegate never ran out of offers", sourceLocation: sourceLocation)
        return prefixes
    }

    /// Why an offer could not be named. Distinct from the delegate simply
    /// running out, which is the helper's ordinary exit.
    private enum OfferShape: Error {
        case notAPrivateKey
        case noLeadingSSHString
    }

    @Test("a PEM-format key is reported as PEM, not as garbage")
    func pemKeyIsReported() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048", "-m", "PEM"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.pemNotSupported) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }
}
