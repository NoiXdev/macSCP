import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Pins `SessionRowActivation.build`, the rule behind what a click, a double
/// click and Return do to a session row.
///
/// The behaviour this replaces: a single click opened a connection. That is
/// the property this whole suite is really about — pointing at a session and
/// opening it are now two different gestures — and it is a property about NOT
/// acting, which is the kind that silently comes back once nothing states it.
///
/// This suite proves WHICH activation each input maps to. It does not prove
/// that macOS delivers a second click as a `count: 2` tap or Return to the
/// focused row, and it does not prove that `SessionSidebar` asks at all —
/// `SessionRowActivationWiringTests` is the wiring half, and no test in this
/// project renders a view.
@Suite("SessionRowActivation")
struct SessionRowActivationTests {
    /// The regression itself: one click must never reach a connection.
    @Test func aSingleClickSelectsAndNeverConnects() {
        let activation = SessionRowActivation.build(
            for: .singleClick, isRenaming: false, isSelected: false)
        #expect(activation == .select)
        #expect(!activation.connects)
    }

    /// Clicking the row that is already selected stays a selection — it
    /// must not turn into a second-click connect just because the row was
    /// already pointed at.
    @Test func aSingleClickOnTheAlreadySelectedRowStillOnlySelects() {
        #expect(
            SessionRowActivation.build(for: .singleClick, isRenaming: false, isSelected: true)
                == .select)
    }

    /// The mouse path to a connection.
    @Test func aDoubleClickConnects() {
        let activation = SessionRowActivation.build(
            for: .doubleClick, isRenaming: false, isSelected: false)
        #expect(activation == .selectAndConnect)
        #expect(activation.connects)
    }

    /// A double click connects the row it landed on whether or not that row
    /// was the selected one: the click itself is what names the session.
    @Test func aDoubleClickConnectsRegardlessOfWhatWasSelectedBefore() {
        #expect(
            SessionRowActivation.build(for: .doubleClick, isRenaming: false, isSelected: true)
                == .selectAndConnect)
    }

    /// The keyboard path — the reason the selection is more than a colour.
    @Test func returnConnectsTheSelectedRow() {
        #expect(
            SessionRowActivation.build(for: .returnKey, isRenaming: false, isSelected: true)
                == .selectAndConnect)
    }

    /// Return arriving at a row the selection is not on names no session
    /// the user pointed at, so it is left for the rest of the window.
    @Test func returnDoesNothingOnARowThatIsNotSelected() {
        #expect(
            SessionRowActivation.build(for: .returnKey, isRenaming: false, isSelected: false)
                == .doNothing)
    }

    /// The rename guard, over every GESTURE rather than the click alone:
    /// while a row is being renamed its text field owns both the pointer and
    /// the keyboard. A click that re-selected the row underneath would pull
    /// focus out of the field and cancel the edit; Return belongs to the
    /// field's own submit.
    @Test(arguments: SessionRowInput.allCases.filter { !$0.isMenuEntry })
    func renamingSwallowsEveryGesture(input: SessionRowInput) {
        for isSelected in [true, false] {
            let activation = SessionRowActivation.build(
                for: input, isRenaming: true, isSelected: isSelected)
            #expect(activation == .doNothing, "input \(input), isSelected \(isSelected)")
            #expect(!activation.acts)
            #expect(!activation.reachesTheHost)
        }
    }

    /// The inputs the rename guard does not apply to. A menu entry the user
    /// read and chose must not silently do nothing because the row happens
    /// to be in rename mode — the interruption is the lesser surprise, and
    /// it is handled: `SidebarRenameHandoff` ends the edit first.
    @Test(arguments: SessionRowInput.allCases.filter(\.isMenuEntry))
    func aMenuEntryActsEvenWhileTheRowIsBeingRenamed(input: SessionRowInput) {
        for isSelected in [true, false] {
            let activation = SessionRowActivation.build(
                for: input, isRenaming: true, isSelected: isSelected)
            #expect(activation.reachesTheHost, "input \(input), isSelected \(isSelected)")
        }
    }

    /// Each menu entry maps to its own far end, and nothing else does. Two
    /// entries that answered the same activation would be one entry the
    /// user cannot tell from the other.
    ///
    /// Each also selects the row it acts on — the two terminal entries did
    /// not, while they were callbacks the row called directly. That the
    /// selection effect actually RUNS, and runs first, is pinned in
    /// `PerformSessionRowInputTests` by
    /// `everyHostReachIsPrecededBySelectingTheSameRow`; here it is only the
    /// activation each entry maps to.
    @Test func eachMenuEntryReachesItsOwnFarEnd() {
        #expect(SessionRowActivation.build(
            for: .contextMenuEntry, isRenaming: false, isSelected: false) == .selectAndConnect)
        #expect(SessionRowActivation.build(
            for: .terminalMenuEntry, isRenaming: false, isSelected: false)
            == .selectAndOpenTerminal)
        #expect(SessionRowActivation.build(
            for: .externalTerminalMenuEntry, isRenaming: false, isSelected: false)
            == .selectAndOpenExternalTerminal)
    }

    /// What each predicate answers per case is part of the contract, not a
    /// convenience: `acts` false is the only thing that leaves a key press
    /// unhandled and the only thing that leaves an open rename alone,
    /// `connects` marks the routes on which macSCP itself dials, and
    /// `reachesTheHost` adds the one on which another program does.
    ///
    /// The split between the last two is deliberate, and it is the reason
    /// the external terminal is inside this type at all: macSCP opens no
    /// connection there and the user's server is contacted all the same, so
    /// the property a stray click must not violate is the wider one.
    @Test func theThreePredicatesAnswerPerCase() {
        #expect(!SessionRowActivation.doNothing.acts)
        #expect(SessionRowActivation.select.acts)
        #expect(SessionRowActivation.selectAndConnect.acts)
        #expect(SessionRowActivation.selectAndOpenTerminal.acts)
        #expect(SessionRowActivation.selectAndOpenExternalTerminal.acts)

        #expect(!SessionRowActivation.doNothing.connects)
        #expect(!SessionRowActivation.select.connects)
        #expect(SessionRowActivation.selectAndConnect.connects)
        #expect(SessionRowActivation.selectAndOpenTerminal.connects)
        #expect(!SessionRowActivation.selectAndOpenExternalTerminal.connects)

        #expect(!SessionRowActivation.doNothing.reachesTheHost)
        #expect(!SessionRowActivation.select.reachesTheHost)
        #expect(SessionRowActivation.selectAndConnect.reachesTheHost)
        #expect(SessionRowActivation.selectAndOpenTerminal.reachesTheHost)
        #expect(SessionRowActivation.selectAndOpenExternalTerminal.reachesTheHost)
    }

    /// A `build` that answered `.selectAndConnect` for everything would pass
    /// the per-input checks one at a time; this is what rules out a constant
    /// answer across the inputs that exist. Stated over the enum's own cases
    /// rather than a list, so an activation nothing can ever answer — a case
    /// added and never wired — fails here.
    @Test func everyActivationIsReachableFromSomeInput() {
        var answers: Set<SessionRowActivation> = []
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    answers.insert(SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected))
                }
            }
        }
        #expect(answers == [
            .doNothing, .select, .selectAndConnect,
            .selectAndOpenTerminal, .selectAndOpenExternalTerminal,
        ])
    }

    /// Nothing but a double click, a selected row's Return and the menu
    /// entries may reach the user's host — stated over the whole input space
    /// rather than case by case, so a further input has to be classified
    /// deliberately instead of inheriting a host reach by default.
    ///
    /// `reachesTheHost` rather than `connects`, because a single click that
    /// launched an external terminal onto the server would be the same
    /// surprise this whole task removed, and `connects` is false for it.
    @Test func nothingOutsideTheIntendedInputsEverReachesTheHost() {
        var reaching: [(SessionRowInput, Bool, Bool)] = []
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let activation = SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected)
                    if activation.reachesTheHost {
                        reaching.append((input, isRenaming, isSelected))
                    }
                }
            }
        }
        #expect(reaching.allSatisfy { input, isRenaming, isSelected in
            input.isMenuEntry
                || (!isRenaming && (input == .doubleClick || (input == .returnKey && isSelected)))
        }, "an input outside double click / selected-row Return / a menu entry reaches the host: \(reaching)")
        #expect(!reaching.isEmpty, "no combination reaches a host at all — the row would be inert")
    }
}

/// Pins `performSessionRowInput` — the one reachable way to act on a row,
/// and therefore the whole chain from an input to a host.
///
/// It replaced a test over `apply` in fix round 3, because `apply` stopped
/// being reachable: as an internal method on a freely constructible enum it
/// WAS the firing site, and `SessionRowActivation.selectAndConnect.apply(…)`
/// written into any function of the view dialled on every single click with
/// the full suite green. Testing the entry point instead is both the
/// stronger statement — build and apply together — and the only one left.
///
/// All three host-reaching effects are spied on, not just connect: fix round
/// 4 brought the two terminal entries onto this path, and a chain that ran
/// the wrong one of them would be invisible to a spy that only watched the
/// connect slot.
///
/// The spies record the ORDER as well as the count, because "select first"
/// is a promise the highlight depends on: the row has to name the session
/// before anything reaches its host.
@Suite("performSessionRowInput")
struct PerformSessionRowInputTests {
    /// Records which effects ran, in order.
    private final class Effects {
        private(set) var log: [String] = []
        func select(_ value: String) { log.append("select(\(value))") }
        func connect(_ value: String) { log.append("connect(\(value))") }
        func openTerminal(_ value: String) { log.append("terminal(\(value))") }
        func openExternalTerminal(_ value: String) { log.append("external(\(value))") }
    }

    /// The log entries that mean the user's host was reached — everything
    /// but the selection.
    private static let hostReaches = ["connect", "terminal", "external"]

    private func run(
        _ input: SessionRowInput, isRenaming: Bool = false, isSelected: Bool = false
    ) -> (log: [String], applied: Bool) {
        let effects = Effects()
        let applied = performSessionRowInput(
            input, on: "row", isRenaming: isRenaming, isSelected: isSelected,
            onSelect: SessionRowSelectEffect(effects.select(_:)),
            onConnect: SessionRowConnectEffect(effects.connect(_:)),
            onOpenTerminal: SessionRowTerminalEffect(effects.openTerminal(_:)),
            onOpenExternalTerminal:
                SessionRowExternalTerminalEffect(effects.openExternalTerminal(_:)))
        return (effects.log, applied)
    }

    /// Whether this log records the host being reached, by any of the three
    /// routes.
    private func reachesHost(_ log: [String]) -> Bool {
        log.contains { entry in Self.hostReaches.contains { entry.hasPrefix($0) } }
    }

    /// The regression the whole task is about, stated where the effects
    /// actually run rather than where they are classified.
    @Test func aSingleClickSelectsAndNeverReachesAnyHostEffect() {
        let result = run(.singleClick)
        #expect(result.log == ["select(row)"])
        #expect(result.applied)
    }

    @Test func aSwallowedInputRunsNoEffectAtAll() {
        let result = run(.singleClick, isRenaming: true)
        #expect(result.log.isEmpty)
        #expect(!result.applied)
    }

    @Test func aDoubleClickSelectsBeforeItConnects() {
        let result = run(.doubleClick)
        #expect(result.log == ["select(row)", "connect(row)"])
        #expect(result.applied)
    }

    @Test func returnConnectsTheSelectedRowAndNothingElse() {
        #expect(run(.returnKey, isSelected: true).log == ["select(row)", "connect(row)"])
        #expect(run(.returnKey, isSelected: false).log.isEmpty)
    }

    /// Each menu entry runs its OWN far end and no other. The two terminal
    /// entries reached theirs through the row before fix round 4, which is
    /// how a single click could reach one of them.
    @Test func eachMenuEntryRunsItsOwnEffectAndNoOther() {
        #expect(run(.contextMenuEntry, isRenaming: true).log == ["select(row)", "connect(row)"])
        #expect(run(.terminalMenuEntry).log == ["select(row)", "terminal(row)"])
        #expect(run(.externalTerminalMenuEntry).log == ["select(row)", "external(row)"])
    }

    @Test(arguments: SessionRowInput.allCases.filter(\.isMenuEntry))
    func aMenuEntryActsEvenOnARowBeingRenamed(input: SessionRowInput) {
        let result = run(input, isRenaming: true)
        #expect(result.log.first == "select(row)")
        #expect(reachesHost(result.log))
    }

    /// Each effect runs at most once — a chain that connected twice would
    /// open two connections from one double click, and the order check alone
    /// would not see it. Over the whole log rather than a chosen pair, so an
    /// effect added later is counted without this test being revisited.
    @Test func noEffectRunsTwiceForAnyInput() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let log = run(input, isRenaming: isRenaming, isSelected: isSelected).log
                    #expect(Set(log).count == log.count, "\(input): \(log)")
                }
            }
        }
    }

    /// And at most one of them reaches the host: an activation that both
    /// connected and opened an external terminal would dial twice from one
    /// entry.
    @Test func atMostOneHostEffectRunsForAnyInput() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let log = run(input, isRenaming: isRenaming, isSelected: isSelected).log
                    let reaches = log.filter { entry in
                        Self.hostReaches.contains { entry.hasPrefix($0) }
                    }
                    #expect(reaches.count <= 1, "\(input): \(log)")
                }
            }
        }
    }

    /// What the entry point reports is what the row hands SwiftUI as
    /// handled/ignored, so it must agree with whether anything ran.
    @Test func whatItReportsAgreesWithWhetherAnEffectRan() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let result = run(input, isRenaming: isRenaming, isSelected: isSelected)
                    #expect(result.applied == !result.log.isEmpty, "\(input)")
                }
            }
        }
    }

    /// The property of the whole task, over the entire input space and at
    /// the point where the effects actually run: only a double click, Return
    /// on the selected row, and the menu entries ever reach the user's host.
    /// A further input added later is iterated by `allCases` and has to be
    /// classified deliberately.
    ///
    /// Over ALL THREE host-reaching effects. Watching the connect slot alone
    /// is exactly the gap fix round 4 closed: `onOpenTerminal` dialled and
    /// no test in this project could see it.
    @Test func onlyTheIntendedInputsEverReachTheHost() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let reached = reachesHost(
                        run(input, isRenaming: isRenaming, isSelected: isSelected).log)
                    let expected = input.isMenuEntry
                        || (!isRenaming
                            && (input == .doubleClick || (input == .returnKey && isSelected)))
                    #expect(
                        reached == expected,
                        "input \(input), isRenaming \(isRenaming), isSelected \(isSelected)")
                }
            }
        }
    }

    /// And the selection effect runs first whenever one does — the host is
    /// never reached on a row the highlight does not name.
    @Test func everyHostReachIsPrecededBySelectingTheSameRow() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let log = run(input, isRenaming: isRenaming, isSelected: isSelected).log
                    if reachesHost(log) {
                        #expect(log.first == "select(row)", "\(input)")
                    }
                }
            }
        }
    }
}

/// Pins `SidebarRenameHandoff.endsOpenRename`: whether an input must first
/// end an inline rename that is open.
@Suite("SidebarRenameHandoff")
struct SidebarRenameHandoffTests {
    /// The case that strands a row: A is being renamed, the user clicks B,
    /// and the focus moves out of A's field whether or not anyone ends the
    /// rename.
    @Test func anActingInputEndsARenameOpenOnAnotherRow() {
        #expect(SidebarRenameHandoff.endsOpenRename(
            renamingID: UUID(), input: .singleClick, isRenaming: false, isSelected: false))
    }

    /// The case fix round 3 exists for: a menu entry on the row that is
    /// BEING renamed. Those are the inputs that act there, so they are the
    /// ones that have to end the edit — otherwise the field stays open with
    /// a draft that is neither committed nor discarded while a connection
    /// opens underneath it. Over every menu entry since round 4 brought the
    /// two terminal ones onto the same path.
    @Test(arguments: SessionRowInput.allCases.filter(\.isMenuEntry))
    func aMenuEntryEndsTheRenameOnTheRowItActsOn(input: SessionRowInput) {
        let id = UUID()
        #expect(SidebarRenameHandoff.endsOpenRename(
            renamingID: id, input: input, isRenaming: true, isSelected: false), "\(input)")
    }

    /// A gesture on the row being renamed does not act, so it must not end
    /// the edit either — that is the click the rename guard swallows.
    @Test func aSwallowedGestureLeavesTheRenameAlone() {
        let id = UUID()
        for input in [SessionRowInput.singleClick, .doubleClick, .returnKey] {
            #expect(!SidebarRenameHandoff.endsOpenRename(
                renamingID: id, input: input, isRenaming: true, isSelected: true), "\(input)")
        }
    }

    /// Nothing open, nothing to end — for every input, so an acting one
    /// cannot end a rename that does not exist.
    @Test func noOpenRenameEndsNothing() {
        for input in SessionRowInput.allCases {
            #expect(!SidebarRenameHandoff.endsOpenRename(
                renamingID: nil, input: input, isRenaming: false, isSelected: true), "\(input)")
        }
    }

    /// The rule stated over the whole space: a rename ends exactly when one
    /// is open and the input acts. Without this, every per-case check in
    /// this suite could hold while some combination fell through the gap the
    /// previous rule left — which is precisely how the menu entry got
    /// missed.
    @Test func aRenameEndsExactlyWhenOneIsOpenAndTheInputActs() {
        let id = UUID()
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let acts = SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected).acts
                    #expect(
                        SidebarRenameHandoff.endsOpenRename(
                            renamingID: id, input: input,
                            isRenaming: isRenaming, isSelected: isSelected) == acts,
                        "\(input), isRenaming \(isRenaming), isSelected \(isSelected)")
                }
            }
        }
    }
}

/// Pins `SessionRowHighlight.build`: which of the three reasons to draw a
/// row background wins when more than one holds at once.
///
/// A type rather than nested ternaries in the row's `background` for the
/// usual reason — precedence is a decision, and one written as a ternary
/// chain inside a view body is one no test can reach. What this suite does
/// NOT prove: which colour each case is drawn in, or that the row draws one
/// at all (view code, no rendering harness).
@Suite("SessionRowHighlight")
struct SessionRowHighlightTests {
    /// The precedence that matters: the selection is the row a double click
    /// and Return act on, so it stays readable even on the session that is
    /// currently connected — which keeps its dot and its name treatment
    /// either way.
    @Test func theSelectionOutranksTheConnectedSession() {
        #expect(
            SessionRowHighlight.build(isActive: true, isSelected: true, isHovering: false)
                == .selected)
        #expect(
            SessionRowHighlight.build(isActive: true, isSelected: true, isHovering: true)
                == .selected)
    }

    @Test func theConnectedSessionOutranksAHover() {
        #expect(
            SessionRowHighlight.build(isActive: true, isSelected: false, isHovering: true)
                == .connected)
    }

    @Test func hoverOnlyWinsWhenNothingElseHolds() {
        #expect(
            SessionRowHighlight.build(isActive: false, isSelected: false, isHovering: true)
                == .hovered)
    }

    /// The claim a background test can make without pixels: the four cases
    /// are four DIFFERENT colours. A mapping that quietly returned the same
    /// fill for `.selected` as for `.none` would satisfy every precedence
    /// check in this suite while the selection was invisible — the failure
    /// the brief names outright, a selection that is only a colouring being
    /// worse than none.
    ///
    /// What it still does not prove: that the row DRAWS the fill, or that
    /// any of them is legible against the sidebar's surface in either
    /// appearance. Rendering a `SessionRow` offscreen the way
    /// `ViewTestabilitySpike` renders its views would need the row made
    /// internal and two `FocusState` bindings built outside a view; that was
    /// weighed and left, and the boundary is stated here rather than implied.
    @Test func theFourCasesAreFourDifferentColours() {
        let cases: [SessionRowHighlight] = [.selected, .connected, .hovered, .none]
        for (index, first) in cases.enumerated() {
            for second in cases[(index + 1)...] {
                #expect(first.fill != second.fill, "\(first) and \(second) draw the same colour")
            }
        }
    }

    /// The one case that is defined by drawing nothing.
    @Test func nothingIsDrawnForTheNoneCase() {
        #expect(SessionRowHighlight.none.fill == Color.clear)
    }

    @Test func aPlainRowDrawsNoBackground() {
        #expect(
            SessionRowHighlight.build(isActive: false, isSelected: false, isHovering: false)
                == .none)
    }

    /// Every case is reachable across the eight combinations — a `build`
    /// that could never answer `.selected` would satisfy the precedence
    /// checks only by accident.
    @Test func everyCaseIsReachable() {
        var answers: Set<SessionRowHighlight> = []
        for isActive in [true, false] {
            for isSelected in [true, false] {
                for isHovering in [true, false] {
                    answers.insert(SessionRowHighlight.build(
                        isActive: isActive, isSelected: isSelected, isHovering: isHovering))
                }
            }
        }
        #expect(answers == [.selected, .connected, .hovered, .none])
    }
}
