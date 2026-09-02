import Foundation
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

    @Test("an RSA key is named RSA, not 'unsupported'")
    func rsaKeyIsNamed() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.typeNotLoadable(algorithm: "RSA")) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    @Test("an ECDSA key is named with its curve", arguments: [(256, "ECDSA P-256"), (384, "ECDSA P-384"), (521, "ECDSA P-521")])
    func ecdsaKeyIsNamed(bits: Int, expected: String) throws {
        let (dir, keyPath) = try makeKey(type: "ecdsa", extra: ["-b", String(bits)])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.typeNotLoadable(algorithm: expected)) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
    }

    /// The header is cleartext even when the private half is encrypted, so an
    /// encrypted RSA key is named BEFORE anyone is asked for a passphrase — the
    /// order that used to produce "passphrase required" for a key that could
    /// never have been used.
    @Test("an encrypted RSA key is named without a passphrase")
    func encryptedRSAKeyIsNamedFirst() throws {
        let (dir, keyPath) = try makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SSHKeyError.typeNotLoadable(algorithm: "RSA")) {
            _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
        }
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
