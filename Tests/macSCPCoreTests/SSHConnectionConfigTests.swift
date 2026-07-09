import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHConnectionConfig")
struct SSHConnectionConfigTests {
    @Test func defaultsToPort22() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(config.port == 22)
    }

    @Test func emptyHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyHost) {
            _ = try SSHConnectionConfig(host: "", username: "tim", auth: .password("x"))
        }
    }

    @Test func emptyUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "", auth: .password("x"))
        }
    }

    @Test func whitespaceOnlyHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyHost) {
            _ = try SSHConnectionConfig(host: "   ", username: "tim", auth: .password("x"))
        }
    }

    @Test func whitespaceOnlyUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "\t", auth: .password("x"))
        }
    }

    @Test func portOutOfRangeThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidPort(70000)) {
            _ = try SSHConnectionConfig(host: "example.com", port: 70000, username: "tim", auth: .password("x"))
        }
    }

    @Test func privateKeyAuthConstructs() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "~/.ssh/id_ed25519", passphrase: nil))
        #expect(config.auth == .privateKey(keyPath: "~/.ssh/id_ed25519", passphrase: nil))
    }

    @Test func connectWithMissingKeyFileThrowsUnwrappedKeyError() async throws {
        let missing = "/tmp/macscp-kein-key-\(UUID().uuidString)"
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "tim",
            auth: .privateKey(keyPath: missing, passphrase: nil))
        await #expect(throws: SSHKeyError.fileNotFound(path: missing)) {
            _ = try await CitadelFileSystem.connect(config: config)
        }
    }
}
