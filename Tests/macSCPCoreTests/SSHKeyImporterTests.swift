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

    private func keygen(_ args: [String]) async throws {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: args)
        #expect(result.status == 0)
    }

    @Test func inspectsAnUnencryptedEd25519Key() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519")
        try await keygen(["-t", "ed25519", "-f", key.path, "-N", "", "-q", "-C", "import-test"])

        let info = try SSHKeyImporter.inspect(privateKeyURL: key, passphrase: nil)
        #expect(info.type == .ed25519)
        #expect(info.fingerprint.hasPrefix("SHA256:"))
        #expect(info.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        // The inspected key must load through the existing loader.
        _ = try SSHPrivateKeyLoader.authentication(username: "t", keyPath: key.path, passphrase: nil)
    }

    @Test func encryptedKeyNeedsThePassphrase() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519")
        try await keygen(["-t", "ed25519", "-f", key.path, "-N", "s3cr3t", "-q"])

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
    @Test func fingerprintMatchesThePublicKeyEvenWithAStaleSiblingPubFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let keyA = dir.appendingPathComponent("id_ed25519_a")
        try await keygen(["-t", "ed25519", "-f", keyA.path, "-N", "", "-q", "-C", "key-a"])

        let keyB = dir.appendingPathComponent("id_ed25519_b")
        try await keygen(["-t", "ed25519", "-f", keyB.path, "-N", "", "-q", "-C", "key-b"])

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

    /// `info(fromPublicKeyLine:)` used to take `type` from the line's PREFIX
    /// TEXT and `fingerprint` from the blob, with nothing tying the two
    /// together. A crafted line could therefore pair an "ED25519 /
    /// connectable" badge with an RSA key's fingerprint — two halves of two
    /// different keys shown as one. An OpenSSH key blob names its own
    /// algorithm in its first field, so the prefix is checkable against it.
    @Test func aPublicKeyLineWhoseTypeContradictsItsBlobIsRejected() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rsa = dir.appendingPathComponent("id_rsa")
        try await keygen(["-t", "rsa", "-b", "2048", "-f", rsa.path, "-N", "", "-q", "-C", "rsa-key"])
        let rsaLine = try String(contentsOf: URL(fileURLWithPath: rsa.path + ".pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = String(rsaLine.split(separator: " ")[1])

        // Honest line: RSA prefix, RSA blob.
        #expect(try SSHKeyImporter.info(fromPublicKeyLine: rsaLine).type == .rsa(bits: 0))
        // Forged line: the RSA blob relabelled as ed25519.
        #expect(throws: SSHKeyImporter.SSHKeyImportError.unreadable) {
            _ = try SSHKeyImporter.info(fromPublicKeyLine: "ssh-ed25519 \(blob) rsa-key")
        }
        // A certificate blob is not a plain key either, and its
        // `ssh-ed25519-cert-v01@openssh.com` name must not pass as ed25519.
        #expect(throws: (any Error).self) {
            _ = try SSHKeyImporter.info(
                fromPublicKeyLine: "ssh-ed25519-cert-v01@openssh.com \(blob) rsa-key")
        }
    }

    /// The identity an `openssh-key-v1` FILE carries in cleartext, read with
    /// no passphrase — the check `EmbeddedKeyPorter` needs for an encrypted
    /// key imported without its passphrase.
    @Test func fingerprintOfAPrivateKeyFileReadsTheFileEvenWhenEncrypted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519")
        try await keygen(["-t", "ed25519", "-f", key.path, "-N", "s3cr3t", "-q", "-C", "enc"])
        let expected = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let blob = String(expected.split(separator: " ")[1])
        // The sibling `.pub` is what `ssh-keygen -l -f` would rather read, so
        // it has to be gone before the private file can be asked about itself.
        try FileManager.default.removeItem(atPath: key.path + ".pub")

        #expect(try SSHKeyImporter.fingerprint(ofPrivateKeyFileAt: key)
            == HostKeyFingerprint.sha256(ofKeyBlobBase64: blob))

        // Not a key file at all: no fingerprint, and never a guess.
        let junk = dir.appendingPathComponent("junk")
        try Data("NOT A KEY AT ALL".utf8).write(to: junk)
        #expect(throws: SSHKeyImporter.SSHKeyImportError.unsupportedOrEncrypted) {
            _ = try SSHKeyImporter.fingerprint(ofPrivateKeyFileAt: junk)
        }
    }

    /// The M18 trap, closed by construction this time: `ssh-keygen -l -f`
    /// silently prefers a sibling `.pub`, so a foreign one next to the private
    /// key makes it report a DIFFERENT key's fingerprint. The caller cannot
    /// tell, so the sibling is refused outright rather than read around. Today
    /// no macSCP code writes a `.pub` beside a materialized key; the day one
    /// does, this fails loudly instead of quietly weakening the check.
    @Test func fingerprintOfAPrivateKeyFileRefusesToReadASiblingPubFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let keyA = dir.appendingPathComponent("id_ed25519_a")
        try await keygen(["-t", "ed25519", "-f", keyA.path, "-N", "s3cr3t", "-q", "-C", "key-a"])
        let keyB = dir.appendingPathComponent("id_ed25519_b")
        try await keygen(["-t", "ed25519", "-f", keyB.path, "-N", "", "-q", "-C", "key-b"])

        // Key B's public line planted next to key A's private key: exactly what
        // `-l -f` would report instead of key A.
        try FileManager.default.removeItem(atPath: keyA.path + ".pub")
        try FileManager.default.copyItem(
            atPath: keyB.path + ".pub", toPath: keyA.path + ".pub")

        #expect(throws: SSHKeyImporter.SSHKeyImportError.publicKeySiblingPresent) {
            _ = try SSHKeyImporter.fingerprint(ofPrivateKeyFileAt: keyA)
        }
    }
}
