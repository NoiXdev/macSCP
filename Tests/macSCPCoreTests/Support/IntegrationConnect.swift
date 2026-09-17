import Foundation
@testable import macSCPCore

/// Cushions reconnect throttling of the test container: on a transient
/// transport error, wait briefly and connect once more.
/// Use ONLY for connects that are SUPPOSED to succeed — not for
/// mismatch/reject tests (there the error is intentional).
///
/// Shared by SIX suites, counted 2026-09-17 with `grep -rln
/// "connectWithRetry {" Tests`: `CitadelFileSystemIntegrationTests`,
/// `CrossBackendTransferIntegrationTests`, `FileKeyTypeIntegrationTests`,
/// `GoServerRSAIntegrationTests`, `HostKeyTypeIntegrationTests` and
/// `TunnelRigITests` (three on 2026-09-02). Generic over what it connects
/// since `TunnelRigITests` dials a forwarding's connection through it, which
/// is not a `CitadelFileSystem`. Two suites still carry a private variant of the
/// same idea with a different signature — `CitadelShellIntegrationTests
/// .connectWithRetry()` and `WebDAVFileSystemIntegrationTests
/// .connectSSHWithRetry(_:)` — so this is the shared copy, not the only one.
func connectWithRetry<Connection>(
    _ make: () async throws -> Connection
) async throws -> Connection {
    do {
        return try await make()
    } catch {
        try? await Task.sleep(for: .milliseconds(500))
        return try await make()
    }
}
