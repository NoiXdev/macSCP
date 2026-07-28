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
        let store = KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)"))
        await #expect(throws: SSHKeyError.fileNotFound(path: missing)) {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        }
    }

    // MARK: - M10c/T1: SSHConnectionConfig.Jump

    @Test func jumpDefaultsNil() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(config.jump == nil)
    }

    @Test func jumpValidatesLikeTarget() throws {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "", username: "j", auth: .password("x")))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.emptyJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "", auth: .password("x")))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpPort(0)) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", port: 0, username: "j", auth: .password("x")))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpPort(65536)) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", port: 65536, username: "j", auth: .password("x")))
        }

        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: "b", port: 22, username: "j", auth: .password("x")))
        #expect(config.jump == SSHConnectionConfig.Jump(host: "b", port: 22, username: "j", auth: .password("x")))
    }

    @Test func jumpAuthFailedIsNotConnectionFailure() {
        #expect(RemoteFSError.jumpAuthenticationFailed.isConnectionFailure == false)
    }
}
