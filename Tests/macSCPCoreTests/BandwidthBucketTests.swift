import Foundation
import Testing
@testable import macSCPCore

/// Deterministic clock driver for BandwidthBucket tests: `sleep` advances the
/// virtual instant instead of actually sleeping, so tests never wait.
private final class VirtualTime: @unchecked Sendable {
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

@Suite("BandwidthBucket")
struct BandwidthBucketTests {
    @Test("first consume within the burst capacity passes without sleeping")
    func burstPassesImmediately() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(800)
        #expect(time.totalSlept == .zero)
    }

    @Test("sustained consumption is paced to the configured rate")
    func sustainedRateIsPaced() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 10 chunks of 1000 bytes = 10_000 bytes at 1000 B/s. The first
        // 1000 ride the initial burst, the remaining 9000 must be paced:
        // total sleep ≈ 9 seconds (tolerance for the +1-byte rounding).
        for _ in 0..<10 { try await bucket.consume(1000) }
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.2)
    }

    @Test("a chunk larger than the capacity does not starve")
    func oversizedChunkPasses() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 100, now: time.now, sleep: time.sleep)
        // Capacity is 100 tokens; a 500-byte chunk must still pass (debt
        // model) and the NEXT consume pays it off by waiting ≈ 5 seconds.
        try await bucket.consume(500)
        try await bucket.consume(100)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 3.9 && slept < 5.2)
    }

    @Test("two consumers share one bucket at the aggregate rate")
    func sharedBucketPacesAggregate() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 2 × 5 × 1000 bytes = 10_000 bytes through ONE bucket: same math
        // as `sustainedRateIsPaced` — total virtual sleep ≈ 9 s, NOT ≈ 4.5 s
        // per consumer in parallel wall-clock (they serialize on the actor).
        async let first: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        async let second: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        _ = try await (first, second)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.3)
    }

    @Test("setRate applies to subsequent pacing")
    func setRateApplies() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(1000)              // eat the initial burst
        await bucket.setRate(bytesPerSecond: 2000)  // double the rate
        try await bucket.consume(2000)              // debt from chunk 1 + this
        try await bucket.consume(2000)
        // After the burst everything is paced at 2000 B/s: 4000 bytes ≈ 2 s
        // (plus paying off the 0-token state left by the burst chunk).
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 1.9 && slept < 2.3)
    }

    @Test("consume throws on task cancellation instead of sleeping forever")
    func consumeIsCancellable() async {
        let time = VirtualTime()
        let bucket = BandwidthBucket(
            bytesPerSecond: 1, now: time.now,
            // Never advances time: without cancellation this would loop.
            sleep: { _ in try Task.checkCancellation() })
        let task = Task {
            try await bucket.consume(1_000_000)   // burst passes (tokens 1 > 0)
            try await bucket.consume(1)           // now deep in debt → waits
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("repeated oversized chunks settle at the configured rate")
    func repeatedOversizedChunksPaceExactly() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 100, now: time.now, sleep: time.sleep)
        // 6 chunks of 500 bytes at 100 B/s. With the fixed formula, each cycle
        // after the first waits only until tokens reach capacity (100), not bytes
        // (500): this avoids the impossible target that caused oversleeping. Result:
        // total sleep = 5 cycles * 5 s = 25 s. The old formula overslept to ≈ 45 s.
        for _ in 0..<6 { try await bucket.consume(500) }
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 24.5 && slept < 25.5)
    }
}
