import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Pins `SessionRowActivation.build`, the rule behind what a click, a double
/// click and Return do to a session row.
///
/// The behaviour this replaces: a single click opened a connection. That is
/// the property every test below is really about — pointing at a session and
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

    /// The rename guard, over every input rather than the click alone: while
    /// a row is being renamed its text field owns both the pointer and the
    /// keyboard. A click that re-selected the row underneath would pull
    /// focus out of the field and cancel the edit; Return belongs to the
    /// field's own submit.
    @Test(arguments: [SessionRowInput.singleClick, .doubleClick, .returnKey])
    func renamingSwallowsEveryInput(input: SessionRowInput) {
        for isSelected in [true, false] {
            let activation = SessionRowActivation.build(
                for: input, isRenaming: true, isSelected: isSelected)
            #expect(activation == .doNothing, "input \(input), isSelected \(isSelected)")
            #expect(!activation.acts)
            #expect(!activation.connects)
        }
    }

    /// `acts` and `connects` are what `SessionSidebar.activate` branches on,
    /// so what each one answers per case is part of the contract, not a
    /// convenience: `acts` false is the only case that leaves a key press
    /// unhandled, `connects` true the only one that dials.
    @Test func theTwoQuestionsTheSidebarAsksAnswerPerCase() {
        #expect(!SessionRowActivation.doNothing.acts)
        #expect(SessionRowActivation.select.acts)
        #expect(SessionRowActivation.selectAndConnect.acts)

        #expect(!SessionRowActivation.doNothing.connects)
        #expect(!SessionRowActivation.select.connects)
        #expect(SessionRowActivation.selectAndConnect.connects)
    }

    /// A `build` that answered `.selectAndConnect` for everything would pass
    /// several checks above one at a time; this is what rules out a constant
    /// answer across the inputs that exist.
    @Test func everyActivationIsReachableFromSomeInput() {
        let answers = [
            SessionRowActivation.build(for: .singleClick, isRenaming: false, isSelected: false),
            SessionRowActivation.build(for: .doubleClick, isRenaming: false, isSelected: false),
            SessionRowActivation.build(for: .returnKey, isRenaming: false, isSelected: false),
        ]
        #expect(answers.contains(.select))
        #expect(answers.contains(.selectAndConnect))
        #expect(answers.contains(.doNothing))
    }

    /// Nothing but a double click or a selected row's Return may connect —
    /// stated over the whole input space rather than case by case, so a
    /// fourth input added later has to be classified deliberately instead of
    /// inheriting a connect by default.
    @Test func onlyTwoOfEveryInputCombinationEverConnect() {
        var connecting: [(SessionRowInput, Bool, Bool)] = []
        for input in [SessionRowInput.singleClick, .doubleClick, .returnKey] {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let activation = SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected)
                    if activation.connects { connecting.append((input, isRenaming, isSelected)) }
                }
            }
        }
        #expect(connecting.allSatisfy { input, isRenaming, isSelected in
            !isRenaming && (input == .doubleClick || (input == .returnKey && isSelected))
        }, "an input outside double-click / selected-row Return connects: \(connecting)")
        #expect(!connecting.isEmpty, "no combination connects at all — the row would be inert")
    }
}

/// Pins `SessionRowActivation.apply(to:onSelect:onConnect:)` — the one mapping
/// from an activation to the two effects a session row has.
///
/// This is the load-bearing half of "a single click never connects", and
/// until fix round 1 it did not exist: the mapping was an `if activation
/// .connects` inside the view, where the reviewer's probe deleted the
/// condition and the whole suite stayed green while every click dialled.
/// Written as a method over spies, that mutation is a failing test rather
/// than a source scan the next edit outgrows.
///
/// The spies record the ORDER as well as the count, because "select before
/// connect" is a promise the highlight depends on: the row has to name the
/// session before the connection starts.
@Suite("SessionRowActivation.apply")
struct SessionRowActivationApplyTests {
    /// Records which effects ran, in order.
    private final class Effects {
        private(set) var log: [String] = []
        func select(_ value: String) { log.append("select(\(value))") }
        func connect(_ value: String) { log.append("connect(\(value))") }
    }

    private func run(_ activation: SessionRowActivation) -> (log: [String], applied: Bool) {
        let effects = Effects()
        let applied = activation.apply(
            to: "row", onSelect: effects.select(_:), onConnect: effects.connect(_:))
        return (effects.log, applied)
    }

    /// The property, exercised rather than scanned for: a `.select` answer
    /// must not reach the connect effect.
    @Test func selectRunsOnlyTheSelectEffect() {
        let result = run(.select)
        #expect(result.log == ["select(row)"])
        #expect(result.applied)
    }

    @Test func doNothingRunsNeitherEffect() {
        let result = run(.doNothing)
        #expect(result.log.isEmpty)
        #expect(!result.applied)
    }

    @Test func selectAndConnectRunsBothInThatOrder() {
        let result = run(.selectAndConnect)
        #expect(result.log == ["select(row)", "connect(row)"])
        #expect(result.applied)
    }

    /// Each effect runs at most once per activation — a mapping that called
    /// `connect` twice would open two connections from one double click, and
    /// the order check alone would not see it.
    @Test func neitherEffectRunsTwice() {
        for activation in [SessionRowActivation.doNothing, .select, .selectAndConnect] {
            let log = run(activation).log
            #expect(log.filter { $0.hasPrefix("select") }.count <= 1, "\(activation)")
            #expect(log.filter { $0.hasPrefix("connect") }.count <= 1, "\(activation)")
        }
    }

    /// `apply`'s answer is what the row reports to SwiftUI as
    /// handled/ignored, so it must agree with `acts` for every case rather
    /// than being a second, independently drifting statement of the same
    /// thing.
    @Test func whatApplyReportsAgreesWithActsForEveryActivation() {
        for activation in [SessionRowActivation.doNothing, .select, .selectAndConnect] {
            #expect(run(activation).applied == activation.acts, "\(activation)")
        }
    }

    /// And the connect effect runs exactly for the activations `connects`
    /// names — stated over every case, so the two cannot drift apart.
    @Test func theConnectEffectRunsExactlyForTheConnectingActivations() {
        for activation in [SessionRowActivation.doNothing, .select, .selectAndConnect] {
            let connected = run(activation).log.contains { $0.hasPrefix("connect") }
            #expect(connected == activation.connects, "\(activation)")
        }
    }

    /// The whole chain in one statement, from input to effect: only a double
    /// click and Return on the selected row may reach `connect`. This is the
    /// property the wiring guard cannot express, tested end to end over the
    /// value layer.
    @Test func onlyTwoInputCombinationsEverReachTheConnectEffect() {
        for input in [SessionRowInput.singleClick, .doubleClick, .returnKey] {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let activation = SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected)
                    let connected = run(activation).log.contains { $0.hasPrefix("connect") }
                    let expected = !isRenaming
                        && (input == .doubleClick || (input == .returnKey && isSelected))
                    #expect(
                        connected == expected,
                        "input \(input), isRenaming \(isRenaming), isSelected \(isSelected)")
                }
            }
        }
    }
}

/// Pins `SidebarRenameHandoff.endsOpenRename` (fix round 1): whether
/// activating one row must first end an inline rename open on another.
@Suite("SidebarRenameHandoff")
struct SidebarRenameHandoffTests {
    /// The case that strands a row: A is being renamed, the user clicks B,
    /// and the focus moves out of A's field whether or not anyone ends the
    /// rename.
    @Test func aRenameOnAnotherRowIsEnded() {
        #expect(SidebarRenameHandoff.endsOpenRename(renamingID: UUID(), activating: UUID()))
    }

    /// Nothing to end.
    @Test func noOpenRenameEndsNothing() {
        #expect(!SidebarRenameHandoff.endsOpenRename(renamingID: nil, activating: UUID()))
    }

    /// The row being renamed is the row being activated: its own activation
    /// is `.doNothing` anyway, and ending the rename here would cancel the
    /// edit the user is in the middle of.
    @Test func aRenameOnTheActivatedRowSurvives() {
        let id = UUID()
        #expect(!SidebarRenameHandoff.endsOpenRename(renamingID: id, activating: id))
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
    /// checks above only by accident.
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
