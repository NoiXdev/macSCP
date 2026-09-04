/// Evaluates `condition` until it is true, sleeping `interval` between
/// evaluations.
///
/// Carries NO deadline of its own. The tree used to hold twelve
/// `waitUntil` helpers, eight of them with a `let deadline =
/// ContinuousClock.now + …` — a wall-clock ceiling, and on a starved
/// three-core CI runner a ceiling measures the runner, not the property
/// (CLAUDE.md, "A wall-clock ceiling in a test measures the runner").
/// The only way out of a condition that never holds is cancellation of
/// the calling task, which a Swift Testing `.timeLimit` trait performs;
/// every suite that calls this carries one, and `PollingGuardTests`
/// checks that it does. On cancellation the name of the wait is printed
/// so the harness's "time limit exceeded" red says which wait it was.
///
/// `isolation` defaults to the caller's actor (`#isolation`), so a
/// main-actor test can read main-actor state in the condition without a
/// hop, and a nonisolated test gets a nonisolated poll.
public func pollUntil(
    _ what: String,
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async throws {
    while !(await condition()) {
        do {
            try await Task.sleep(for: interval)
        } catch {
            print("pollUntil: cancelled while waiting for \(what)")
            throw error
        }
    }
}
