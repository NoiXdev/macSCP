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
/// **What the fourth stage does instead.** `remote.disconnect()` carries
/// its own bound, inside `CitadelFileSystem.disconnect()` — the one
/// `7ac7f7e` installed around the SFTP channel close. It is deliberately
/// left as it is and is NOT wrapped here; measured against a frozen peer in
/// the pass that added this file, `disconnect()` came back in 5.002063 s,
/// 5.304208 s and 5.333977 s across three runs, i.e. its inner bound plus
/// the parent closes. So all four stages are bounded; three of them from
/// here.
///
/// **Which stage actually needs this.** Measured in the same pass, against a
/// `docker pause`d peer with a real PTY shell open and a real SFTP download
/// running at the moment of the freeze, three runs each:
///
/// - `cancelAll`: returned in 0.004462916 s / 0.004904750 s / 0.005558917 s.
/// - `stopAll`: returned in 0.000214583 s / 0.000272750 s / 0.000562250 s.
/// - `terminal.shutdown`: did NOT return inside a 20-second watchdog, in
///   all three runs. This is the stage the bound exists for; it ends in
///   `CitadelShell.close()`, which is `pump.cancel()` plus an unbounded
///   `await pump.value`.
///
/// The two that return are bounded anyway, and the honesty about that
/// belongs here rather than in a report: `stopAll` contains no `await` at
/// all today, so its bound cannot fire — it is insurance against a future
/// suspension point, not a fix for a measured hang. `cancelAll` does
/// suspend (step 3 awaits every running transfer), and it is documented as
/// able to block on an open conflict prompt; it simply did not hang in the
/// scenario measured.
enum TeardownStage: CaseIterable {
    case cancelTransfers
    case stopEditWatchers
    case shutDownTerminal

    /// The call this stage stands for, spelled the way `teardown(_:reason:)`
    /// spells it — this is what a log line has to name for the reader to find
    /// the abandoned step.
    var callSite: String {
        switch self {
        case .cancelTransfers: "transferQueue.cancelAll(reason:)"
        case .stopEditWatchers: "editManager.stopAll()"
        case .shutDownTerminal: "terminal.shutdown()"
        }
    }

    /// Five seconds, argued in both directions from measurements taken in the
    /// pass that introduced this type — never from a number carried over.
    ///
    /// **Downward.** The healthy cost of these three stages against the
    /// Docker rig on loopback, with a real PTY shell open, ten runs: the
    /// slowest `cancelAll` on an empty queue was 0.000275333 s, the slowest
    /// `stopAll` 0.000915167 s, the slowest `terminal.shutdown()`
    /// 0.004636166 s, and the slowest whole four-stage teardown
    /// 0.006074334 s. `cancelAll` was measured separately with a transfer
    /// actually running (an 8 MB SFTP download, five runs), because an empty
    /// queue says nothing about the step that waits for one: slowest
    /// 0.007007209 s. Five seconds is more than seven hundred times the
    /// slowest of those — headroom for a real line with a real round-trip
    /// time, which a loopback measurement cannot show.
    ///
    /// **Upward.** This bound is spent ON TOP of detection, which already
    /// costs two probe deadlines. Only one of the three stages was measured
    /// to fire it (see this type's own doc comment), so the realistic frozen
    /// path adds this bound once, not three times, before `disconnect()`
    /// spends its own.
    ///
    /// It is the same number as `CitadelFileSystem.sftpCloseBoundSeconds`
    /// and deliberately NOT derived from it: that one bounds a single SFTP
    /// channel close inside one backend, this one bounds three App-layer
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
