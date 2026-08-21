import Foundation
import Testing

/// Guards the shape of the two connect-attempt-cancellation call sites in
/// `ContentView+Detail.swift`'s `detail` (connection-liveness plan, Task 6):
/// four claims about that code, each checked by scanning source text rather
/// than by running it — this project has no SwiftUI rendering harness (same
/// boundary as `LivenessProbeWiringGuardTests`/`LivenessDotWiringGuardTests`;
/// see either's doc comment for the same idiom).
///
/// 1. The connecting-vs-form choice comes from `ConnectionSurfacePlan
///    .surface(` — not a condition reimplemented inline, which could
///    silently drift from `ConnectionSurfacePlanTests`' pinned cases.
/// 2. Cancel calls BOTH `cancelConnecting()` (releases `ConnectionViewModel
///    .state` without waiting on the dial) and `teardown(` (the ONE
///    teardown path the brief requires, "nicht über einen eigenen Weg") —
///    neither alone leaves the tab in a sane state: without
///    `cancelConnecting()` the form reappears still disabled; without
///    `teardown(` nothing resets `tab.liveness`/the form's retained fields.
/// 3. The ad-hoc connect's completion asks `ConnectAttemptOutcome
///    .shouldApply(` — not a condition reimplemented inline.
/// 4. That guard runs BEFORE `startSession(` is called, not after — a
///    guard written after the call it is meant to gate would compile and
///    pass every other check while doing nothing.
///
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced
/// brace all count as failures. Self-tested against synthetic source, so
/// the guard cannot pass silently just because the real file moved, was
/// reformatted past recognition, or failed to read.
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

    /// Anchors the ad-hoc form's `onConnected` trailing closure, unique in
    /// the file (checked by `theGuardAnchorAppearsExactlyOnceInTheRealFile`).
    private static let completionAnchor = "// Connect completion guard (connection-liveness plan, Task 6)"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - The four guarded claims, run against the real file

    @Test func theBranchAsksConnectionSurfacePlan() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.blockBody(after: Self.surfaceAnchor, in: source)
        #expect(body.contains("ConnectionSurfacePlan.surface("), """
            the connecting-vs-form branch no longer calls `ConnectionSurfacePlan.surface(` — \
            a condition reimplemented inline here could drift from the pinned cases in \
            `ConnectionSurfacePlanTests` without either suite noticing.
            """)
    }

    @Test func cancelReleasesStateAndRunsTeardown() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.blockBody(after: Self.surfaceAnchor, in: source)
        // The full call expression, not bare `cancelConnecting()` — the
        // surrounding doc comment names `ConnectionViewModel
        // .cancelConnecting()` in prose, and a bare-method-name check would
        // still find that mention even with the real call deleted.
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

    @Test func theCompletionAsksConnectAttemptOutcome() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.blockBody(after: Self.completionAnchor, in: source)
        #expect(body.contains("ConnectAttemptOutcome.shouldApply("), """
            the ad-hoc connect's completion closure no longer calls \
            `ConnectAttemptOutcome.shouldApply(` — a condition reimplemented inline here \
            could drift from the pinned cases in `ConnectAttemptOutcomeTests` without \
            either suite noticing.
            """)
    }

    @Test func theGuardRunsBeforeStartSession() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.blockBody(after: Self.completionAnchor, in: source)
        guard let guardRange = body.range(of: "ConnectAttemptOutcome.shouldApply(") else {
            Issue.record("no `ConnectAttemptOutcome.shouldApply(` found in the completion closure.")
            return
        }
        guard let startSessionRange = body.range(of: "startSession(") else {
            Issue.record("no `startSession(` found in the completion closure.")
            return
        }
        #expect(guardRange.lowerBound < startSessionRange.lowerBound, """
            `startSession(` is called before `ConnectAttemptOutcome.shouldApply(` is even \
            consulted — a guard written after the call it is meant to gate does nothing.
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

    @Test func theGuardAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.completionAnchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.completionAnchor)` in \
            ContentView+Detail.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerAcceptsABranchThatDelegatesToThePlan() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if ConnectionSurfacePlan.surface(for: tab.liveness, hostKeyPromptPending: false) == .connecting {
                ConnectingAttemptView(onCancel: {
                    tab.connectionViewModel.cancelConnecting()
                    Task { await teardown(tab) }
                })
            }
            """
        let body = try Self.blockBody(after: Self.surfaceAnchor, in: source)
        #expect(body.contains("ConnectionSurfacePlan.surface("))
        #expect(body.contains("tab.connectionViewModel.cancelConnecting()"))
        #expect(body.contains("teardown(tab)"))
    }

    @Test func scannerFlagsAnInlineReimplementationWithNoCancel() throws {
        let source = """
            // Connecting surface branch (connection-liveness plan, Task 6)
            if tab.liveness == .connecting {
                ConnectingAttemptView(onCancel: {})
            }
            """
        let body = try Self.blockBody(after: Self.surfaceAnchor, in: source)
        #expect(!body.contains("ConnectionSurfacePlan.surface("))
        #expect(!body.contains("tab.connectionViewModel.cancelConnecting()"))
    }

    @Test func scannerFlagsAGuardWrittenAfterTheCall() throws {
        let source = """
            // Connect completion guard (connection-liveness plan, Task 6)
            ) { fs in
                startSession(in: tab, with: fs, startPath: "/")
                guard ConnectAttemptOutcome.shouldApply(livenessAtCompletion: tab.liveness) else { return }
            }
            """
        let body = try Self.blockBody(after: Self.completionAnchor, in: source)
        let guardRange = try #require(body.range(of: "ConnectAttemptOutcome.shouldApply("))
        let startSessionRange = try #require(body.range(of: "startSession("))
        #expect(startSessionRange.lowerBound < guardRange.lowerBound)
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        let source = "if tab.liveness == .connecting { ConnectingAttemptView(onCancel: {}) }"
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.blockBody(after: Self.surfaceAnchor, in: source)
        }
    }

    // MARK: - Scanner
    //
    // Anchors on the comment marker itself, then depth-counts braces from
    // the first opening `{` found after it to its matching close — the same
    // brace-matching technique `LivenessProbeWiringGuardTests`/
    // `LivenessDotWiringGuardTests` use.

    /// The block's text: everything from right after `anchor` through the
    /// balanced-brace close of the first `{` found after it — INCLUDING the
    /// header text before that opening brace, not just what sits inside the
    /// braces. Both anchors in this file sit before an `if`'s CONDITION
    /// (`ConnectionSurfacePlan.surface(...)`) or a trailing closure's
    /// parameter list, and both of those live in the header, not the body —
    /// a scanner that dropped the header could never see either. Throws
    /// rather than returning `nil` so a missing anchor or an unbalanced file
    /// fails the calling test loudly, not as a silently-empty string that
    /// would make every `contains` check in the calling tests trivially
    /// false.
    private static func blockBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let afterAnchor = source[anchorRange.upperBound...]
        guard let openBraceIndex = afterAnchor.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < afterAnchor.endIndex {
            let character = afterAnchor[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(afterAnchor[afterAnchor.startIndex...index])
                }
            }
            index = afterAnchor.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }
}
