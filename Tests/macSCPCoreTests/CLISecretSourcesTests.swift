import Foundation
import Testing
@testable import macSCPCore

@Suite("PasswordCommandSecretSource")
struct PasswordCommandSecretSourceTests {
    @Test func returnsTheCommandsOutputWithTrailingNewlineStripped() throws {
        let source = PasswordCommandSecretSource(command: "echo hunter2")
        #expect(try source.secret(for: UUID()) == "hunter2")
    }

    @Test func labelNamesTheSourceForVerboseDiagnostics() {
        #expect(PasswordCommandSecretSource(command: "echo x").label == "--password-command")
    }

    /// A non-zero exit aborts with a typed error carrying only the exit
    /// code — never the command's stdout, even when that stdout looks like
    /// it could be (or contain) a secret.
    @Test func aNonZeroExitThrowsWithoutCarryingTheOutput() {
        let source = PasswordCommandSecretSource(command: "echo hunter2; exit 1")
        #expect(throws: PasswordCommandError.commandFailed(status: 1)) {
            try source.secret(for: UUID())
        }
    }

    /// The error type itself is structurally incapable of carrying the
    /// command's output or input — this pins that invariant so a future
    /// edit can't quietly add an associated value that leaks it.
    @Test func theFailureCasesCarryNoStringPayload() {
        let cases: [PasswordCommandError] = [
            .launchFailed, .commandFailed(status: 1), .unreadableOutput,
        ]
        for failure in cases {
            let description = String(describing: failure)
            #expect(!description.contains("hunter2"))
        }
    }

    @Test func unreadableOutputThrows() {
        // A byte sequence that is not valid UTF-8.
        let source = PasswordCommandSecretSource(command: "printf '\\xff\\xfe'")
        #expect(throws: PasswordCommandError.unreadableOutput) {
            try source.secret(for: UUID())
        }
    }

    @Test func emptyOutputIsReturnedAsEmptyNotThrown() throws {
        // "did not deliver" is `SecretResolver`'s job to interpret (an empty
        // value counts as no value) — this source just reports what the
        // command actually printed.
        let source = PasswordCommandSecretSource(command: "true")
        #expect(try source.secret(for: UUID()) == "")
    }
}

@Suite("EnvironmentSecretSource")
struct EnvironmentSecretSourceTests {
    @Test func returnsTheVariablesValueWhenSet() throws {
        let source = EnvironmentSecretSource(
            variableName: "MACSCP_PASSWORD", environment: ["MACSCP_PASSWORD": "s3cr3t"])
        #expect(try source.secret(for: UUID()) == "s3cr3t")
    }

    @Test func returnsNilWhenUnset() throws {
        let source = EnvironmentSecretSource(variableName: "MACSCP_PASSWORD", environment: [:])
        #expect(try source.secret(for: UUID()) == nil)
    }

    @Test func labelNamesTheVariableForVerboseDiagnostics() {
        let source = EnvironmentSecretSource(variableName: "AWS_SECRET_ACCESS_KEY", environment: [:])
        #expect(source.label.contains("AWS_SECRET_ACCESS_KEY"))
    }
}

@Suite("KeychainSecretSource")
struct KeychainSecretSourceTests {
    @Test func delegatesToTheUnderlyingStore() throws {
        let store = InMemorySecretStore()
        let sessionID = UUID()
        try store.savePassword("from-keychain", for: sessionID)
        let source = KeychainSecretSource(store: store)
        #expect(try source.secret(for: sessionID) == "from-keychain")
    }

    @Test func propagatesAReadFailureInsteadOfSwallowingIt() {
        let source = KeychainSecretSource(store: UnreliableSecretStore(failsReads: true))
        #expect(throws: KeychainError.self) {
            try source.secret(for: UUID())
        }
    }

    @Test func labelIsKeychain() {
        #expect(KeychainSecretSource(store: InMemorySecretStore()).label == "keychain")
    }
}
