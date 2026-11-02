import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What a sheet that is closed while lock reads are still outstanding leaves
/// behind at the store.
///
/// The bounded read itself (`ConcurrencyGate`, `readLockState(of:)`, the limit)
/// is pinned in `ObjectVersionsSheetTests`. This suite holds the one property
/// that suite does not: a read whose task was cancelled puts no further request
/// on the wire, whether it was running when the cancel came or was still
/// queued behind the gate.
///
/// **Where the cancel is observed from.** The sheet closes by SwiftUI
/// cancelling each state cell's `.task`, which is one `readLockState(of:)` task
/// per realised row. These cases start one task per row and cancel them all,
/// which is the same cancel arriving the same way.
///
/// **Why the postconditions are read at the end and not before a release.**
/// `AsyncSignal.wait()` answers `.cancelled` at once for a cancelled task, so a
/// read held at the fake store is let go by the cancel itself: there is no
/// release for a test to hold back. What is snapshotted before the cancel is
/// the state the cancel acts on (four reads at the store, the rest queued); what
/// is asserted afterwards is read only once every task has finished
/// (`await task.value` for each), so nothing is in flight that could still
/// land, and a request that "arrives late" is counted and not missed.
@Suite("Object versions lock read cancellation")
@MainActor
struct ObjectVersionsLockReadTests {
    private static let target = ObjectVersionsTarget(
        bucket: "b", key: "a.txt", displayName: "a.txt", displayPath: "/b/a.txt")

    private static func history(_ count: Int) -> [ObjectVersion] {
        (0..<count).map {
            ObjectVersion(
                versionId: "v\($0)", key: "a.txt", isLatest: $0 == count - 1, isDeleteMarker: false,
                size: 10, modifiedAt: Date(timeIntervalSince1970: TimeInterval($0)),
                entityTag: "E\($0)")
        }
    }

    /// A sheet over `count` versions on a bucket with Object Lock, loaded, with
    /// every version read held at the store until the hold is released (or the
    /// reader is cancelled).
    private static func heldSheet(count: Int) async -> (
        model: ObjectVersionsModel, hold: FakeBucketSettings.VersionReadHold,
        settings: FakeBucketSettings
    ) {
        let hold = FakeBucketSettings.VersionReadHold(
            threshold: ObjectVersionsModel.lockReadLimit, reached: AsyncSignal(),
            release: AsyncSignal())
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.versionReadHold = hold
        let fake = FakeBucketSettings(lock: fixture)
        let model = ObjectVersionsModel(
            target: target, provider: FakeVersionProvider(versions: history(count)),
            recorder: nil, locks: .init(settings: fake, cache: ObjectLockStateCache(settings: fake)))
        await model.load()
        return (model, hold, fake)
    }

    /// The sheet is closed with `lockReadLimit` reads at the store and the rest
    /// of a long history queued behind the gate. Nothing more reaches the
    /// store: not the second request of a read that was running, and not a
    /// request from any row that was waiting.
    @Test(.timeLimit(.minutes(5)))
    func closingTheSheetCancelsTheLockReadsStillOutstanding() async {
        let (model, hold, settings) = await Self.heldSheet(count: 14)
        let rows = model.versions
        let cells = rows.map { row in Task { @MainActor in await model.readLockState(of: row) } }
        _ = await hold.reached.wait()
        // Every other row's task is runnable now: give them the chance to reach
        // the gate and queue.
        for _ in 0..<50 { await Task.yield() }

        // The state the cancel acts on, read before it. This is the positive
        // beside the zero below: four reads ARE at the store (so the counter is
        // wired and sees a request), and they are the first request of their
        // rows only.
        #expect(settings.versionReads.count == ObjectVersionsModel.lockReadLimit)
        #expect(settings.versionReads.allSatisfy { $0.kind == .retention })
        #expect(model.readings.isEmpty)

        for cell in cells { cell.cancel() }
        for cell in cells { await cell.value }

        // Everything has finished. The four running reads got no second
        // request out, the ten queued rows got none out, and no row was
        // recorded as read: each is as unknown as before.
        #expect(settings.versionReads.count == ObjectVersionsModel.lockReadLimit)
        #expect(settings.versionReads.allSatisfy { $0.kind == .retention })
        #expect(model.readings.isEmpty)
        #expect(rows.allSatisfy { model.rowState(of: $0) == .lockUnknown })
    }

    /// The gate on its own: a waiter whose task was cancelled while it queued
    /// does not run its body, and does not hold the ones behind it. The first
    /// body is the control: it is not cancelled and runs.
    @Test(.timeLimit(.minutes(5)))
    func aWaiterCancelledInTheQueueNeverRunsItsBodyAndStrandsNobody() async {
        @MainActor final class Probe {
            var bodiesRun: [Int] = []
        }
        let gate = ConcurrencyGate(limit: 1)
        let probe = Probe()
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let first = Task { @MainActor in
            await gate.run { () async -> Int in
                probe.bodiesRun.append(0)
                entered.signal()
                _ = await release.wait()
                return 0
            }
        }
        _ = await entered.wait()
        let queued = (1...4).map { index in
            Task { @MainActor in
                await gate.run { () async -> Int in
                    probe.bodiesRun.append(index)
                    return index
                }
            }
        }
        for _ in 0..<50 { await Task.yield() }
        // Before the cancel and before the slot is given back: only the first
        // body has run, so the four are waiting and not merely not started.
        #expect(probe.bodiesRun == [0])
        for task in queued { task.cancel() }
        release.signal()
        let firstResult = await first.value
        var queuedResults: [Int?] = []
        for task in queued { queuedResults.append(await task.value) }
        #expect(firstResult == 0)
        #expect(queuedResults.allSatisfy { $0 == nil })
        #expect(probe.bodiesRun == [0])
    }
}
