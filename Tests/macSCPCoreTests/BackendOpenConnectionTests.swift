import Testing
@testable import macSCPCore

/// The one public way into a connection, and the property that comes with
/// making it the only one.
///
/// `descriptor(for:).connect(...)` let the caller pick a descriptor and a
/// config independently, so "SSH descriptor, S3 config" was a shape that
/// compiled and each backend's closure had to refuse at runtime. The entry
/// point derives the descriptor from `config.kind`, so that pairing is not
/// expressible through it at all — which is what the first test measures:
/// a config of every kind gets past its backend's own kind guard.
///
/// The fixtures all point at port 1 on the loopback interface, where
/// nothing listens: the dial fails immediately, and failing at the DIAL
/// rather than at the kind guard is exactly the observation.
@Suite("BackendDescriptor.openConnection")
struct BackendOpenConnectionTests {
    /// The prefix every backend's kind guard puts on its refusal. Read by
    /// both tests below — the second one is what keeps the first from
    /// passing vacuously if this sentence ever changes.
    private static let refusalPrefix = "wrong config for the"

    private static let s3Config = ConnectionConfig.s3(S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:1", bucket: "b",
        usePathStyle: true, sessionToken: nil))

    private static let configs: [ConnectionConfig] = [
        .ssh(try! SSHConnectionConfig(
            host: "127.0.0.1", port: 1, username: "u", auth: .password("p"))),
        s3Config,
        .webdav(WebDAVConnectionConfig(
            baseURL: "http://127.0.0.1:1/dav", username: "u",
            useNextcloudPath: false, password: "p")),
    ]

    @Test func everyConfigReachesTheBackendItsOwnKindNames() async {
        #expect(Set(Self.configs.map(\.kind)) == Set(ConnectionKind.allCases), """
            the fixtures no longer cover every `ConnectionKind` — a kind with no fixture is a \
            route this test does not check.
            """)
        for config in Self.configs {
            await #expect {
                _ = try await BackendDescriptor.openConnection(
                    config, hostKey: .refusing, certificate: .refusing, timeoutSeconds: 1)
            } throws: { error in
                guard case RemoteFSError.protocolError(let reason) = error else { return true }
                return !reason.hasPrefix(Self.refusalPrefix)
            }
        }
    }

    /// The positive half of the check above, which is otherwise a claim
    /// that a string does NOT appear — and a claim like that starts holding
    /// for free the moment the string is reworded. Reached through the
    /// module-internal closure on purpose: pairing a descriptor with a
    /// foreign config is the mistake the entry point removes, so producing
    /// the refusal at all now takes `@testable` access.
    @Test func theRefusalThisRecognizesIsOneABackendReallyProduces() async throws {
        await #expect {
            _ = try await BackendDescriptor.descriptor(for: .ssh)
                .connect(Self.s3Config, .refusing, .refusing, 1)
        } throws: { error in
            guard case RemoteFSError.protocolError(let reason) = error else { return false }
            return reason.hasPrefix(Self.refusalPrefix)
        }
    }
}
