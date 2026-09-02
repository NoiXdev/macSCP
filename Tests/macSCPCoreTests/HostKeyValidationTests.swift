import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import macSCPCore

@Suite("HostKeyValidation")
struct HostKeyValidationTests {
    private let candidate = HostKeyCandidate(
        host: "example.com", port: 22,
        keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")

    @Test func unknownHostAsksUser() {
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: nil) == .askUser)
    }

    @Test func knownIdenticalKeyAccepts() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known) == .accept)
    }

    @Test func knownDifferentKeyIsMismatch() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "TEVFUlpFSUxF")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known)
            == .mismatch(expected: known.fingerprintSHA256))
    }
}

/// The validator itself, not just its decision function: it is the piece
/// that reads the known-hosts store during the handshake, and the read is
/// the one step in the SSH TOFU path that can fail from outside.
/// `WebDAVSessionDelegate` has the same guard tested on its side; this is
/// the missing twin.
@Suite("TOFUHostKeyValidator")
struct TOFUHostKeyValidatorTests {
    /// A real key, generated at runtime — no key material in the repo, the
    /// rule `HostKeyFingerprintTests` already follows.
    private func makeHostKey() async throws -> NIOSSHPublicKey {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("id_ed25519")
        let keygenResult = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                        "-N", "", "-q", "-C", "tofu-test"])
        #expect(keygenResult.status == 0)
        let pubLine = try String(
            contentsOfFile: keyURL.path(percentEncoded: false) + ".pub", encoding: .utf8)
        return try NIOSSHPublicKey(openSSHPublicKey: pubLine)
    }

    private func makeStoreDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the hook and reports both halves of its answer: what the box
    /// carries outward, and whether the handshake was allowed to continue.
    private func runValidator(
        store: KnownHostsStore, key: NIOSSHPublicKey
    ) -> (result: HostKeyProbeResult?, accepted: Bool) {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Void.self)
        let box = TOFUHostKeyValidator.Box()
        let validator = TOFUHostKeyValidator(
            host: "nas.local", port: 22, knownHosts: store, box: box)
        let accepted = OutcomeBox()
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        promise.futureResult.whenComplete { accepted.value = (try? $0.get()) != nil }
        loop.run()
        return (box.result, accepted.value)
    }

    /// A corrupt store must fail closed as `.lookupFailed` — NEVER as
    /// `.unknown`. The downgrade is what would be dangerous: an unreadable
    /// store would re-run TOFU and overwrite the remembered key, so
    /// `HostKeyError.mismatch` — the hard stop — could never fire for that
    /// host again.
    @Test func corruptStoreFailsClosedInsteadOfLookingUnknown() async throws {
        let dir = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not valid json".write(to: dir.appendingPathComponent("known_hosts.json"),
                                   atomically: true, encoding: .utf8)

        let (result, accepted) = runValidator(
            store: KnownHostsStore(directory: dir), key: try await makeHostKey())

        #expect(accepted == false)
        guard case .lookupFailed(let reason) = try #require(result) else {
            Issue.record("expected .lookupFailed, got \(String(describing: result))")
            return
        }
        // The verdict's text is shown to a person, so it is held to the
        // same standard as the write side's. `JSONSerialization` throws an
        // `NSError` and `JSONDecoder` hands it on inside
        // `DecodingError.dataCorrupted` — so a stringified `DecodingError`
        // prints a Foundation `userInfo` table even though the enum itself
        // has none. Naming the case is what survives that.
        #expect(reason.contains("dataCorrupted"))
        #expect(!reason.contains("UserInfo="))
        #expect(!reason.contains("NSDebugDescription"))
    }

    /// The other half of the same argument, and the reason a blanket switch
    /// to `localizedDescription` would have been a loss: a store that IS
    /// valid JSON but the wrong shape has something specific to say, and
    /// `localizedDescription` says only that the data is missing. The
    /// coding path is macSCP's own — its `Codable` keys and the file's own
    /// indices — so it can be printed without printing Foundation's table.
    @Test func wronglyShapedStoreNamesTheMissingKeyAndItsPath() async throws {
        let dir = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"[{"host":"nas.local","port":22,"publicKeyBase64":"QUJD"}]"#
            .write(to: dir.appendingPathComponent("known_hosts.json"),
                   atomically: true, encoding: .utf8)

        let (result, accepted) = runValidator(
            store: KnownHostsStore(directory: dir), key: try await makeHostKey())

        #expect(accepted == false)
        guard case .lookupFailed(let reason) = try #require(result) else {
            Issue.record("expected .lookupFailed, got \(String(describing: result))")
            return
        }
        #expect(reason == "keyNotFound at [0].keyType")
    }

    /// The control for the test above: a store that reads fine and simply
    /// holds nothing yields `.unknown` — the arm that leads to the prompt.
    /// Without this, "fails closed" could just be the validator refusing
    /// everything.
    @Test func readableEmptyStoreReportsUnknownAndAsks() async throws {
        let dir = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (result, accepted) = runValidator(
            store: KnownHostsStore(directory: dir), key: try await makeHostKey())

        #expect(accepted == false)   // the hook cannot await; the box carries the question
        guard case .unknown = try #require(result) else {
            Issue.record("expected .unknown, got \(String(describing: result))")
            return
        }
    }

    /// A remembered, identical key is accepted inside the hook and leaves
    /// the box empty — nothing to ask, nothing to report.
    @Test func rememberedIdenticalKeyIsAcceptedSilently() async throws {
        let dir = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await makeHostKey()
        let candidate = HostKeyCandidate(host: "nas.local", port: 22, publicKey: key)
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "nas.local", port: 22, keyType: candidate.keyType,
            publicKeyBase64: candidate.publicKeyBase64))

        let (result, accepted) = runValidator(store: store, key: key)

        #expect(accepted == true)
        #expect(result == nil)
    }
}

/// Minimal mutable box for capturing the promise's outcome out of an
/// escaping completion closure.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
