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

    // MARK: - M11d final review, Finding C-1 (CRITICAL): a comma-only guard
    // on the jump host/username is not enough. `ssh -J` turns a jump host
    // into an implicit `ProxyCommand` that IT EXECUTES via `/bin/sh -c`
    // WITHOUT validating it for shell metacharacters (unlike the target
    // host/user, which ssh DOES validate) — the reviewer reproduced real
    // local command execution on OpenSSH_10.2p1 with each of:
    //   - "ju@$(>PWNED_SUBST)nx1.invalid"      (command substitution)
    //   - "ju@`>PWNED_BACKTICK`nx1.invalid"    (backticks)
    //   - "ju@nx1.invalid -oProxyCommand=>PWNED_OPT" (a bare space smuggles
    //     an extra -o option into the inner ssh invocation)
    // The comma-only guard is replaced by a strict WHITELIST (ASCII
    // letters/digits, `.`, `-`, `_`, `:`, `%` for hosts; ASCII
    // letters/digits, `.`, `-`, `_` for usernames; no leading `-` in
    // either) applied in `SSHConnectionConfig.init` — the one source of
    // Jump validation — AND, defense in depth, to the TARGET host/username
    // too, so macSCP does not depend on the local `ssh` build's own
    // argument handling. This closes the earlier deliberate asymmetry: a
    // comma in the target host/username is REJECTED now as well (it isn't
    // in the whitelist), even though ssh itself never comma-splits the
    // target's positional destination argument.

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

    @Test func commaInTargetHostOrUsernameNowThrowsToo() {
        // Was "commaInTargetHostOrUsernameIsAllowed" (M11d fix round 1):
        // the earlier asymmetry justified NOT restricting the target,
        // because ssh's positional destination argument is never
        // comma-split the way `-J`'s destination spec is. C-1's whitelist
        // is applied uniformly for defense in depth, so a comma is
        // rejected here too now — this fixture is the exact "existing test
        // uses a value outside the whitelist" case the review asked to be
        // reported rather than have the rule weakened for.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "a,b.example.com", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "ti,m", auth: .password("x"))
        }
    }

    // MARK: - C-1: the reviewer's three reproduced-on-real-ssh payloads,
    // each asserted to throw at construction (no ssh invoked — the point
    // of this whitelist is that these values never reach ssh at all).

    @Test func reproducedPayloadCommandSubstitutionThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "$(>PWNED_SUBST)nx1.invalid", username: "ju", auth: .password("x")))
        }
    }

    @Test func reproducedPayloadBacktickThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "`>PWNED_BACKTICK`nx1.invalid", username: "ju", auth: .password("x")))
        }
    }

    @Test func reproducedPayloadSmuggledOptionViaSpaceThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "nx1.invalid -oProxyCommand=>PWNED_OPT", username: "ju", auth: .password("x")))
        }
    }

    // MARK: - C-1: one case per metacharacter class, for all four fields
    // (jump host, jump username, target host, target username).

    @Test(arguments: [
        " ", "\t", "\n", "\u{0}", "\"", "'", "$", "`", ";", "&", "<", ">",
        "|", "(", ")", "{", "}", "\\", ",", "/",
    ])
    func metacharacterInJumpHostThrows(char: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "host\(char)name", username: "j", auth: .password("x")))
        }
    }

    @Test(arguments: [
        " ", "\t", "\"", "'", "$", "`", ";", "&", "<", ">", "|", "(", ")",
        "{", "}", "\\", ",", "/", ":", "%",
    ])
    func metacharacterInJumpUsernameThrows(char: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "user\(char)name", auth: .password("x")))
        }
    }

    @Test(arguments: [
        " ", "\t", "\"", "'", "$", "`", ";", "&", "<", ">", "|", "(", ")",
        "{", "}", "\\", ",", "/",
    ])
    func metacharacterInTargetHostThrows(char: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "host\(char)name", username: "tim", auth: .password("x"))
        }
    }

    @Test(arguments: [
        " ", "\t", "\"", "'", "$", "`", ";", "&", "<", ">", "|", "(", ")",
        "{", "}", "\\", ",", "/", ":", "%",
    ])
    func metacharacterInTargetUsernameThrows(char: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "user\(char)name", auth: .password("x"))
        }
    }

    @Test func leadingDashRejectedInAllFourFields() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "-oProxyCommand=x", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "-tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "-oProxyCommand=x", username: "j", auth: .password("x")))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "-j", auth: .password("x")))
        }
    }

    // MARK: - C-1 regression: ordinary values must still be accepted, for
    // both target and jump.

    @Test(arguments: [
        "example.com", "192.168.0.1", "2001:db8::1", "fe80::1%en0", "my-host_1",
    ])
    func ordinaryHostValuesAreAccepted(host: String) throws {
        let config = try SSHConnectionConfig(host: host, username: "tim", auth: .password("x"))
        #expect(config.host == host)
        let withJump = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: host, username: "deploy", auth: .password("x")))
        #expect(withJump.jump?.host == host)
    }

    @Test(arguments: ["deploy", "user.name", "my-host_1"])
    func ordinaryUsernameValuesAreAccepted(username: String) throws {
        let config = try SSHConnectionConfig(host: "example.com", username: username, auth: .password("x"))
        #expect(config.username == username)
        let withJump = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: "b", username: username, auth: .password("x")))
        #expect(withJump.jump?.username == username)
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
