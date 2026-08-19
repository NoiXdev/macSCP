import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHConnectionConfig redaction")
struct SSHConnectionConfigRedactionTests {
    @Test func passwordPayloadIsEmptiedButTheCaseSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("hunter2"))

        // Hoisted into a Bool on purpose: `#expect` expands its receiver,
        // and an expanded auth value must never be able to carry a secret
        // into a failure message.
        let isEmptiedPassword: Bool
        if case .password(let value) = config.redactingSecrets().auth {
            isEmptiedPassword = value.isEmpty
        } else {
            isEmptiedPassword = false
        }
        #expect(isEmptiedPassword)
    }

    @Test func privateKeyKeepsItsPathAndLosesItsPassphrase() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"))

        let keepsPathWithoutPassphrase: Bool
        if case .privateKey(let keyPath, let passphrase) = config.redactingSecrets().auth {
            keepsPathWithoutPassphrase = keyPath == "/keys/id_ed25519" && passphrase == nil
        } else {
            keepsPathWithoutPassphrase = false
        }
        #expect(keepsPathWithoutPassphrase)
    }

    @Test func agentAuthIsUnchanged() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .agent)
        #expect(config.redactingSecrets().auth == .agent)
    }

    @Test func theJumpHopIsRedactedToo() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .agent,
            jump: SSHConnectionConfig.Jump(
                host: "bastion.example.com", port: 2222, username: "hop",
                auth: .password("hunter2")))

        let jump = config.redactingSecrets().jump
        let isEmptiedJumpPassword: Bool
        if case .password(let value) = jump?.auth {
            isEmptiedJumpPassword = value.isEmpty
        } else {
            isEmptiedJumpPassword = false
        }
        #expect(isEmptiedJumpPassword)
        #expect(jump?.host == "bastion.example.com")
        #expect(jump?.port == 2222)
        #expect(jump?.username == "hop")
    }

    @Test func everyNonSecretFieldSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim", auth: .password("hunter2"))
        let redacted = config.redactingSecrets()

        #expect(redacted.host == "example.com")
        #expect(redacted.port == 2200)
        #expect(redacted.username == "tim")
    }

    /// The property that actually matters for the one caller: redaction
    /// changes nothing the external-terminal path can observe, because that
    /// path never reads a secret in the first place.
    @Test func theGeneratedScriptIsUnchangedByRedaction() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"),
            jump: SSHConnectionConfig.Jump(
                host: "bastion.example.com", port: 2222, username: "hop",
                auth: .password("hunter2")))

        #expect(
            SSHCommandBuilder.scriptContents(for: config.redactingSecrets())
                == SSHCommandBuilder.scriptContents(for: config))
    }
}
