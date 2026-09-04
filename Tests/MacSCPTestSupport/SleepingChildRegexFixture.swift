/// A fixture for `PollingGuardTests.noSleepingChildRacesWorkInAGroup`: real,
/// compiling Swift code in the exact shape that guard's regex exists to
/// catch — an `addTask` whose body's first statement is `Task.sleep(for:`,
/// the sleeping-child-races-real-work pattern `CLAUDE.md` ("A wall-clock
/// ceiling in a test measures the runner") retired from
/// `ConnectMainActorLivenessTests` and `CitadelShellIntegrationTests`.
///
/// Never called from a test. It exists only so the guard's positive check
/// has a real match to read instead of asserting the regex against
/// nothing — CLAUDE.md, "Guards that name what they watch": a negative
/// needs a positive beside it. It lives here, beside `PollUntil.swift`
/// under `Tests/MacSCPTestSupport/`, and `PollingGuardTests.sources()`
/// excludes this file by name exactly as it excludes its own and
/// `PollUntil.swift`'s, so this genuine match is never itself read back as
/// an offender.
enum SleepingChildRegexFixture {
    static func demonstratesTheBannedShape() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(3))
            }
            try await group.waitForAll()
        }
    }

    /// The second shape the regex must catch, added in the fix round that
    /// turned `AsyncSignal.race(timeout:_:)`'s blind spot into a named
    /// exemption (2026-09-04): the sleep is not the child's first token —
    /// it sits one level inside a `do {}` — but it is still the first
    /// meaningful call the child makes, and still races real work in the
    /// same group. Never called from a test, for the same reason as
    /// `demonstratesTheBannedShape` above.
    static func demonstratesTheDoWrappedBannedShape() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    // unreachable in this fixture; `Task.sleep` throws only
                    // on cancellation, which nothing here triggers.
                }
            }
            try await group.waitForAll()
        }
    }
}
