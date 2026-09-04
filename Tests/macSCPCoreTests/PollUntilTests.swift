import Testing
import MacSCPTestSupport

@Suite("pollUntil", .timeLimit(.minutes(1)))
struct PollUntilTests {
    /// A condition that holds on the third evaluation returns after
    /// exactly three evaluations — the helper polls, it does not race.
    @Test func returnsOnceTheConditionHolds() async throws {
        var evaluations = 0
        try await pollUntil("three evaluations", every: .milliseconds(1)) {
            evaluations += 1
            return evaluations == 3
        }
        #expect(evaluations == 3)
    }

    /// A condition that never holds ends only through cancellation: the
    /// task is cancelled from outside, the helper throws
    /// `CancellationError`, and the test proves the evaluation count kept
    /// growing until then (a positive companion — a helper that returned
    /// at once would count one).
    @Test func endsOnlyThroughCancellation() async throws {
        let counter = EvaluationCounter()
        let waiter = Task {
            try await pollUntil("never", every: .milliseconds(1)) {
                await counter.bump() >= 0 && false
            }
        }
        while await counter.value < 5 { await Task.yield() }
        waiter.cancel()
        var thrown: (any Error)?
        do { try await waiter.value } catch { thrown = error }
        #expect(thrown is CancellationError)
        #expect(await counter.value >= 5)
    }

    /// The closure runs on the caller's actor: a main-actor test reads a
    /// main-actor property inside the condition without a hop.
    @MainActor
    @Test func theConditionRunsOnTheCallersActor() async throws {
        @MainActor final class Flag { var isSet = false }
        let flag = Flag()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            flag.isSet = true
        }
        try await pollUntil("the flag") { flag.isSet }
        #expect(flag.isSet)
    }
}

private actor EvaluationCounter {
    var value = 0
    func bump() -> Int { value += 1; return value }
}
