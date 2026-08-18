import Foundation
import Testing
@testable import macSCPCore

@Suite("PaneVisibility")
struct PaneVisibilityTests {
    /// Both halves visible is the ordinary state, and both toggles are live.
    @Test func withBothVisibleEitherCanBeTurnedOff() {
        let visibility = PaneVisibility(showsFiles: true, showsTerminal: true)

        #expect(
            visibility.toggleState(for: .files, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
        #expect(
            visibility.toggleState(for: .terminal, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
    }

    /// The last visible half cannot be turned off — the window would be
    /// empty. The toggle is disabled rather than silently doing nothing, so
    /// the user can see why the click does not land.
    @Test func theLastVisibleHalfIsLocked() {
        let visibility = PaneVisibility(showsFiles: true, showsTerminal: false)

        #expect(
            visibility.toggleState(for: .files, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: false))
        #expect(
            visibility.toggleState(for: .terminal, hasShell: true)
                == PaneToggleState(isOn: false, isEnabled: true))
    }

    /// A backend without a shell has no terminal to show. Files is then the
    /// only half, and therefore locked — the same rule as above, reached by
    /// a different road. A stored `showsTerminal: true` left over from a
    /// different backend does not change that: `hasShell` overrides it.
    @Test func withoutAShellFilesIsTheOnlyHalfAndIsLocked() {
        let visibility = PaneVisibility(showsFiles: true, showsTerminal: true)

        #expect(
            visibility.toggleState(for: .files, hasShell: false)
                == PaneToggleState(isOn: true, isEnabled: false))
        #expect(
            visibility.toggleState(for: .terminal, hasShell: false)
                == PaneToggleState(isOn: false, isEnabled: false))
    }

    /// Turning a half back on unlocks the other one again — the lock is a
    /// consequence of the state, never a latch that stays set.
    @Test func turningTheOtherHalfBackOnUnlocksBoth() {
        let onlyFiles = PaneVisibility(showsFiles: true, showsTerminal: false)

        let restored = onlyFiles.applyingClick(on: .terminal, hasShell: true)

        #expect(restored == PaneVisibility(showsFiles: true, showsTerminal: true))
        #expect(
            restored.toggleState(for: .files, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
        #expect(
            restored.toggleState(for: .terminal, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
    }

    /// A stored state that says "no halves visible" cannot be trusted — a
    /// hand-edited `sessions.json` could carry it, and it would render an
    /// empty window. Decoding repairs it rather than propagating it.
    @Test func aStoredStateWithNothingVisibleIsRepaired() throws {
        let json = Data(#"{"showsFiles":false,"showsTerminal":false}"#.utf8)

        let visibility = try JSONDecoder().decode(PaneVisibility.self, from: json)

        #expect(visibility.showsFiles == true)
        #expect(visibility.showsTerminal == false)
    }

    /// `showsFiles`/`showsTerminal` are `let`: the only way to reach
    /// "neither visible" is through the repairing initializer, never
    /// through in-place mutation of a value already held. A regression to
    /// `var` here would let this exact sequence -- turning files off, then
    /// attempting to also turn off the terminal that just became the only
    /// visible half -- assign both to `false` directly; going through
    /// `applyingClick` instead proves the repair still catches it even
    /// after two real clicks in sequence, not just a single hand-built
    /// input.
    @Test func aSequenceOfClicksCannotReachNothingVisible() {
        let bothVisible = PaneVisibility(showsFiles: true, showsTerminal: true)

        let filesOff = bothVisible.applyingClick(on: .files, hasShell: true)
        #expect(filesOff == PaneVisibility(showsFiles: false, showsTerminal: true))

        let attemptToClearTerminalToo = filesOff.applyingClick(on: .terminal, hasShell: true)
        #expect(attemptToClearTerminalToo.showsFiles || attemptToClearTerminalToo.showsTerminal)
    }

    /// Clicking the last visible half's toggle anyway (the lock is enforced
    /// by the caller, not by refusing the call) lands on "nothing visible",
    /// which the model repairs — so the click is a no-op instead of a way
    /// around the lock.
    @Test func clickingTheLockedToggleAnywayIsANoOp() {
        let onlyFiles = PaneVisibility(showsFiles: true, showsTerminal: false)

        let clicked = onlyFiles.applyingClick(on: .files, hasShell: true)

        #expect(clicked == onlyFiles)
    }

    /// Turning files off while there is no shell must not strand a
    /// `showsTerminal: true` that has nothing behind it. Without folding
    /// `hasShell` into the `.files` branch too, this would compute
    /// `PaneVisibility(showsFiles: false, showsTerminal: true)` -- a value
    /// that needs no repair on its own terms, yet describes a window with
    /// files hidden and a terminal that cannot actually run. Pins the
    /// second bullet of `applyingClick`'s doc comment.
    @Test func aFilesClickWithoutAShellCannotLeaveAnEmptyWindow() {
        let visibility = PaneVisibility(showsFiles: true, showsTerminal: true)

        let clicked = visibility.applyingClick(on: .files, hasShell: false)

        #expect(clicked == PaneVisibility(showsFiles: true, showsTerminal: false))
    }

    /// A shell-less backend's terminal toggle click is unconditionally a
    /// no-op in the model itself — not something a caller has to remember to
    /// withhold. Unlike `clickingTheLockedToggleAnywayIsANoOp` above, this
    /// state is not otherwise locked (files is not the only visible half by
    /// the ordinary rule); only `hasShell: false` makes the click land on
    /// nothing.
    @Test func aTerminalClickWithoutAShellIsANoOp() {
        let visibility = PaneVisibility(showsFiles: true, showsTerminal: false)

        let clicked = visibility.applyingClick(on: .terminal, hasShell: false)

        #expect(clicked == visibility)
    }
}
