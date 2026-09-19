import Foundation

/// Awaits `run`, and cancels it if the CASE is cancelled first — by its
/// suite's time limit. A bare `await run.value` does not answer the case's
/// cancellation, so a run that never returns would outlive the limit and
/// hold the whole test process; this makes the limit a hang bound that
/// actually ends the case.
func finishing<Value: Sendable>(_ run: Task<Value, Never>) async -> Value {
    await withTaskCancellationHandler {
        await run.value
    } onCancel: {
        run.cancel()
    }
}

/// The same for a throwing run, answering its `Result`.
func finishingResult<Value: Sendable>(
    _ run: Task<Value, any Error>
) async -> Result<Value, any Error> {
    await withTaskCancellationHandler {
        await run.result
    } onCancel: {
        run.cancel()
    }
}
