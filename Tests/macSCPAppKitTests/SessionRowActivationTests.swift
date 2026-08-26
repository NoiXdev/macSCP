import Foundation
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
