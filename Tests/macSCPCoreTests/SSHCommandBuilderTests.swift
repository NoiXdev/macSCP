import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHCommandBuilder")
struct SSHCommandBuilderTests {
    @Test func passwordAuthOnlyUsesLoginAndHost() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(SSHCommandBuilder.arguments(for: config) == ["-l", "tim", "example.com"])
    }

    @Test func nonDefaultPortAddsDashP() throws {
        let config = try SSHConnectionConfig(host: "example.com", port: 2222, username: "tim", auth: .password("x"))
        #expect(SSHCommandBuilder.arguments(for: config) == ["-p", "2222", "-l", "tim", "example.com"])
    }

    @Test func privateKeyAddsIdentity() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/k", passphrase: "geheim"))
        let args = SSHCommandBuilder.arguments(for: config)
        #expect(args == ["-l", "tim", "-i", "/k", "example.com"])

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
        #expect(SSHCommandBuilder.arguments(for: config) == ["-l", "tim", "-J", "j@b", "example.com"])

        let configNonDefaultPort = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("x"),
            jump: .init(host: "b", port: 2022, username: "j", auth: .password("x")))
        #expect(SSHCommandBuilder.arguments(for: configNonDefaultPort) == ["-l", "tim", "-J", "j@b:2022", "example.com"])
    }

    @Test func jumpAndKeyTogether() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/k", passphrase: nil),
            jump: .init(host: "b", username: "j", auth: .password("x")))
        let args = SSHCommandBuilder.arguments(for: config)
        #expect(args == ["-l", "tim", "-i", "/k", "-J", "j@b", "example.com"])
    }

    @Test(arguments: [
        // (keyPath, username, host)
        ("/pfad mit leer/id", "tim", "example.com"),
        ("/k", "ti'm", "example.com"),
        ("/k", "tim", "a;rm -rf /"),
        ("/k", "tim", "$(whoami)"),
        ("/k", "tim", "`id`"),
    ])
    func quotingIsSafe(keyPath: String, username: String, host: String) throws {
        let config = try SSHConnectionConfig(
            host: host, username: username,
            auth: .privateKey(keyPath: keyPath, passphrase: nil))
        let shell = SSHCommandBuilder.shellCommand(for: config)

        // Requirement 3: every argument is fully wrapped in single quotes, with
        // embedded single quotes escaped as '\''. Round-trip the generated
        // string through a POSIX-shell word split and require it to reproduce
        // arguments(for:) exactly — this is what proves shell metacharacters
        // in the host/username/key path never take effect.
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
