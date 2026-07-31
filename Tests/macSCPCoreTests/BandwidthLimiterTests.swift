import Testing
@testable import macSCPCore

@Suite("BandwidthLimiter")
@MainActor
struct BandwidthLimiterTests {
    @Test func zeroMeansNoBucket() {
        let limiter = BandwidthLimiter()
        #expect(limiter.uploadBucket == nil)
        #expect(limiter.downloadBucket == nil)
    }

    @Test func settingLimitCreatesBucketAndKeepsInstanceOnRerate() {
        let limiter = BandwidthLimiter()
        limiter.uploadLimitBytesPerSec = 1024
        let first = limiter.uploadBucket
        #expect(first != nil)
        limiter.uploadLimitBytesPerSec = 4096 // re-rate: same instance
        #expect(limiter.uploadBucket === first)
        limiter.uploadLimitBytesPerSec = 0 // disable: reference dropped
        #expect(limiter.uploadBucket == nil)
        #expect(limiter.downloadBucket == nil) // directions independent
    }

    @Test func twoQueuesShareTheLimiterBuckets() {
        let limiter = BandwidthLimiter()
        limiter.downloadLimitBytesPerSec = 2048
        let queueA = TransferQueueViewModel()
        let queueB = TransferQueueViewModel()
        queueA.limiter = limiter
        queueB.limiter = limiter
        // Both queues resolve the SAME bucket instance — the aggregate-rate
        // math on a shared bucket is proven in BandwidthBucketTests (M6a);
        // identity is the queue-level contract.
        #expect(queueA.limiter?.downloadBucket === queueB.limiter?.downloadBucket)
        #expect(queueA.limiter?.downloadBucket != nil)
    }
}
