import Foundation
import Testing
@testable import macSCPCore

/// The CLI's secret seams, once they read from `BackendDescriptor` instead of
/// switching over `ConnectionKind` themselves (M22/T10).
///
/// `BackendDescriptorTests` already pins `requiresSecret` as a property of the
/// descriptors; what this suite adds is the CLI SIDE of it — that
/// `secretSources(for:passwordCommand:keychainStore:)` converts a
/// `StoredSession` through the RIGHT backend's adapter before asking, which is
/// the one way this refactor could silently lose the agent-auth guard.
@Suite("CLISecretSources schema")
struct CLISecretSourcesSchemaTests {
    private func makeSession(
        kind: ConnectionKind, authKind: StoredSession.AuthKind = .password
    ) -> StoredSession {
        StoredSession(
            name: "test", kind: kind,
            // SSH's fields only for an SSH session (M23/T8): `authKind` is
            // what the agent guard reads, and it now lives where the guard
            // can only reach it through the SSH block.
            ssh: kind == .ssh
                ? StoredSSHConfig(
                    host: "example.test", username: "user", authKind: authKind)
                : nil,
            s3: kind == .s3
                ? StoredS3Config(
                    accessKeyID: "id", region: "r", endpoint: "https://example.test",
                    bucket: "b", usePathStyle: true)
                : nil,
            webdav: kind == .webdav
                ? StoredWebDAVConfig(
                    baseURL: "https://example.test/dav", username: "user",
                    useNextcloudPath: false)
                : nil,
            ftp: kind == .ftp
                ? StoredFTPConfig(
                    host: "example.test", port: 21, username: "user",
                    security: .explicitTLS)
                : nil)
    }

    /// The environment-variable name is a property of the backend, not a
    /// branch in the CLI. S3 keeps the AWS-conventional name so existing
    /// pipelines need not relearn one.
    ///
    /// **Compared over `ConnectionKind.allCases`, never listed**, which is
    /// what that first sentence has always argued for and what this test did
    /// not do until 2026-11-08: it asserted `.s3`, `.webdav` and `.ssh`, read
    /// as exhaustive and was not. Nothing was unpinned at the time — FTP had
    /// `theSecretEnvironmentVariableIsNamedForFTP` beside it — but a FIFTH
    /// kind would have left this naming four of five in silence, which is the
    /// shape `everyConnectionKindHasAMatrixSuite` exists to refuse. One
    /// dictionary against another, with `expectedSecretVariable(for:)`
    /// exhaustive over the enum, so a fifth kind does not compile until
    /// someone names its variable here.
    ///
    /// The overlap with the FTP test beside it is deliberate: this one says
    /// every kind names the right VARIABLE, that one says the CLI's secret
    /// CHAIN for an FTP session is built out of it in the right order. Only
    /// names appear in either, never a value.
    @Test func eachBackendNamesItsOwnEnvironmentVariable() {
        let named = Dictionary(uniqueKeysWithValues: ConnectionKind.allCases.map {
            ($0, BackendDescriptor.descriptor(for: $0).secretEnvironmentVariable)
        })
        let expected = Dictionary(uniqueKeysWithValues: ConnectionKind.allCases.map {
            ($0, Self.expectedSecretVariable(for: $0))
        })
        #expect(named == expected)
    }

    /// The variable each backend is expected to name. EXHAUSTIVE over
    /// `ConnectionKind`; `nil` would mean a backend that takes no secret from
    /// the environment, and no backend here is one.
    private static func expectedSecretVariable(for kind: ConnectionKind) -> String? {
        switch kind {
        // The AWS convention, kept so existing pipelines need not relearn a
        // name.
        case .s3: return "AWS_SECRET_ACCESS_KEY"
        // All three authenticate with a plain password, so no second or third
        // name was invented for them.
        case .ssh, .webdav, .ftp: return "MACSCP_PASSWORD"
        }
    }

    /// FTP's variable, and the chain the CLI walks for an FTP session
    /// (FTP plan Task 10).
    ///
    /// The VARIABLE is named here; no value of any kind appears in this
    /// file. FTP authenticates with a plain password, as WebDAV does, so it
    /// reuses the same name rather than inventing a third — which is the
    /// claim worth pinning: the chain is read off the descriptor, and an FTP
    /// session that fell back to no variable at all would still walk a
    /// two-source chain and look plausible.
    ///
    /// **Green on arrival**, and said so rather than presented as a red
    /// cleared: `BackendDescriptor.ftpDescriptor` named the variable when it
    /// landed in Task 3, and `secretSources(for:passwordCommand:
    /// keychainStore:)` reads every backend's through the same field. Its
    /// sensitivity was measured with `scripts/mutation-probe` instead of
    /// asserted — see FTP plan Task 10's report.
    @Test func theSecretEnvironmentVariableIsNamedForFTP() {
        #expect(BackendDescriptor.descriptor(for: .ftp).secretEnvironmentVariable
            == "MACSCP_PASSWORD")
        let chain = secretSources(
            for: makeSession(kind: .ftp), passwordCommand: "echo x",
            keychainStore: InMemorySecretStore())
        #expect(chain.sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain",
        ])
        #expect(chain.kinds == [.passwordCommand, .environment, .keychain])
    }

    /// A WebDAV session's chain, which had no test of its own before: same
    /// order as SSH's, and the same variable name (WebDAV authenticates with a
    /// plain password, so no third name was invented for it).
    @Test func aWebDAVSessionUsesTheSSHVariableNameInTheSameOrder() {
        let chain = secretSources(
            for: makeSession(kind: .webdav), passwordCommand: "echo x",
            keychainStore: InMemorySecretStore())
        #expect(chain.sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain",
        ])
        #expect(chain.kinds == [.passwordCommand, .environment, .keychain])
    }

    /// The conversion the CLI now performs before asking `requiresSecret`:
    /// each backend reads the stored session through its OWN adapter. Asking
    /// SSH's adapter about an S3 session (or vice versa) would answer from a
    /// field the other backend never fills — the failure mode that would turn
    /// the agent-auth guard into a coin flip.
    @Test func aSessionIsReadThroughItsOwnBackendsAdapter() {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        #expect(!ssh.requiresSecret(ssh.sessionValues(makeSession(kind: .ssh, authKind: .agent))))
        #expect(ssh.requiresSecret(ssh.sessionValues(makeSession(kind: .ssh, authKind: .password))))
        // `authKind` is SSH's column; an S3 session that happens to carry
        // `.agent` in it still needs its secret access key.
        let s3 = BackendDescriptor.descriptor(for: .s3)
        #expect(s3.requiresSecret(s3.sessionValues(makeSession(kind: .s3, authKind: .agent))))
        let webdav = BackendDescriptor.descriptor(for: .webdav)
        #expect(webdav.requiresSecret(
            webdav.sessionValues(makeSession(kind: .webdav, authKind: .agent))))
    }

    /// The adapter reads the backend's own stored configuration, not just an
    /// empty bag — a session with no stored configuration still answers
    /// rather than trapping.
    @Test func theAdapterCarriesTheStoredConfigurationWhenThereIsOne() {
        let s3 = BackendDescriptor.descriptor(for: .s3)
        #expect(s3.sessionValues(makeSession(kind: .s3))[S3Field.bucket] == "b")
        let webdav = BackendDescriptor.descriptor(for: .webdav)
        #expect(webdav.sessionValues(makeSession(kind: .webdav))[WebDAVField.baseURL]
            == "https://example.test/dav")
        // `kind == .s3` with no stored S3 block is inconsistent data, not a
        // crash: the adapter yields the empty bag and `build` is what reports
        // it.
        let bare = StoredSession(name: "test", kind: .s3)
        #expect(s3.sessionValues(bare)[S3Field.bucket] == "")
    }

    /// One error case for every backend, so a fourth protocol adds no case.
    @Test func theMissingConfigurationErrorNamesItsKind() {
        let error = StoredSessionConnectionError.missingBackendConfiguration(kind: .webdav)
        #expect(error == .missingBackendConfiguration(kind: .webdav))
        #expect(error != .missingBackendConfiguration(kind: .s3))
    }

    /// The CLI's message names the protocol rather than saying "backend", so
    /// the one case still reads like the two it replaced.
    @Test func theMessageNamesTheProtocol() {
        for (kind, name) in [(ConnectionKind.s3, "S3"), (.webdav, "WebDAV"), (.ssh, "SSH")] {
            let message = CLIErrorMapping.message(
                for: StoredSessionConnectionError.missingBackendConfiguration(kind: kind))
            #expect(message.contains(name))
        }
        // Still an authentication-class failure, i.e. the documented exit
        // code does not shift under the merge.
        #expect(CLIErrorMapping.exitCode(
            for: StoredSessionConnectionError.missingBackendConfiguration(kind: .s3)) == .auth)
    }
}
