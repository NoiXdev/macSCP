import Foundation

/// A fixture for `PollingGuardTests`'s two `Date`-spelled ceiling checks,
/// added in the "ceilings under other spellings" plan's final fix round:
/// real, compiling Swift code in the exact shapes those checks' regexes
/// exist to catch — `Date().timeIntervalSince(...) <` and `.wait(until:
/// Date(` — the `Foundation`-clock spellings of
/// `noTestAssertsAnElapsedCeiling` and `noTestCarriesItsOwnDeadline`'s own
/// `ContinuousClock` patterns. `CLISecretSourcesTests.swift` and
/// `NetworkTraceTests.swift` carried these for real until this round
/// replaced them with a floor plus a suite `.timeLimit`, and an
/// `AsyncSignal` join plus a suite `.timeLimit`, respectively.
///
/// Never called from a test. It exists only so each guard's positive check
/// has a real match to read instead of asserting the regex against
/// nothing — CLAUDE.md, "Guards that name what they watch": a negative
/// needs a positive beside it. It lives here, beside `PollUntil.swift` and
/// `SleepingChildRegexFixture.swift` under `Tests/MacSCPTestSupport/`, and
/// `PollingGuardTests.sources()` excludes this file by name exactly as it
/// excludes those two, so this genuine match is never itself read back as
/// an offender.
enum CeilingRegexFixture {
    /// The shape `noTestAssertsAnElapsedSinceCeiling` looks for: an upper
    /// bound on how much time has passed, spelled with `Date` instead of
    /// `ContinuousClock`.
    static func demonstratesTheElapsedSinceCeiling(startedAt started: Date) -> Bool {
        Date().timeIntervalSince(started) < 1
    }

    /// The shape `noWaitTakesAWallClockDeadline` looks for: a wait whose
    /// deadline is built from `Date` rather than ending only on
    /// cancellation. The one real caller this pattern ever had
    /// (`BlockingGate.wait(until:)`, before this round) built it on
    /// `NSCondition` — but that type is ALSO one of
    /// `TestsNeverBlockThePoolGuardTests`'s own forbidden blocking-wait
    /// spellings, and this fixture is never called, so using it here would
    /// trip that other guard for a call nothing ever makes. `FakeGate`
    /// spells the same `.wait(until: Date(` call shape without the type
    /// that would do so.
    private struct FakeGate {
        func wait(until deadline: Date) { _ = deadline }
    }

    static func demonstratesTheWaitUntilDateCeiling() {
        FakeGate().wait(until: Date().addingTimeInterval(1))
    }
}
