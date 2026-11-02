import Testing
import macSCPCore

/// A bound on waiting for a signal that turns "never arrives" into a named
/// failure instead of a park.
///
/// **This bound is a hang bound, not a ceiling.** The assertion is that the
/// signal ARRIVED, and never that it arrived within some time: five minutes is
/// the house hang-bound figure (20 times the worst ambient main-actor tick gap
/// measured on the three-core CI runner, 14.67 s, run 33707411271), so a slow
/// machine cannot defeat it, and a test that reads `.signalled` cannot have been
/// made to pass or fail by how long it took.
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
