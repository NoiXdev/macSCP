import Foundation
import Observation

/// App-global bandwidth ceilings (M8a): ONE shared token bucket per
/// direction for the whole app — every tab's queue resolves its throttle
/// from here, so a 300 KB/s limit is 300 in aggregate across all tabs.
/// Semantics are identical to the per-queue wiring it replaces (M6a/M6b):
/// re-rating a non-zero limit keeps the live instance (running transfers
/// follow), toggling 0 <-> n swaps the reference (applies to transfers
/// starting afterwards).
@MainActor
@Observable
public final class BandwidthLimiter {
    public init() {}

    public var uploadLimitBytesPerSec: Int = 0 {
        didSet {
            uploadRateGeneration += 1
            uploadBucket = Self.updatedBucket(
                uploadBucket, bytesPerSecond: uploadLimitBytesPerSec,
                generation: uploadRateGeneration)
        }
    }
    public var downloadLimitBytesPerSec: Int = 0 {
        didSet {
            downloadRateGeneration += 1
            downloadBucket = Self.updatedBucket(
                downloadBucket, bytesPerSecond: downloadLimitBytesPerSec,
                generation: downloadRateGeneration)
        }
    }
    private var uploadRateGeneration = 0
    private var downloadRateGeneration = 0

    public private(set) var uploadBucket: BandwidthBucket?
    public private(set) var downloadBucket: BandwidthBucket?

    private static func updatedBucket(
        _ bucket: BandwidthBucket?, bytesPerSecond: Int, generation: Int
    ) -> BandwidthBucket? {
        guard bytesPerSecond > 0 else { return nil }
        guard let bucket else { return BandwidthBucket(bytesPerSecond: bytesPerSecond) }
        // Keep the instance (running transfers hold it) and re-rate it. The
        // hop is fire-and-forget by design: pacing catches up on the next
        // consume; the generation makes unordered hops last-write-wins.
        Task { await bucket.setRate(bytesPerSecond: bytesPerSecond, generation: generation) }
        return bucket
    }
}
