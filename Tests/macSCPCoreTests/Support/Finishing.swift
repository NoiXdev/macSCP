import Foundation
import macSCPCore

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

/// Starts `operation` in a task of its own and waits for it to return
/// through a signal the CASE's cancellation ends. For an operation held by
/// something that cancellation does not reach — a detached task's `value`,
/// an abort the case has not released yet — which neither `await
/// run.value` nor `finishing(_:)` could stop waiting for: cancelling the
/// run does not unpark what holds it. An operation that never returns reads
/// `.cancelled` once the suite's time limit fires, and the case goes on.
///
/// The case then reads what it asserts, heals — releases what it held —
/// and only then awaits `task`, which the healing lets finish.
func returnedOrCancelled<Value: Sendable>(
    _ operation: @escaping @Sendable () async -> Value
) async -> (returned: AsyncSignal.WaitOutcome, task: Task<Value, Never>) {
    let returned = AsyncSignal()
    let task = Task {
        let value = await operation()
        returned.signal()
        return value
    }
    return (await returned.wait(), task)
}
