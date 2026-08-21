import Foundation
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
/// 1. The connecting-vs-form choice comes from `ConnectionSurfacePlan
///    .surface(` — not a condition reimplemented inline, which could
///    silently drift from `ConnectionSurfacePlanTests`' pinned cases.
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
/// tell prose from code). See `stripCommentsAndStrings`'s own doc comment.
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

    /// Anchors the `if ConnectionSurfacePlan.surface(...) == .connecting`
    /// branch and its `ConnectingAttemptView(onCancel:)`, unique in the file
    /// (checked by `theSurfaceAnchorAppearsExactlyOnceInTheRealFile`).
    private static let surfaceAnchor = "// Connecting surface branch (connection-liveness plan, Task 6)"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - The three guarded claims, run against the real file

    @Test func theBranchAsksConnectionSurfacePlan() throws {
        let body = try Self.strippedBody(after: Self.surfaceAnchor)
        #expect(body.contains("ConnectionSurfacePlan.surface("), """
            the connecting-vs-form branch no longer calls `ConnectionSurfacePlan.surface(` — \
            a condition reimplemented inline here could drift from the pinned cases in \
            `ConnectionSurfacePlanTests` without either suite noticing.
            """)
    }

    @Test func cancelReleasesStateAndRunsTeardown() throws {
        let body = try Self.strippedBody(after: Self.surfaceAnchor)
        #expect(body.contains("tab.connectionViewModel.cancelConnecting()"), """
            the connecting branch no longer calls `tab.connectionViewModel.cancelConnecting()` \
            — without it `ConnectionViewModel.state` stays `.connecting` after Cancel, and \
            the form reappears still disabled.
            """)
        #expect(body.contains("teardown(tab)"), """
            the connecting branch's Cancel no longer calls `teardown(tab)` — the brief \
            requires Cancel to clean up through the ONE teardown path, not a separate one.
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
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
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
                    Task { await teardown(tab) }
                })
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(body.contains("ConnectionSurfacePlan.surface("))
        #expect(body.contains("tab.connectionViewModel.cancelConnecting()"))
        #expect(body.contains("teardown(tab)"))
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
                    Task { await teardown(tab) }
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
                    Task { await teardown(tab) }
                })
            }
            """
        let body = try Self.strippedBody(after: Self.surfaceAnchor, in: source)
        #expect(!body.contains("tab.connectionViewModel.cancelConnecting()"), """
            a string literal naming `cancelConnecting()` must not satisfy the check once \
            the real call is deleted.
            """)
    }

    @Test func stripperSelfTestRemovesLineAndBlockCommentsAndStringLiterals() {
        let source = #"""
            let a = "cancelConnecting()" // cancelConnecting()
            /* cancelConnecting() */ let b = 1
            let c = """
                cancelConnecting()
                """
            cancelConnecting()
            """#
        let stripped = Self.stripCommentsAndStrings(source)
        #expect(stripped.components(separatedBy: "cancelConnecting()").count - 1 == 1, """
            expected exactly 1 real occurrence of `cancelConnecting()` to survive stripping \
            (the un-commented, un-quoted call on the last line); found \
            \(stripped.components(separatedBy: "cancelConnecting()").count - 1).
            """)
    }

    // MARK: - Scanner
    //
    // Anchors on the comment marker itself, then depth-counts braces from
    // the first opening `{` found after it to its matching close — the same
    // brace-matching technique `LivenessProbeWiringGuardTests`/
    // `LivenessDotWiringGuardTests` use. The extracted text is then run
    // through `stripCommentsAndStrings` before any caller sees it.

    /// Convenience over `strippedBody(after:in:)` for the real file — reads
    /// it fresh on every call rather than caching it, so a test run always
    /// checks the file as it stands right now.
    private static func strippedBody(after anchor: String) throws -> String {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        return try strippedBody(after: anchor, in: source)
    }

    /// The block's text: everything from right after `anchor` through the
    /// balanced-brace close of the first `{` found after it — INCLUDING the
    /// header text before that opening brace, not just what sits inside the
    /// braces (the surface anchor sits before an `if`'s CONDITION,
    /// `ConnectionSurfacePlan.surface(...)`, which lives in the header, not
    /// the body — a scanner that dropped the header could never see it).
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
        let stripped = stripCommentsAndStrings(String(source[anchorRange.upperBound...]))
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

    /// Strips `//` and `/* */` comments and both `"..."` and `"""..."""`
    /// string literals from Swift source, replacing each with a single
    /// space (connection-liveness plan, Task 6 fix round 1) — so a
    /// `contains(...)` check below can no longer be satisfied by a doc
    /// comment or a log/error string merely NAMING the call it is meant to
    /// verify actually runs. Measured necessary, not theoretical: a
    /// mutation that deleted the real `cancelConnecting()` call from
    /// `ContentView+Detail.swift` still passed `cancelReleasesStateAndRunsTeardown`
    /// before this fix, because the surrounding doc comment names that
    /// method in prose.
    ///
    /// Applied to the text AFTER the anchor, before the brace scan runs
    /// over it (fix round 2 — see `strippedBody(after:in:)`'s own doc
    /// comment for why that order, not the reverse, matters) — not to the
    /// whole source before searching for the anchor itself, which is a
    /// `//` comment and would vanish under a global strip before it could
    /// ever be found.
    ///
    /// Handles `\"`-escaped quotes inside regular string literals and
    /// nested `/* */` block comments (Swift allows both). Does not attempt
    /// string-interpolation-aware parsing (`\(...)` inside a string literal
    /// is treated as ordinary string content and stripped along with the
    /// rest of the literal) — nothing in the regions this guard scans uses
    /// interpolation, and stripping a stray interpolation body along with
    /// its enclosing string is the safe direction for this guard's purpose
    /// (it can only make a `contains` check find LESS text, never invent a
    /// match that was not really code).
    private static func stripCommentsAndStrings(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                // Triple-quoted literal: skip to the closing `"""`.
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    i += 1
                }
                i = min(i + 3, chars.count)
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                i = min(i + 1, chars.count)
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
