import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferActivitySummary")
@MainActor
struct TransferActivitySummaryTests {
    private typealias VM = TransferQueueViewModel

    private func makeItem(
        status: VM.Item.Status,
        direction: TransferDirection = .download
    ) -> VM.Item {
        VM.Item(
            id: UUID(),
            fileName: "f",
            direction: direction,
            status: status,
            destinationTabID: nil,
            isEditUpload: false,
            destinationDirectory: "/",
            destinationSupportsResume: true,
            crossBackendTarget: nil
        )
    }

    private func running(_ transferred: UInt64, _ total: UInt64?, rate: Double? = nil) -> VM.Item.Status {
        .running(TransferProgress(bytesTransferred: transferred, totalBytes: total, bytesPerSecond: rate))
    }

    @Test func nilWhenNoActiveItems() {
        let items = [makeItem(status: .finished), makeItem(status: .cancelled)]
        #expect(VM.activitySummary(for: items, direction: nil) == nil)
    }

    @Test func singleRunningWithKnownTotal() {
        let items = [makeItem(status: running(50, 100, rate: 1024))]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 1)
        #expect(s?.pendingCount == 0)
        #expect(s?.fraction == 0.5)
        #expect(s?.bytesPerSecond == 1024)
        #expect(s?.direction == .download)
    }

    @Test func multipleRunningByteWeightedFraction() {
        // 10/100 and 40/100 → 50/200 = 0.25; rates 1000+3000 = 4000.
        let items = [
            makeItem(status: running(10, 100, rate: 1000)),
            makeItem(status: running(40, 100, rate: 3000)),
        ]
        let s = VM.activitySummary(for: items, direction: .upload)
        #expect(s?.runningCount == 2)
        #expect(s?.fraction == 0.25)
        #expect(s?.bytesPerSecond == 4000)
    }

    @Test func runningWithoutTotalGivesNilFractionButCounts() {
        let items = [makeItem(status: running(500, nil, rate: 2048))]
        let s = VM.activitySummary(for: items, direction: nil)
        #expect(s?.runningCount == 1)
        #expect(s?.fraction == nil)
        #expect(s?.bytesPerSecond == 2048)
    }

    @Test func rateNilWhenNoRunningItemReportsRate() {
        let items = [makeItem(status: running(10, 100, rate: nil))]
        let s = VM.activitySummary(for: items, direction: nil)
        #expect(s?.fraction == 0.1)
        #expect(s?.bytesPerSecond == nil)
    }

    @Test func onlyQueuedItems() {
        let items = [makeItem(status: .queued), makeItem(status: .queued)]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 0)
        #expect(s?.pendingCount == 2)
        #expect(s?.fraction == nil)
        #expect(s?.bytesPerSecond == nil)
        #expect(s?.direction == .download)
    }

    @Test func mixedRunningAndQueued() {
        let items = [
            makeItem(status: running(25, 100, rate: 500)),
            makeItem(status: .queued),
            makeItem(status: .finished),
        ]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 1)
        #expect(s?.pendingCount == 1)
        #expect(s?.fraction == 0.25)
    }
}
