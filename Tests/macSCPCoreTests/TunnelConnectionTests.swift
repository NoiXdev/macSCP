import Foundation
import Testing

@testable import macSCPCore

/// What `TunnelConnection.connect` decides BEFORE it dials — the two arms a
/// test can reach with no server at all. The dial itself is proven against
/// the rig in `TunnelRigITests`.
@Suite("TunnelConnection")
struct TunnelConnectionTests {

    /// A tunnel needs an SSH connection; there is no `direct-tcpip` over S3
    /// or WebDAV. The refusal is typed so the App can render it without
    /// reading an error's text.
    @Test func aSessionThatIsNotSSHIsRefused() async throws {
        let directory = throwawayDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = s3Session(name: "objects")
        let store = KnownHostsStore(directory: directory)

        await #expect(throws: TunnelFailure.self) {
            _ = try await TunnelConnection.connect(
                session: session, secrets: [FixedSecret("secret-access-key")],
                knownHosts: store, decider: .refusing)
        }
    }

    /// The three refusals are `TunnelCarriers`', word for word — the dial
    /// does not word them a second time. Derived from the rule rather than
    /// spelled here, so a reworded sentence cannot leave the dial saying one
    /// thing and the command line, which asks `TunnelCarriers` directly
    /// before dialling at all, saying another.
    @Test(arguments: [
        TunnelSessionShape.notSSH, .loginSet, .jumpHost,
    ])
    func aRefusedSessionThrowsTheCarriersSentence(shape: TunnelSessionShape) async throws {
        let directory = throwawayDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = shape.session
        let store = KnownHostsStore(directory: directory)
        let refusal = try #require(TunnelCarriers.refusal(for: session))

        await #expect(throws: TunnelFailure.connectFailed(reason: refusal)) {
            _ = try await TunnelConnection.connect(
                session: session, secrets: [FixedSecret("unused")],
                knownHosts: store, decider: .refusing)
        }
    }

    /// A missing secret is NOT a `TunnelFailure`: it is the existing
    /// stored-session error, propagated unchanged, which is what lets the
    /// App map it to `TunnelState.needsConfirmation` rather than to
    /// `.failed`.
    @Test func aMissingSecretPropagatesTheStoredSessionError() async throws {
        let directory = throwawayDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = sshSession(name: "rig", host: "127.0.0.1", port: 2222, username: "testuser")
        let store = KnownHostsStore(directory: directory)

        await #expect(throws: StoredSessionConnectionError.secretRequired) {
            _ = try await TunnelConnection.connect(
                session: session, secrets: [], knownHosts: store, decider: .refusing)
        }
    }
}

// MARK: - Helpers

/// The three session shapes a forwarding refuses. An enum rather than the
/// sessions themselves because `@Test(arguments:)` wants `Sendable`
/// `CustomTestArgumentEncodable` values, and a case name reads better in a
/// failure than a whole `StoredSession` would.
enum TunnelSessionShape: Sendable {
    case notSSH
    case loginSet
    case jumpHost

    var session: StoredSession {
        switch self {
        case .notSSH:
            return s3Session(name: "objects")
        case .loginSet:
            return sshSession(name: "prod", loginSetID: UUID())
        case .jumpHost:
            return sshSession(
                name: "behind",
                jump: StoredSession.JumpSpec(host: "example.invalid", username: "tim"))
        }
    }
}

private struct FixedSecret: SecretSource {
    let label = "fixture"
    private let value: String

    init(_ value: String) { self.value = value }

    func secret(for sessionID: UUID) throws -> String? { value }
}

/// Neither test above ever reaches the handshake, so nothing is written into
/// this directory — it exists only because `KnownHostsStore` needs one. It is
/// still removed by the caller's `defer`, so a run leaves nothing behind
/// either way.
private func throwawayDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-kh-tunnel-\(UUID().uuidString)")
}
