import Foundation
import Testing
@testable import macSCPCore

/// `OneAtATime`, the latch login-set import runs through. The first run is
/// held open on a signal the test raises, so "the second call arrived while
/// the first was in flight" is the test's own sequence, not a race.
@Suite("OneAtATime", .timeLimit(.minutes(1)))
@MainActor
struct OneAtATimeTests {
    @Test func anOverlappingRunIsRefusedWithoutRunning() async {
        let latch = OneAtATime()
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let first = Task { @MainActor in
            await latch.run { () -> Int in
                entered.signal()
                _ = await release.wait()
                return 1
            }
        }
        _ = await entered.wait()

        // Positive: the first run is in flight, and the latch says so.
        #expect(latch.isRunning)

        var secondRan = false
        let second = await latch.run { () -> Int in
            secondRan = true
            return 2
        }
        // Negative: the overlapping run was refused, and its body never ran.
        #expect(second == nil)
        #expect(secondRan == false)

        release.signal()
        #expect(await first.value == 1)
        #expect(latch.isRunning == false)
    }

    @Test func aRunAfterTheFirstHasFinishedProceeds() async {
        let latch = OneAtATime()
        #expect(await latch.run { 1 } == 1)
        #expect(await latch.run { 2 } == 2)
        #expect(latch.isRunning == false)
    }
}
