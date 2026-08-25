import Foundation
import Testing

/// Guards that the Keep-Alive interval stepper's commit path in
/// `SettingsView.swift` writes `store.keepAliveIntervalSeconds` ONLY
/// through `KeepAliveControlPlan.storedValue(forIntervalChangeTo:isEnabled:)`.
///
/// Added in Task 9's fix round 1: review found the stepper's `set` closure
/// writing the committed value straight to the store, bypassing
/// `KeepAliveControlPlan` entirely. That call site was safe only because
/// the Stepper's own `15...600` range and `.disabled` state kept `0` out —
/// not because anything tested said so — so a regression reintroduced at
/// the call site itself (e.g. reverting to a raw assignment) could never
/// be caught by mutating the plan, which is the whole point of having
/// extracted it. `KeepAliveControlPlanTests` proves what the plan
/// function itself does; this proves the real call site actually reaches
/// it.
///
/// Same boundary as this project's other wiring guards (see
/// `ConnectTimeoutAppWiringGuardTests`'s doc comment for the idiom): a
/// SOURCE-TEXT scan, not a behavioral test — this project has no SwiftUI
/// rendering harness, so a `Stepper`'s `set` closure can only be checked by
/// reading it, not by running it. Fail-closed: an unreadable file, a
/// missing anchor, or unbalanced braces all count as failures. Self-tested
/// against synthetic source, so the guard cannot pass silently just
/// because the real file moved or was reformatted past recognition.
@Suite("Keep-alive interval stepper wiring guard")
struct KeepAliveStepperWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/KeepAliveStepperWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectTimeoutAppWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    /// Anchors the interval stepper's `set` closure, unique in the file
    /// (checked by `theAnchorAppearsExactlyOnceInTheRealFile` below) —
    /// the auto-refresh interval's own `set` closure two sections above it
    /// uses `set: { store.autoRefreshIntervalSeconds = $0 }`, a different
    /// shape entirely, so this anchor cannot accidentally match it.
    private static let anchor = "set: { newValue in"

    /// Extracts the body of the closure `anchor` opens — everything
    /// between `anchor`'s own `{` (already consumed by the anchor string)
    /// and its matching `}`, by plain brace counting. `nil` on a missing
    /// anchor or unbalanced braces rather than a guess.
    private static func setClosureBody(in source: String) -> String? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        var depth = 1
        var index = anchorRange.upperBound
        let bodyStart = index
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - The guarded claim, run against the real file

    @Test func theIntervalStepperRoutesThroughThePlan() throws {
        let source = try String(contentsOf: Self.settingsFile, encoding: .utf8)
        let body = try #require(Self.setClosureBody(in: source), """
            no `\(Self.anchor)` closure found in SettingsView.swift — \
            re-anchor this guard.
            """)
        // Two separate `contains` checks, not one concatenated literal: the
        // real call wraps its arguments onto their own lines
        // (`KeepAliveControlPlan.storedValue(\n    forIntervalChangeTo: ...`),
        // so a single glued-together substring would never match the actual
        // formatted source.
        #expect(body.contains("KeepAliveControlPlan.storedValue("), """
            the interval stepper's `set` closure no longer calls \
            `KeepAliveControlPlan.storedValue(forIntervalChangeTo:isEnabled:)` — \
            a write to `store.keepAliveIntervalSeconds` here that bypasses the \
            plan cannot be caught by mutating the plan itself.
            """)
        #expect(body.contains("forIntervalChangeTo:"), """
            `KeepAliveControlPlan.storedValue(` is called without its \
            `forIntervalChangeTo:` argument label in the interval stepper's \
            `set` closure — re-check which plan function is actually being \
            called.
            """)
        #expect(!body.contains("keepAliveIntervalSeconds = newValue"), """
            the interval stepper's `set` closure assigns \
            `store.keepAliveIntervalSeconds` directly from `newValue` again, \
            bypassing `KeepAliveControlPlan` — route it through \
            `storedValue(forIntervalChangeTo:isEnabled:)` instead.
            """)
    }

    /// Fail-closed check, same reasoning as
    /// `ConnectTimeoutAppWiringGuardTests.theAnchorAppearsExactlyOnceInTheRealFile`:
    /// if the anchor ever stops being unique, the guard above could be
    /// matching the wrong closure silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.settingsFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in \
            SettingsView.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    /// Single-line call shape — proves the extractor and the two
    /// `contains` checks agree when nothing wraps.
    @Test func scannerAcceptsARoutedCommitOnOneLine() {
        let source = """
            Stepper(
                value: Binding(
                    get: { 1 },
                    set: { newValue in
                        lastKnownKeepAliveInterval = newValue
                        store.keepAliveIntervalSeconds = KeepAliveControlPlan.storedValue(
                            forIntervalChangeTo: newValue, isEnabled: true)
                    }
                ),
                in: 15...600
            )
            """
        let body = try? #require(Self.setClosureBody(in: source))
        #expect(body?.contains("KeepAliveControlPlan.storedValue(") == true)
        #expect(body?.contains("forIntervalChangeTo:") == true)
        #expect(body?.contains("keepAliveIntervalSeconds = newValue") == false)
    }

    /// Wrapped-argument call shape — the ACTUAL shape the real file uses
    /// (`storedValue(` on one line, `forIntervalChangeTo:` on the next).
    /// This is the case that first defeated a single concatenated-literal
    /// `contains` check against the real file — kept here so the scanner
    /// itself, not just the real-file assertion, is pinned against it.
    @Test func scannerAcceptsARoutedCommitWithWrappedArguments() {
        let source = """
            Stepper(
                value: Binding(
                    get: { 1 },
                    set: { newValue in
                        lastKnownKeepAliveInterval = newValue
                        store.keepAliveIntervalSeconds = KeepAliveControlPlan.storedValue(
                            forIntervalChangeTo: newValue,
                            isEnabled: KeepAliveControlPlan.isEnabled(
                                storedSeconds: store.keepAliveIntervalSeconds))
                    }
                ),
                in: 15...600
            )
            """
        let body = try? #require(Self.setClosureBody(in: source))
        #expect(body?.contains("KeepAliveControlPlan.storedValue(") == true)
        #expect(body?.contains("forIntervalChangeTo:") == true)
        #expect(body?.contains("keepAliveIntervalSeconds = newValue") == false)
    }

    @Test func scannerFlagsABypassedRawAssignment() {
        let source = """
            Stepper(
                value: Binding(
                    get: { 1 },
                    set: { newValue in
                        lastKnownKeepAliveInterval = newValue
                        store.keepAliveIntervalSeconds = newValue
                    }
                ),
                in: 15...600
            )
            """
        let body = try? #require(Self.setClosureBody(in: source))
        #expect(body?.contains("KeepAliveControlPlan.storedValue(") == false)
        #expect(body?.contains("keepAliveIntervalSeconds = newValue") == true)
    }

    @Test func scannerFailsClosedOnAMissingAnchor() {
        #expect(Self.setClosureBody(in: "nothing to see here") == nil)
    }

    @Test func scannerFailsClosedOnUnbalancedBraces() {
        let source = "set: { newValue in store.keepAliveIntervalSeconds = newValue"
        #expect(Self.setClosureBody(in: source) == nil)
    }
}
