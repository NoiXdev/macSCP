import Foundation
import Testing
@testable import macSCPCore

/// Test-Keys werden zur LAUFZEIT erzeugt (ssh-keygen) — nie eingecheckt.
@Suite("SSHPrivateKeyLoader")
struct SSHPrivateKeyLoaderTests {
    /// Erzeugt einen ed25519-Key im Temp-Verzeichnis; passphrase "" = unverschlüsselt.
    private func makeKey(passphrase: String) throws -> (dir: URL, keyPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("id_ed25519")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
            "-N", passphrase, "-q", "-C", "macscp-test",
        ]
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
            Issue.record("unsupportedFormat erwartet")
        } catch let error as SSHKeyError {
            guard case .unsupportedFormat = error else {
                Issue.record("unsupportedFormat erwartet, war: \(error)")
                return
            }
        }
    }
}
