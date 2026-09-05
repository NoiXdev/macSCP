import Foundation
import Testing
@testable import MacSCPAppKit

/// The helper shell a relaunch leaves behind (Quit Teardown plan, fix
/// round 1).
///
/// **Why the composed text and not a behaviour.** `relaunch()` spawns a
/// detached `/bin/sh` and then calls `NSApp.terminate(nil)`; there is
/// nothing left in this process to observe, and a test that actually ran
/// the helper would relaunch the app on the machine running the suite. The
/// command string is the whole decision, so it is what
/// `waitAndReopenCommand(pid:bundlePath:)` returns and what these tests
/// read.
///
/// **What went wrong before.** The helper was `sleep 1; open "<bundle>"`.
/// That raced a quit which used to be instant; since the quit became
/// deferred (`AppDelegate.applicationShouldTerminate(_:)` tears every live
/// tab down first), the old process can still be alive at one second — and
/// `open` on a running app ACTIVATES it rather than launching a new one, so
/// the relaunch silently does nothing.
@Suite("App relauncher")
struct AppRelauncherTests {
    /// A pid that is not this process's, so a match in the text below
    /// cannot be a coincidence of the runner's own numbers.
    private static let pid: Int32 = 424_242
    private static let bundlePath = "/Applications/macSCP.app"

    private static var command: String {
        AppRelauncher.waitAndReopenCommand(pid: pid, bundlePath: bundlePath)
    }

    /// The wait is for THIS process, by pid — the fact that matters — and
    /// not for an interval that happens to cover it today.
    @Test func theHelperWaitsForThisProcessByPid() {
        let command = Self.command
        #expect(command.contains("kill -0 424242"), """
            the helper no longer polls this process's pid: \(command)
            """)
        #expect(command.contains("sleep \(AppRelauncher.pollSeconds)"), """
            the helper no longer sleeps between polls — it would spin: \(command)
            """)
    }

    /// The reopen comes AFTER the wait. A guard on presence alone would be
    /// satisfied by a command that opened first and polled afterwards, which
    /// is the exact defect this round fixes.
    @Test func theAppIsReopenedOnlyAfterTheWait() throws {
        let command = Self.command
        let poll = command.range(of: "kill -0")
        let open = command.range(of: "open \"\(Self.bundlePath)\"")
        #expect(poll != nil, "the helper no longer polls at all")
        #expect(open != nil, """
            the helper no longer opens the bundle it was given: \(command)
            """)
        if let poll, let open {
            #expect(poll.lowerBound < open.lowerBound, """
                the helper opens the app before it has waited for the old process to go: \
                \(command)
                """)
        }
    }

    /// The wait is bounded: nothing reaps a detached helper, so a process
    /// that never exits would otherwise leave it polling forever and the
    /// user with no app and no message. The cap opens the app anyway.
    @Test func theWaitIsCappedAndTheCapIsTheTwoConstantsArithmetic() {
        #expect(AppRelauncher.maxWaitIterations == 300)
        #expect(
            Double(AppRelauncher.maxWaitIterations) * AppRelauncher.pollSeconds
                == AppRelauncher.maxWaitSeconds, """
                the iteration count no longer works out to maxWaitSeconds — \
                \(AppRelauncher.maxWaitIterations) × \(AppRelauncher.pollSeconds) ≠ \
                \(AppRelauncher.maxWaitSeconds)
                """)
        #expect(Self.command.contains("-lt \(AppRelauncher.maxWaitIterations)"), """
            the helper's loop no longer carries the cap: \(Self.command)
            """)
    }

    /// Sixty seconds, and the reason it is not smaller: `QuitWatchdog.bound`
    /// is the point after which the quit starts no further tab, not a hard
    /// ceiling — one tab's own bounded teardown may still be running past
    /// it. The cap has to clear that overrun comfortably.
    ///
    /// Deliberately NOT derived from `QuitWatchdog.bound` in code: the two
    /// answer different questions and moving one must not move the other.
    /// This expectation is what says the relation was checked rather than
    /// assumed.
    @Test func theCapClearsTheQuitWatchdogSeveralTimesOver() {
        let watchdogSeconds = Double(QuitWatchdog.bound.components.seconds)
        #expect(watchdogSeconds == 15)
        #expect(AppRelauncher.maxWaitSeconds >= watchdogSeconds * 2, """
            the relaunch helper's cap (\(AppRelauncher.maxWaitSeconds)s) no longer clears the \
            quit's own watchdog (\(watchdogSeconds)s) with room for the one tab that may still \
            be tearing down past it.
            """)
    }
}
