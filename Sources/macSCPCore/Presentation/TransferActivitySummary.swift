import Foundation

/// A compact, app-glanceable roll-up of ONE transfer queue's current
/// activity (M11n). Derived purely from the queue's items so it can be unit
/// tested without driving the queue; the menu-bar panel renders one of these
/// per connected tab. `nil` (see `TransferQueueViewModel.activitySummary`)
/// means the queue is idle.
public struct TransferActivitySummary: Equatable, Sendable {
    /// Number of items currently transferring.
    public let runningCount: Int
    /// Number of items queued but not yet running.
    public let pendingCount: Int
    /// Byte-weighted overall progress across the RUNNING items whose total
    /// size is known (Σ transferred / Σ total). `nil` when no running item
    /// knows its total — the UI then omits the percentage rather than
    /// inventing one.
    public let fraction: Double?
    /// Sum of the per-item rates over running items that report one; `nil`
    /// when none reports a rate yet.
    public let bytesPerSecond: Double?
    /// Direction to show the up/down arrow for — the queue's `displayDirection`.
    public let direction: TransferDirection?

    public init(
        runningCount: Int,
        pendingCount: Int,
        fraction: Double?,
        bytesPerSecond: Double?,
        direction: TransferDirection?
    ) {
        self.runningCount = runningCount
        self.pendingCount = pendingCount
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
        self.direction = direction
    }
}
