import Foundation
import macSCPCore
import os

/// The stages of `ContentView.teardown(_:reason:)` that this file gives a
/// wall-clock bound, and the bound itself.
///
/// **Why per stage and not around the whole teardown.** The order
/// `cancelAll` → `editManager.stopAll` → `terminal.shutdown` →
/// `remote.disconnect` is an architecture invariant (`CLAUDE.md`), and a
/// single bound around all four would abandon the sequence wherever it
/// happened to be standing — leaving the later stages unrun and the log
/// unable to say which one did not come back. A bound per stage keeps the
/// order intact, keeps teardown running to its end, and makes every
/// abandonment local and nameable.
///
/// **Which stage actually needs this.** Measured against a `docker pause`d
/// peer with a real PTY shell open and a real SFTP download running at the
/// moment of the freeze, three runs each:
///
/// - `cancelAll`: returned in 0.004462916 s / 0.004904750 s / 0.005558917 s.
/// - `stopAll`: returned in 0.000214583 s / 0.000272750 s / 0.000562250 s.
/// - `terminal.shutdown`: did NOT return inside a 20-second watchdog, in
///   all three runs. This is the stage the bound exists for; it ends in
///   `CitadelShell.close()`, which is `pump.cancel()` plus an unbounded
///   `await pump.value`.
///
/// **`stopAll` is bounded anyway, and the honesty about that belongs here
/// rather than in a report:** it contains no `await` at all today, so its
/// bound cannot fire — it is insurance against a future suspension point,
/// not a fix for a measured hang.
///
/// **The two stages this type does NOT cover, and why.**
///
/// - `transferQueue.cancelAll(reason:)`, the first stage, is called
///   directly and is NOT bounded. It was wrapped here once, in `eed1c8a`,
///   and the maintainer removed the wrapper on 2026-08-28: the measurement
///   above says the bound catches nothing (three runs out of three against
///   a frozen peer, all back inside six milliseconds), while wrapping it
///   costs something real — `BoundedClose` runs its operation in a separate
///   task, so `teardown` suspends BEFORE the queue sweep instead of
///   sweeping it in teardown's own first main-actor turn. Swift offers no
///   third option: an async function cannot be run synchronously up to its
///   first suspension point inside another task, so it is the bound or the
///   synchronous head, and the measurement makes the synchronous head worth
///   more. `ContentView.teardown(_:reason:)` states what that leaves
///   unbounded; `LivenessGiveUpOrderingTests` pins both halves.
/// - `remote.disconnect()`, the fourth stage, carries its own bound inside
///   `CitadelFileSystem.disconnect()` — the one `7ac7f7e` installed around
///   the SFTP channel close. It is deliberately left as it is and is NOT
///   wrapped here; measured against the same frozen peer, `disconnect()`
///   came back in 5.002063 s, 5.304208 s and 5.333977 s across three runs,
///   i.e. its inner bound plus the parent closes.
enum TeardownStage: CaseIterable {
    case stopEditWatchers
    case shutDownTerminal

    /// The call this stage stands for, spelled the way `teardown(_:reason:)`
    /// spells it — this is what a log line has to name for the reader to find
    /// the abandoned step.
    var callSite: String {
        switch self {
        case .stopEditWatchers: "editManager.stopAll()"
        case .shutDownTerminal: "terminal.shutdown()"
        }
    }

    /// Five seconds, argued in both directions from measurements taken in the
    /// pass that introduced this type — never from a number carried over.
    ///
    /// **Downward.** The healthy cost of these two stages against the
    /// Docker rig on loopback, with a real PTY shell open, ten runs: the
    /// slowest `stopAll` was 0.000915167 s and the slowest
    /// `terminal.shutdown()` 0.004636166 s (the slowest whole four-stage
    /// teardown, for scale, was 0.006074334 s). Five seconds is more than a
    /// thousand times the slowest of those — headroom for a real line with
    /// a real round-trip time, which a loopback measurement cannot show.
    ///
    /// **Upward.** This bound is spent ON TOP of detection, which already
    /// costs two probe deadlines. Only one of the two stages was measured
    /// to fire it (see this type's own doc comment), so the realistic frozen
    /// path adds this bound once, not twice, before `disconnect()` spends
    /// its own.
    ///
    /// It is the same number as `CitadelFileSystem.sftpCloseBoundSeconds`
    /// and deliberately NOT derived from it: that one bounds a single SFTP
    /// channel close inside one backend, this one bounds two App-layer
    /// stages that a WebDAV or S3 session runs too. Same reasoning applied
    /// twice, not one quantity written twice — so moving one must not move
    /// the other.
    var boundSeconds: Int { 5 }

    /// Runs `operation` under this stage's bound. Returns whether it
    /// finished inside it; `false` means the stage was abandoned and
    /// teardown carried on to the next one.
    @discardableResult
    func runBounded(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await runBounded(boundSeconds: boundSeconds, operation)
    }

    /// The bound passed explicitly, so the ungated test can exercise the
    /// abandonment branch without spending five real seconds on it. Every
    /// production call site goes through the overload above.
    @discardableResult
    func runBounded(
        boundSeconds: Int, _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let finished = await BoundedClose.run(
            boundSeconds: boundSeconds, operation: operation)
        if !finished {
            // `os.Logger`, at `.error`, and not a new channel of any kind:
            // this file follows `EditorResolver`, which logs its one
            // "configured thing was unusable, carrying on" line the same way
            // under the same subsystem. The alternative on offer was an
            // `AuditEvent`, and it is the wrong shelf twice over — the audit
            // log exists for what the USER did to a STORED session, and
            // `tab.auditRecorder` is nil for an ad-hoc connect, so the
            // channel would be missing in half the cases this fires. What
            // the user needs to know (the connection is gone, these
            // transfers died with it) is already said by `liveness = .lost`
            // and the queue's own items; what is left over is a fact about
            // OUR cleanup, which is a diagnostic.
            //
            // `.error` rather than `.info`/`.debug` because only `.error`
            // and above are persisted to disk by default — a level that is
            // dropped unless someone enabled it in advance is not a record
            // of an event nobody was watching for.
            //
            // `privacy: .public` on both interpolations: neither is user
            // data (one is a fixed call site from `callSite`, the other an
            // integer), and without it the unified log redacts them to
            // `<private>`, which would leave a line that says a stage was
            // abandoned without saying which.
            Self.logger.error("""
                teardown stage \(callSite, privacy: .public) did not return \
                within \(boundSeconds, privacy: .public)s and was abandoned; \
                teardown continued with the next stage
                """)
        }
        return finished
    }

    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "Teardown")
}
