import Foundation
import MacSCPTestSupport
import Testing

/// Guards the shape of the connecting-surface branch and its Cancel control
/// in `ContentView+Detail.swift`'s `detail` (connection-liveness plan, Task
/// 6; fix round 1 replaced the ad-hoc completion guard this suite used to
/// pin — see below — with a Core-level fix, and added the Critical-1 fix
/// for the stored-session reconnect lock): three claims about that code,
/// each checked by scanning source text rather than by running it — this
/// project has no SwiftUI rendering harness (same boundary as
/// `LivenessProbeWiringGuardTests`/`LivenessDotWiringGuardTests`; see
/// either's doc comment for the same idiom).
///
/// 1. The connecting-vs-form choice comes from `detailSurface(for: tab)` —
///    `DetailSurfacePlan.surface`, which composes `ConnectionSurfacePlan
///    .surface` (jump-and-groups plan, Task 1) — not a condition
///    reimplemented inline, which could silently drift from
///    `ConnectionSurfacePlanTests`' and `DetailSurfacePlanTests`' pinned
///    cases. That the resolver reaches both plans is
///    `DetailSurfaceWiringGuardTests`' claim, not this suite's.
/// 2. Cancel calls BOTH `cancelConnecting()` (releases `ConnectionViewModel
///    .state`, and moves Core's own attempt token, without waiting on the
///    dial) and `teardown(` (the ONE teardown path the brief requires,
///    "nicht über einen eigenen Weg") — neither alone leaves the tab in a
///    sane state: without `cancelConnecting()` the form reappears still
///    disabled; without `teardown(` nothing resets `tab.liveness`/the
///    form's retained fields.
/// 3. Cancel also resets the stored-session reconnect lock
///    (`tab.reconnectAttempt`/`tab.isReconnecting`) — measured missing in
///    fix round 0 (Critical 1): without it, a Cancel on the stored-session
///    path leaves the sidebar disabled until the abandoned attempt's own
///    Task, still suspended on the dial, eventually reaches its `defer`.
///
/// Fix round 0 also had a fourth claim, about an App-layer guard
/// (`ConnectAttemptOutcome`) the ad-hoc form's completion closure used to
/// consult before calling `startSession`. That guard is gone: the review
/// that found Critical 2 also found the guard was a weaker version of the
/// same idea, keyed on a fact (`tab.liveness`) that cannot tell a
/// cancelled attempt from a brand-new one reading the same value — Core's
/// `ConnectionViewModel.currentAttempt` now refuses a superseded attempt's
/// write at the source, which is what actually closes that gap (and the
/// stored-session path's identical hole, which the removed App-layer guard
/// never covered at all). Nothing here re-guards `startSession(` for that
/// reason.
///
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced
/// brace all count as failures. Self-tested against synthetic source, so
/// the guard cannot pass silently just because the real file moved, was
/// reformatted past recognition, or failed to read.
///
/// Comment/string-stripped before any `contains` check (fix round 1,
/// measured against THIS suite: a mutation that deleted the real
/// `cancelConnecting()` call still passed, because the surrounding doc
/// comment names that method in prose, and a bare `.contains` check cannot
/// tell prose from code). See `SwiftSource.blankingCommentsAndStrings`'s own
/// doc comment (`Tests/MacSCPTestSupport/SwiftSourceStripping.swift`).
@Suite("Connecting attempt wiring guard")
struct ConnectingAttemptWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConnectingAttemptWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `LivenessProbeWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    /// Anchors the `let surface = detailSurface(for: tab)` read, the
    /// `if surface == .connecting` branch after it and its
    /// `ConnectingAttemptView(onCancel:)`, unique in the file
    /// (checked by `theSurfaceAnchorAppearsExactlyOnceInTheRealFile`).
    private static let surfaceAnchor = "// Connecting surface branch (connection-liveness plan, Task 6)"

    private enum ScanError: Error {
        case anchorNotFound, openBraceNotFound, unbalancedBraces
    }

    // MARK: - The three guarded claims, run against the real file

    @Test func theBranchAsksTheDetailSurfacePlan() throws {
        let body = try Self.strippedBody(after: Self.surfaceAnchor)
        #expect(body.contains("let surface = detailSurface(for: tab)"), """
            the connecting-vs-form branch no longer reads `detailSurface(for: tab)` — a \
            condition reimplemented inline here could drift from the pinned cases in \
            `ConnectionSurfacePlanTests` and `DetailSurfacePlanTests` without either suite \
            noticing.
            """)
    }

    @Test func cancelReleasesStateAndRunsTeardown() throws {
        let body = try Self.strippedBody(after: Self.surfaceAnchor)
        #expect(body.contains("tab.connectionViewModel.cancelConnecting()"), """
            the connecting branch no longer calls `tab.connectionViewModel.cancelConnecting()` \
            — without it `ConnectionViewModel.state` stays `.connecting` after Cancel, and \
            the form reappears still disabled.
            """)
        #expect(body.contains("teardown(tab, reason: .userRequested)"), """
            the connecting branch's Cancel no longer calls \
            `teardown(tab, reason: .userRequested)` — the brief requires Cancel to clean up \
            through the ONE teardown path, not a separate one, and `.userRequested` (not \
            `.connectionLost`) is what marks this a deliberate stop rather than a drop \
            (connection-liveness plan, Task 8, fix round 1).
            """)
    }

    @Test func cancelResetsTheReconnectLock() throws {
        let body = try Self.strippedBody(after: Self.surfaceAnchor)
        #expect(body.contains("tab.reconnectAttempt = UUID()"), """
            the connecting branch's Cancel no longer resets `tab.reconnectAttempt` — the \
            stored-session path's `defer { if tab.reconnectAttempt == myAttempt { tab \
            .isReconnecting = false } }` (`ContentView.connect(in:stored:)`) would then \
            release the lock for whichever attempt happens to be current when the ABANDONED \
            Task's own deferred cleanup eventually runs, not necessarily this one.
            """)
        #expect(body.contains("tab.isReconnecting = false"), """
            the connecting branch's Cancel no longer resets `tab.isReconnecting` directly — \
            without it, a stored-session connect's sidebar lock stays disabled until the \
            abandoned attempt's own wrapping Task, still suspended on the dial, eventually \
            reaches its `defer` (Critical 1, fix round 0 review).
            """)
    }

    @Test func theSurfaceAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try SourceCorpus.text(of: Self.detailFile)
        let count = source.components(separatedBy: Self.surfaceAnchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.surfaceAnchor)` in \
            ContentView+Detail.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerAcceptsABranchThatDelegatesToThePlanAndResetsTheLock() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if ConnectionSurfacePlan.surface(for: tab.liveness, hostKeyPromptPending: false) == .connecting {
                ConnectingAttemptView(onCancel: {
                    tab.connectionViewModel.cancelConnecting()
                    tab.reconnectAttempt = UUID()
                    tab.isReconnecting = false
                    Task { await teardown(tab, reason: .userRequested) }
                })
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(body.contains("ConnectionSurfacePlan.surface("))
        #expect(body.contains("tab.connectionViewModel.cancelConnecting()"))
        #expect(body.contains("teardown(tab, reason: .userRequested)"))
        #expect(body.contains("tab.reconnectAttempt = UUID()"))
        #expect(body.contains("tab.isReconnecting = false"))
    }

    @Test func scannerFlagsAnInlineReimplementationWithNoCancel() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if tab.liveness == .connecting {
                ConnectingAttemptView(onCancel: {})
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(!body.contains("ConnectionSurfacePlan.surface("))
        #expect(!body.contains("tab.connectionViewModel.cancelConnecting()"))
        #expect(!body.contains("tab.reconnectAttempt = UUID()"))
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        let source = "if tab.liveness == .connecting { ConnectingAttemptView(onCancel: {}) }"
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        }
    }

    /// The exact failure fix round 0 shipped, reproduced here as a
    /// regression test on the SCANNER itself: a doc comment mentioning the
    /// real method name in prose, with the actual call deleted, must NOT
    /// satisfy the check.
    @Test func scannerIsNotFooledByACommentNamingTheCall() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if ConnectionSurfacePlan.surface(for: tab.liveness, hostKeyPromptPending: false) == .connecting {
                ConnectingAttemptView(onCancel: {
                    // Best-effort (see `ConnectionViewModel.cancelConnecting()`'s own doc comment).
                    tab.reconnectAttempt = UUID()
                    tab.isReconnecting = false
                    Task { await teardown(tab, reason: .userRequested) }
                })
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(!body.contains("tab.connectionViewModel.cancelConnecting()"), """
            the comment naming `cancelConnecting()` must not satisfy the check once the \
            real call is deleted — the stripped body should no longer contain it.
            """)
    }

    /// Same shape, for a string literal instead of a comment — e.g. a log
    /// line or an error message that happens to name the call.
    @Test func scannerIsNotFooledByAStringLiteralNamingTheCall() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if ConnectionSurfacePlan.surface(for: tab.liveness, hostKeyPromptPending: false) == .connecting {
                ConnectingAttemptView(onCancel: {
                    logCancel("did not call tab.connectionViewModel.cancelConnecting() here")
                    tab.reconnectAttempt = UUID()
                    tab.isReconnecting = false
                    Task { await teardown(tab, reason: .userRequested) }
                })
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(!body.contains("tab.connectionViewModel.cancelConnecting()"), """
            a string literal naming `cancelConnecting()` must not satisfy the check once \
            the real call is deleted.
            """)
    }

    // The stripper's own behaviour (comment/string removal, line-structure
    // preservation, raw-string parsing, fail-closed on the unterminated
    // forms) used to have self-tests here; they are now pinned once, for
    // the shared implementation, by `SwiftSourceStrippingTests` in
    // `macSCPCoreTests` — see docs/BACKLOG.md, "Polish: terminal resize,
    // transfer cancel and paths".

    // MARK: - Scanner
    //
    // Anchors on the comment marker itself, then depth-counts braces from
    // the first opening `{` found after it to its matching close — the same
    // brace-matching technique `LivenessProbeWiringGuardTests`/
    // `LivenessDotWiringGuardTests` use. The extracted text is then run
    // through `SwiftSource.blankingCommentsAndStrings` before any caller sees it.

    /// Convenience over `strippedBody(after:in:)` for the real file — read
    /// through `SourceCorpus`, which reads each file at most once per test
    /// process, so every check in a run reads the file as it stood when the
    /// first of them asked for it.
    private static func strippedBody(after anchor: String) throws -> String {
        let source = try SourceCorpus.text(of: Self.detailFile)
        return try strippedBody(after: anchor, in: source)
    }

    /// The block's text: everything from right after `anchor` through the
    /// balanced-brace close of the first `{` found after it — INCLUDING the
    /// header text before that opening brace, not just what sits inside the
    /// braces (the surface anchor sits before the read the `if` switches
    /// on, `let surface = detailSurface(for: tab)`, which lives in the
    /// header, not the body — a scanner that dropped the header could never
    /// see it).
    /// Throws rather than returning `nil` so a missing anchor or an
    /// unbalanced file fails the calling test loudly, not as a silently-
    /// empty string that would make every `contains` check in the calling
    /// tests trivially false.
    ///
    /// Strips comments and string literals FIRST, from the text after the
    /// anchor, and only THEN counts braces on the result (fix round 2 —
    /// the previous order, brace-match-then-strip, let a `{` or `}`
    /// sitting inside a comment shift where the scanner believed the block
    /// ended, since at brace-matching time that character was still a real
    /// brace as far as the depth counter could tell; only after the match
    /// already happened did stripping remove it). The anchor itself is
    /// still found in the RAW, unstripped source — it is a `//` comment,
    /// and a whole-source strip first would delete it before it could ever
    /// be searched for.
    private static func strippedBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let stripped = try SwiftSource.blankingCommentsAndStrings(
            String(source[anchorRange.upperBound...]))
        guard let openBraceIndex = stripped.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < stripped.endIndex {
            let character = stripped[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[stripped.startIndex...index])
                }
            }
            index = stripped.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

}
