import Foundation

/// A fixture for `PollingGuardTests.noEventLoopFutureIsAwaitedWithGet`,
/// added when the two remaining `EventLoopFuture.get()` sites named in
/// `docs/BACKLOG.md` ("Wall-clock ceilings still in the tree") —
/// `AgentAuthTests.nextOffer` and `SSHPrivateKeyLoaderTests.collectOfferedKeys`
/// — were converted to `awaitCancellably`
/// (`Tests/MacSCPTestSupport/AwaitCancellably.swift`): real, compiling
/// Swift code in the exact shape that check's regex exists to catch — an
/// identifier ending `future`/`Future`/`futureResult` immediately followed
/// by `.get()`. `EventLoopFuture.get()` ignores task cancellation, so an
/// un-awaited-cancellably future can park a run past its suite
/// `.timeLimit` instead of ending it.
///
/// Never called from a test. It exists only so the guard's positive check
/// has a real match to read instead of asserting the regex against
/// nothing — CLAUDE.md, "Guards that name what they watch": a negative
/// needs a positive beside it. It lives here, beside `PollUntil.swift`,
/// `CeilingRegexFixture.swift` and `SleepingChildRegexFixture.swift`
/// under `Tests/MacSCPTestSupport/`, and `PollingGuardTests.sources()`
/// excludes this file by name exactly as it excludes those, so this
/// genuine match is never itself read back as an offender.
enum FutureGetRegexFixture {
    /// A stand-in for a bare `EventLoopFuture` local, spelling the
    /// `future.get()` shape without a real NIO type.
    private struct FakeFuture {
        func get() -> Int { 0 }
    }

    /// A stand-in for `EventLoopPromise.futureResult`, spelling the
    /// `promise.futureResult.get()` shape the two converted call sites
    /// carried.
    private struct FakePromise {
        var futureResult: FakeFuture { FakeFuture() }
    }

    static func demonstratesTheFutureGetShape() {
        let future = FakeFuture()
        _ = future.get()
        let promise = FakePromise()
        _ = promise.futureResult.get()
    }
}
