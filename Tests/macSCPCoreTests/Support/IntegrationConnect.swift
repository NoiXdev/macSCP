import Foundation
@testable import macSCPCore

/// Cushions reconnect throttling of the test container: on a transient
/// transport error, wait briefly and connect once more.
/// Use ONLY for connects that are SUPPOSED to succeed — not for
/// mismatch/reject tests (there the error is intentional).
///
/// Shared across the gated integration suites (`CitadelFileSystemIntegrationTests`,
/// `HostKeyTypeIntegrationTests`) — moved here rather than duplicated so
/// there is exactly one copy to keep in sync with the rig's throttling
/// behavior.
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
