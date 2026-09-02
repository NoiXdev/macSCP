import Foundation
@testable import macSCPCore

/// Cushions reconnect throttling of the test container: on a transient
/// transport error, wait briefly and connect once more.
/// Use ONLY for connects that are SUPPOSED to succeed — not for
/// mismatch/reject tests (there the error is intentional).
///
/// Shared by `CitadelFileSystemIntegrationTests`,
/// `HostKeyTypeIntegrationTests` and `CrossBackendTransferIntegrationTests`
/// (counted 2026-09-02). Two suites still carry a private variant of the
/// same idea with a different signature — `CitadelShellIntegrationTests
/// .connectWithRetry()` and `WebDAVFileSystemIntegrationTests
/// .connectSSHWithRetry(_:)` — so this is the shared copy, not the only one.
func connectWithRetry(
    _ make: () async throws -> CitadelFileSystem
) async throws -> CitadelFileSystem {
    do {
        return try await make()
    } catch {
        try? await Task.sleep(for: .milliseconds(500))
        return try await make()
    }
}
