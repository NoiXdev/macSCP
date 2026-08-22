import Foundation
import Testing

/// Guards the wiring this task's brief calls its load-bearing security
/// decision: **the reconnect runs through the same connect path as a fresh
/// connect** (connection-liveness plan, Task 7). Plus the three other
/// claims about code no test in this project can render — the lost-surface
/// branch, the unattended schedule, and the tab-strip dot precedence.
///
/// Why a source scan at all: this project has no SwiftUI rendering harness
/// (the same boundary `ConnectingAttemptWiringGuardTests`,
/// `LivenessProbeWiringGuardTests` and `LivenessDotWiringGuardTests`
/// document). Everything decidable was deliberately moved into plain
/// functions and is tested by value in `ReconnectPlanTests`; what remains
/// here is exactly the part that cannot be: whether the views and the
/// reconnect entry point still ASK those functions instead of deciding
/// again, and whether the redial still goes through the shared connect.
///
/// The four claims:
///
/// 1. `ContentView.reconnect(_:)` dials by calling `connect(in:stored:)` —
///    the same function a sidebar click and the form's own Connect go
///    through — and names no backend, descriptor or file-system dial of its
///    own. A second dial here is the second place TOFU, the keychain rules
///    and the plaintext confirmation could be forgotten; the design spec
///    calls that out as the decision this whole section rests on.
/// 2. `ContentView.detail`'s lost branch renders `LostConnectionPlan
///    .content`'s answer and routes its two buttons to `reconnect(_:)` /
///    `dismissLostConnection(_:)`, rather than assembling text or clearing
///    state inline.
/// 3. `ReconnectRunner` asks `ReconnectPlan.step(...)`, counts the attempt
///    before dialing, and calls `onAttempt`.
/// 4. `TabItemView.indicator` asks `TabIndicatorPlan.indicator(...)` and
///    hands it `tab.liveness` — the value the `.lost` suppression is
///    decided from. A version that kept the call and dropped that argument
///    would compile-fail, which is why the argument is checked by name
///    here: it is the difference between the rule being wired and merely
///    being available.
///
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced
/// brace all count as failures. Self-tested against synthetic source below,
/// so the scanner cannot pass silently just because a real file moved or
/// was reformatted past recognition.
///
/// Comment/string-stripped before any `contains` check — the exact
/// mutation that defeated an earlier guard on this branch was a doc comment
/// naming the call whose real invocation had been deleted. See
/// `stripCommentsAndStrings`'s own doc comment.
@Suite("Reconnect wiring guard")
struct ReconnectWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectingAttemptWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func file(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    private static let contentViewFile = file("Sources/MacSCPAppKit/ContentView.swift")
    private static let detailFile = file("Sources/MacSCPAppKit/ContentView+Detail.swift")
    private static let tabStripFile = file("Sources/MacSCPAppKit/TabStripView.swift")

    /// Declaration lines, not comments, wherever the declaration is what
    /// the claim is about: a renamed function or type must fail this suite
    /// loudly ("re-anchor this guard") rather than quietly scanning some
    /// other block. The one comment anchor
    /// (`lostBranchAnchor`) exists because that branch has no declaration
    /// of its own to anchor on — see its own use site in the source, which
    /// says as much.
    private static let reconnectAnchor = "func reconnect(_ tab: SessionTab)"
    private static let lostBranchAnchor = "// Lost surface branch (connection-liveness plan, Task 7)"
    private static let runnerAnchor = "struct ReconnectRunner: View"
    private static let mirrorWriteAnchor = "// Liveness mirror write (connection-liveness plan, Task 7)"
    private static let indicatorAnchor = "private var indicator: TabIndicatorPlan.Indicator"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - Claim 1: the reconnect uses the shared connect path

    @Test func theReconnectDialsThroughTheSharedConnect() throws {
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: Self.contentViewFile)
        #expect(body.contains("connect(in: tab, stored: stored)"), """
            `ContentView.reconnect(_:)` no longer calls `connect(in:stored:)`. The reconnect \
            must go through the SAME connect path a fresh connect takes — that is what keeps \
            TOFU a hard stop, the keychain rules unchanged, and the plaintext confirmation \
            asked, without a second path where any of them could be forgotten.
            """)
    }

    /// The negative half of the same claim, and the one that actually
    /// catches a second path being grown here: a redial that reached for a
    /// backend, a descriptor, a file system or the form's own `connect()`
    /// would be exactly the "zweiter Pfad" the design spec forbids.
    @Test(arguments: [
        ".connect(", "BackendDescriptor", "RemoteFileSystem", "CitadelFileSystem", "SSHClient",
    ])
    func theReconnectNamesNoDialOfItsOwn(forbidden: String) throws {
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: Self.contentViewFile)
        #expect(!body.contains(forbidden), """
            `ContentView.reconnect(_:)` now mentions `\(forbidden)` in code. A reconnect that \
            dials anything itself is a second connect path, and with it a second place a \
            security rule can be forgotten.
            """)
    }

    // MARK: - Claim 2: the lost branch delegates

    @Test func theLostBranchRendersThePlansContent() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("surface == .lost"), """
            the lost branch no longer tests `surface == .lost` — the surface choice must stay \
            `ConnectionSurfacePlan.surface`'s answer, whose cases `ConnectionSurfacePlanTests` \
            pins.
            """)
        #expect(body.contains("LostConnectionPlan.content("), """
            the lost branch no longer asks `LostConnectionPlan.content(` — text assembled \
            inline here would escape `ReconnectPlanTests`' check that this surface can only \
            ever show a fixed set of catalog keys, which is what keeps a host name, a server \
            message or a typed value off it.
            """)
    }

    @Test func theLostBranchRoutesBothButtonsToTheirRealHandlers() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("reconnect(tab)"), """
            the lost surface's Reconnect button no longer calls `reconnect(tab)`.
            """)
        #expect(body.contains("dismissLostConnection(tab)"), """
            the lost surface's dismissal no longer calls `dismissLostConnection(tab)` — \
            clearing only one of `liveness`/`lostConnection` inline would leave either the \
            surface up or an unattended schedule running behind the form.
            """)
    }

    // MARK: - Claim 3: the unattended schedule delegates

    @Test func theRunnerAsksTheReconnectPlan() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("ReconnectPlan.step("), """
            `ReconnectRunner` no longer calls `ReconnectPlan.step(` — a schedule reimplemented \
            inside this view would drift from the behaviours `ReconnectPlanTests` pins, \
            including the rule that an attempt needing a person is never repeated unattended.
            """)
        #expect(body.contains("Task.sleep"), """
            `ReconnectRunner` no longer sleeps — an attempt fired without the backoff the plan \
            hands it is a retry storm, not a schedule.
            """)
    }

    @Test func theRunnerCountsTheAttemptAndFiresIt() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("automaticAttempts += 1"), """
            `ReconnectRunner` no longer counts the attempt — `ReconnectPlan.step` paces itself \
            by that count, so without it `.onceThenAsk` would retry forever and `.automatic` \
            would never back off past its first delay.
            """)
        #expect(body.contains("onAttempt(tab)"), """
            `ReconnectRunner` no longer calls `onAttempt(tab)` — the schedule would run and \
            nothing would be dialed.
            """)
    }

    // MARK: - Claim 3b: the mirror delegates

    @Test func theLivenessMirrorAsksItsPlan() throws {
        let body = try Self.strippedBody(after: Self.mirrorWriteAnchor, in: Self.detailFile)
        #expect(body.contains("ConnectAttemptLivenessPlan.write("), """
            `ConnectAttemptLivenessMirror` no longer asks `ConnectAttemptLivenessPlan.write(` \
            — the case Task 7 added (a failed attempt on a tab that is describing a lost \
            connection goes back to the lost surface, not to the form) lives only there.
            """)
        #expect(body.contains("tab.lostConnection?.reason = reason"), """
            the mirror no longer writes back the reason the plan derived — the reconnect \
            schedule reads `lostConnection.reason`, so without this write an attempt that \
            stopped at a host key or a passphrase would keep being repeated unattended.
            """)
    }

    // MARK: - Claim 4: the tab-strip dot precedence

    @Test func theTabIndicatorAsksItsPlanAndHandsItTheLiveness() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(body.contains("TabIndicatorPlan.indicator("), """
            `TabItemView.indicator` no longer calls `TabIndicatorPlan.indicator(` — the \
            attention/activity rules, including the `.lost` suppression, would be decided in a \
            view body nothing can render.
            """)
        #expect(body.contains("liveness: tab.liveness"), """
            `TabItemView.indicator` no longer threads `tab.liveness` into the plan. This is \
            the mutation shape this branch has already been bitten by twice: the call stays, \
            the value it decides from does not, and the suppression silently stops happening \
            while every plan test still passes.
            """)
    }

    /// The negative half: the old inline decision must be gone, not merely
    /// shadowed by a call placed above it.
    @Test func theTabIndicatorDecidesNothingItself() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(!body.contains("return .attention"), """
            `TabItemView.indicator` decides `.attention` itself again — that is the \
            pre-Task-7 body, which had no way to know about `.lost`.
            """)
    }

    // MARK: - Anchor uniqueness

    @Test(arguments: [
        (reconnectAnchor, "Sources/MacSCPAppKit/ContentView.swift"),
        (lostBranchAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (runnerAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (mirrorWriteAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (indicatorAnchor, "Sources/MacSCPAppKit/TabStripView.swift"),
    ])
    func everyAnchorAppearsExactlyOnceInItsRealFile(anchor: String, relativePath: String) throws {
        let source = try String(contentsOf: Self.file(relativePath), encoding: .utf8)
        let count = source.components(separatedBy: anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(anchor)` in \(relativePath), found \(count) — \
            re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source)

    @Test func scannerAcceptsAReconnectThatDelegates() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                guard let stored = reconnectTarget(for: tab) else { return }
                connect(in: tab, stored: stored)
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(body.contains("connect(in: tab, stored: stored)"))
        #expect(!body.contains(".connect("))
    }

    /// The failure this guard exists for: a reconnect that grew its own
    /// dial instead of going through the shared path.
    @Test func scannerFlagsAReconnectThatDialsItself() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                let fs = try? await CitadelFileSystem.connect(config, decider)
                startSession(in: tab, with: fs)
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
        #expect(body.contains(".connect("))
        #expect(body.contains("CitadelFileSystem"))
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.strippedBody(after: Self.reconnectAnchor, in: "func somethingElse() {}")
        }
    }

    /// The exact mutation that defeated an earlier guard on this branch,
    /// reproduced against THIS scanner: a comment naming the call, with the
    /// real call deleted, must not satisfy the check.
    @Test func scannerIsNotFooledByACommentNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                // Goes through connect(in: tab, stored: stored), the shared path.
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func scannerIsNotFooledByAStringLiteralNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                log("connect(in: tab, stored: stored)")
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func stripperSelfTestRemovesLineAndBlockCommentsAndStringLiterals() {
        let source = #"""
            let a = "ReconnectPlan.step(" // ReconnectPlan.step(
            /* ReconnectPlan.step( */ let b = 1
            let c = """
                ReconnectPlan.step(
                """
            ReconnectPlan.step(
            """#
        let stripped = Self.stripCommentsAndStrings(source)
        #expect(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1 == 1, """
            expected exactly 1 real occurrence of `ReconnectPlan.step(` to survive stripping \
            (the un-commented, un-quoted call on the last line); found \
            \(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1).
            """)
    }

    // MARK: - Scanner
    //
    // Anchors on the marker, then depth-counts braces from the first
    // opening `{` found after it to its matching close, over text that has
    // already had comments and string literals removed. The returned text
    // starts at the anchor, not at that brace: several claims above are
    // about a call in the block's HEADER (a `switch` subject, an `if`
    // condition), which a scanner that dropped the header could never see.
    // Same technique and same reasoning as
    // `ConnectingAttemptWiringGuardTests`' own scanner.

    private static func strippedBody(after anchor: String, in file: URL) throws -> String {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try strippedBody(after: anchor, in: source)
    }

    /// Strips comments and string literals FIRST, from the text after the
    /// anchor, and only THEN counts braces on the result: a `{` or `}`
    /// inside a comment would otherwise shift where the scanner believes
    /// the block ends, since at brace-matching time it is still a brace as
    /// far as a depth counter can tell. The anchor itself is found in the
    /// RAW source — one of the anchors is a `//` comment, which a
    /// whole-source strip would delete before it could be searched for.
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
    /// space — so a `contains(...)` check cannot be satisfied by a doc
    /// comment or a log/error string merely NAMING the call it is meant to
    /// verify actually runs. Measured necessary on this branch, not
    /// theoretical: see `ConnectingAttemptWiringGuardTests`' own copy, whose
    /// doc comment records the mutation that got through without it.
    ///
    /// Handles `\"`-escaped quotes and nested `/* */` block comments. Does
    /// not parse string interpolation (`\(...)` inside a literal is treated
    /// as string content and stripped with it) — that can only make a
    /// `contains` check find LESS text, never invent a match that was not
    /// code.
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
