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
