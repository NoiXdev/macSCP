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

    // MARK: - M11d fix round 1, Finding 2: `ssh -J` splits its destination
    // spec on `,` itself. A jump host or username containing a comma would
    // smuggle in an extra, unapproved hop that ssh contacts first — the
    // config must refuse to build rather than let that reach
    // `SSHCommandBuilder`. (The target host/username are never split on
    // comma by ssh — see `SSHCommandBuilder`'s doc comment — so they are
    // deliberately not restricted here.)

    @Test func commaInJumpHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "attacker.example,realjump.example", username: "j", auth: .password("x")))
        }
    }

    @Test func commaInJumpUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "j,attacker", auth: .password("x")))
        }
    }

    @Test func commaInTargetHostOrUsernameIsAllowed() throws {
        // Deliberate asymmetry: `-J` is the only ssh argument split on comma
        // (it's the destination-spec syntax for chaining jump hosts). The
        // target host/username are passed as a single trailing positional
        // argument (behind `--`, never split by ssh), so a comma there
        // cannot smuggle in an extra hop and needs no rejection.
        let config = try SSHConnectionConfig(host: "a,b.example.com", username: "ti,m", auth: .password("x"))
        #expect(config.host == "a,b.example.com")
        #expect(config.username == "ti,m")
    }

    // MARK: - M11d fix round 1, Finding 3: an empty private-key path would
    // make `SSHCommandBuilder` emit a bare `-i ''` to ssh.

    @Test func emptyKeyPathThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyKeyPath) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim",
                auth: .privateKey(keyPath: "", passphrase: nil))
        }
    }

    @Test func whitespaceOnlyKeyPathThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyKeyPath) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim",
                auth: .privateKey(keyPath: "   ", passphrase: nil))
        }
    }

    @Test func emptyJumpKeyPathThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyJumpKeyPath) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(
                    host: "b", username: "j",
                    auth: .privateKey(keyPath: "", passphrase: nil)))
        }
    }
}
