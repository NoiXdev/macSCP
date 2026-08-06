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
            name: "test", host: "example.test", username: "user",
            authKind: authKind, kind: kind,
            s3: kind == .s3
                ? StoredS3Config(
                    accessKeyID: "id", region: "r", endpoint: "https://example.test",
                    bucket: "b", usePathStyle: true)
                : nil,
            webdav: kind == .webdav
                ? StoredWebDAVConfig(
                    baseURL: "https://example.test/dav", username: "user",
                    useNextcloudPath: false)
                : nil)
    }

    /// The environment-variable name is a property of the backend, not a
    /// branch in the CLI. S3 keeps the AWS-conventional name so existing
    /// pipelines need not relearn one.
    @Test func eachBackendNamesItsOwnEnvironmentVariable() {
        #expect(BackendDescriptor.descriptor(for: .s3).secretEnvironmentVariable
            == "AWS_SECRET_ACCESS_KEY")
        #expect(BackendDescriptor.descriptor(for: .webdav).secretEnvironmentVariable
            == "MACSCP_PASSWORD")
        #expect(BackendDescriptor.descriptor(for: .ssh).secretEnvironmentVariable
            == "MACSCP_PASSWORD")
    }

    /// A WebDAV session's chain, which had no test of its own before: same
    /// order as SSH's, and the same variable name (WebDAV authenticates with a
    /// plain password, so no third name was invented for it).
    @Test func aWebDAVSessionUsesTheSSHVariableNameInTheSameOrder() {
        let sources = secretSources(
            for: makeSession(kind: .webdav), passwordCommand: "echo x",
            keychainStore: InMemorySecretStore())
        #expect(sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain",
        ])
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
        let bare = StoredSession(
            name: "test", host: "h", username: "u", authKind: .password, kind: .s3)
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
