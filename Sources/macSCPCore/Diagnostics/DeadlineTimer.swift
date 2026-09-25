import Foundation
import Synchronization

/// The process's one timing thread: a deadline that fires whatever else the
/// process is doing.
///
/// **Why a thread, and not Dispatch.** A diagnostic step's deadline is a
/// hard limit (maintainer's ruling, 2026-09-24): the step ends by it however
/// loaded the machine is. Every Dispatch mechanism that could carry it needs
/// a workqueue thread AT THE MOMENT IT FIRES, and a process that has filled
/// the relevant pool has none to give. Measured 2026-09-25 on the ten-core
/// development machine, in a standalone binary rather than in the test
/// suite; each run count below is the number of runs that number was taken
/// from, and every run of a given shape agreed:
///
/// - `DispatchQueue.global().asyncAfter`, 0.3 s, armed behind 80 blocks
///   parked in `read(2)` on that queue (`kern.wq_max_constrained_threads` is
///   64 here): had not fired 5 s later in 4 of 4 runs; it fired at
///   5.001–5.011 s, when the parked blocks were released. The thread below,
///   given the same 0.3 s in the same 4 runs, fired at 0.300–0.307 s. With
///   the cooperative pool saturated instead — 20 CPU-bound tasks on 10
///   cores, 1 run — the same Dispatch timer fired at 10.001 s against a due
///   time of about 0.8 s, and the thread at 0.825 s. With BOTH saturated,
///   5 of 5 runs: the Dispatch timer did not fire inside the window at all;
///   the thread fired at 0.806–0.821 s against that same due time.
/// - `DispatchQueue(label:).asyncAfter` and `DispatchSource.makeTimerSource`
///   on a private queue: both fired on time with both pools saturated
///   (0.808–0.838 s against a 0.8 s due time, 3 runs), because a private
///   serial queue draws OVERCOMMIT threads, which the constrained limit does
///   not bound. They lose one level down: `kern.wq_max_threads` (512 here)
///   bounds those too, and behind 544 blocked private-queue blocks neither
///   had fired 5 s later, in 3 of 3 runs, while the thread below fired at
///   0.300–0.310 s. Both still have to be GIVEN a thread when they fire;
///   this thread already has one.
/// - A `Task.sleep` deadline needs the cooperative pool, which is the pool
///   the diagnostics run on. `DetachedProbe`'s own comment records that one
///   from before: a 1 s sleep let a 3 s probe run to completion under the
///   full suite.
/// - Raising QoS was not measured, and is not a candidate on the argument
///   above: it reorders what a pool serves, and the pools here have nothing
///   to serve it with.
///
/// **What it costs.** One thread for the process, started on the first
/// deadline anything schedules and never joined — roughly half a megabyte of
/// reserved stack, and no CPU at all while nothing is pending, because the
/// loop parks on a semaphore with no timeout when the set is empty.
/// Scheduling and cancelling are a lock and a dictionary write; the loop
/// scans the pending set on each wake, which is fine at the handful of
/// deadlines a diagnosis has in flight and would want a heap if that ever
/// became thousands.
///
/// **What a caller owes it.** A body runs ON the timing thread, so a body
/// that blocks holds up every other deadline in the process. Both callers
/// here hand it one `OneShot.deliver(nil)`: a lock, a flag and a
/// continuation resumption, which hands the waiting task back to the
/// cooperative pool rather than doing its work here.
final class DeadlineTimer: Sendable {
    static let shared = DeadlineTimer()

    /// What `cancel(_:)` takes. An opaque id rather than the entry itself, so
    /// a caller cannot hold the body alive after the deadline has passed.
    struct Ticket: Sendable, Hashable {
        fileprivate let id: UInt64
    }

    private struct Entry {
        let at: DispatchTime
        let body: @Sendable () -> Void
    }

    private struct State {
        var entries: [UInt64: Entry] = [:]
        var nextID: UInt64 = 0
        var isRunning = false
    }

    private let state = Mutex(State())
    /// Wakes the loop when a deadline is scheduled. Counting, so a signal
    /// that lands while the loop is between reading the pending set and
    /// waiting is not lost — it returns the next wait at once and the loop
    /// reads the set again.
    private let wake = DispatchSemaphore(value: 0)

    private init() {}

    /// Runs `body` on the timing thread once `timeout` has passed, unless the
    /// returned ticket is cancelled first.
    func schedule(after timeout: Duration, _ body: @escaping @Sendable () -> Void) -> Ticket {
        let (id, needsThread) = state.withLock { state -> (UInt64, Bool) in
            let id = state.nextID
            state.nextID += 1
            state.entries[id] = Entry(at: .now() + timeout.seconds, body: body)
            let needsThread = !state.isRunning
            state.isRunning = true
            return (id, needsThread)
        }
        if needsThread {
            let thread = Thread { [self] in loop() }
            thread.name = "macSCP.DeadlineTimer"
            // Above the default, because what waits behind a deadline is a
            // user watching a diagnosis; below `.userInteractive`, which is
            // for the frames being drawn while they watch.
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        wake.signal()
        return Ticket(id: id)
    }

    /// Calls off a deadline. Idempotent, and safe to call after it has
    /// already fired — the entry is gone either way. A deadline that fires
    /// while this is being called still runs its body once; the callers here
    /// are settled by a `OneShot`, which drops whichever answer is second.
    func cancel(_ ticket: Ticket) {
        state.withLock { _ = $0.entries.removeValue(forKey: ticket.id) }
    }

    private func loop() {
        while true {
            let earliest = state.withLock { $0.entries.values.map(\.at).min() }
            // No pending deadline means no wake-up is due: park until
            // `schedule` signals. `.distantFuture` rather than a poll
            // interval, so an idle process pays nothing for this thread.
            _ = wake.wait(timeout: earliest ?? .distantFuture)

            let now = DispatchTime.now()
            let due = state.withLock { state -> [Entry] in
                let due = state.entries.filter { $0.value.at <= now }
                for id in due.keys { state.entries.removeValue(forKey: id) }
                return Array(due.values)
            }
            for entry in due { entry.body() }
        }
    }
}
