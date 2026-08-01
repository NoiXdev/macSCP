import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHKeyGenerator")
struct SSHKeyGeneratorTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-keygen-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func generatesEd25519FileWith0600AndOpenSSHPublicKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "macscp-test", passphrase: nil, into: dir)

        #expect(FileManager.default.fileExists(atPath: key.privateKeyURL.path))
        let perms = try FileManager.default.attributesOfItem(
            atPath: key.privateKeyURL.path)[.posixPermissions] as! NSNumber
        #expect(perms.int16Value == 0o600)
        #expect(key.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
    }

    @Test func generatedEd25519KeyLoadsThroughTheLoader() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "roundtrip", passphrase: nil, into: dir)
        // Roundtrip: the loader must accept our generated file.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: key.privateKeyURL.path, passphrase: nil)
    }

    @Test func passphraseProtectedKeyRequiresThePassphrase() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "enc", passphrase: "s3cr3t", into: dir)
        // Wrong/empty passphrase must fail to load.
        #expect(throws: (any Error).self) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: key.privateKeyURL.path, passphrase: nil)
        }
        // Correct passphrase loads.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: key.privateKeyURL.path, passphrase: "s3cr3t")
    }

    @Test func generatesRSAAndECDSA() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rsa = try SSHKeyGenerator.generate(
            type: .rsa(bits: 2048), comment: "r", passphrase: nil, into: dir)
        #expect(rsa.publicKeyOpenSSH.hasPrefix("ssh-rsa "))
        let ecdsa = try SSHKeyGenerator.generate(
            type: .ecdsa, comment: "e", passphrase: nil, into: dir)
        #expect(ecdsa.publicKeyOpenSSH.hasPrefix("ecdsa-"))
    }
}
