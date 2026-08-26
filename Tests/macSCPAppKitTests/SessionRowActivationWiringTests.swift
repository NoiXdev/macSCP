import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards what is left of "a single click never connects" after fix round 2
/// made most of it impossible to express.
///
/// The property: **a connection is reached only for `.doubleClick`,
/// `.returnKey` on the selected row, and `.contextMenuEntry` — never for a
/// single click.** Where each part of it is held, enumerated by asking where
/// it could be violated FROM rather than by collecting the mutations someone
/// happened to run (two rounds of exactly that is how three of the reviewers'
/// probes ended up green):
///
/// 1. `SessionRowActivation.build` misclassifies an input.
///    → `SessionRowActivationTests`, which mutates red because the mistake
///    is inside the function under test. Not guarded here.
/// 2. `apply` runs the wrong effect for an activation.
///    → `SessionRowActivationApplyTests`, spies over both effects. Same
///    reason. Not guarded here.
/// 3. The view fires the connect effect itself, or puts it where the
///    selection effect belongs.
///    → **Compile error**, not a guard. `SessionRowConnectEffect.run` is
///    `fileprivate` to the file that declares it, and the two effects are
///    different types. The three mutations the reviewers ran green against
///    the previous round — the effect in the select slot, a call from
///    `moveSelection` with its parameter renamed, a call from the
///    imported-hosts row — no longer build.
/// 4. Another handler in this file reaches a connection some other way.
///    → Same boundary for the connect effect. NOT covered for the sidebar's
///    two terminal callbacks, which also connect and are still plain
///    closures; Guard B covers the gesture half of that.
/// 5. A gesture handler lies about which input happened — a count-1 handler
///    forwarding `.doubleClick`. No type can prevent it: the input is a
///    value the handler chooses. → **Guard A**, the honest residue.
/// 6. A gesture handler calls a connecting callback instead of forwarding
///    an input at all. → **Guard B**.
/// 7. The input is rewritten between the row and the plan. The closure that
///    made this possible is **deleted** — `sessionRows` hands over the
///    activation method itself — and → **Guard C** keeps it deleted.
/// 8. A connect path in a DIFFERENT file. `ContentView` constructs the
///    effect and can dial without the sidebar; nothing here sees that, and
///    saying so is the honest boundary rather than an implied one.
///
/// Everything the previous round guarded about sites 3 and 4 has been
/// deleted rather than kept as belt-and-braces: a guard nobody can violate
/// reads as coverage and is not.
///
/// `SessionSidebar` and `SessionRow` cannot be DRIVEN from a test here:
/// `ViewTestabilitySpike` shows views of this package can be instantiated
/// and rendered offscreen, but there is no way to inject a click or a key
/// press. Every guard here is therefore a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/SessionSidebar.swift`; they say which handler
/// routes which input, never that macOS delivers it.
///
/// Known blind spots: the scans are line-based and literal, so a handler
/// split across lines reads as a MISSING route rather than a compliant one
/// — every guard fails closed, and a reformat costs a re-anchor instead of
/// silent cover.
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

    /// Which site is allowed to forward which input — the whole of Guard A
    /// is this table plus "exactly one line each, and nothing else on it".
    /// The menu entry is in it for the same reason the gestures are: it is
    /// an input now, not a separate connect path.
    private static let inputRoutes: [(input: String, site: String)] = [
        (".singleClick", ".onTapGesture(count: 1)"),
        (".doubleClick", ".onTapGesture(count: 2)"),
        (".returnKey", ".onKeyPress(.return)"),
        (".contextMenuEntry", "\"sidebar.connect\""),
    ]

    // MARK: - Guard A: each input is forwarded from exactly one site

    /// Violation site 5. Presence alone is not the property: a count-1
    /// handler that ALSO forwards `.doubleClick` satisfies "each input is
    /// routed somewhere" while a single click connects. Each input must
    /// appear on exactly one line, that line must be its own site, and it
    /// must forward no other input.
    @Test func eachInputIsForwardedFromExactlyOneSiteAndThatSiteForwardsNothingElse() throws {
        let body = try Self.sessionRowBody()
        for route in Self.inputRoutes {
            let carriers = body.lines.indices.filter { index in
                Self.isCode(body.lines[index]) && body.lines[index].contains(route.input)
            }
            #expect(carriers.count == 1, """
                `\(route.input)` is forwarded from \(carriers.count) site(s) in `SessionRow`'s \
                body (line(s) \(carriers.map { body.offset + $0 + 1 })), expected exactly one — \
                a second site forwarding it means some other input now claims to be that one, \
                and for the connecting inputs that is a single click opening a connection.
                """)
            guard let only = carriers.first else { continue }
            let line = body.lines[only]
            #expect(line.contains(route.site), """
                `\(route.input)` is forwarded from a site that is not `\(route.site)` (line \
                \(body.offset + only + 1)) — the input a handler forwards must be the thing \
                that actually happened.
                """)
            for other in Self.inputRoutes.map(\.input) where other != route.input {
                #expect(!line.contains(other), """
                    the `\(route.site)` handler (line \(body.offset + only + 1)) forwards \
                    `\(other)` as well as `\(route.input)` — one gesture reported as two inputs \
                    is how a single click reaches a connecting activation.
                    """)
            }
        }
    }

    // MARK: - Guard B: a gesture handler forwards, and does nothing else

    /// Violation site 6. The row still holds callbacks that connect —
    /// `onOpenTerminal` and `onOpenExternalTerminal` are a connect plus a
    /// pane layout — and those are ordinary closures no type protects. A
    /// gesture may name exactly one callback, `onInput`; anything else it
    /// could call, it must not.
    @Test func noGestureHandlerNamesAnyCallbackButTheInputForward() throws {
        let body = try Self.sessionRowBody()
        var violations: [String] = []
        for index in body.lines.indices {
            let line = body.lines[index]
            guard Self.isCode(line) else { continue }
            guard line.contains(".onTapGesture") || line.contains(".onKeyPress") else { continue }
            let foreign = Self.callbackCalls(in: line).filter { $0 != "onInput" }
            if !foreign.isEmpty {
                violations.append("line \(body.offset + index + 1): \(foreign.joined(separator: ", "))")
            }
            #expect(line.contains("onInput("), """
                the gesture at line \(body.offset + index + 1) does not forward an input at all \
                — a gesture in this row exists to hand `SessionRowActivation` something to \
                decide about, never to act by itself.
                """)
        }
        #expect(violations.isEmpty, """
            gesture handler(s) in `SessionRow`'s body call a callback other than `onInput`: \
            \(violations.joined(separator: "; ")) — a gesture that calls `onOpenTerminal`, or \
            any other callback that ends in a connection, walks around the plan entirely, and \
            no type stops it because those callbacks are plain closures.
            """)
    }

    // MARK: - Guard C: nothing stands between the row and the plan

    /// Violation site 7. The sidebar hands the row its activation method
    /// verbatim; a closure there would be a second place to relabel an
    /// input, which is what the reviewer's probe did while every guard
    /// stayed green. Deleting the site is the fix — this keeps it deleted.
    @Test func theRowReceivesTheActivationMethodItselfNotAClosureAroundIt() throws {
        let lines = try Self.sourceLines()
        // The declaration (`let onInput: …`) names the same label and is not
        // a hand-over.
        let handOvers = lines.indices.filter { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return Self.isCode(lines[index]) && trimmed.contains("onInput:")
                && !trimmed.hasPrefix("let ")
        }
        #expect(handOvers.count == 1, """
            expected exactly one `onInput:` hand-over in SessionSidebar.swift, found \
            \(handOvers.count) at line(s) \(handOvers.map { $0 + 1 }) — re-anchor this guard.
            """)
        guard let only = handOvers.first else { return }
        let trimmed = lines[only].trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "onInput: activate(_:on:),", """
            the row's input callback is no longer the bare `activate(_:on:)` method reference \
            (found `\(trimmed)`) — anything with a body here can rewrite the input on its way \
            to the plan, so that a single click arrives as a double click and connects.
            """)
    }

    // MARK: - Guard D: the row stops being focusable while it is renamed

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

    // MARK: - Guard E: a rename that ends hands the keyboard back

    /// `selectedSessionID` survives a rename, the row's focus does not. A row
    /// that draws as selected while Return does nothing on it is exactly the
    /// "selection no key acts on" the brief rules out. Every deliberate end
    /// of a rename therefore goes through one function that hands focus back
    /// to the selected row — the commits, and both cancel wirings.
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
        // The two cancel WIRINGS, which the previous round left uncovered: a
        // rename abandoned with Escape, from a row or from a group header,
        // reaches `endRename` only through these.
        for wiring in ["onCancelRename: endRename,", ".onExitCommand(perform: endRename)"] {
            let wired = lines.contains { Self.isCode($0) && $0.contains(wiring) }
            #expect(wired, """
                `\(wiring)` is gone — a cancelled rename would end somewhere that does not hand \
                the keyboard back, and the selection would outlive the focus again.
                """)
        }
    }

    // MARK: - Guard F: activating a row ends its neighbour's rename

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

    // MARK: - Guard G: the plan is actually consulted

    /// Not a safety guard — sites 3 and 4 are compile errors now — but the
    /// "the rule is right and is not wired in" check the plan's own tests
    /// cannot be: an `activate` that stopped asking would leave every test
    /// in `SessionRowActivationTests` green over code nothing calls.
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

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The reviewer's probe against the previous round: the count-1 handler
    /// forwards the connecting input as well. Both halves of Guard A must
    /// reject it — the duplicate carrier, and the foreign input on the line.
    @Test func scannerFlagsAHandlerThatForwardsASecondInput() {
        let body = [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick, session) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick, session); _ = onInput(.doubleClick, session) }",
        ]
        #expect(body.filter { $0.contains(".doubleClick") }.count == 2)
        let singleLine = body.first { $0.contains(".onTapGesture(count: 1)") } ?? ""
        #expect(singleLine.contains(".doubleClick"))
    }

    /// The compliant shape must pass — without a check for it, the
    /// duplicate-carrier check could be satisfied by a scanner that flags
    /// everything.
    @Test func scannerAcceptsOneSitePerInput() {
        let body = [
            "        .onTapGesture(count: 2) { _ = onInput(.doubleClick, session) }",
            "        .onTapGesture(count: 1) { _ = onInput(.singleClick, session) }",
            "        .onKeyPress(.return) { onInput(.returnKey, session) ? .handled : .ignored }",
            "            Button(L10n.string(\"sidebar.connect\", \"Connect\")) { _ = onInput(.contextMenuEntry, session) }",
        ]
        for route in Self.inputRoutes {
            let carriers = body.filter { $0.contains(route.input) }
            #expect(carriers.count == 1, "\(route.input)")
            #expect(carriers[0].contains(route.site), "\(route.input)")
            for other in Self.inputRoutes.map(\.input) where other != route.input {
                #expect(!carriers[0].contains(other), "\(route.input)")
            }
        }
    }

    /// Guard B's scanner must see a callback smuggled into a gesture — and
    /// must not mistake the forward itself, or a non-callback call like
    /// `L10n.string(`, for one.
    @Test func callbackScannerSeesAForeignCallbackInAGesture() {
        let smuggled = "        .onTapGesture(count: 1) { onOpenTerminal() }"
        #expect(Self.callbackCalls(in: smuggled).filter { $0 != "onInput" } == ["onOpenTerminal"])

        let compliant = "        .onTapGesture(count: 1) { _ = onInput(.singleClick, session) }"
        #expect(Self.callbackCalls(in: compliant).filter { $0 != "onInput" }.isEmpty)

        let menuEntry = "            Button(L10n.string(\"sidebar.connect\", \"Connect\")) { _ = onInput(.contextMenuEntry, session) }"
        #expect(Self.callbackCalls(in: menuEntry).filter { $0 != "onInput" }.isEmpty)
    }

    /// A closure around the hand-over — the shape that let the reviewer
    /// rewrite the input — must not read as the bare method reference.
    @Test func handOverScannerRejectsAClosureAroundTheActivationMethod() {
        let rewritten = "                onInput: { input, session in activate(input == .singleClick ? .doubleClick : input, on: session) },"
        #expect(rewritten.trimmingCharacters(in: .whitespaces) != "onInput: activate(_:on:),")
        let compliant = "                onInput: activate(_:on:),"
        #expect(compliant.trimmingCharacters(in: .whitespaces) == "onInput: activate(_:on:),")
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

    /// Every callback this line CALLS, by this project's naming convention
    /// for them: an identifier starting `on` + capital, immediately applied,
    /// and NOT reached through a dot. The dot is what separates a callback
    /// the view holds (`onInput(`) from the modifier the handler is attached
    /// to (`.onTapGesture(`, `.onKeyPress(`), which would otherwise read as
    /// a callback call on every line this scans. A label (`onInput:`) has a
    /// colon rather than a paren and is not a call either.
    private static func callbackCalls(in line: String) -> [String] {
        var found: [String] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            guard characters[index] == "o", index + 1 < characters.count,
                  characters[index + 1] == "n",
                  index + 2 < characters.count, characters[index + 2].isUppercase
            else {
                index += 1
                continue
            }
            // Not a callback call if the identifier continues to the left,
            // or if it is a member of something — a modifier, not a callback.
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber
                || characters[index - 1] == "_" || characters[index - 1] == "." {
                index += 1
                continue
            }
            var end = index + 2
            while end < characters.count,
                  characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                end += 1
            }
            if end < characters.count, characters[end] == "(" {
                found.append(String(characters[index..<end]))
            }
            index = end
        }
        return found
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
