import AppKit

/// Relaunches the running app (M11p): used after a language change, which
/// only takes effect on a fresh launch (the bundle's localized tables cache
/// after first use). Spawns a detached shell that waits for THIS process to
/// exit, then reopens the .app, and terminates immediately. A deliberate
/// user action — no `deinit` cleanup needed, same as a normal quit.
///
/// **The wait used to be a fixed `sleep 1`, and the deferred quit broke it**
/// (Quit Teardown plan, fix round 1). `NSApp.terminate(nil)` below now
/// reaches `AppDelegate.applicationShouldTerminate(_:)`, which returns
/// `.terminateLater` whenever a tab holds a session and tears every one of
/// them down — bounded by `QuitWatchdog.bound`, but a bound is not a
/// promise of speed. If the old process is still alive when `open` fires,
/// `open` ACTIVATES the dying instance instead of launching a new one, and
/// then the app exits: the relaunch silently does nothing, and the user is
/// left with no app and no error. A healthy four-stage teardown was
/// measured at about six milliseconds, so the old second was ample in the
/// ordinary case; against a frozen peer it was not, and "ordinary case"
/// is not what a relaunch may depend on.
///
/// So the shell polls for the pid instead of guessing at a duration. It is
/// the process's own exit that is waited for, which is the fact that
/// matters, rather than an interval that happens to cover it today.
@MainActor
enum AppRelauncher {
    /// How often the helper asks whether this process is gone. Two tenths
    /// of a second: short enough that the relaunch feels immediate after an
    /// ordinary quit, long enough that a wait spanning the whole watchdog
    /// costs a few hundred `kill -0` calls rather than thousands.
    nonisolated static let pollSeconds = 0.2

    /// The cap on that polling, in seconds — after it the helper opens the
    /// app anyway.
    ///
    /// **Why there is a cap at all.** The helper is detached: nothing
    /// reaps it, and nothing else would ever open the app. A process
    /// wedged in a way `QuitWatchdog.bound` cannot cover (a hang below the
    /// bound's own cancellation points, or a debugger) would otherwise
    /// leave the helper polling forever and the user with a relaunch that
    /// never happens and no message saying so. Opening anyway is the
    /// better failure: at worst `open` activates the still-running old
    /// instance, which is exactly the old behaviour, and the user sees an
    /// app rather than nothing.
    ///
    /// **Why sixty.** `QuitWatchdog.bound` is fifteen seconds, and that
    /// bound is the point after which no further TAB is started rather than
    /// a hard ceiling — one tab's own bounded teardown may still be running
    /// past it (see that constant's doc comment). Sixty is four times the
    /// bound: enough headroom for that overrun several times over, and
    /// still short enough to be a wait rather than an abandonment. It is
    /// deliberately NOT derived from `QuitWatchdog.bound` in code — the two
    /// answer different questions, and moving one must not move the other.
    nonisolated static let maxWaitSeconds = 60.0

    /// Iterations of the poll loop the cap works out to. Written as the
    /// division rather than as `300` so the two constants above stay the
    /// only numbers, and `AppRelauncherTests` checks the arithmetic.
    nonisolated static var maxWaitIterations: Int { Int(maxWaitSeconds / pollSeconds) }

    /// The shell the helper runs: poll until `pid` is gone or the cap is
    /// reached, then open `bundlePath`.
    ///
    /// `kill -0` sends no signal; it only asks whether the process can be
    /// signalled, which is the cheapest "is it still there" POSIX offers.
    /// Its stderr is discarded because the failing case — "no such process"
    /// — is the ANSWER here, not an error to report.
    ///
    /// `nonisolated`, like the three constants above: composing a string
    /// is not main-actor work, and a test that only reads the text should
    /// not have to be on the main actor to do it.
    ///
    /// A function rather than an inline string so a test can read what is
    /// composed. There is nothing to observe about a detached `/bin/sh` the
    /// app immediately quits behind; the text is the only thing a test can
    /// hold.
    nonisolated static func waitAndReopenCommand(pid: Int32, bundlePath: String) -> String {
        """
        i=0
        while kill -0 \(pid) 2>/dev/null && [ "$i" -lt \(maxWaitIterations) ]; do
        sleep \(pollSeconds)
        i=$((i+1))
        done
        open "\(bundlePath)"
        """
    }

    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            waitAndReopenCommand(
                pid: ProcessInfo.processInfo.processIdentifier, bundlePath: bundlePath),
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}
