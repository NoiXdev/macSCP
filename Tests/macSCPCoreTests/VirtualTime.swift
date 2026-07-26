import Foundation

/// Deterministic clock driver for `BandwidthBucket`-backed tests: `sleep`
/// advances the virtual instant instead of actually sleeping, so tests never
/// wait. Shared by `BandwidthBucketTests` (M6a/T1) and the migrated
/// `TransferEngine` throttle tests (M6a/T2).
final class VirtualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private(set) var totalSlept = Duration.zero

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in lock.withLock { instant } }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            try Task.checkCancellation()
            lock.withLock {
                instant = instant.advanced(by: duration)
                totalSlept += duration
            }
        }
    }
}
