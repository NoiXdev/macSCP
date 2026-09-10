import Citadel
import Crypto
import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import Testing
// `@testable` for ONE member, and specifically for its INSTANCE form:
// `NIOSSHPublicKey.userAuthAlgorithmName`, which NIOSSH writes as `pkalg`
// (`SSHMessages.swift:1314`) and into the signed payload. It sits in an
// internal `extension NIOSSHPublicKey` (`NIOSSHPublicKey.swift:162`),
// alongside the equally internal `keyPrefix` and `hostKeyAlgorithms`.
//
// The STATIC reads below (`Insecure.RSA.SHA2PublicKey<…>.userAuthAlgorithmName`,
// `Insecure.RSA.PublicKey.userAuthAlgorithmName`) need none of this: the
// protocol requirement and its default are public (`CustomKeys.swift:85`,
// `:106`). Nothing else in this file should lean on the wider import.
//
// Reading the instance property is what keeps the RSA offer test about the
// algorithm NAME rather than the blob type, which since swift-nio-ssh 0.3.10
// / Citadel 0.12.1-noix.3 is `ssh-rsa` for every RSA offer; re-deriving the
// name from the offered key's Swift type would be a second copy of it.
//
// What it costs: `swift test -c release` cannot compile this file
// ("module 'NIOSSH' was not compiled for testing"), because SwiftPM passes
// `-enable-testing` only in debug. Acceptable for the debug suite this
// project runs — and a FORK ITEM: expose a public accessor for
// `userAuthAlgorithmName` on `NIOSSHPublicKey` in `NoiXdev/swift-nio-ssh`
// (0.3.11), offer it upstream as `apple/swift-nio-ssh` would need it too,
// and record it in the dependencies spec. This import goes away with it.
@testable import NIOSSH
@testable import macSCPCore

/// Test keys are generated at RUNTIME (ssh-keygen) — never checked in.
///
/// `.timeLimit(.minutes(1))`: `makeKey` shells out to `ssh-keygen` once per
/// call, well under a second even on a loaded runner — a single invocation
/// taking a full minute would itself be the defect. The project default is
/// enough; nothing here needed the wider limit.
@Suite("SSHPrivateKeyLoader", .timeLimit(.minutes(1)))
struct SSHPrivateKeyLoaderTests {
    /// Generates a key of `type` in the temp directory; passphrase "" = unencrypted.
    /// `extra` is appended to the ssh-keygen argument list (e.g. `["-b", "384"]`,
    /// `["-m", "PEM"]`).
    private func makeKey(type: String = "ed25519", passphrase: String = "",
                         extra: [String] = []) async throws -> (dir: URL, keyPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("id_\(type)")
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-t", type, "-f", keyURL.path(percentEncoded: false),
                        "-N", passphrase, "-q", "-C", "macscp-test"] + extra)
        #expect(result.status == 0)
        return (dir, keyURL.path(percentEncoded: false))
    }

    @Test func loadsUnencryptedKey() async throws {
        let (dir, keyPath) = try await makeKey(passphrase: "")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
    }

    @Test func loadsEncryptedKeyWithCorrectPassphrase() async throws {
        let (dir, keyPath) = try await makeKey(passphrase: "geheime-phrase")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: "geheime-phrase")
    }

    @Test func encryptedKeyWithoutPassphraseThrowsPassphraseRequired() async throws {
        let (dir, keyPath) = try await makeKey(passphrase: "geheime-phrase")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    @Test func encryptedKeyWithWrongPassphraseThrowsWrongPassphrase() async throws {
        let (dir, keyPath) = try await makeKey(passphrase: "geheime-phrase")
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
    func loadsRSAKey() async throws {
        let (dir, keyPath) = try await makeKey(type: "rsa", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
    }

    @Test("an ECDSA key loads on each curve", arguments: [256, 384, 521])
    func loadsECDSAKey(bits: Int) async throws {
        let (dir, keyPath) = try await makeKey(type: "ecdsa", extra: ["-b", String(bits)])
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
        let (dir, keyPath) = try await makeKey(type: "ecdsa", extra: ["-b", String(bits)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)
        let offers = try await offeredKeys(method)
        // Both identifiers, because for ECDSA they ARE the same string — the
        // split RFC 8332 forces on RSA does not exist here.
        #expect(offers == [OfferedKey(algorithmName: expectedPrefix, blobType: expectedPrefix)])
    }

    /// The whole reason an RSA key FILE can be used at all is that the offer
    /// carries an RFC 8332 SHA-2 algorithm NAME — and, since Citadel
    /// `0.12.1-noix.3`, that it carries it in the right field: `pkalg` and the
    /// signed payload, while the key BLOB stays typed `ssh-rsa` the way a Go
    /// server insists on. Both halves are read back off the offer the way
    /// NIOSSH does — the name from the property NIOSSH writes, the blob type
    /// from the SERIALIZED bytes — not from a property that merely happens to
    /// agree with them.
    ///
    /// The name equality is the positive half: without it the SHA-1 check
    /// would pass against an empty list, which is the silent-negative shape
    /// `CLAUDE.md` names. The blob-type equality is the second positive, and
    /// the one that would have caught the older, coupled wire: it fails the
    /// moment an RSA blob is typed anything but `ssh-rsa`. Note that the
    /// SHA-1 check has to read an ALGORITHM name — every RSA blob is
    /// `ssh-rsa` now, so the same check against the blob type could never
    /// match and would pass on a SHA-1 offer.
    ///
    /// Every name is read from a symbol rather than spelled, so a rename in
    /// Citadel fails here instead of going quiet.
    ///
    /// This is also the pin for the loader passing `includeSHA1Fallback:
    /// false` explicitly: with `true` the list gains a third entry and the
    /// equality fails.
    @Test("an RSA key is offered as rsa-sha2 only, never as ssh-rsa")
    func rsaKeyOffersSHA2Only() async throws {
        let (dir, keyPath) = try await makeKey(type: "rsa", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)

        let offers = try await offeredKeys(method)
        #expect(offers.map(\.algorithmName) == [
            Insecure.RSA.SHA2PublicKey<RSASHA2_512>.userAuthAlgorithmName,
            Insecure.RSA.SHA2PublicKey<RSASHA2_256>.userAuthAlgorithmName,
        ])
        #expect(Set(offers.map(\.blobType)) == [Insecure.RSA.PublicKey.publicKeyPrefix])
        #expect(!offers.map(\.algorithmName)
            .contains(Insecure.RSA.PublicKey.userAuthAlgorithmName))
    }

    /// The header is cleartext even when the private half is encrypted, so
    /// the key type is known before the passphrase is. What the fork changed
    /// is only the verdict: an encrypted RSA key now asks for its passphrase
    /// instead of being turned away for its type.
    @Test("an encrypted RSA key without a passphrase asks for one")
    func encryptedRSAKeyWithoutPassphraseThrowsPassphraseRequired() async throws {
        let (dir, keyPath) = try await makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    @Test("an encrypted RSA key with the wrong passphrase says so")
    func encryptedRSAKeyWithWrongPassphraseThrowsWrongPassphrase() async throws {
        let (dir, keyPath) = try await makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
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
    func encryptedECDSAKeyMapsPassphraseFailures(bits: Int) async throws {
        let (dir, keyPath) = try await makeKey(
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

    /// One offered public key, in the two identifiers RFC 8332 §3 keeps
    /// apart: the algorithm name the request carries as `pkalg`, and the type
    /// string inside the key blob itself. They are one string for every
    /// algorithm here except RSA.
    struct OfferedKey: Equatable, Sendable, CustomStringConvertible {
        let algorithmName: String
        let blobType: String

        var description: String { "\(algorithmName) in a \(blobType) blob" }
    }

    /// Drives the delegate until it runs out of offers, and returns both
    /// identifiers of each offered public key.
    ///
    /// The offer list is private to `SSHAuthenticationMethod`, so the only
    /// way to observe it is the way NIOSSH does: ask for the next offer
    /// until the delegate refuses. The blob type is read back out of the
    /// SERIALIZED key blob, which begins with an SSH string holding it — not
    /// from a property that merely happens to agree with those bytes — and
    /// the algorithm name from `NIOSSHPublicKey.userAuthAlgorithmName`, which
    /// is the property NIOSSH itself writes into the request. Adapted from
    /// the fork's own `RSASHA2Tests.offeredPublicKeys`, with one change
    /// forced by
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
    private func offeredKeys(
        _ method: SSHAuthenticationMethod,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [OfferedKey] {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let offers = await collectOfferedKeys(method, on: loop, sourceLocation: sourceLocation)
        try await group.shutdownGracefully()
        return offers
    }

    private func collectOfferedKeys(
        _ method: SSHAuthenticationMethod, on loop: any EventLoop,
        sourceLocation: SourceLocation
    ) async -> [OfferedKey] {

        var offers: [OfferedKey] = []
        // The list is finite and short; the cap only stops a runaway loop
        // from hanging the suite if the delegate ever stops draining itself.
        for _ in 0..<16 {
            let offerPromise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            let keyPromise = loop.makePromise(of: OfferedKey.self)
            offerPromise.futureResult.whenComplete { result in
                switch result {
                case .failure(let error):
                    // The delegate is out of offers — this is the loop's exit.
                    keyPromise.fail(error)
                case .success(let offer):
                    guard case .privateKey(let privateKey)? = offer?.offer else {
                        keyPromise.fail(OfferShape.notAPrivateKey)
                        return
                    }
                    let publicKey = privateKey.publicKey
                    var buffer = ByteBuffer()
                    publicKey.write(to: &buffer)
                    guard let length = buffer.readInteger(as: UInt32.self),
                          let blobType = buffer.readString(length: Int(length))
                    else {
                        keyPromise.fail(OfferShape.noLeadingSSHString)
                        return
                    }
                    keyPromise.succeed(OfferedKey(
                        algorithmName: String(publicKey.userAuthAlgorithmName),
                        blobType: blobType))
                }
            }
            method.nextAuthenticationType(
                availableMethods: .publicKey, nextChallengePromise: offerPromise)

            do {
                // `awaitCancellably`, not `EventLoopFuture.get()` — `get()`
                // ignores task cancellation (see its doc comment,
                // `Tests/MacSCPTestSupport/AwaitCancellably.swift`), so a
                // delegate that stalled here would park the run past this
                // suite's `.timeLimit` instead of ending it.
                offers.append(try await awaitCancellably(keyPromise.futureResult))
            } catch let shape as OfferShape {
                Issue.record("offer \(offers.count) is unreadable: \(shape)",
                             sourceLocation: sourceLocation)
                return offers
            } catch {
                return offers
            }
        }

        Issue.record("delegate never ran out of offers", sourceLocation: sourceLocation)
        return offers
    }

    /// Why an offer could not be named. Distinct from the delegate simply
    /// running out, which is the helper's ordinary exit.
    private enum OfferShape: Error {
        case notAPrivateKey
        case noLeadingSSHString
    }

    // MARK: - PEM files (PEM private keys plan, Task 3)

    /// The one passphrase the PEM cells below use.
    ///
    /// A named constant because `#expect` reports the SOURCE TEXT of the
    /// expression it checks, so a passphrase spelled inside an expectation
    /// leaks through the failure message — the second exit `CLAUDE.md` names
    /// ("A value a test must not leak has two exits, not one"). It reaches
    /// `ssh-keygen -N` and the loader, nothing else.
    static let pemPassphrase = "pem-loader-fixture"

    /// Every shape `PEMFixtures.Shape.all` produces — RSA 2048 and ECDSA on
    /// all three curves, each written by `ssh-keygen -m PEM` (PKCS#1 / SEC1)
    /// and by `-m PKCS8` — plain and passphrase-protected: sixteen cells.
    ///
    /// This replaces `pemKeyIsReported`, which asserted the refusal these
    /// files used to get. The refusal was the boundary check in
    /// `authentication(username:keyPath:passphrase:)`; the files it turned
    /// away are exactly the ones read here.
    @Test("a PEM key loads", arguments: PEMFixtures.Shape.all, [false, true])
    func aPEMKeyLoads(shape: PEMFixtures.Shape, encrypted: Bool) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let passphrase: String? = encrypted ? Self.pemPassphrase : nil
        let keyPath = try await PEMFixtures.sshKeygen(
            type: shape.type, bits: shape.bits, format: shape.format,
            passphrase: passphrase, in: dir)
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: passphrase)
    }

    /// `rsaKeyOffersSHA2Only`'s twin for a PEM RSA file, and it exists
    /// because the PEM path reaches `.rsaSHA2` through its OWN call: the
    /// components go through `OpenSSHKeyContainer.unencryptedRSA` and
    /// Citadel's `sshRsa` parser, and that call passes its own
    /// `includeSHA1Fallback:`. A `true` there would offer SHA-1 for every
    /// PEM RSA key while the OpenSSH path stayed correct, and the original
    /// test could not see it.
    ///
    /// Read the same way, off the same two identifiers — see
    /// `rsaKeyOffersSHA2Only`'s doc comment for what each half proves.
    @Test("a PEM RSA key is offered as rsa-sha2 only, never as ssh-rsa")
    func pemRSAKeyOffersSHA2Only() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = try await PEMFixtures.sshKeygen(
            type: "rsa", bits: 2048, format: .pem, passphrase: nil, in: dir)
        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: nil)

        let offers = try await offeredKeys(method)
        #expect(offers.map(\.algorithmName) == [
            Insecure.RSA.SHA2PublicKey<RSASHA2_512>.userAuthAlgorithmName,
            Insecure.RSA.SHA2PublicKey<RSASHA2_256>.userAuthAlgorithmName,
        ])
        #expect(Set(offers.map(\.blobType)) == [Insecure.RSA.PublicKey.publicKeyPrefix])
        #expect(!offers.map(\.algorithmName)
            .contains(Insecure.RSA.PublicKey.userAuthAlgorithmName))
    }

    /// Ed25519 has no cell in `Shape.all` because no producer on this
    /// machine writes one: `ssh-keygen -m PEM`/`-m PKCS8` refuse ed25519
    /// ("error in libcrypto") and LibreSSL 3.3.6 does not know the algorithm
    /// (design table, 2026-09-10). The file is therefore built from a
    /// CryptoKit seed and its fixed PKCS#8 prefix, and what it measures is
    /// the loader's ed25519 arm, not an external producer.
    ///
    /// The offer is read back rather than the return value merely being
    /// discarded: the ECDSA arms would also return a `SSHAuthenticationMethod`
    /// for a mis-dispatched key, and the offered algorithm name is what says
    /// which arm ran. Both names come from NIOSSH's own key, never spelled.
    @Test("an Ed25519 PKCS#8 key loads")
    func ed25519PKCS8KeyLoads() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let keyURL = dir.appendingPathComponent("ed25519-pkcs8.pem")
        try Data(PEMFixtures.ed25519PKCS8PEM(seed: seed).utf8).write(to: keyURL)

        let method = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyURL.path(percentEncoded: false), passphrase: nil)
        let offers = try await offeredKeys(method)
        let expected = String(NIOSSHPrivateKey(
            ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            .publicKey.userAuthAlgorithmName)
        #expect(offers == [OfferedKey(algorithmName: expected, blobType: expected)])
    }

    /// swift-crypto carries no DES, so a 3DES file cannot be opened with any
    /// passphrase — and saying "wrong passphrase" to someone holding the
    /// right one is the failure this case exists to prevent. The cipher name
    /// is the decoder's own constant, not a substring of the file.
    @Test("a DES-EDE3 PEM key is named")
    func desEDE3PEMKeyIsNamed() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainPath = try await PEMFixtures.sshKeygen(
            type: "rsa", bits: 2048, format: .pem, passphrase: nil, in: dir)
        let keyPath = dir.appendingPathComponent("des3.pem").path(percentEncoded: false)
        try await PEMFixtures.openssl(["rsa", "-in", plainPath, "-des3",
                                       "-passout", "pass:\(Self.pemPassphrase)",
                                       "-out", keyPath])

        #expect(throws: SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC"))) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: Self.pemPassphrase)
        }
    }

    /// The two passphrase verdicts have to survive the PEM path unchanged —
    /// they are the two `SSHKeyError` cases `ConnectionViewModel` treats as
    /// `.needsPerson`, and a PEM key that reported `unsupportedFormat`
    /// instead would silently lose the passphrase prompt.
    ///
    /// Both encryptions ssh-keygen writes: the legacy `DEK-Info` header
    /// (`-m PEM`) and PBES2 (`-m PKCS8`). The right passphrase opens the
    /// same file at the end, so neither refusal is about the file.
    @Test("an encrypted PEM key maps the two passphrase failures",
          arguments: [PEMFixtures.Format.pem, .pkcs8])
    func encryptedPEMKeyMapsThePassphraseFailures(format: PEMFixtures.Format) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = try await PEMFixtures.sshKeygen(
            type: "rsa", bits: 2048, format: format,
            passphrase: Self.pemPassphrase, in: dir)

        #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: nil)
        }
        let wrong = "not-the-" + Self.pemPassphrase
        #expect(throws: SSHKeyError.wrongPassphrase) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: keyPath, passphrase: wrong)
        }
        // The positive half, as in the OpenSSH twin above: the same file
        // opens with the right passphrase, so both refusals are about the
        // passphrase and not about PEM.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: keyPath, passphrase: Self.pemPassphrase)
    }
}
