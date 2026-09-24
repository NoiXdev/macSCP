import Foundation
import Testing
@testable import macSCPCore

/// `SSHKeyPassphraseTool` against the real `/usr/bin/ssh-keygen`.
///
/// Every key here is generated at runtime (`SSHKeyGenerator.generate`) into a
/// throwaway directory — no key material is committed, and nothing reads
/// `~/.ssh`. ED25519 throughout: the bcrypt KDF is what an encrypted key costs
/// on every open, and `KeyToolBound`'s own measurement (0.13 s at the default
/// `-a 16`) is an ED25519 one.
///
/// No wall-clock ceiling anywhere: the suite's `.timeLimit` is a hang bound,
/// not a speed assertion (CLAUDE.md, "A wall-clock ceiling in a test measures
/// the runner").
///
/// Passphrases live in named constants and every expectation is a `Bool`
/// computed first, so neither a value nor its spelling reaches a failure
/// message.
@Suite("SSHKeyPassphraseTool", .timeLimit(.minutes(5)))
struct SSHKeyPassphraseToolTests {
    private static let original = "fixture-tool-original"
    private static let replacement = "fixture-tool-replacement"

    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-passtool-\(UUID().uuidString)")
    }

    @Test func thePassphraseAKeyWasMadeWithOpensItAndAnotherOneDoesNot() async throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await SSHKeyGenerator.generate(
            type: .ed25519, comment: "tool-test", passphrase: Self.original, into: dir)

        let theRightOneOpensIt = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.original)
        let theOtherOneDoesNot = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.replacement)
        #expect(theRightOneOpensIt)
        #expect(theOtherOneDoesNot == false)
    }

    @Test func changingThePassphraseReEncryptsTheFile() async throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await SSHKeyGenerator.generate(
            type: .ed25519, comment: "tool-test", passphrase: Self.original, into: dir)
        let before = try Data(contentsOf: key.privateKeyURL)

        try await SSHKeyPassphraseTool.changePassphrase(
            ofKeyAt: key.privateKeyURL, from: Self.original, to: Self.replacement)

        let theNewOneOpensIt = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.replacement)
        let theOldOneNoLongerDoes = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.original)
        #expect(theNewOneOpensIt)
        #expect(theOldOneNoLongerDoes == false)
        // The bytes really were rewritten — so the two answers above are a
        // re-encryption and not a tool that quietly accepts anything.
        #expect(try Data(contentsOf: key.privateKeyURL) != before)
        #expect(SSHKeyConverter.isOpenSSHFormat(fileAt: key.privateKeyURL))
    }

    @Test func aWrongOldPassphraseLeavesTheFileExactlyAsItWas() async throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await SSHKeyGenerator.generate(
            type: .ed25519, comment: "tool-test", passphrase: Self.original, into: dir)
        let before = try Data(contentsOf: key.privateKeyURL)

        await #expect(throws: SSHKeyPassphraseTool.PassphraseToolError.failed) {
            try await SSHKeyPassphraseTool.changePassphrase(
                ofKeyAt: key.privateKeyURL, from: Self.replacement, to: Self.replacement)
        }

        #expect(try Data(contentsOf: key.privateKeyURL) == before)
        let theOriginalStillOpensIt = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.original)
        #expect(theOriginalStillOpensIt)
    }

    @Test func aKeyThatHadNoPassphraseCanBeGivenOne() async throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await SSHKeyGenerator.generate(
            type: .ed25519, comment: "tool-test", passphrase: nil, into: dir)

        try await SSHKeyPassphraseTool.changePassphrase(
            ofKeyAt: key.privateKeyURL, from: "", to: Self.replacement)

        let theNewOneOpensIt = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: Self.replacement)
        let anEmptyOneNoLongerDoes = try await SSHKeyPassphraseTool.opensKey(
            at: key.privateKeyURL, passphrase: "")
        #expect(theNewOneOpensIt)
        #expect(anEmptyOneNoLongerDoes == false)
    }

    @Test func aMissingFileIsNotReportedAsAWrongPassphrase() async throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let absent = dir.appendingPathComponent(UUID().uuidString)

        await #expect(throws: SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing) {
            _ = try await SSHKeyPassphraseTool.opensKey(at: absent, passphrase: Self.original)
        }
        await #expect(throws: SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing) {
            try await SSHKeyPassphraseTool.changePassphrase(
                ofKeyAt: absent, from: Self.original, to: Self.replacement)
        }
    }
}

/// The same two actions end to end against the REAL login keychain, which is
/// the one thing the form suite's in-memory double cannot prove: that the
/// value a correction stores is the value `ManagedKeyPassphrase.resolve` later
/// hands the dial.
///
/// Gated behind `MACSCP_KEYCHAIN=1` — it writes to and deletes from the real
/// keychain, which CI runners answer unreliably. The two cases in this suite
/// are the only gated ones this task adds.
@Suite(
    "Managed key passphrase, end to end",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_KEYCHAIN"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
@MainActor
struct ManagedKeyPassphraseEndToEndTests {
    private static let original = "fixture-e2e-original"
    private static let replacement = "fixture-e2e-replacement"

    /// A fresh store directory, a real generated key registered in it, and the
    /// test-service keychain `KeychainSecretStoreTests` already uses.
    private func rig() async throws -> (
        store: ManagedKeyStore, secrets: KeychainSecretStore, key: ManagedKey, directory: URL
    ) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-passe2e-\(UUID().uuidString)")
        let store = ManagedKeyStore(directory: directory)
        let generated = try await SSHKeyGenerator.generate(
            type: .ed25519, comment: "e2e", passphrase: Self.original, into: store.keyDirectory)
        let key = ManagedKey(
            name: "e2e", comment: "e2e", type: .ed25519, fingerprint: generated.fingerprint,
            publicKeyOpenSSH: generated.publicKeyOpenSSH, createdAt: Date(),
            hasPassphrase: true, fileName: generated.privateKeyURL.lastPathComponent)
        try store.add(key)
        return (store, KeychainSecretStore(service: "dev.noix.macSCP.test"), key, directory)
    }

    @Test func aCorrectionIsWhatTheDialLaterResolvesTo() async throws {
        let rig = try await rig()
        defer {
            try? rig.secrets.deletePassword(for: rig.key.id)
            try? FileManager.default.removeItem(at: rig.directory)
        }
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.original

        let task = try #require(
            form.start(key: rig.key, store: rig.store, secrets: rig.secrets))
        #expect(await task.value == .stored)

        let keyPath = try #require(rig.store.privateKeyURL(for: rig.key))
            .path(percentEncoded: false)
        let resolved = ManagedKeyPassphrase.resolve(
            keyPath: keyPath, typed: "", store: rig.store, secrets: rig.secrets)
        let theDialGetsTheCorrectedValue = resolved.passphrase == Self.original
        #expect(theDialGetsTheCorrectedValue)
    }

    @Test func aChangeMovesBothTheFileAndWhatTheDialResolvesTo() async throws {
        let rig = try await rig()
        defer {
            try? rig.secrets.deletePassword(for: rig.key.id)
            try? FileManager.default.removeItem(at: rig.directory)
        }
        try rig.secrets.savePassword(Self.original, for: rig.key.id)
        let form = ChangeKeyPassphraseForm()
        form.oldPassphrase = Self.original
        form.newPassphrase = Self.replacement
        form.newPassphraseConfirm = Self.replacement

        let task = try #require(
            form.start(key: rig.key, store: rig.store, secrets: rig.secrets))
        #expect(await task.value == .changed)

        let keyURL = try #require(rig.store.privateKeyURL(for: rig.key))
        let resolved = ManagedKeyPassphrase.resolve(
            keyPath: keyURL.path(percentEncoded: false), typed: "",
            store: rig.store, secrets: rig.secrets)
        let theDialGetsTheNewValue = resolved.passphrase == Self.replacement
        #expect(theDialGetsTheNewValue)
        let andItOpensTheFile = try await SSHKeyPassphraseTool.opensKey(
            at: keyURL, passphrase: resolved.passphrase)
        #expect(andItOpensTheFile)
    }
}
