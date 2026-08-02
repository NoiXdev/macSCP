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
}
