import Foundation
import Testing

/// Guards the shape of the liveness-probe loop in `ContentView+Detail.swift`
/// (connection-liveness plan, Task 4; fix round 1 moved the loop from
/// `ContentView.detail` into `LivenessProbeRunner.body`, still in the same
/// file — see that type's own doc comment for why): five claims about that
/// loop, each checked by scanning source text rather than by running it.
///
/// 1. The keep-alive interval is read INSIDE the `while`, every lap — not
///    hoisted to a `let` outside it, which would freeze the value at the
///    loop's first iteration and ignore a setting changed mid-session.
/// 2. The probe/retry/give-up decision comes from `LivenessProbePolicy
///    .decide(...)` (Task 1) — not a condition rewritten inline, which
///    could silently drift from that policy without either test suite
///    noticing.
/// 3. A `.giveUp` verdict delegates to `onGiveUp` — not a second,
///    ad-hoc route reimplementing what that callback already does.
/// 4. The probe arm races and writes through `LivenessProbeStep.perform`,
///    writes no liveness of its own, and STOPS on `.abandoned` (whole-branch
///    final review, finding I-1). A race spelled out here again, with the
///    write straight after its `await`, is the defect itself: the race
///    cannot be cut short by cancelling the task around it, so that write
///    lands on a tab already torn down. `LivenessProbeCancellationTests`
///    proves the guarded function refuses it; this claim is what keeps the
///    loop asking that function rather than inlining a second, unguarded
///    copy — the same split as claim 3.
/// 5. `settingsStore.keepAliveEnabled` is checked BEFORE the interval is
///    read, every lap (keep-alive-two-settings plan, Task 2). Since Task 1
///    made `keepAliveIntervalSeconds` always read 15…600 — a stored `0` now
///    reads as the default, not as "off" — an enabled check placed AFTER
///    the interval read, or missing outright, would leave the loop with no
///    way left to skip probing at all.
///
/// Claim 3 used to assert the `.giveUp` case called `teardown(_:)`
/// literally, which a reviewer defeated (fix round 3) by swapping that
/// call with `tab.liveness = .lost` — a source scan cannot see WHICH
/// statement ran first, only that both are spelled somewhere in the case
/// body. That property now belongs to `LivenessGiveUpOrderingTests`, which
/// drives the real `ContentView.handleLivenessGiveUp(_:)` and observes the
/// order actually held; this claim only pins that `.giveUp` asks that
/// function rather than reimplementing its two statements inline, the same
/// role `LivenessProbeCoverageTests`/`LivenessProbeMountGuardTests` split
/// between them for WHICH tabs get probed.
///
/// Same boundary as this project's other wiring guards (see
/// `ConnectTimeoutAppWiringGuardTests`'s doc comment for the same idiom):
/// this project has no SwiftUI rendering harness, so a `.task(id:)`
/// closure's shape can only be checked by reading it, not by running it.
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced brace
/// all count as failures. Self-tested against synthetic source, so the
/// guard cannot pass silently just because the real file moved, was
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

    /// Anchors the probe loop's own `.task(id:)`, unique in the file
    /// (checked by `theAnchorAppearsExactlyOnceInTheRealFile`).
    private static let anchor = "// Liveness probe (Task 4)"

    /// The probe arm's own `case` label, spelled exactly as the loop
    /// spells it — `caseBody(named:)` matches the whole label, so both
    /// actions have to be named here.
    private static let probeCase = ".probe, .probeAgainNow"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - The five guarded claims, run against the real file

    @Test func theLoopReadsTheIntervalInsideItself() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(body.contains("settingsStore.keepAliveIntervalSeconds"), """
            the probe loop's body no longer reads \
            `settingsStore.keepAliveIntervalSeconds` inside the `while` — a read \
            hoisted outside the loop would freeze the interval at the loop's \
            first lap and ignore a setting changed mid-session.
            """)
    }

    @Test func theLoopChecksKeepAliveEnabledBeforeReadingTheInterval() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        guard let enabledRange = body.range(of: "guard settingsStore.keepAliveEnabled else") else {
            Issue.record("""
                the probe loop's body no longer calls \
                `guard settingsStore.keepAliveEnabled else` — with \
                `keepAliveIntervalSeconds` always reading 15…600 (Task 1: a \
                stored `0` reads as the default), the switch is the only thing \
                left that can turn probing off at all.
                """)
            return
        }
        guard let intervalRange = body.range(of: "settingsStore.keepAliveIntervalSeconds") else {
            Issue.record("the probe loop's body no longer reads `settingsStore.keepAliveIntervalSeconds` — re-anchor this guard.")
            return
        }
        #expect(enabledRange.lowerBound < intervalRange.lowerBound, """
            `settingsStore.keepAliveIntervalSeconds` is read before \
            `settingsStore.keepAliveEnabled` is checked — a store with the \
            switch off but an interval configured (always ≥ 15 now) would \
            fall through to probing, since there is no `0` sentinel left to \
            catch it.
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

    @Test func giveUpDelegatesToOnGiveUp() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        guard let giveUpCase = Self.caseBody(named: ".giveUp", in: body) else {
            Issue.record("no `case .giveUp:` found inside the probe loop — re-anchor this guard.")
            return
        }
        #expect(giveUpCase.contains("await onGiveUp(tab)"), """
            the `.giveUp` case no longer calls `await onGiveUp(tab)` — reimplementing \
            its `teardown(_:)`-then-`.lost` order inline here would bring back the \
            exact ordering bug `LivenessGiveUpOrderingTests` exists to catch, since \
            that order is no longer provable by reading this file alone.
            """)
    }

    @Test func theProbeArmGoesThroughTheGuardedStep() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.loopBody(after: Self.anchor, in: source)
        guard let probeCase = Self.caseBody(named: Self.probeCase, in: body) else {
            Issue.record("no `case \(Self.probeCase):` found inside the probe loop — re-anchor this guard.")
            return
        }
        #expect(probeCase.contains("LivenessProbeStep.perform("), """
            the probe arm no longer calls `LivenessProbeStep.perform(` — that function is \
            where the race and the write of its result sit together with the cancellation \
            guard between them, and a race run here instead would put the write back \
            straight after an `await` that cancellation cannot shorten.
            """)
        #expect(!probeCase.contains("tab.liveness ="), """
            the probe arm writes `tab.liveness` itself again — every write of a probe's \
            answer belongs behind `LivenessProbeStep.perform`'s own guard, since a write \
            spelled out here is a write with nothing in front of it.
            """)
        #expect(probeCase.contains("guard result != .abandoned else { return }"), """
            the probe arm no longer stops on `.abandoned` — a probe whose task was \
            cancelled, or whose session went away, must end the loop rather than be \
            counted as a failed probe against a connection nobody is watching any more.
            """)
    }

    /// Fail-closed check, same reasoning as
    /// `ConnectTimeoutAppWiringGuardTests.theAnchorAppearsExactlyOnceInTheRealFile`:
    /// if the anchor ever stops being unique, the five claims this suite
    /// makes could be scanning the wrong loop silently.
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
                guard settingsStore.keepAliveEnabled else {
                    try? await Task.sleep(for: .seconds(LivenessProbePolicy.idleRecheckSeconds))
                    continue
                }
                let interval = settingsStore.keepAliveIntervalSeconds
                let action = LivenessProbePolicy.decide(
                    queueIsBusy: tab.transferQueue.isActive, consecutiveFailures: failures)
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(body.contains("settingsStore.keepAliveIntervalSeconds"))
    }

    @Test func scannerFlagsALoopThatNeverChecksKeepAliveEnabled() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(!body.contains("guard settingsStore.keepAliveEnabled else"))
    }

    @Test func scannerAcceptsALoopThatChecksKeepAliveEnabledBeforeTheInterval() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                guard settingsStore.keepAliveEnabled else {
                    try? await Task.sleep(for: .seconds(LivenessProbePolicy.idleRecheckSeconds))
                    continue
                }
                let interval = settingsStore.keepAliveIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let enabledRange = try #require(body.range(of: "guard settingsStore.keepAliveEnabled else"))
        let intervalRange = try #require(body.range(of: "settingsStore.keepAliveIntervalSeconds"))
        #expect(enabledRange.lowerBound < intervalRange.lowerBound)
    }

    @Test func scannerFlagsALoopThatChecksKeepAliveEnabledAfterTheInterval() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                guard settingsStore.keepAliveEnabled else {
                    try? await Task.sleep(for: .seconds(LivenessProbePolicy.idleRecheckSeconds))
                    continue
                }
                try? await Task.sleep(for: .seconds(interval))
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let enabledRange = try #require(body.range(of: "guard settingsStore.keepAliveEnabled else"))
        let intervalRange = try #require(body.range(of: "settingsStore.keepAliveIntervalSeconds"))
        #expect(!(enabledRange.lowerBound < intervalRange.lowerBound))
    }

    /// A raw-text scan cannot tell a real guard from a comment quoting it —
    /// this fixture has the real `guard settingsStore.keepAliveEnabled else`
    /// removed entirely and only a comment spelling that same text out.
    /// `loopBody` has to strip `//` line comments from the body before the
    /// claims run, or this fixture would read as if the guard were present.
    @Test func scannerFlagsAGuardWrittenOnlyAsAComment() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                // The real guard used to read:
                // guard settingsStore.keepAliveEnabled else { continue }
                let interval = settingsStore.keepAliveIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(!body.contains("guard settingsStore.keepAliveEnabled else"), """
            a comment quoting the real guard's text satisfied this check with \
            the real guard removed — `loopBody` must strip line comments \
            before the claims run.
            """)
    }

    @Test func scannerFlagsAnInlineDecisionRewrite() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                if failures >= 2 {
                    tab.liveness = .lost
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        #expect(!body.contains("LivenessProbePolicy.decide("))
    }

    @Test func scannerFlagsAGiveUpThatReimplementsInline() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                switch action {
                case .giveUp:
                    await teardown(tab)
                    tab.liveness = .lost
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let giveUpCase = try #require(Self.caseBody(named: ".giveUp", in: body))
        #expect(!giveUpCase.contains("await onGiveUp(tab)"))
    }

    @Test func scannerAcceptsAGiveUpThatDelegates() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                switch action {
                case .giveUp:
                    await onGiveUp(tab)
                    return
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let giveUpCase = try #require(Self.caseBody(named: ".giveUp", in: body))
        #expect(giveUpCase.contains("await onGiveUp(tab)"))
    }

    @Test func scannerFlagsAProbeArmThatRacesAndWritesInline() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                switch LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) {
                case .probe, .probeAgainNow:
                    let alive = await LivenessProbeRace.run(timeoutSeconds: 10) { true }
                    tab.liveness = alive ? .connected : .degraded
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let probeCase = try #require(Self.caseBody(named: Self.probeCase, in: body))
        #expect(!probeCase.contains("LivenessProbeStep.perform("))
        #expect(probeCase.contains("tab.liveness ="))
    }

    @Test func scannerFlagsAProbeArmThatCountsAnAbandonedProbeAsAFailure() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                switch LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) {
                case .probe, .probeAgainNow:
                    let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 10)
                    if result == .alive { break probing }
                    consecutiveFailures += 1
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let probeCase = try #require(Self.caseBody(named: Self.probeCase, in: body))
        #expect(probeCase.contains("LivenessProbeStep.perform("))
        #expect(!probeCase.contains("guard result != .abandoned else { return }"))
    }

    @Test func scannerAcceptsAProbeArmThatDelegatesAndStops() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                switch LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) {
                case .probe, .probeAgainNow:
                    let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 10)
                    guard result != .abandoned else { return }
                    if result == .alive { break probing }
                    consecutiveFailures += 1
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let probeCase = try #require(Self.caseBody(named: Self.probeCase, in: body))
        #expect(probeCase.contains("LivenessProbeStep.perform("))
        #expect(!probeCase.contains("tab.liveness ="))
        #expect(probeCase.contains("guard result != .abandoned else { return }"))
    }

    /// Pins the one property every other scanner claim rests on: a case
    /// body ends where the NEXT arm begins.
    ///
    /// Every other fixture here has a single arm, so the scanner could stop
    /// at the wrong place and each of them would still pass — which is how
    /// an earlier version, matching only a `case` in column zero, swallowed
    /// the whole of `.giveUp` into the probe arm while staying green. Both
    /// arms below are indented, as they are in the real file.
    @Test func scannerStopsACaseBodyAtTheNextArm() throws {
        let source = """
            // Liveness probe (Task 4)
            while !Task.isCancelled {
                let interval = settingsStore.keepAliveIntervalSeconds
                switch LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) {
                case .probe, .probeAgainNow:
                    let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 10)
                    guard result != .abandoned else { return }
                case .giveUp:
                    await onGiveUp(tab)
                }
            }
            """
        let body = try Self.loopBody(after: Self.anchor, in: source)
        let probeCase = try #require(Self.caseBody(named: Self.probeCase, in: body))
        let giveUpCase = try #require(Self.caseBody(named: ".giveUp", in: body))
        #expect(probeCase.contains("LivenessProbeStep.perform("))
        #expect(!probeCase.contains("onGiveUp("), "the probe arm must not swallow the arm after it")
        #expect(giveUpCase.contains("onGiveUp("))
        #expect(!giveUpCase.contains("LivenessProbeStep.perform("))
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
    /// balanced-brace close, with `//` line comments stripped (see
    /// `stripLineComments(from:)`). Throws rather than returning `nil` so a
    /// missing anchor or an unbalanced file fails the calling test loudly,
    /// not as a silently-empty string that would make every `contains`
    /// check in the calling tests trivially false.
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
                    return stripLineComments(from: String(afterAnchor[bodyStart..<index]))
                }
            }
            index = afterAnchor.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    /// Drops everything from the first `//` on each line to that line's end.
    ///
    /// Every claim below is a `contains`/`range(of:)` scan of raw text, so a
    /// comment that quotes the very code a claim looks for — e.g. `// guard
    /// settingsStore.keepAliveEnabled else { continue }` describing a guard
    /// that was actually deleted — would satisfy the scan exactly as if the
    /// real guard were still there. Stripping comments before the claims run
    /// closes that: only executable text remains for them to match against.
    /// No string-literal awareness, deliberately — this is a heuristic
    /// source scan, not a parser, and none of the loop's own source (real
    /// file or fixtures) puts `//` inside a string literal that a claim
    /// needs to see.
    private static func stripLineComments(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentRange = line.range(of: "//") else { return line }
                return line[line.startIndex..<commentRange.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The text of one `case <marker>:` arm, from just after its colon up to
    /// (but not including) the next line that BEGINS a `case` — leading
    /// whitespace ignored, since every arm in the real file is indented —
    /// or the end of `text` if this is the switch's last arm. No brace-depth
    /// tracking needed: none of this loop's `case` bodies opens a nested
    /// `switch`, so the next such line unambiguously belongs to the same
    /// enclosing `switch`.
    ///
    /// The indentation-insensitive stop is what makes a claim of the form
    /// "this arm does NOT contain X" mean the arm rather than the rest of
    /// the switch: an earlier version matched only a `case` at column zero,
    /// which in the real file never matched at all, so every arm's text ran
    /// on to the end of the loop and a negative claim silently spoke about
    /// its neighbours too.
    private static func caseBody(named marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: "case \(marker):") else { return nil }
        let rest = text[markerRange.upperBound...]
        var body = ""
        var isFirstLine = true
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !isFirstLine, trimmed.hasPrefix("case ") || trimmed == "default:" { break }
            body += (isFirstLine ? "" : "\n") + line
            isFirstLine = false
        }
        return body
    }
}
