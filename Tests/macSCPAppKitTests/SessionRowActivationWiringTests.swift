import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards what is left of "a single click never reaches a host" once the
/// parts that could be made impossible have been.
///
/// The property: **the user's host is reached only for `.doubleClick`,
/// `.returnKey` on the selected row, and the three menu entries the user
/// picks by name — never for a single click, and never for a hover.**
/// "Host", not "connection": "Open in External Terminal" opens no
/// connection macSCP holds and reaches the server all the same.
///
/// Four rounds of review have each found the same shape of hole, and the
/// lesson is written here rather than re-learned: every violation is spelled
/// correctly, so an anchor against a spelling loses. Round 1 left an
/// unguarded condition; round 2 replaced it with an unguarded slot; round 3
/// found the slot had become an unguarded `self`; round 4 found the rule had
/// only ever been applied to one of the sidebar's three host-reaching
/// callbacks, while `onOpenTerminal` — a connect — stayed a plain closure
/// that any function in the file could call. What follows is therefore split
/// by what KIND of thing holds each site, and the split is the claim — each
/// line of it was checked by planting the mutation, not by reading.
///
/// 1. `build` misclassifies an input. → `SessionRowActivationTests`; the
///    mutation is inside the function under test.
/// 2. The chain from an input to an effect misroutes. →
///    `PerformSessionRowInputTests`, spies over the one entry point.
/// 3. The view fires the connect effect by choosing an activation for it —
///    `SessionRowActivation.selectAndConnect.apply(…)`. → **Compile error**:
///    `apply` is `fileprivate`, and `performSessionRowInput` never hands an
///    activation back.
/// 4. The view fires the effect directly: calling it, unwrapping `run`,
///    reaching it by key path, or passing it where the selection effect
///    belongs. → **Compile error** on all four spellings. NOT closed against
///    an extension added to the effects' own file, or `Mirror` — both
///    deliberately left; see `SessionRowConnectEffect` for why a guard
///    against those would be worth less than the stated limit.
/// 5. The entry point is called from somewhere else in the sidebar, or with
///    an input the caller did not receive. → **Guard A** (every input
///    literal in the file sits on its own site) and **Guard B** (one call
///    site, inside `activate`).
/// 6. A handler acts through a DIFFERENT host-reaching callback instead of
///    forwarding. → **Guard D** in the row's body, **Guard E** in
///    `activate`. Reached by `.onHover` while this suite only read two
///    modifiers, which is what round 3 corrected — and, until round 4, by
///    any function of the file at all, because the callback it acted
///    through was a closure rather than an effect (site 9).
/// 7. The input is rewritten between the row and the plan. → The closure
///    that allowed it is deleted; **Guard I** keeps it deleted.
/// 8. A connect path in a DIFFERENT file. → Out of reach, measured rather
///    than assumed: a dial planted in `ContentView.swift` leaves this suite
///    green. **Guard J** pins only that the sidebar is given live effects
///    at all, not what other files do with theirs.
/// 9. A host-reaching callback is spelled as a plain closure, so calling it
///    compiles anywhere. → **Guard K**, over the declarations rather than
///    the calls: while the declaration is an effect type, every call that
///    site 6 watches for is a compile error instead of a scan result. This
///    is the one that was missed three times, and it was missed by taking
///    the previous round's list of routes as the starting point.
///
/// `SessionSidebar` and `SessionRow` cannot be DRIVEN from a test here:
/// `ViewTestabilitySpike` shows views of this package can be instantiated
/// and rendered offscreen, but there is no way to inject a click or a key
/// press. Every guard here is a source-text scan; they say which handler
/// routes which input, never that macOS delivers it. The scans are
/// line-based and literal, so a handler split across lines reads as a
/// MISSING route rather than a compliant one — they fail closed, and a
/// reformat costs a re-anchor instead of silent cover.
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
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    /// Which site is allowed to name which input. The three menu entries are
    /// in the table for the same reason the gestures are: each is an input
    /// now, not a connect path of its own.
    private static let inputRoutes: [(input: String, site: String)] = [
        (".singleClick", ".onTapGesture(count: 1)"),
        (".doubleClick", ".onTapGesture(count: 2)"),
        (".returnKey", ".onKeyPress(.return)"),
        (".contextMenuEntry", "\"sidebar.connect\""),
        (".terminalMenuEntry", "Button(openTerminalTitle)"),
        (".externalTerminalMenuEntry", "Button(externalTerminalTitle)"),
    ]

    /// Every callback of this sidebar whose far end reaches the user's host,
    /// with the effect type each one must be declared as (Guard K). Derived
    /// from `SessionSidebar`'s own properties and each one's far end, not
    /// from any earlier round's list: `onConnect` dials through
    /// `ContentView.connectFromSidebar`, `onOpenTerminal` through
    /// `openTerminalFromSidebar` (the same dial plus a pane layout), and
    /// `onOpenExternalTerminal` through `openExternalTerminalFromSidebar`,
    /// which resolves a configuration — keychain read included — and hands
    /// it to a program that dials. Every other callback the sidebar holds
    /// ends in this app's own window: a sheet, the store, a form, or the
    /// active tab's existing shell.
    private static let hostReachingDeclarations = [
        "let onConnect: SessionRowConnectEffect<StoredSession>",
        "let onOpenTerminal: SessionRowTerminalEffect<StoredSession>",
        "let onOpenExternalTerminal: SessionRowExternalTerminalEffect<StoredSession>",
    ]

    private static let hostReachingNames = [
        "onConnect", "onOpenTerminal", "onOpenExternalTerminal",
    ]

    /// The far end of each host-reaching effect, as `ContentView+Detail.swift`
    /// has to spell it (Guard J).
    private static let effectHandOvers: [(prefix: String, method: String)] = [
        ("onConnect: SessionRowConnectEffect", "connectFromSidebar("),
        ("onOpenTerminal: SessionRowTerminalEffect", "openTerminalFromSidebar("),
        (
            "onOpenExternalTerminal: SessionRowExternalTerminalEffect",
            "openExternalTerminalFromSidebar("
        ),
    ]

    /// The table is hand-written while `SessionRowInput` is `CaseIterable`;
    /// without this, a seventh input would be classified by every value test
    /// and simply not carried here.
    @Test func theRoutingTableCoversEveryInputTheEnumHas() {
        #expect(Self.inputRoutes.count == SessionRowInput.allCases.count, """
            `inputRoutes` lists \(Self.inputRoutes.count) inputs but `SessionRowInput` has \
            \(SessionRowInput.allCases.count) — an input nothing in this table names is an \
            input Guard A does not route.
            """)
    }

    // MARK: - Guard A: every input literal sits on its own site, file-wide

    /// Violation site 5, and the "a handler lies about which gesture
    /// happened" half of it. File-wide rather than scoped to the row's body:
    /// naming an input is how anything in this file reaches the entry point,
    /// so a literal anywhere else — in `moveSelection`, in the imported-hosts
    /// row — is a second, unrouted way in.
    @Test func everyInputLiteralInTheFileSitsOnItsOwnSiteAndNamesNoOther() throws {
        let lines = try Self.sourceLines()
        for route in Self.inputRoutes {
            let carriers = lines.indices.filter { index in
                Self.isCode(lines[index]) && lines[index].contains(route.input)
            }
            #expect(carriers.count == 1, """
                `\(route.input)` is named at \(carriers.count) place(s) in SessionSidebar.swift \
                (line(s) \(carriers.map { $0 + 1 })), expected exactly one — a second one is \
                either a handler claiming an input that did not happen, or a function other \
                than the row's own handlers reaching the activation path.
                """)
            guard let only = carriers.first else { continue }
            #expect(lines[only].contains(route.site), """
                `\(route.input)` is named at a place that is not `\(route.site)` (line \
                \(only + 1)) — the input a handler forwards must be the thing that actually \
                happened.
                """)
            for other in Self.inputRoutes.map(\.input) where other != route.input {
                #expect(!lines[only].contains(other), """
                    the `\(route.site)` handler (line \(only + 1)) names `\(other)` as well as \
                    `\(route.input)` — one gesture reported as two inputs is how a single click \
                    reaches a connecting activation.
                    """)
            }
        }
    }

    // MARK: - Guard B: one way in, from one place

    /// Violation site 5's other half: the entry point called with an input
    /// that was passed in rather than made up is safe, so what has to be
    /// pinned is WHERE it is called from. `activate` is the sidebar's single
    /// door; a second call — in the function that moves the selection, in
    /// another row — is a second door with no handler behind it.
    @Test func theEntryPointIsCalledOnceAndOnlyFromTheActivationPath() throws {
        let lines = try Self.sourceLines()
        let calls = lines.indices.filter { index in
            Self.isCode(lines[index]) && lines[index].contains("performSessionRowInput(")
        }
        #expect(calls.count == 1, """
            expected exactly one call to `performSessionRowInput(` in SessionSidebar.swift, \
            found \(calls.count) at line(s) \(calls.map { $0 + 1 }) — that function is the only \
            thing in this file that can open a connection, so every call to it is a connect \
            path somebody has to have read.
            """)
        guard let only = calls.first,
              let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        #expect(activate.contains(only), """
            the call to `performSessionRowInput(` at line \(only + 1) is outside `activate` — \
            the rename hand-off and the selection rules live there, and a call that skips them \
            connects without either.
            """)
    }

    // MARK: - Guard C: no tap gesture without a click count, file-wide

    /// Restored in fix round 3. It was deleted in round 2 as "covered by the
    /// routing table", and that was simply wrong: the table was scoped to
    /// `SessionRow`'s body, so nothing watched the imported-hosts row any
    /// more. The reviewer then planted a countless `.onTapGesture` there
    /// that connected, and the suite stayed green — the day this guard's own
    /// doc comment had predicted when it was written.
    ///
    /// File-wide, therefore, and staying that way: a countless tap gesture
    /// fires on the FIRST click, which is the behaviour this whole task
    /// removed from the session row.
    ///
    /// It watches the GESTURE, not what the gesture does — the reviewer's
    /// probe that added a click count to the same connecting line went from
    /// red to green on that one token. That blind spot is covered from the
    /// other side since fix round 4 rather than by widening this scan:
    /// a line in this file that reaches a host no longer compiles unless it
    /// names an input, which Guard A routes.
    @Test func noTapGestureInTheFileOmitsItsClickCount() throws {
        let lines = try Self.sourceLines()
        let countless = lines.indices.filter { index in
            let line = lines[index]
            guard Self.isCode(line) else { return false }
            return line.contains(".onTapGesture") && !line.contains("count:")
        }
        #expect(countless.isEmpty, """
            `SessionSidebar.swift` attaches a tap gesture without a `count:` at line(s) \
            \(countless.map { $0 + 1 }) — a countless tap gesture fires on the FIRST click. \
            Every row in this sidebar spells out which click count it answers, including the \
            imported-hosts row, which answers one click deliberately and does not connect.
            """)
    }

    // MARK: - Guard D: outside its menu, the row forwards and nothing else

    /// Violation site 6. The row's remaining callbacks stay inside this
    /// window — a sheet, the store, a form, the active tab's shell — and no
    /// type protects them; inside the context menu, calling them is the
    /// entire point. Everywhere else in the body, the only callback that may
    /// be called is `onInput`.
    ///
    /// Round 2's version of this read `.onTapGesture` and `.onKeyPress`
    /// lines only, which left `.onHover` free: a mouseover that dialled was
    /// green. The rule is now about WHERE a callback is called, not which
    /// modifier is on the line, so a modifier nobody has thought of yet is
    /// covered too.
    ///
    /// What it is NOT, and what fix round 4 had to close elsewhere: this
    /// scan reads `SessionRow`'s body. A gesture in the imported-hosts row,
    /// or a call in `moveSelection`, is outside it entirely. Guard K is what
    /// covers those, by making the call itself impossible.
    @Test func outsideItsContextMenuTheRowCallsNoCallbackButTheInputForward() throws {
        let body = try Self.sessionRowBody()
        guard let menu = Self.range(ofBlockStartingWith: ".contextMenu {", in: body.lines) else {
            Issue.record("`.contextMenu {` not found inside `SessionRow`'s body — re-anchor this guard")
            return
        }
        var violations: [String] = []
        for index in body.lines.indices where !menu.contains(index) {
            let line = body.lines[index]
            guard Self.isCode(line) else { continue }
            let foreign = Self.callbackCalls(in: line).filter { $0 != "onInput" }
            if !foreign.isEmpty {
                violations.append(
                    "line \(body.offset + index + 1): \(foreign.joined(separator: ", "))")
            }
        }
        #expect(violations.isEmpty, """
            `SessionRow`'s body calls a callback other than `onInput` outside its context \
            menu: \(violations.joined(separator: "; ")) — a hover, a drag or a gesture that \
            calls `onOpenTerminal`, or any other callback ending in a connection, walks around \
            the plan entirely. Only entries the user picks by name may act directly.
            """)
    }

    // MARK: - Guard E: the activation path forwards and nothing else

    /// Violation site 6 inside the sidebar rather than the row: `activate`
    /// can hand the plan exactly the right input and then also act on its
    /// own account, which leaves every guard that looks for the right call
    /// perfectly satisfied. It may reach the entry point, the rename
    /// hand-off and its own state — no callback.
    @Test func theActivationPathCallsNoCallbackOfItsOwn() throws {
        let lines = try Self.sourceLines()
        guard let activate = Self.range(ofBlockStartingWith: "private func activate(", in: lines)
        else {
            Issue.record("`private func activate(` not found — re-anchor this guard")
            return
        }
        var violations: [String] = []
        for index in activate where Self.isCode(lines[index]) {
            let called = Self.callbackCalls(in: lines[index])
            if !called.isEmpty {
                violations.append("line \(index + 1): \(called.joined(separator: ", "))")
            }
        }
        #expect(violations.isEmpty, """
            `activate` calls a callback itself: \(violations.joined(separator: "; ")) — it \
            forwards an input and applies what comes back; anything it does beside that is a \
            second action on the same gesture, invisible to every guard that only checks the \
            forward is still there.
            """)
    }

    // MARK: - Guard F: the row stops being focusable while it is renamed

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

    // MARK: - Guard G: a rename that ends hands the keyboard back

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
        for wiring in ["onCancelRename: endRename,", ".onExitCommand(perform: endRename)"] {
            let wired = lines.contains { Self.isCode($0) && $0.contains(wiring) }
            #expect(wired, """
                `\(wiring)` is gone — a cancelled rename would end somewhere that does not hand \
                the keyboard back, and the selection would outlive the focus again.
                """)
        }
    }

    // MARK: - Guard H: activating a row ends an open rename

    /// Acting on a row moves the first responder to it, which takes focus
    /// out of whatever rename field held it. Left to the focus-loss handler
    /// alone, that row can keep drawing an editable field with a draft in it
    /// that is neither committed nor discarded — including, since the menu
    /// entry stopped being subject to the rename guard, its OWN row.
    @Test func theActivationPathEndsAnOpenRename() throws {
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
            `activate` never asks `SidebarRenameHandoff.endsOpenRename(` — an activation would \
            pull the first responder out of an open rename field and leave that row editable, \
            unfocused and unreachable except by clicking inside the field itself.
            """)
        let ends = activate.contains {
            Self.isCode(lines[$0]) && lines[$0].contains("endRename()")
        }
        #expect(ends, """
            `activate` asks whether a rename must end and never ends one — the question would \
            be answered and dropped.
            """)
    }

    // MARK: - Guard I: nothing stands between the row and the plan

    /// Violation site 7. The sidebar hands the row its activation method
    /// verbatim; a closure there would be a second place to relabel an
    /// input, which is what a reviewer's probe did while every guard stayed
    /// green. Deleting the site is the fix — this keeps it deleted.
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

    // MARK: - Guard J: the sidebar is given the abilities it cannot fake

    /// The counter-direction to every other guard in this suite, and the one
    /// thing nothing held until fix round 3: handing the sidebar a do-nothing
    /// effect (`SessionRowConnectEffect { _ in }`) leaves it unable to act by
    /// ANY route, with the suite green. The rest of this suite says a click
    /// must not reach a host; this one says a double click and the menu
    /// entries still must.
    ///
    /// One row per host-reaching effect since round 4 — an inert effect is
    /// exactly as invisible for the terminal entries as it was for connect.
    @Test func theSidebarIsHandedEffectsThatActuallyReachTheHost() throws {
        let lines = try String(contentsOf: Self.detailFile, encoding: .utf8)
            .components(separatedBy: "\n")
        for wiring in Self.effectHandOvers {
            let handOvers = lines.indices.filter { index in
                Self.isCode(lines[index]) && lines[index].contains(wiring.prefix)
            }
            #expect(handOvers.count == 1, """
                expected exactly one `\(wiring.prefix)` in ContentView+Detail.swift, found \
                \(handOvers.count) at line(s) \(handOvers.map { $0 + 1 }) — re-anchor this guard.
                """)
            guard let only = handOvers.first else { continue }
            #expect(lines[only].contains(wiring.method), """
                the effect handed to the sidebar no longer calls `\(wiring.method)` (line \
                \(only + 1)) — that route would reach nothing at all, and every other guard in \
                this suite would still pass.
                """)
        }
    }

    // MARK: - Guard K: every callback that reaches the host is an effect value

    /// The route three rounds of enumeration missed, each time by reading
    /// the previous round's list instead of the sidebar's callbacks.
    /// `onConnect` was wrapped in a type this view cannot fire; the two
    /// terminal callbacks were left plain closures — and "Open Terminal" IS
    /// a connect, by its own doc comment and by
    /// `ContentView.openTerminalFromSidebar`, which is `connectFromSidebar`
    /// plus `paneVisibility:`. A single line, `onOpenTerminal(session)` in
    /// the function that moves the selection, made every single click dial
    /// with the whole suite green; the same line in the imported-hosts row
    /// did it with a correct `count: 1`.
    ///
    /// `onOpenExternalTerminal` is held to the same rule although macSCP
    /// itself never dials on that route: it reads the keychain and hands the
    /// resolved configuration to a program that does. The user's host is
    /// reached either way, which is what a stray click would amount to.
    ///
    /// What this guard pins is the DECLARATIONS, not a behaviour: spelling
    /// one of them as a closure again re-opens every route at once and
    /// changes nothing any behavioural test in this project can observe.
    ///
    /// Its limit, stated rather than implied: it knows these callbacks by
    /// name. A FOURTH callback that reaches a host, added under a new name,
    /// is a new capability nothing here would notice — no syntactic rule
    /// separates it from `onEdit`, which takes the same `StoredSession` and
    /// only opens a form. What holds then is `SessionRowInput`'s doc: an
    /// entry that starts a session on the user's host is an input, and
    /// anything else is not.
    @Test func everyHostReachingCallbackOfTheSidebarIsAnEffectValue() throws {
        let lines = try Self.sourceLines()
        for declaration in Self.hostReachingDeclarations {
            let sites = lines.indices.filter {
                Self.isCode(lines[$0])
                    && lines[$0].trimmingCharacters(in: .whitespaces) == declaration
            }
            #expect(sites.count == 1, """
                `SessionSidebar` does not declare `\(declaration)` exactly once (found \
                \(sites.count)) — a callback that reaches the user's host and is spelled as a \
                plain closure can be called from any function in this file, which is how a \
                single click connected while every other guard here stayed green.
                """)
        }
    }

    /// The row's half of the same rule. A callback the row holds is one any
    /// modifier attached to the row can call, and Guard D only watches the
    /// body: the row's route to the host is the input forward, and nothing
    /// else.
    @Test func theRowHoldsNoHostReachingCallbackOfItsOwn() throws {
        let declarations = try Self.sessionRowDeclarations()
        let held = Self.hostReachingNames.filter { name in
            declarations.contains { line in
                Self.isCode(line)
                    && line.trimmingCharacters(in: .whitespaces).hasPrefix("let \(name):")
            }
        }
        #expect(held.isEmpty, """
            `SessionRow` declares \(held.joined(separator: ", ")) — the row reaches the user's \
            host through its input forward alone, so a callback of its own is a second route \
            that any gesture, hover or drag on the row can take.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// Guard K's scanner must tell a plain closure from an effect value, and
    /// must see a host-reaching callback the row holds under any spelling of
    /// its type.
    @Test func theDeclarationScannerTellsAClosureFromAnEffectValue() {
        let closure = "    let onOpenTerminal: (StoredSession) -> Void"
        #expect(!Self.hostReachingDeclarations.contains(
            closure.trimmingCharacters(in: .whitespaces)))
        let effect = "    let onOpenTerminal: SessionRowTerminalEffect<StoredSession>"
        #expect(Self.hostReachingDeclarations.contains(
            effect.trimmingCharacters(in: .whitespaces)))

        let rowHoldsOne = ["    let onOpenTerminal: () -> Void"]
        #expect(Self.hostReachingNames.contains { name in
            rowHoldsOne.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("let \(name):") }
        })
        let rowHoldsNone = ["    let onInput: (SessionRowInput, StoredSession) -> Bool"]
        #expect(!Self.hostReachingNames.contains { name in
            rowHoldsNone.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("let \(name):") }
        })
    }

    /// A handler that forwards a second, connecting input — the shape that
    /// survived an earlier round.
    @Test func scannerFlagsAHandlerThatNamesASecondInput() {
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
            "                Button(openTerminalTitle) { _ = onInput(.terminalMenuEntry, session) }",
            "                Button(externalTerminalTitle) { _ = onInput(.externalTerminalMenuEntry, session) }",
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

    /// Guard D's scanner must see a callback smuggled into any modifier —
    /// the hover that dialled is the one that got past its predecessor —
    /// and must not mistake the forward itself, the modifier it is attached
    /// to, or a non-callback call for one.
    ///
    /// The synthetic lines name callbacks the row still holds. The hover
    /// that dialled named `onOpenTerminal`, which is no longer a callback
    /// anywhere: writing that line is a compile error since fix round 4, so
    /// a scanner test over it would prove nothing about anything reachable.
    @Test func callbackScannerSeesAForeignCallbackWhicheverModifierHoldsIt() {
        let hover = "        .onHover { isHovering = $0; if $0 { onShowAuditLog() } }"
        #expect(Self.callbackCalls(in: hover).filter { $0 != "onInput" } == ["onShowAuditLog"])

        let tap = "        .onTapGesture(count: 1) { onEdit() }"
        #expect(Self.callbackCalls(in: tap).filter { $0 != "onInput" } == ["onEdit"])

        let compliant = "        .onTapGesture(count: 1) { _ = onInput(.singleClick, session) }"
        #expect(Self.callbackCalls(in: compliant).filter { $0 != "onInput" }.isEmpty)

        let plainHover = "        .onHover { isHovering = $0 }"
        #expect(Self.callbackCalls(in: plainHover).isEmpty)

        let menuEntry = "            Button(L10n.string(\"sidebar.connect\", \"Connect\")) { _ = onInput(.contextMenuEntry, session) }"
        #expect(Self.callbackCalls(in: menuEntry).filter { $0 != "onInput" }.isEmpty)

        // A hand-over is not a call: the name is not followed by a paren.
        let handOver = "                    .onSubmit(onCommitRename)"
        #expect(Self.callbackCalls(in: handOver).isEmpty)
    }

    /// A closure around the hand-over — the shape that let a reviewer
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
    /// to (`.onTapGesture(`, `.onHover(`), which would otherwise read as a
    /// callback call on every line this scans. A label (`onInput:`) has a
    /// colon rather than a paren and is not a call either, nor is a
    /// hand-over (`.onSubmit(onCommitRename)`), where the name is followed
    /// by `)`.
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

    /// `SessionRow`'s stored properties: its lines from the struct
    /// declaration up to its `var body`, which is where Guard D takes over.
    private static func sessionRowDeclarations() throws -> [String] {
        let lines = try sourceLines()
        guard let structStart = lines.firstIndex(where: {
            $0.contains("struct SessionRow: View {")
        }) else {
            throw ScanFailure.anchorMissing("struct SessionRow: View {")
        }
        let tail = Array(lines[structStart...])
        guard let bodyStart = tail.firstIndex(where: { $0.contains("var body: some View {") })
        else {
            throw ScanFailure.anchorMissing("var body: some View { inside SessionRow")
        }
        return Array(tail[..<bodyStart])
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
