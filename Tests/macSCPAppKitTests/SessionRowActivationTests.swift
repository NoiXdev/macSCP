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
    @Test(arguments: SessionRowInput.allCases.filter { $0 != .contextMenuEntry })
    func renamingSwallowsEveryGesture(input: SessionRowInput) {
        for isSelected in [true, false] {
            let activation = SessionRowActivation.build(
                for: input, isRenaming: true, isSelected: isSelected)
            #expect(activation == .doNothing, "input \(input), isSelected \(isSelected)")
            #expect(!activation.acts)
            #expect(!activation.connects)
        }
    }

    /// The one input the rename guard does not apply to. A menu entry the
    /// user read and chose must not silently do nothing because the row
    /// happens to be in rename mode — the interruption is the lesser
    /// surprise, and it is handled: selecting the row takes focus off the
    /// field, which cancels the edit the way leaving it any other way does.
    @Test func theMenuEntryConnectsEvenWhileTheRowIsBeingRenamed() {
        for isSelected in [true, false] {
            #expect(
                SessionRowActivation.build(
                    for: .contextMenuEntry, isRenaming: true, isSelected: isSelected)
                    == .selectAndConnect)
        }
    }

    /// And it selects rather than connecting behind the highlight's back:
    /// after any route to a connection, the row that was connected is the
    /// row that is marked.
    @Test func theMenuEntrySelectsTheRowItConnects() {
        #expect(SessionRowActivation.build(
            for: .contextMenuEntry, isRenaming: false, isSelected: false).connects)
        #expect(SessionRowActivation.build(
            for: .contextMenuEntry, isRenaming: false, isSelected: false) == .selectAndConnect)
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
    /// the per-input checks one at a time; this is what rules out a constant
    /// answer across the inputs that exist.
    @Test func everyActivationIsReachableFromSomeInput() {
        let answers = SessionRowInput.allCases.map {
            SessionRowActivation.build(for: $0, isRenaming: false, isSelected: false)
        }
        #expect(answers.contains(.select))
        #expect(answers.contains(.selectAndConnect))
        #expect(answers.contains(.doNothing))
    }

    /// Nothing but a double click, a selected row's Return and the menu
    /// entry may connect — stated over the whole input space rather than
    /// case by case, so a further input has to be classified deliberately
    /// instead of inheriting a connect by default.
    @Test func onlyThreeOfEveryInputCombinationEverConnect() {
        var connecting: [(SessionRowInput, Bool, Bool)] = []
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let activation = SessionRowActivation.build(
                        for: input, isRenaming: isRenaming, isSelected: isSelected)
                    if activation.connects { connecting.append((input, isRenaming, isSelected)) }
                }
            }
        }
        #expect(connecting.allSatisfy { input, isRenaming, isSelected in
            input == .contextMenuEntry
                || (!isRenaming && (input == .doubleClick || (input == .returnKey && isSelected)))
        }, "an input outside double click / selected-row Return / menu entry connects: \(connecting)")
        #expect(!connecting.isEmpty, "no combination connects at all — the row would be inert")
    }
}

/// Pins `performSessionRowInput` — the one reachable way to act on a row,
/// and therefore the whole chain from an input to a connection.
///
/// It replaced a test over `apply` in fix round 3, because `apply` stopped
/// being reachable: as an internal method on a freely constructible enum it
/// WAS the firing site, and `SessionRowActivation.selectAndConnect.apply(…)`
/// written into any function of the view dialled on every single click with
/// the full suite green. Testing the entry point instead is both the
/// stronger statement — build and apply together — and the only one left.
///
/// The spies record the ORDER as well as the count, because "select before
/// connect" is a promise the highlight depends on: the row has to name the
/// session before the connection starts.
@Suite("performSessionRowInput")
struct PerformSessionRowInputTests {
    /// Records which effects ran, in order.
    private final class Effects {
        private(set) var log: [String] = []
        func select(_ value: String) { log.append("select(\(value))") }
        func connect(_ value: String) { log.append("connect(\(value))") }
    }

    private func run(
        _ input: SessionRowInput, isRenaming: Bool = false, isSelected: Bool = false
    ) -> (log: [String], applied: Bool) {
        let effects = Effects()
        let applied = performSessionRowInput(
            input, on: "row", isRenaming: isRenaming, isSelected: isSelected,
            onSelect: SessionRowSelectEffect(effects.select(_:)),
            onConnect: SessionRowConnectEffect(effects.connect(_:)))
        return (effects.log, applied)
    }

    /// The regression the whole task is about, stated where the effects
    /// actually run rather than where they are classified.
    @Test func aSingleClickSelectsAndNeverReachesTheConnectEffect() {
        let result = run(.singleClick)
        #expect(result.log == ["select(row)"])
        #expect(result.applied)
    }

    @Test func aSwallowedInputRunsNeitherEffect() {
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

    @Test func theMenuEntryConnectsEvenOnARowBeingRenamed() {
        #expect(run(.contextMenuEntry, isRenaming: true).log == ["select(row)", "connect(row)"])
    }

    /// Each effect runs at most once — a chain that connected twice would
    /// open two connections from one double click, and the order check alone
    /// would not see it.
    @Test func neitherEffectRunsTwiceForAnyInput() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let log = run(input, isRenaming: isRenaming, isSelected: isSelected).log
                    #expect(log.filter { $0.hasPrefix("select") }.count <= 1, "\(input)")
                    #expect(log.filter { $0.hasPrefix("connect") }.count <= 1, "\(input)")
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
    /// the point where the effect actually runs: only a double click,
    /// Return on the selected row, and the menu entry ever reach a
    /// connection. A further input added later is iterated by `allCases`
    /// and has to be classified deliberately.
    @Test func onlyTheThreeIntendedInputsEverReachTheConnectEffect() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let connected = run(input, isRenaming: isRenaming, isSelected: isSelected)
                        .log.contains { $0.hasPrefix("connect") }
                    let expected = input == .contextMenuEntry
                        || (!isRenaming
                            && (input == .doubleClick || (input == .returnKey && isSelected)))
                    #expect(
                        connected == expected,
                        "input \(input), isRenaming \(isRenaming), isSelected \(isSelected)")
                }
            }
        }
    }

    /// And the selection effect runs for exactly the inputs that act — a
    /// connection is never opened on a row the highlight does not name.
    @Test func everyConnectIsPrecededBySelectingTheSameRow() {
        for input in SessionRowInput.allCases {
            for isRenaming in [true, false] {
                for isSelected in [true, false] {
                    let log = run(input, isRenaming: isRenaming, isSelected: isSelected).log
                    if log.contains(where: { $0.hasPrefix("connect") }) {
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

    /// The case fix round 3 exists for: the menu entry on the row that is
    /// BEING renamed. It is the one input that acts there, so it is the one
    /// input that has to end the edit — otherwise the field stays open with
    /// a draft that is neither committed nor discarded while a connection
    /// opens underneath it.
    @Test func theMenuEntryEndsTheRenameOnTheRowItActsOn() {
        let id = UUID()
        #expect(SidebarRenameHandoff.endsOpenRename(
            renamingID: id, input: .contextMenuEntry, isRenaming: true, isSelected: false))
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
    /// is open and the input acts. Without this, the cases above could all
    /// hold while some combination fell through the gap the previous rule
    /// left — which is precisely how the menu entry got missed.
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
