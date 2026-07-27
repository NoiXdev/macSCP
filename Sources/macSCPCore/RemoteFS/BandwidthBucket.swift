import Foundation

/// Shared token bucket pacing all transfers of one direction to a single
/// aggregate bandwidth limit (M6a). Owned per direction by
/// `TransferQueueViewModel`; every concurrent `copyFile` calls
/// `consume(_:)` before each chunk, so N parallel transfers share exactly
/// one limit instead of getting N × limit (the M5c per-transfer virtual
/// clock this replaces).
///
/// Debt model: `consume` waits only until the token balance is POSITIVE,
/// then deducts the full chunk size — the balance may go negative. That
/// keeps chunks larger than the burst capacity (64 KiB chunks under a
/// sub-64-KB/s limit) from starving while still pacing the average rate
/// exactly to the limit; the burst is bounded by capacity + one chunk.
///
/// Clock and sleep are injectable so tests drive a virtual timeline and
/// never actually sleep. The defaults use the real `ContinuousClock` and
/// `Task.sleep` — unlike the replaced virtual clock, real elapsed transfer
/// time refills tokens, so an already-slow link is no longer throttled
/// additionally (the M5c over-throttling).
public actor BandwidthBucket {
    private var rate: Double            // tokens (bytes) per second
    private var capacity: Double        // burst bound: 1 second of rate
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private var lastAppliedGeneration = 0

    public init(
        bytesPerSecond: Int,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        // A non-positive rate is a caller bug (the queue creates no bucket
        // for "0 = unlimited") — clamp defensively rather than trap.
        self.rate = Double(max(1, bytesPerSecond))
        self.capacity = self.rate
        self.tokens = self.rate         // start with a full burst
        self.now = now
        self.sleep = sleep
        self.lastRefill = now()
    }

    /// Updates the rate (Settings change at runtime). Tokens are clamped to
    /// the new capacity; a negative balance (debt) is deliberately kept.
    /// `generation` orders concurrent fire-and-forget re-rates (M6b): a call
    /// carrying a generation older than the last applied one is ignored, so
    /// a delayed hop can never overwrite a newer rate. `nil` (tests, direct
    /// use) bypasses the ordering check.
    public func setRate(bytesPerSecond: Int, generation: Int? = nil) {
        if let generation {
            guard generation > lastAppliedGeneration else { return }
            lastAppliedGeneration = generation
        }
        refill()
        rate = Double(max(1, bytesPerSecond))
        capacity = rate
        tokens = min(tokens, capacity)
    }

    /// Waits until the token balance is positive, then deducts `bytes`.
    /// Cooperatively cancellable: throws `CancellationError` from the
    /// injected `sleep` (Task.sleep default) or the explicit check.
    public func consume(_ bytes: Int) async throws {
        while true {
            try Task.checkCancellation()
            refill()
            if tokens > 0 {
                tokens -= Double(bytes)
                return
            }
            // Sleep until enough tokens accumulate to bring the balance
            // positive after deducting the bytes, then re-check — several
            // consumers may have been admitted meanwhile (actor reentrancy),
            // so this loops. The min() bounds the target to capacity, since
            // refill() caps tokens there: waiting to reach bytes (when bytes
            // > capacity) is impossible.
            let waitSeconds = (-tokens + min(Double(bytes), capacity)) / rate
            try await sleep(Duration.seconds(fromDouble: waitSeconds))
        }
    }

    private func refill() {
        let instant = now()
        let elapsed = (instant - lastRefill).secondsAsDouble
        lastRefill = instant
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * rate)
    }
}
