import Foundation

@testable import macSCPCore

/// The protocol deadlines a test hands the production FTP client when it dials
/// an in-process server (`LoopbackFTPServer`, `ScriptedFTPServer`) and asserts
/// something OTHER than a timeout.
///
/// Such a deadline is a wall-clock ceiling under another spelling (CLAUDE.md,
/// "A wall-clock ceiling in a test measures the runner", the 2026-11-09
/// update). Measured on CI run 42606504360 (three cores): six FTP cases that
/// dialled with `timeout: .seconds(30)` each reported `failed after` between
/// 134.528 and 135.623 seconds, with `timedOut` or "did not answer in time"
/// where a greeting refusal, a connection or a per-file error was due. All six
/// started within the run's first two seconds and all six ended inside the
/// same two seconds, which reads as one stall of the whole runner that outlasted
/// every deadline under it, not as six slow dials -- an inference from the
/// timestamps, not a measurement of the thread pool. The six names, one per
/// line (the log carries each twice, once from the test step and once from
/// the verdicts step, hence the `sort -u`):
///
///     gh run view 42606504360 --repo NoiXdev/macSCP --log | /usr/bin/grep -e 'failed after 13[45]\.' | /usr/bin/grep -o 'Test [A-Za-z0-9_]*(' | sort -u
///
/// So the figure sits above the whole suite's own wall clock (212.296 s on that
/// run), and a hang is ended by the suite's `.timeLimit`, not by this. It is a
/// parameter, never an assertion: nothing compares an elapsed time against it.
/// `aDataReadIsBoundedByItsOwnIdleTimeoutAndNotByTheDialsTimeout` already
/// dialled with `.seconds(600)` before this type existed, which is where the
/// figure comes from.
///
/// A case that DOES assert a timeout keeps its own short figure and does not
/// use this.
enum LoopbackFTPDeadline {
    /// The dial's `timeout:` — it bounds every wait the dial performs, and
    /// every reply wait until the dial is finished.
    static let dial: Duration = .seconds(600)

    /// The shipped tuning with both idle bounds raised to `dial`.
    ///
    /// The shipped figures are 60 s for a silent reply and 120 s for a silent
    /// data read (`FTPControlConnection.Tuning.init`), both below the 135 s
    /// stall measured above, so a connection that is USED after its dial needs
    /// them raised as much as its dial does. The keepalive interval is not a
    /// deadline and keeps the shipped figure unless a case names its own.
    static func tuning(
        keepaliveInterval: Duration = FTPControlConnection.Tuning.default.keepaliveInterval,
        dataIdleTimeout: Duration = dial
    ) -> FTPControlConnection.Tuning {
        FTPControlConnection.Tuning(
            keepaliveInterval: keepaliveInterval,
            replyIdleTimeout: dial,
            dataIdleTimeout: dataIdleTimeout)
    }
}
