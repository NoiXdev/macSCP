import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHKeyImporter")
struct SSHKeyImporterTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-import-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func keygen(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func inspectsAnUnencryptedEd25519Key() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519")
        keygen(["-t", "ed25519", "-f", key.path, "-N", "", "-q", "-C", "import-test"])

        let info = try SSHKeyImporter.inspect(privateKeyURL: key, passphrase: nil)
        #expect(info.type == .ed25519)
        #expect(info.fingerprint.hasPrefix("SHA256:"))
        #expect(info.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        // The inspected key must load through the existing loader.
        _ = try SSHPrivateKeyLoader.authentication(username: "t", keyPath: key.path, passphrase: nil)
    }

    @Test func encryptedKeyNeedsThePassphrase() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519")
        keygen(["-t", "ed25519", "-f", key.path, "-N", "s3cr3t", "-q"])

        // Wrong/empty passphrase: public-key derivation (ssh-keygen -y) fails.
        #expect(throws: (any Error).self) {
            _ = try SSHKeyImporter.inspect(privateKeyURL: key, passphrase: nil)
        }
        let info = try SSHKeyImporter.inspect(privateKeyURL: key, passphrase: "s3cr3t")
        #expect(info.type == .ed25519)
    }

    /// `ssh-keygen -l -f <private key>` prefers a sibling `.pub` file over
    /// deriving from the private key itself. If that sibling `.pub` belongs
    /// to a DIFFERENT key, the fingerprint reported by `-l` and the public
    /// key reported by `-y` (which always reads the private key directly)
    /// end up describing two different keys. Regression coverage for that
    /// mismatch: plant key B's `.pub` next to key A's private key, then
    /// assert the returned fingerprint still matches the returned public key
    /// (i.e. both describe key A, never key B).
    @Test func fingerprintMatchesThePublicKeyEvenWithAStaleSiblingPubFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let keyA = dir.appendingPathComponent("id_ed25519_a")
        keygen(["-t", "ed25519", "-f", keyA.path, "-N", "", "-q", "-C", "key-a"])

        let keyB = dir.appendingPathComponent("id_ed25519_b")
        keygen(["-t", "ed25519", "-f", keyB.path, "-N", "", "-q", "-C", "key-b"])

        // Overwrite key A's sibling .pub with key B's .pub, simulating a
        // stale/foreign public key file sitting next to the private key.
        let pubA = URL(fileURLWithPath: keyA.path + ".pub")
        let pubB = URL(fileURLWithPath: keyB.path + ".pub")
        try FileManager.default.removeItem(at: pubA)
        try FileManager.default.copyItem(at: pubB, to: pubA)

        let info = try SSHKeyImporter.inspect(privateKeyURL: keyA, passphrase: nil)

        // The public key always comes from `-y` on the private key, so it
        // must describe key A.
        #expect(info.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        // The fingerprint must be derived from THAT SAME public key blob —
        // not from the stale sibling .pub file (which would describe key B).
        let blob = info.publicKeyOpenSSH.split(separator: " ")[1]
        let expectedFingerprint = HostKeyFingerprint.sha256(ofKeyBlobBase64: String(blob))
        #expect(info.fingerprint == expectedFingerprint)
    }
}
