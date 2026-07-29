import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHCommandBuilder")
struct SSHCommandBuilderTests {
    @Test func passwordAuthOnlyUsesLoginAndHost() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(SSHCommandBuilder.arguments(for: config) == ["-l", "tim", "--", "example.com"])
    }

    @Test func nonDefaultPortAddsDashP() throws {
        let config = try SSHConnectionConfig(host: "example.com", port: 2222, username: "tim", auth: .password("x"))
        #expect(SSHCommandBuilder.arguments(for: config) == ["-p", "2222", "-l", "tim", "--", "example.com"])
    }

    @Test func privateKeyAddsIdentity() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/k", passphrase: "geheim"))
        let args = SSHCommandBuilder.arguments(for: config)
        #expect(args == ["-l", "tim", "-i", "/k", "--", "example.com"])

        // Requirement 2: the passphrase never leaves the builder in any output.
        let shell = SSHCommandBuilder.shellCommand(for: config)
        #expect(!shell.contains("geheim"))
        let script = SSHCommandBuilder.scriptContents(for: config)
        #expect(!script.contains("geheim"))
    }

    @Test func agentAuthAddsNothing() throws {
        let agentConfig = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .agent)
        let passwordConfig = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(SSHCommandBuilder.arguments(for: agentConfig) == SSHCommandBuilder.arguments(for: passwordConfig))
    }

    @Test func jumpAddsDashJ() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: "b", username: "j", auth: .password("x")))
        #expect(SSHCommandBuilder.arguments(for: config) == ["-l", "tim", "-J", "j@b", "--", "example.com"])

        let configNonDefaultPort = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: "b", port: 2022, username: "j", auth: .password("x")))
        #expect(
            SSHCommandBuilder.arguments(for: configNonDefaultPort)
                == ["-l", "tim", "-J", "j@b:2022", "--", "example.com"])
    }

    @Test func jumpAndKeyTogether() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/k", passphrase: nil),
            jump: .init(host: "b", username: "j", auth: .password("x")))
        let args = SSHCommandBuilder.arguments(for: config)
        #expect(args == ["-l", "tim", "-i", "/k", "-J", "j@b", "--", "example.com"])
    }

    // MARK: - Finding 1 (M11d fix round 1): a host that looks like an ssh
    // option must never be parsed as one.

    @Test func dashDashPrecedesHostDirectly() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        let args = SSHCommandBuilder.arguments(for: config)
        #expect(args.count >= 2)
        #expect(args[args.count - 2] == "--")
        #expect(args[args.count - 1] == config.host)
    }

    @Test func hostileHostIsRejectedBeforeEverReachingCommandBuilder() {
        // Was "hostileHostIsNeverParsedAsAnOption" (M11d fix round 1): it
        // used to construct these configs directly and inspect
        // `SSHCommandBuilder`'s `--`-based argv shape as a defense-in-depth
        // layer. M11d final review, C-1 closes this off one layer earlier —
        // `SSHConnectionConfig.init`'s strict host whitelist now refuses to
        // construct ANY host starting with `-` (or containing shell
        // metacharacters like `=`, `/`) at all, so a value like this can no
        // longer reach `SSHCommandBuilder` in the first place. The `--`
        // placement itself is untouched (see `dashDashPrecedesHostDirectly`
        // above) and remains a second, structural line of defense even
        // though the whitelist makes it unreachable via the public API today.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            // "-V" makes real ssh print its version and exit 0 instead of
            // connecting, if it ever reached ssh as a bare leading-dash token.
            _ = try SSHConnectionConfig(host: "-V", username: "tim", auth: .password("x"))
        }
        #expect(throws: SSHConnectionConfig.ConfigError.invalidHost) {
            // "-oProxyCommand=..." is the classic ssh-option-injection
            // escalation path.
            _ = try SSHConnectionConfig(host: "-oProxyCommand=/bin/sh", username: "tim", auth: .password("x"))
        }
    }

    // MARK: - Finding 2 (M11d fix round 1): `ssh -J` splits its destination
    // spec on `,` itself, so a jump host/username containing a comma would
    // smuggle in an extra, unapproved hop that ssh contacts first. The
    // rejection lives in `SSHConnectionConfig.init` (the one source of Jump
    // validation) — this proves the config refuses to build at all, so
    // `SSHCommandBuilder` never even sees a comma-bearing jump value.

    @Test func commaInJumpHostRefusesToBuildConfig() {
        // Verified against real ssh: `-J 'j@attacker.example,realjump.example'`
        // connects to attacker.example FIRST, an extra unapproved hop ssh
        // inserts by splitting the destination spec on the comma itself.
        #expect(throws: SSHConnectionConfig.ConfigError.invalidJumpHost) {
            _ = try SSHConnectionConfig(
                host: "example.com", username: "tim", auth: .password("x"),
                jump: .init(host: "attacker.example,realjump.example", username: "j", auth: .password("x")))
        }
    }

    @Test(arguments: [
        // Only `keyPath` varies now (M11d final review, C-1): the
        // host/username hostile forms this used to cover ("ti'm",
        // "a;rm -rf /", "$(whoami)", "`id`") are rejected earlier, at
        // construction, by `SSHConnectionConfig`'s own whitelist — they can
        // no longer reach this layer at all. `keyPath` has no whitelist
        // (a private-key path is free-form filesystem text), so it's the
        // one field left that still needs the shell-quoting layer proven
        // safe against metacharacters/spaces/quotes.
        "/pfad mit leer/id",
        "/k'k",
        "/k;rm -rf /",
        "/k$(whoami)",
        "/k`id`",
    ])
    func quotingIsSafe(keyPath: String) throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: keyPath, passphrase: nil))
        let shell = SSHCommandBuilder.shellCommand(for: config)

        // Requirement 3: every argument is fully wrapped in single quotes, with
        // embedded single quotes escaped as '\''. Round-trip the generated
        // string through a POSIX-shell word split and require it to reproduce
        // arguments(for:) exactly — this is what proves shell metacharacters
        // in the key path never take effect.
        let words = posixShellSplit(shell)
        #expect(words.first == "ssh")
        #expect(Array(words.dropFirst()) == SSHCommandBuilder.arguments(for: config))
    }

    @Test func scriptContentsShape() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/k", passphrase: "geheim"))
        let script = SSHCommandBuilder.scriptContents(for: config)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "#!/bin/sh")

        let removeLineIndex = lines.firstIndex(where: { $0.contains("rm -f -- \"$0\"") })
        let execLineIndex = lines.firstIndex(where: { $0.hasPrefix("exec ") })
        #expect(removeLineIndex != nil)
        #expect(execLineIndex != nil)
        if let removeLineIndex, let execLineIndex {
            #expect(removeLineIndex < execLineIndex)
        }

        let execOccurrences = script.components(separatedBy: "exec ssh").count - 1
        #expect(execOccurrences == 1)

        #expect(!script.contains("geheim"))
    }
}

/// Test-only POSIX-lite shell word splitter: splits on unquoted whitespace,
/// treats `'...'` as a literal (no escapes inside), and treats a backslash
/// outside single quotes as escaping the next character. This mirrors real
/// POSIX shell quote-removal rules for the subset of syntax
/// `SSHCommandBuilder` ever emits, and is exactly the mechanism that proves
/// wrapping each argument in single quotes prevents metacharacters from
/// taking effect: whatever the generator escaped, this must undo losslessly.
private func posixShellSplit(_ command: String) -> [String] {
    var words: [String] = []
    var current = ""
    var hasCurrent = false
    var inSingleQuote = false
    var iterator = command.makeIterator()

    while let char = iterator.next() {
        if inSingleQuote {
            if char == "'" {
                inSingleQuote = false
            } else {
                current.append(char)
            }
            continue
        }
        switch char {
        case "'":
            inSingleQuote = true
            hasCurrent = true
        case "\\":
            if let escaped = iterator.next() {
                current.append(escaped)
                hasCurrent = true
            }
        case " ", "\t":
            if hasCurrent {
                words.append(current)
                current = ""
                hasCurrent = false
            }
        default:
            current.append(char)
            hasCurrent = true
        }
    }
    if hasCurrent {
        words.append(current)
    }
    return words
}
