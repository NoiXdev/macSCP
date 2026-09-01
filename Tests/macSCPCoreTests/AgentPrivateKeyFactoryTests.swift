import Foundation
import Testing
@testable import macSCPCore

/// `AgentPrivateKeyFactory.supports(keyType:)` and `.privateKey(for:client:)`
/// used to be two separate literals — a `Set` and a `switch` naming the same
/// five key types. A rename could pull them apart silently: `supports` says
/// yes, `privateKey` returns `nil`, and `AgentAuthDelegate` skips an identity
/// it just promised `CitadelFileSystem.connectHop` it would try.
///
/// Planting that exact drift (dropping `"ssh-rsa"` from the `Set` only, while
/// the `switch` still handled it) and running the full `AgentAuth`/
/// `ConnectFailureSecrecyTests` suites left every test green — nothing in
/// the existing coverage called `supports` and `privateKey` on the same key
/// type and compared the answers. This suite is that missing guard.
///
/// The single-table refactor (one `[String: factory]` dictionary backing
/// both methods) makes the two agree structurally, so this drift can no
/// longer be reintroduced by a rename alone. The test still hardcodes the
/// five known agent key types below: there is no public list to read them
/// from (the table is `private`), and reading it via `@testable` would only
/// restate the implementation rather than check it independently.
@Suite("AgentPrivateKeyFactory")
struct AgentPrivateKeyFactoryTests {
    /// The closed set of agent key types macSCP is expected to offer through
    /// an ssh-agent, mirroring `AgentPrivateKeyFactory`'s own table.
    private static let knownAgentKeyTypes = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    private static func makeIdentity(keyType: String) -> AgentIdentity {
        AgentIdentity(
            publicKeyBlob: Data(), comment: "test-\(keyType)",
            keyType: keyType, fingerprintSHA256: "SHA256:test-\(keyType)")
    }

    private static func makeClient() -> SSHAgentClient {
        SSHAgentClient(transport: UnusedTransport())
    }

    /// A transport that is never actually invoked: `privateKey(for:client:)`
    /// only wraps `client` into an `AgentBackedPrivateKey`, it never signs.
    private struct UnusedTransport: SSHAgentTransport {
        func roundTrip(_ request: Data) async throws -> Data {
            struct Unreachable: Error {}
            throw Unreachable()
        }
        func close() async {}
    }

    @Test("every type supports() recognizes also produces a private key", arguments: knownAgentKeyTypes)
    func supportedTypeProducesPrivateKey(keyType: String) {
        #expect(AgentPrivateKeyFactory.supports(keyType: keyType))
        let identity = Self.makeIdentity(keyType: keyType)
        let privateKey = AgentPrivateKeyFactory.privateKey(for: identity, client: Self.makeClient())
        #expect(privateKey != nil)
    }

    @Test("every type privateKey() produces is also reported by supports()", arguments: knownAgentKeyTypes)
    func privateKeyProducingTypeIsSupported(keyType: String) {
        let identity = Self.makeIdentity(keyType: keyType)
        let privateKey = AgentPrivateKeyFactory.privateKey(for: identity, client: Self.makeClient())
        #expect(privateKey != nil)
        #expect(AgentPrivateKeyFactory.supports(keyType: keyType))
    }

    @Test("an unrecognized key type is neither supported nor keyed")
    func unrecognizedTypeIsRejectedByBoth() {
        let identity = Self.makeIdentity(keyType: "ssh-dss")
        #expect(!AgentPrivateKeyFactory.supports(keyType: "ssh-dss"))
        #expect(AgentPrivateKeyFactory.privateKey(for: identity, client: Self.makeClient()) == nil)
    }
}
