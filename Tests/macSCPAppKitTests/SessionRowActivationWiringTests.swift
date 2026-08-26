import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards how a session row's pointer and keyboard input reach the sidebar's
/// connect callback.
///
/// The property, stated once so every guard can be checked against it rather
/// than against the lines that happen to exist: **the connect callback is
/// reached only when `SessionRowActivation` answered `.selectAndConnect` —
/// that is, on a double click, or on Return on the row that holds the
/// selection. A single click never reaches it.**
///
/// Fix round 1 rewrote this suite. Its first version was written after the
/// implementation and was shaped like it: two of the reviewer's four
/// mutation probes left the whole suite green while every single click
/// dialled a host. Mutation testing shows a guard's SENSITIVITY, never its
/// SCOPE, so the anchors below were chosen by enumerating where the property
/// can be violated from, not by collecting the probes that broke it:
///
/// 1. `SessionRowActivation.build` could classify `.singleClick` as
///    connecting. Not guarded here — `SessionRowActivationTests` covers it
///    directly, and that suite is sensitive (the mutation is inside the
///    function it tests).
/// 2. The application of the plan's answer could ignore it. **Structural
///    now, not guarded:** `SessionRowActivation.apply(to:onSelect:onConnect:)`
///    is the only mapping from an activation to the connect effect, it is a
///    total `switch` over the enum, and `SessionRowActivationApplyTests`
///    exercises it with spies. The view holds no `if` over the answer that a
///    later edit could drop — which is what the first version of this suite
///    failed to notice was missing.
/// 3. The view could hand `apply` a connect effect that also runs on select,
///    or invoke the callback next to the call. Guard: `activate` never
///    CALLS the connect callback at all — it passes it by name (Guard A).
/// 4. Some other place in this file could call the connect callback.
///    Guard: exactly one call site file-wide, the row's context-menu
///    closure (Guard G).
/// 5. A row handler could forward the WRONG input for its gesture — a
///    count-1 handler forwarding `.doubleClick` is a lie about which
///    gesture happened, and no type can prevent it. Guard: each input is
///    forwarded from exactly one handler, that handler carries the matching
///    modifier, and it forwards nothing else (Guard B).
/// 6. A new gesture could be attached that forwards a connecting input.
///    Covered by Guard B's "exactly one handler per input", plus Guard C:
///    no tap gesture anywhere in the file omits its click count.
/// 7. A connect path could be added in a DIFFERENT file. Out of reach of
///    every scan here, and stated rather than implied.
///
/// `SessionSidebar` and `SessionRow` cannot be DRIVEN from a test in this
/// project: `ViewTestabilitySpike` shows views of this package can be
/// instantiated and rendered offscreen, but there is no way to inject a
/// click or a key press, which is what these guards are about. They are
/// therefore SOURCE-TEXT scans over
/// `Sources/MacSCPAppKit/SessionSidebar.swift`. They do not prove that macOS
/// delivers a second click as a `count: 2` tap or Return to a focused row —
/// only which handler the source routes each input into.
///
/// Known blind spots, stated up front rather than discovered later:
/// - Line-based and literal. A handler split so that neither the modifier
///   nor the input case it forwards sits on one line would be read as a
///   MISSING route, not as a compliant one — every guard here fails closed,
///   so a reformat costs a re-anchor rather than silent cover.
/// - Most guards here are scoped to one function or one view, so a
///   violation moved elsewhere in the file leaves them green. Counted in
///   this pass, two are file-wide: Guard C (no countless tap gesture
///   anywhere) and Guard G (one call site for the connect callback). None
///   of them sees another file at all.
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

    /// Which modifier is allowed to forward which input. The whole of Guard
    /// B is this table plus "exactly one line each, and nothing else on it".
    private static let inputRoutes: [(input: String, modifier: String)] = [
        (".singleClick", ".onTapGesture(count: 1)"),
        (".doubleClick", ".onTapGesture(count: 2)"),
        (".returnKey", ".onKeyPress(.return)"),
    ]

    // MARK: - Guard A: the activation path never CALLS the connect callback

    /// Violation site 3. `activate` hands `onConnect` to `apply` by name, so
    /// there is no call in the view whose condition could be dropped and no
    /// second effect it could be smuggled into. Anything that invokes the
    /// callback inside `activate` — in the select effect, beside the apply,
    /// or with the plan's answer ignored — is a call, and this is red.
    @Test func theActivationPathNeverCallsTheConnectCallbackItself() throws {
        let lines = try Self.sourceLines()
        guard let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        let calls = activate.filter { Self.isCode(lines[$0]) && lines[$0].contains("onConnect(") }
        #expect(calls.isEmpty, """
            `activate` CALLS the connect callback at line(s) \(calls.map { $0 + 1 }) instead of \
            handing it to `SessionRowActivation.apply` by name. A call inside `activate` is a \
            connect the view performs on its own account: whatever condition guards it today \
            can be dropped by one edit, and then a single click dials. The callback must be \
            passed, never invoked, here.
            """)
        let handsItOver = activate.contains {
            Self.isCode(lines[$0]) && lines[$0].contains("onConnect: onConnect")
        }
        #expect(handsItOver, """
            `activate` no longer passes `onConnect: onConnect` to `apply` — without it the guard \
            above is satisfied by an `activate` that cannot connect at all, which is the other \
            way to be wrong.
            """)
    }

    /// The plan is what `activate` acts on, and `apply` is how. Present-tense
    /// companion to Guard A: without it, an `activate` that decided for
    /// itself and never mentioned the callback would pass everything above.
    @Test func theActivationPathAsksThePlanAndAppliesItsAnswer() throws {
        let lines = try Self.sourceLines()
        guard let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        for expected in ["SessionRowActivation.build(", ".apply("] {
            let found = activate.contains { Self.isCode(lines[$0]) && lines[$0].contains(expected) }
            #expect(found, """
                `activate` no longer contains `\(expected)` — the decision would be back inside \
                the view, where no test can reach it.
                """)
        }
    }

    // MARK: - Guard B: each input is forwarded from exactly one handler

    /// Violation sites 5 and 6. Presence alone is not the property: a
    /// count-1 handler that ALSO forwards `.doubleClick` satisfies "each
    /// input is routed somewhere" while a single click connects. Each input
    /// must appear on exactly one line, that line must carry its own
    /// modifier, and it must forward no other input.
    @Test func eachInputIsForwardedFromExactlyOneHandlerAndThatHandlerForwardsNothingElse() throws {
        let body = try Self.sessionRowBody()
        for route in Self.inputRoutes {
            let carriers = body.lines.indices.filter { index in
                Self.isCode(body.lines[index]) && body.lines[index].contains(route.input)
            }
            #expect(carriers.count == 1, """
                `\(route.input)` is forwarded from \(carriers.count) handler(s) in `SessionRow`'s \
                body (line(s) \(carriers.map { body.offset + $0 + 1 })), expected exactly one — \
                a second handler forwarding it means some other gesture now claims to be that \
                input, and for the connecting inputs that is a single click opening a connection.
                """)
            guard let only = carriers.first else { continue }
            let line = body.lines[only]
            #expect(line.contains(route.modifier), """
                `\(route.input)` is forwarded from a handler that is not `\(route.modifier)` \
                (line \(body.offset + only + 1)) — the input a handler forwards must be the \
                gesture that actually happened.
                """)
            for other in Self.inputRoutes.map(\.input) where other != route.input {
                #expect(!line.contains(other), """
                    the `\(route.modifier)` handler (line \(body.offset + only + 1)) forwards \
                    `\(other)` as well as `\(route.input)` — one gesture reported as two inputs \
                    is how a single click reaches a connecting activation.
                    """)
            }
        }
    }

    // MARK: - Guard C: no tap gesture without a click count, file-wide

    /// Violation site 6, and the shape this task removed: a tap gesture that
    /// names no count fires on the FIRST click. File-wide rather than scoped
    /// to `SessionRow`, so the imported-hosts row is covered too — it does
    /// not connect today, but a scan that stopped at `SessionRow` would not
    /// notice the day it does.
    @Test func noTapGestureInTheFileOmitsItsClickCount() throws {
        let lines = try Self.sourceLines()
        let countless = lines.indices.filter { index in
            let line = lines[index]
            guard Self.isCode(line) else { return false }
            return line.contains(".onTapGesture") && !line.contains("count:")
        }
        #expect(countless.isEmpty, """
            `SessionSidebar.swift` attaches a tap gesture without a `count:` at line(s) \
            \(countless.map { $0 + 1 }) — a countless tap gesture fires on the FIRST click, \
            which is the behaviour this task removed from the session row; every row in this \
            sidebar spells out which click count it answers.
            """)
    }

    // MARK: - Guard D: no tap handler calls the connect callback directly

    @Test func noTapHandlerReachesTheConnectCallbackDirectly() throws {
        let body = try Self.sessionRowBody()
        let violations = body.lines.indices.filter { index in
            let line = body.lines[index]
            guard Self.isCode(line) else { return false }
            // Both spellings: `onConnect(` is the row's callback, `onSelect(`
            // what the sidebar's was called while a single click connected.
            return line.contains("onTapGesture")
                && (line.contains("onConnect(") || line.contains("onSelect("))
        }
        #expect(violations.isEmpty, """
            a tap handler in `SessionRow`'s body calls a connect callback directly at line(s) \
            \(violations.map { body.offset + $0 + 1 }) — every gesture must go through \
            `SessionRowActivation`, which is the one place that knows a single click selects \
            and only a double click connects.
            """)
    }

    // MARK: - Guard E: the row stops being focusable while it is renamed

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

    // MARK: - Guard F: the context menu keeps its own connect entry

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

    // MARK: - Guard G: one call site for the sidebar's connect callback

    /// Violation site 4, file-wide. The sidebar hands one stored session to
    /// its connect callback in exactly ONE place: the closure it gives the
    /// row for the context-menu entry. `activate` passes the callback by
    /// name (Guard A), so a second `onConnect(session)` anywhere in this file
    /// is a connect path no guard here describes.
    @Test func theSidebarInvokesItsConnectCallbackAtExactlyOneCallSite() throws {
        let lines = try Self.sourceLines()
        let callSites = Self.connectCallbackCallSites(in: lines)
        #expect(callSites.count == 1, """
            expected exactly one `onConnect(session)` call in SessionSidebar.swift (the closure \
            handed to the row for its context-menu entry), found \(callSites.count) at line(s) \
            \(callSites.map { $0 + 1 }) — every other connect must go through \
            `SessionRowActivation.apply`, which only connects for `.selectAndConnect`.
            """)
    }

    // MARK: - Guard H: a rename that ends hands the keyboard back

    /// The silent divergence this round fixes: `selectedSessionID` survives a
    /// rename, the row's focus does not. A row that draws as selected while
    /// Return does nothing on it is exactly the "selection no key acts on"
    /// the brief rules out. Every deliberate end of a rename therefore goes
    /// through one function that hands focus back to the selected row.
    ///
    /// The focus-LOSS handler is deliberately not part of this: focus went
    /// somewhere else on purpose there, and grabbing it back would fight the
    /// user for the first responder.
    @Test func everyDeliberateRenameEndHandsTheKeyboardBackToTheSelectedRow() throws {
        let lines = try Self.sourceLines()
        guard let endRename = Self.range(ofBlockStartingWith: "private func endRename()", in: lines)
        else {
            Issue.record("`private func endRename()` not found — re-anchor this guard")
            return
        }
        let handsBack = endRename.contains {
            lines[$0].trimmingCharacters(in: .whitespaces) == "focusedRowID = selectedSessionID"
        }
        #expect(handsBack, """
            `endRename` does not assign `focusedRowID = selectedSessionID` — a committed or \
            cancelled rename would leave the row drawn as selected with the keyboard pointing \
            nowhere, and Return would silently do nothing until the row is clicked again.
            """)
        for function in ["private func commitSessionRename(", "private func commitGroupRename("] {
            guard let block = Self.range(ofBlockStartingWith: function, in: lines) else {
                Issue.record("`\(function)` not found — re-anchor this guard")
                continue
            }
            let callsEndRename = block.contains {
                Self.isCode(lines[$0]) && lines[$0].contains("endRename()")
            }
            #expect(callsEndRename, """
                `\(function)` does not call `endRename()` — it would clear the rename without \
                handing the keyboard back, which is the divergence this guard exists for.
                """)
            let clearsDirectly = block.contains {
                Self.isCode(lines[$0])
                    && lines[$0].trimmingCharacters(in: .whitespaces) == "renamingID = nil"
            }
            #expect(!clearsDirectly, """
                `\(function)` clears `renamingID` itself instead of going through `endRename()` \
                — a second rename-ending path is a second place to forget the hand-back.
                """)
        }
    }

    // MARK: - Guard I: activating another row ends its open rename

    /// A click on row B while row A is being renamed moves the first
    /// responder to B, which takes focus out of A's text field. Left to the
    /// focus-loss handler alone, A can keep drawing an editable field that
    /// nothing can reach. `activate` ends it deliberately instead.
    @Test func activatingARowEndsARenameOpenOnADifferentRow() throws {
        let lines = try Self.sourceLines()
        guard let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        let asks = activate.contains {
            Self.isCode(lines[$0]) && lines[$0].contains("SidebarRenameHandoff.endsOpenRename(")
        }
        #expect(asks, """
            `activate` never asks `SidebarRenameHandoff.endsOpenRename(` — a click on another \
            row would pull the first responder out of an open rename field and leave that row \
            editable, unfocused and unreachable except by clicking inside the field itself.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The pre-task source: one countless tap gesture, guarding only against
    /// the rename.
    @Test func scannerFlagsTheCountlessTapGestureThisTaskRemoved() {
        let line = "        .onTapGesture { if !isRenaming { onSelect() } }"
        #expect(Self.isCode(line) && line.contains(".onTapGesture") && !line.contains("count:"))
    }

    @Test func scannerAcceptsTapGesturesThatNameTheirCount() {
        for line in [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick) }",
        ] {
            #expect(!(line.contains(".onTapGesture") && !line.contains("count:")))
        }
    }

    /// The reviewer's probe 3, in the exact shape that left the first version
    /// of this suite green: the count-1 handler forwards the connecting input
    /// as well. Both halves of Guard B must reject it — the duplicate
    /// `.doubleClick` carrier AND the foreign input on the count-1 line.
    @Test func scannerFlagsAHandlerThatForwardsASecondInput() {
        let body = [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick); _ = onInput(.doubleClick) }",
            "        .onKeyPress(.return) { onInput(.returnKey) ? .handled : .ignored }",
        ]
        let doubleCarriers = body.filter { $0.contains(".doubleClick") }
        #expect(doubleCarriers.count == 2, "the duplicate carrier must be visible to Guard B")
        let singleLine = body.first { $0.contains(".onTapGesture(count: 1)") } ?? ""
        #expect(singleLine.contains(".doubleClick"), "the foreign input must be visible on the line")
    }

    /// The compliant shape must pass both halves — without this, the check
    /// above could be satisfied by a scanner that flags everything.
    @Test func scannerAcceptsOneHandlerPerInput() {
        let body = [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick) }",
            "        .onKeyPress(.return) { onInput(.returnKey) ? .handled : .ignored }",
        ]
        for route in Self.inputRoutes {
            let carriers = body.filter { $0.contains(route.input) }
            #expect(carriers.count == 1)
            #expect(carriers[0].contains(route.modifier))
            for other in Self.inputRoutes.map(\.input) where other != route.input {
                #expect(!carriers[0].contains(other))
            }
        }
    }

    /// The reviewer's probe 1, translated to the structure this round
    /// introduced: the connect callback invoked inside `activate` rather than
    /// handed over. Guard A must see it wherever in the function it sits —
    /// including inside the SELECT effect, which is the shape a line-based
    /// "is it next to `connect:`" check would have missed.
    @Test func connectCallbackScannerSeesACallSmuggledIntoTheSelectEffect() {
        let source = """
            private func activate(_ input: SessionRowInput, on session: StoredSession) -> Bool {
                let activation = SessionRowActivation.build(
                    for: input, isRenaming: false, isSelected: false)
                return activation.apply(
                    to: session,
                    onSelect: { moveSelection(to: $0); onConnect(session) },
                    onConnect: onConnect)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        let calls = activate!.filter { Self.isCode(lines[$0]) && lines[$0].contains("onConnect(") }
        #expect(!calls.isEmpty)
    }

    /// And the compliant shape, which mentions the callback only by name.
    @Test func connectCallbackScannerAcceptsTheCallbackPassedByName() {
        let source = """
            private func activate(_ input: SessionRowInput, on session: StoredSession) -> Bool {
                let activation = SessionRowActivation.build(
                    for: input, isRenaming: false, isSelected: false)
                return activation.apply(
                    to: session, onSelect: moveSelection(to:), onConnect: onConnect)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        let calls = activate!.filter { Self.isCode(lines[$0]) && lines[$0].contains("onConnect(") }
        #expect(calls.isEmpty)
    }

    /// A doc comment naming the connect callback in prose must not be
    /// counted as a call site by Guard G.
    @Test func connectCallbackScannerIgnoresCommentedMentions() {
        let source = """
            /// See `onConnect(session)` in the caller for what this connects.
            private func rows() {
                onConnect(session)
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.connectCallbackCallSites(in: lines).count == 1)
    }

    /// The declaration is not a call — a scanner that counted it would
    /// report one call site too many and never go green.
    @Test func connectCallbackScannerIgnoresTheDeclaration() {
        let lines = ["    let onConnect: (StoredSession) -> Void"]
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

    /// Every non-comment line that CALLS the sidebar's connect callback with
    /// a session. Its declaration (`let onConnect: …`) carries no `(` after
    /// the name and its hand-over to `apply` (`connect: onConnect`) carries
    /// no argument, so neither is a call site.
    private static func connectCallbackCallSites(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let line = lines[index]
            return isCode(line) && line.contains("onConnect(session)")
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
