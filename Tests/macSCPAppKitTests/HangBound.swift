import Testing
import macSCPCore

/// A bound on waiting for a signal that turns "never arrives" into a named
/// failure instead of a park.
///
/// **This bound is a hang bound, not a ceiling.** The assertion is that the
/// signal ARRIVED, and never that it arrived within some time, so a test that
/// reads `.signalled` cannot have been made to pass or fail by how long it took.
///
/// **Where five minutes comes from** is the project's own derivation, not a new
/// one: CLAUDE.md, "A wall-clock ceiling in a test measures the runner", the
/// 2026-10-30 update, which raised the suites' `.timeLimit` to `.minutes(5)` as
/// "2.3x the 131.530 s run against 0.31x the 960 s step budget". Recomputed, to
/// the digits the record rounds: 300 / 131.530 = 2.2808 and 300 / 960 = 0.3125
/// (`python3 -I -c 'print(300/131.530, 300/960)'`). So the bound sits above a
/// whole suite run as that CI run measured it, and below the step budget
/// that would kill the job and lose the test's name.
///
/// A second, supporting figure, from the same section of CLAUDE.md: the largest
/// main-actor tick gap measured with nothing under test was 14.668071541 s (CI
/// run 33707411271), and 300 / 14.668071541 = 20.4526
/// (`python3 -I -c 'print(300/14.668071541)'`), a little over twenty times. That
/// is why a slow machine cannot defeat the bound.
///
/// Why it exists although every suite carries `.timeLimit(.minutes(5))`: a test
/// parked on a signal that nobody raises is not ended by the time limit
/// (`docs/BACKLOG.md`, "A test parked on a bare continuation outlives its time
/// limit"), and a park that is finally killed by the job's step budget loses the
/// test's name. Here the wait ends, the failure names the wait, and the test
/// goes on to its own cleanup.
extension AsyncSignal {
    /// The bound, in one place.
    static let hangBound: Duration = .seconds(5 * 60)

    /// Waits for the signal and records an issue, naming `what`, if it did not
    /// arrive. Answers whether it did, so a caller that cannot go on without it
    /// says `guard await signal.arrives("…") else { return }`.
    @discardableResult
    func arrives(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let outcome = await wait(timeout: Self.hangBound)
        let arrived = outcome == .signalled
        #expect(arrived, "\(what): the signal never arrived (\(outcome))", sourceLocation: sourceLocation)
        return arrived
    }
}
