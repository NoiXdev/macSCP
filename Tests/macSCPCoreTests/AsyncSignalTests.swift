import Foundation
import Testing

/// `AsyncSignal`'s three outcomes, each pinned on its own.
///
/// `SubprocessRunnerTests.aCancelledRunKillsItsChildAndReportsCancellation`
/// covers the same contract end to end, but it does not isolate this type:
/// planting the defect here — `wait()` reporting `.signalled` for a
/// cancellation — left that test green in 5 of 5 runs, because in a runner
/// under cancellation the `Task.sleep` branch of `race` throws at once and
/// wins the race before the collapsed `wait()` can answer. A property that
/// another path happens to cover today is not a property that is guarded.
@Suite("AsyncSignal")
struct AsyncSignalTests {
    /// The positive half. Without it the cancellation test below would go on
    /// passing against a `wait()` that answers `.cancelled` for everything.
    @Test func aRaisedLatchReportsSignalled() async {
        let signal = AsyncSignal()
        async let waited = signal.wait()
        // Raised from a thread that is not the waiter's, which is the only
        // way this type is ever used.
        DispatchQueue.global().async { signal.signal() }
        #expect(await waited == .signalled)
    }

    /// Latching: a signal that lands before anyone waits still satisfies
    /// every later wait. `LoopbackTLSStub`'s listener can become ready before
    /// the initializer reaches its wait, and `EmbeddedKeyPorterTests` waits
    /// twice on one signal.
    @Test func aLatchRaisedBeforehandSatisfiesEveryLaterWait() async {
        let signal = AsyncSignal()
        signal.signal()
        #expect(signal.isRaised)
        #expect(await signal.wait() == .signalled)
        #expect(await signal.wait(timeout: .seconds(30)) == .signalled)
    }

    /// The outcome the type exists to distinguish. An `AsyncStream` ends the
    /// same way for a cancellation as for a `finish()`, so a `wait()` that
    /// only observed the stream ending would answer `.signalled` here — and
    /// `SubprocessRunner` would then read `terminationStatus` off a child
    /// that is still running and walk away leaving it there.
    @Test func aCancelledWaitIsNotASignal() async throws {
        let signal = AsyncSignal()
        let waiter = Task { await signal.wait() }
        // Long enough for the waiter to have registered, so this measures a
        // cancellation DURING the wait rather than before it. Both are
        // `.cancelled`, but only this one exercises the stream.
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        #expect(signal.isRaised == false)
    }

    /// The bounded wait's own third outcome, and the one that must not be
    /// confused with a cancellation the caller never asked for.
    @Test func anUnraisedLatchTimesOutRatherThanReportingEither() async {
        let signal = AsyncSignal()
        let started = ContinuousClock.now
        let outcome = await signal.wait(timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - started
        #expect(outcome == .timedOut)
        #expect(elapsed >= .milliseconds(150), "the bound returned early after \(elapsed)")
        #expect(elapsed < .seconds(10), "the bound overran at \(elapsed)")
    }

    /// A bounded wait inside a task the caller cancels says `.cancelled`, not
    /// `.timedOut`: the deadline never arrived, the caller left.
    @Test func aCancelledBoundedWaitSaysCancelledRatherThanTimedOut() async throws {
        let signal = AsyncSignal()
        let waiter = Task { await signal.wait(timeout: .seconds(120)) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
    }
}
