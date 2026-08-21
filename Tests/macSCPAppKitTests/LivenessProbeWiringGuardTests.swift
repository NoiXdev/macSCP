import Foundation
import Testing

/// Guards the shape of the liveness-probe loop in `ContentView+Detail.swift`
/// (connection-liveness plan, Task 4): three claims about that loop, each
/// checked by scanning source text rather than by running it.
///
/// 1. The keep-alive interval is read INSIDE the `while`, every lap — not
///    hoisted to a `let` above it, which would freeze the value at the
///    loop's first iteration and ignore a setting changed mid-session.
/// 2. The probe/retry/give-up decision comes from `LivenessProbePolicy
///    .decide(...)` (Task 1) — not a condition rewritten inline, which
///    could silently drift from that policy without either test suite
///    noticing.
/// 3. A `.giveUp` verdict tears the session down through the existing
///    `teardown(_:)` path — not a second, ad-hoc route that could skip a
///    step of the invariant order (`cancelAll` → terminal `shutdown` →
///    `disconnect`).
///
/// Same boundary as this project's other wiring guards (see
/// `ConnectTimeoutAppWiringGuardTests`'s doc comment, right beside this
/// file): this project has no SwiftUI rendering harness, so a `.task(id:)`
/// closure's shape can only be checked by reading it, not by running it.
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced brace
/// all count as failures. Self-tested against synthetic source below, so
/// the guard cannot pass silently just because the real file moved, was
/// reformatted past recognition, or failed to read.
@Suite("Liveness probe loop wiring guard")
struct LivenessProbeWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/LivenessProbeWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectTimeoutAppWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    /// Anchors the probe loop's own `.task(id:)` — distinct from the
    /// auto-refresh loop's `.task(id: session.id)` a few lines above it in
    /// the same file (checked unique against the real file by
    /// `theAnchorAppearsExactlyOnceInTheRealFile` below).
    private static let anchor = "// Liveness probe (Task 4)"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - The three guarded claims, run against the real file

    @Test func theLoopReadsTheIntervalInsideItself() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(body.contains("settingsStore.keepAliveIntervalSeconds"), """
            the probe loop's body no longer reads \
            `settingsStore.keepAliveIntervalSeconds` inside the `while` — a read \
            hoisted above the loop would freeze the interval at the loop's first \
            lap and ignore a setting changed mid-session.
            """)
    }

    @Test func theLoopDecidesThroughLivenessProbePolicy() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(body.contains("LivenessProbePolicy.decide("), """
            the probe loop's body no longer calls `LivenessProbePolicy.decide(` — \
            a condition rewritten inline could drift from Task 1's policy without \
            either test suite noticing.
            """)
    }

    @Test func giveUpRoutesThroughTeardown() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        guard let giveUpCase = Self.caseBody(named: ".giveUp", in: body) else {
            Issue.record("no `case .giveUp:` found inside the probe loop — re-anchor this guard.")
            return
        }
        #expect(giveUpCase.contains("await teardown(tab)"), """
            the `.giveUp` case no longer calls `await teardown(tab)` — a separate \
            teardown route could bypass the invariant order (`cancelAll` → \
            terminal `shutdown` → `disconnect`) this project's ONE teardown path \
            guarantees.
            """)
    }

    /// Fail-closed check, same reasoning as
    /// `ConnectTimeoutAppWiringGuardTests.theAnchorAppearsExactlyOnceInTheRealFile`:
    /// if the anchor ever stops being unique, the three claims above could be
    /// scanning the wrong loop silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in \
            ContentView+Detail.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerFlagsAnIntervalHoistedAboveTheLoop() throws {
        let source = """
            // Liveness probe (Task 4)
            let interval = settingsStore.keepAliveIntervalSeconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                let action = LivenessProbePolicy.decide(
                    queueIsBusy: tab.transferQueue.isActive, consecutiveFailures: failures)
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(!body.contains("settingsStore.keepAliveIntervalSeconds"))
    }

    @Test func scannerAcceptsTheIntervalReadInsideTheLoop() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                let action = LivenessProbePolicy.decide(
                    queueIsBusy: tab.transferQueue.isActive, consecutiveFailures: failures)
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(body.contains("settingsStore.keepAliveIntervalSeconds"))
    }

    @Test func scannerFlagsAnInlineDecisionRewrite() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                if failures >= 2 {
                    tab.session?.liveness = .lost
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(!body.contains("LivenessProbePolicy.decide("))
    }

    @Test func scannerFlagsAGiveUpThatBypassesTeardown() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                switch action {
                case .giveUp:
                    tab.session?.liveness = .lost
                    await session.remote.disconnect()
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let giveUpCase = try #require(Self.caseBody(named: ".giveUp", in: body))
        #expect(!giveUpCase.contains("await teardown(tab)"))
    }

    @Test func scannerAcceptsAGiveUpThatCallsTeardown() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                switch action {
                case .giveUp:
                    tab.session?.liveness = .lost
                    await teardown(tab)
                    return
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let giveUpCase = try #require(Self.caseBody(named: ".giveUp", in: body))
        #expect(giveUpCase.contains("await teardown(tab)"))
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        let source = "while !Task.isCancelled { let interval = settingsStore.keepAliveIntervalSeconds }"
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.loopBody(after: Self.anchor, in: source)
        }
    }

    // MARK: - Scanner
    //
    // Anchors on the comment marker itself, then depth-counts braces from
    // the loop's own opening `{` to its matching close — the same
    // brace-matching technique `ConnectTimeoutAppWiringGuardTests` uses for
    // a call's parens, applied here to a `while` block instead.

    /// The probe loop's body text: everything between the `while` block's
    /// own opening `{` (the first one found after `anchor`) and its
    /// balanced-brace close. Throws rather than returning `nil` so a
    /// missing anchor or an unbalanced file fails the calling test loudly,
    /// not as a silently-empty string that would make every `contains`
    /// check below trivially false.
    private static func loopBody(after anchor: String, in source: String) throws -> String {
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
                    let bodyStart = afterAnchor.index(after: openBraceIndex)
                    return String(afterAnchor[bodyStart..<index])
                }
            }
            index = afterAnchor.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    /// The text of one `case <marker>:` arm, from just after its colon up to
    /// (but not including) the next `case ` at the start of a line, or the
    /// end of `text` if this is the switch's last arm. No brace-depth
    /// tracking needed: none of this loop's `case` bodies open a nested
    /// `switch`, so the next line-leading `case ` unambiguously belongs to
    /// the same enclosing `switch`.
    private static func caseBody(named marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: "case \(marker):") else { return nil }
        let rest = text[markerRange.upperBound...]
        if let nextCaseRange = rest.range(of: "\ncase ") {
            return String(rest[..<nextCaseRange.lowerBound])
        }
        return String(rest)
    }
}
