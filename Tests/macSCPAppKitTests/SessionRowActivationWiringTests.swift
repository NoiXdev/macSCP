import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards how a session row's pointer and keyboard input reach the connect
/// callback — the "the rule is right and is not wired in" shape
/// `SidebarFilterWiringTests`, `PaneRenderConditionGuardTests` and
/// `PaneVisibilityWiringGuardTests` already exist to catch.
///
/// `SessionRowActivationTests` pins what `SessionRowActivation.build`
/// decides without ever touching `SessionSidebar.swift`. That decision could
/// be perfectly correct and simply not asked: a row that keeps a bare
/// `.onTapGesture { onConnect() }` connects on a single click no matter what
/// the plan says, and every plan test stays green while it does. This suite
/// is the wiring check those cannot be.
///
/// `SessionSidebar` cannot be instantiated in this project (no view-render
/// harness — the boundary the four precedent guard suites already document),
/// so this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/SessionSidebar.swift`, not a rendered-view
/// assertion. What it therefore does NOT prove: that macOS actually
/// delivers a second click as a `count: 2` tap, or a Return key press to a
/// focused row. It proves only which handler the source routes each input
/// into.
///
/// Known blind spots, stated up front rather than discovered later:
/// - Line-based and literal. A handler split across lines so that neither
///   `.onTapGesture` nor the input case it forwards sits on the same line
///   would slip past. A rename of `SessionRowInput`'s cases would be read as
///   a missing route, not as a compliant rewrite — the guard would fail
///   loudly rather than pass silently, which is the direction to fail in.
/// - Scoped to `SessionRow`'s `body`. A connect path added in a different
///   view, or in `SessionSidebar`'s own body, is outside every scan here
///   except the file-wide connect-callback count.
@Suite("Session row activation wiring guard")
struct SessionRowActivationWiringTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SessionRowActivationWiringTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    // MARK: - Guard 1: no tap gesture without a click count

    /// The regression this task removes: a tap gesture that names no count
    /// fires on the FIRST click, which is what made a single click connect.
    @Test func everyTapGestureOnTheRowNamesItsClickCount() throws {
        let body = try Self.sessionRowBody()
        let countless = body.lines.indices.filter { index in
            let line = body.lines[index]
            guard Self.isCode(line) else { return false }
            return line.contains(".onTapGesture") && !line.contains("count:")
        }
        #expect(countless.isEmpty, """
            `SessionRow`'s body attaches a tap gesture without a `count:` at line(s) \
            \(countless.map { body.offset + $0 + 1 }) — a countless tap gesture fires on the \
            FIRST click, which is exactly the behaviour this task replaced: a single click \
            must select the row, never open a connection.
            """)
    }

    // MARK: - Guard 2: no tap handler calls the connect callback directly

    @Test func noTapHandlerReachesTheConnectCallbackDirectly() throws {
        let body = try Self.sessionRowBody()
        let violations = body.lines.indices.filter { index in
            let line = body.lines[index]
            guard Self.isCode(line) else { return false }
            // Both spellings: `onConnect(` is what the row's own callback is
            // called now, `onSelect(` what it was called while a single
            // click still connected — a revert to either shape is the same
            // regression.
            return line.contains("onTapGesture")
                && (line.contains("onConnect(") || line.contains("onSelect("))
        }
        #expect(violations.isEmpty, """
            a tap handler in `SessionRow`'s body calls the connect callback directly at \
            line(s) \(violations.map { body.offset + $0 + 1 }) — every click must go through \
            `SessionRowActivation.build`, which is the one place that knows a single click \
            selects and only a double click connects.
            """)
    }

    // MARK: - Guard 3: both click counts route through the plan's inputs

    @Test func theRowRoutesEachClickCountThroughItsOwnInput() throws {
        let body = try Self.sessionRowBody()
        let single = body.lines.contains { line in
            Self.isCode(line) && line.contains(".onTapGesture(count: 1)")
                && line.contains(".singleClick")
        }
        #expect(single, """
            `SessionRow`'s body has no `.onTapGesture(count: 1)` forwarding `.singleClick` — \
            without it a single click does nothing at all, which is worse than today: the \
            row would lose the gesture that puts the selection somewhere.
            """)
        let double = body.lines.contains { line in
            Self.isCode(line) && line.contains(".onTapGesture(count: 2)")
                && line.contains(".doubleClick")
        }
        #expect(double, """
            `SessionRow`'s body has no `.onTapGesture(count: 2)` forwarding `.doubleClick` — \
            the double click is the mouse path to a connection now that the single click \
            only selects.
            """)
    }

    // MARK: - Guard 4: Return reaches the plan too

    /// Point 3 of the brief's own reasoning: a selection no key acts on is
    /// just a colouring. The key press is what makes the selection carry.
    @Test func theRowRoutesTheReturnKeyThroughItsOwnInput() throws {
        let body = try Self.sessionRowBody()
        let handled = body.lines.contains { line in
            Self.isCode(line) && line.contains(".onKeyPress(.return)")
        }
        #expect(handled, """
            `SessionRow`'s body no longer handles `.onKeyPress(.return)` — the keyboard path \
            to a connection is gone, and the row's selection would be a colouring no key \
            acts on.
            """)
        let forwardsReturnInput = body.lines.contains { line in
            Self.isCode(line) && line.contains(".returnKey")
        }
        #expect(forwardsReturnInput, """
            `SessionRow`'s body never forwards `.returnKey` — the Return handler must ask \
            `SessionRowActivation.build` the same way both click handlers do, rather than \
            deciding for itself whether to connect.
            """)
    }

    // MARK: - Guard 5: the row stops being focusable while it is renamed

    /// The rename must keep the keyboard: a focusable row competing with its
    /// own inline `TextField` would take Return away from the field that is
    /// being edited.
    @Test func theRowIsNotFocusableWhileItIsBeingRenamed() throws {
        let body = try Self.sessionRowBody()
        let guarded = body.lines.contains { line in
            Self.isCode(line) && line.contains(".focusable(!isRenaming)")
        }
        #expect(guarded, """
            `SessionRow`'s body does not spell `.focusable(!isRenaming)` — while a row is \
            being renamed its inline text field owns the keyboard, and a focusable row would \
            compete with it for Return.
            """)
    }

    // MARK: - Guard 6: the context menu keeps its own connect entry

    /// The third connect path, and the reason disarming the single click
    /// loses nothing: the row's context menu already carries a "Connect"
    /// entry. Present-tense guard — it is what makes the other guards' "a
    /// single click must not connect" safe to demand.
    @Test func theContextMenuKeepsItsConnectEntry() throws {
        let body = try Self.sessionRowBody()
        guard let menu = Self.range(ofBlockStartingWith: ".contextMenu {", in: body.lines) else {
            Issue.record("`.contextMenu {` not found inside `SessionRow`'s body — re-anchor this guard")
            return
        }
        let hasConnectEntry = menu.contains { index in
            let line = body.lines[index]
            return Self.isCode(line) && line.contains("\"sidebar.connect\"")
                && line.contains("onConnect()")
        }
        #expect(hasConnectEntry, """
            the session row's context menu no longer carries a `sidebar.connect` entry that \
            calls the connect callback — that entry is the reason a single click is free to \
            stop connecting, so it must not disappear in the same breath.
            """)
    }

    // MARK: - Guard 7: no fourth connect path in the file

    /// Every call of the sidebar's connect callback, file-wide. Exactly two
    /// are intended: the activation path (`activate`, which asks the plan
    /// first) and the row's context-menu entry. A third would be a connect
    /// path nothing in this suite describes.
    @Test func theSidebarInvokesItsConnectCallbackFromExactlyTwoPlaces() throws {
        let lines = try Self.sourceLines()
        let callSites = Self.connectCallbackCallSites(in: lines)
        #expect(callSites.count == 2, """
            expected exactly two calls to the sidebar's connect callback in \
            SessionSidebar.swift (the activation path and the context-menu entry), found \
            \(callSites.count) at line(s) \(callSites.map { $0 + 1 }) — a third call site is \
            a connect path that no guard in this suite describes.
            """)
    }

    /// The activation path is one of those two, and it is the one that asks
    /// the plan: without this, Guard 7's count could be satisfied by two
    /// unrelated call sites while the planned one disappeared.
    @Test func theActivationPathAsksThePlanBeforeConnecting() throws {
        let lines = try Self.sourceLines()
        guard let activate = Self.range(
            ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        let asksThePlan = activate.contains { lines[$0].contains("SessionRowActivation.build(") }
        #expect(asksThePlan, """
            `activate` no longer calls `SessionRowActivation.build(` — the decision would be \
            back inside the view, where no test can reach it.
            """)
        let connects = activate.contains { Self.isCode(lines[$0]) && lines[$0].contains("onSelect(") }
        #expect(connects, """
            `activate` never invokes the sidebar's connect callback — the double click and \
            the Return key would decide to connect and then do nothing.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The exact pre-task source: one countless tap gesture, guarding only
    /// against the rename.
    @Test func scannerFlagsTheCountlessTapGestureThisTaskRemoved() {
        let line = "        .onTapGesture { if !isRenaming { onSelect() } }"
        let flagged = Self.isCode(line) && line.contains(".onTapGesture") && !line.contains("count:")
        #expect(flagged)
    }

    @Test func scannerAcceptsTapGesturesThatNameTheirCount() {
        let lines = [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick) }",
        ]
        for line in lines {
            #expect(!(line.contains(".onTapGesture") && !line.contains("count:")))
        }
    }

    /// A comment that describes the old shape must not be read as the shape
    /// itself — the scanners skip comment lines for exactly this reason.
    @Test func scannerIgnoresTheOldShapeQuotedInAComment() {
        let line = "    /// Replaces the old `.onTapGesture { onConnect() }`, which connected on one click."
        #expect(!Self.isCode(line))
    }

    /// A doc comment naming the connect callback in prose must not be
    /// counted as a call site by Guard 7.
    @Test func connectCallbackScannerIgnoresCommentedMentions() {
        let source = """
            /// See `onSelect(stored)` in the caller for what this connects.
            private func activate() {
                onSelect(session)
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.connectCallbackCallSites(in: lines).count == 1)
    }

    /// The declaration is not a call — a scanner that counted it would
    /// report one call site too many and never go green.
    @Test func connectCallbackScannerIgnoresTheDeclaration() {
        let lines = ["    let onSelect: (StoredSession) -> Void"]
        #expect(Self.connectCallbackCallSites(in: lines).isEmpty)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like the precedent guards' scanners.

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: Self.sourceFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// A line that is neither blank nor a `//`/`///` comment — the scanners
    /// read compiled statements, not prose about them.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("//")
    }

    /// Every non-comment line that CALLS the sidebar's connect callback
    /// (`onSelect(`), excluding its declaration (`let onSelect:`, which
    /// carries no opening parenthesis after the name).
    private static func connectCallbackCallSites(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let line = lines[index]
            return isCode(line) && line.contains("onSelect(")
        }
    }

    /// `SessionRow`'s `body`, as its own lines plus the offset of its first
    /// line in the file (so failure messages can report real file line
    /// numbers). Anchored on the struct declaration first, because
    /// `SessionSidebar.swift` holds more than one `var body: some View {`.
    private static func sessionRowBody() throws -> (lines: [String], offset: Int) {
        let lines = try sourceLines()
        guard let structStart = lines.firstIndex(where: {
            $0.contains("struct SessionRow: View {")
        }) else {
            throw ScanFailure.anchorMissing("struct SessionRow: View {")
        }
        let tail = Array(lines[structStart...])
        guard let body = range(ofBlockStartingWith: "var body: some View {", in: tail) else {
            throw ScanFailure.anchorMissing("var body: some View { inside SessionRow")
        }
        return (Array(tail[body]), structStart + body.lowerBound)
    }

    private enum ScanFailure: Error {
        case anchorMissing(String)
    }

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `SidebarFilterWiringTests.range(ofBlockStartingWith:in:)`.
    private static func range(
        ofBlockStartingWith marker: String, in lines: [String]
    ) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 {
                return start...index
            }
        }
        return nil
    }
}
