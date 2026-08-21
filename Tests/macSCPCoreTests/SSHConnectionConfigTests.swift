import Foundation
import NIOCore
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
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: { _ in true })
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
        // was applied uniformly for defense in depth, so a comma was
        // rejected here too. M11d fix3 (I-3) later replaced the TARGET
        // whitelist with a ban list (see `isValidTargetHost`/
        // `isValidTargetUsername`), but `,` is still on that ban list, so
        // this assertion still holds under the new rule too.
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
        "{", "}", ",", "/",
    ])
    func metacharacterInTargetUsernameThrows(char: String) {
        // M11d fix3 (I-3): ":" and "%" moved out of this list — the new
        // target ban list (`isValidTargetUsername`) does not forbid them,
        // only the jump whitelist still does (see
        // `metacharacterInJumpUsernameThrows` above). "\\" moved out too:
        // `DOMAIN\user` is a legitimate target username, see
        // `targetUsernameAcceptsRealWorldFormats` below — it stays
        // rejected for the target HOST and for the jump username, see
        // `targetHostRejectsAtSignAndBackslashButUsernameAcceptsThem` and
        // `metacharacterInJumpUsernameThrows`.
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

    /// The same guard, with a combining mark on the `-`.
    ///
    /// `value.first` yields a `Character` — an extended grapheme cluster —
    /// so `-` followed by U+0308 was one symbol that compared unequal to
    /// `"-"`, and `host = "-̈x.com"` and `username = "-̈l"` were accepted
    /// while their undecorated forms were rejected. `ssh` and getopt read
    /// the `-` byte and the mark separately. The ban lists beside this guard
    /// had already moved onto scalars a round earlier; the guard one line
    /// above them had not.
    ///
    /// The jump fields would refuse these anyway through their whitelists
    /// (`Character.isASCII` is false for a decorated cluster), and they are
    /// asserted here so the four fields answer alike rather than two by
    /// accident.
    @Test(
        "a leading dash carrying a combining mark is rejected too",
        arguments: ["\u{0308}", "\u{FE0F}", "\u{0301}"])
    func aDecoratedLeadingDashIsRejected(mark: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(
                host: "-\(mark)oProxyCommand=x", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "-\(mark)l", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "-\(mark)x.com", username: "j", auth: .password("x")))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "-\(mark)l", auth: .password("x")))
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

    // MARK: - M11d fix3, re-review finding I-3: the whitelist above (C-1)
    // was too strict for the TARGET host/username, where no shell is ever
    // involved — the target host is positional behind `--` and the target
    // username is an `-l` argv, neither ever enters ssh's ProxyCommand
    // string. The target fields now use a BAN list
    // (`isValidTargetHost`/`isValidTargetUsername`) that still blocks every
    // shell-dangerous character but allows real-world values the old
    // whitelist rejected. The JUMP fields (`isValidJumpHost`/
    // `isValidJumpUsername`, tested above) are UNCHANGED — the jump
    // destination is the one ssh executes via `/bin/sh -c` as an implicit
    // ProxyCommand, so it keeps the strict whitelist.

    @Test(arguments: ["user@install", "DOMAIN\\user", "user+tag", "bjørn"])
    func targetUsernameAcceptsRealWorldFormats(username: String) throws {
        // A WP Engine-style SFTP username, an AD "DOMAIN\user" account on a
        // Windows SSH server, a "+"-tagged username, and a non-ASCII
        // username — all legitimate values the old whitelist rejected.
        // None of these ever enter ssh's ProxyCommand string: the target
        // username is passed as a literal `-l` argv.
        let config = try SSHConnectionConfig(host: "example.com", username: username, auth: .password("x"))
        #expect(config.username == username)
    }

    @Test(arguments: ["münchen.de", "example.com", "10.0.0.5", "2001:db8::1", "fe80::1%en0", "host_name"])
    func targetHostAcceptsIDNAndOrdinaryValues(host: String) throws {
        // An IDN host (German umlaut) plus the values already accepted
        // before this fix — the target host is positional behind `--`, so
        // it never enters ssh's ProxyCommand string either.
        let config = try SSHConnectionConfig(host: host, username: "tim", auth: .password("x"))
        #expect(config.host == host)
    }

    @Test(arguments: [
        " ", "\t", "\n", "\u{0}", "$(whoami)", "`id`", ";", "|", "&", "<", ">", "../x", "a,b",
    ])
    func targetHostStillRejectsShellDangerousValues(payload: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "host\(payload)name", username: "tim", auth: .password("x"))
        }
    }

    @Test(arguments: [
        " ", "\t", "\n", "\u{0}", "$(whoami)", "`id`", ";", "|", "&", "<", ">", "../x", "a,b",
    ])
    func targetUsernameStillRejectsShellDangerousValues(payload: String) {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "user\(payload)name", auth: .password("x"))
        }
    }

    @Test func targetHostAndUsernameStillRejectLeadingDash() {
        // Already covered by `leadingDashRejectedInAllFourFields` above;
        // this documents the exact reviewer payload for the target fields.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "-oProxyCommand=id", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "-oProxyCommand=id", auth: .password("x"))
        }
    }

    @Test func targetHostRejectsAtSignAndBackslashButUsernameAcceptsThem() {
        // The one asymmetry within the TARGET pair itself: "@" and "\"
        // can't appear in a hostname (no legitimate host needs them) but
        // are real characters in "user@install" / "DOMAIN\user" usernames
        // (see `targetUsernameAcceptsRealWorldFormats` above).
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "host@name", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            _ = try SSHConnectionConfig(host: "host\\name", username: "tim", auth: .password("x"))
        }
    }

    @Test func jumpUsernameStillRejectsAtSignDespiteTargetAcceptingIt() {
        // Intentional asymmetry: `user@install` is a legitimate TARGET
        // username (see `targetUsernameAcceptsRealWorldFormats`), but it
        // must stay rejected as a JUMP username — the jump destination is
        // the one that reaches `/bin/sh` via ssh's implicit ProxyCommand.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpUsername) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "b", username: "user@install", auth: .password("x")))
        }
    }

    @Test func jumpHostStillRejectsIDNDespiteTargetAcceptingIt() {
        // Same intentional asymmetry as above, for the host side:
        // "münchen.de" is a legitimate TARGET host but stays rejected as a
        // JUMP host.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "münchen.de", username: "j", auth: .password("x")))
        }
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
