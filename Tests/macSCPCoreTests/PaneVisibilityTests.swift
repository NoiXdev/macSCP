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

        let restored = onlyFiles.applyingClick(on: .terminal)

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

    /// Clicking the last visible half's toggle anyway (the lock is enforced
    /// by the caller, not by refusing the call) lands on "nothing visible",
    /// which the model repairs — so the click is a no-op instead of a way
    /// around the lock.
    @Test func clickingTheLockedToggleAnywayIsANoOp() {
        let onlyFiles = PaneVisibility(showsFiles: true, showsTerminal: false)

        let clicked = onlyFiles.applyingClick(on: .files)

        #expect(clicked == onlyFiles)
    }
}
