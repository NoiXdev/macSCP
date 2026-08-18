import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SessionTab")
@MainActor
struct SessionTabTests {
    /// Builds a tab with the same collaborators `ContentView` hands it.
    /// Adjust only the initializer arguments if Core's signatures differ.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects. A throwing
                // stub is the smallest value that satisfies the signature.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// A tab with no session is not connected, and shows the generic title
    /// rather than a stale name.
    @Test func aFreshTabIsNotConnectedAndUsesTheGenericTitle() {
        let tab = makeTab()

        #expect(tab.isConnected == false)
        #expect(tab.displayTitle.isEmpty == false)
        #expect(tab.displayTitle != "tabs.newConnection")
    }

    /// A named tab shows its own name.
    @Test func aNamedTabShowsItsName() {
        let tab = makeTab()
        tab.titleName = "prod-web"

        #expect(tab.displayTitle == "prod-web")
    }

    /// The confirmation suspends until answered, then reports the answer and
    /// clears the pending flag. A dialog that stayed "pending" after being
    /// answered would block every later connect on this tab.
    @Test func answeringTheConfirmationResumesItAndClearsThePendingFlag() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(await answer == true)
        #expect(tab.plaintextConfirmationPending == false)
    }

    /// A refusal is reported as `false`, and clears the pending flag exactly
    /// like an acceptance does. `ContentView`'s connector closure guards on
    /// exactly this value (`guard await box.tab.confirmPlaintext() else {
    /// throw … }`), so a `confirmPlaintext()` that came back `true` here
    /// would let a refused connect through.
    @Test func refusingTheConfirmationReportsFalse() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == false)
    }

    /// Resolving twice must not resume the continuation twice — that traps
    /// at runtime. The second call is a no-op by design.
    ///
    /// Caveat: the `#expect` below cannot observe a trap directly — a double
    /// resume aborts the whole test process (SIGABRT) rather than failing
    /// this assertion. A regression here would still fail the run, just not
    /// as a clean red result isolated to this test.
    @Test func resolvingTwiceIsHarmless() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == true)
    }

    /// Resolving without a pending prompt must not trap either — the UI can
    /// dismiss a sheet that was never asked for.
    ///
    /// Caveat: same as `resolvingTwiceIsHarmless` above — a regression to an
    /// unguarded unwrap would abort the process rather than fail the
    /// `#expect` below, which itself is nearly satisfied by construction
    /// (`confirmPlaintext()` is never called here, so the flag was never set
    /// `true` to begin with).
    @Test func resolvingWithNothingPendingIsHarmless() {
        let tab = makeTab()

        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(tab.plaintextConfirmationPending == false)
    }

    /// The audit flag must be resettable to false at the start of a connect:
    /// its whole purpose is that a previous connect's confirmation cannot
    /// leak into a later, unrelated connect's audit record.
    @Test func theConfirmationFlagCanBeSetAndCleared() {
        let tab = makeTab()

        tab.markPlaintextConfirmed()
        #expect(tab.pendingPlaintextConfirmation)

        tab.resetPendingPlaintextConfirmation()
        #expect(tab.pendingPlaintextConfirmation == false)
    }

    // MARK: - Pane toggles (P2 terminal-chrome milestone, Task 3)

    /// A fresh tab shows files and hides the terminal — the same starting
    /// point `TerminalPanelViewModel.isVisible`'s own default (`false`)
    /// already implies for `showsTerminal`.
    @Test func aFreshTabShowsFilesOnly() {
        let tab = makeTab()

        #expect(tab.showsFiles)
        #expect(
            tab.paneToggleState(for: .files, terminalIsVisible: false, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: false))
        #expect(
            tab.paneToggleState(for: .terminal, terminalIsVisible: false, hasShell: true)
                == PaneToggleState(isOn: false, isEnabled: true))
    }

    /// With both halves visible, either toggle reads as on and enabled —
    /// `paneToggleState` reaches all the way through to `PaneVisibility`,
    /// not just echoing `showsFiles` back for every toggle case.
    @Test func withBothHalvesVisibleBothTogglesAreEnabled() {
        let tab = makeTab()

        #expect(
            tab.paneToggleState(for: .files, terminalIsVisible: true, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
        #expect(
            tab.paneToggleState(for: .terminal, terminalIsVisible: true, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))
    }

    /// Once Files has been turned off, Terminal becomes the only visible
    /// half — and its OWN toggle must now report itself locked too. Before
    /// this task the terminal toggle was never locked (files could never be
    /// hidden), so this pins the retrofit: `paneToggleState(for: .terminal,
    /// …)` folds in the same "last visible half" rule `.files` already
    /// gets, not a rule that only ever applies to Files.
    @Test func withOnlyTerminalVisibleTheTerminalToggleIsLocked() {
        let tab = makeTab()

        #expect(
            tab.paneToggleState(for: .terminal, terminalIsVisible: true, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: true))

        tab.applyFilesToggleClick(terminalIsVisible: true, hasShell: true)
        #expect(tab.showsFiles == false)

        #expect(
            tab.paneToggleState(for: .terminal, terminalIsVisible: true, hasShell: true)
                == PaneToggleState(isOn: true, isEnabled: false))
    }

    /// A shell-less backend disables the terminal toggle regardless of
    /// which half is currently visible — `hasShell` is folded in by
    /// `PaneVisibility` itself, not re-derived here.
    @Test func withoutAShellTheTerminalToggleIsAlwaysDisabled() {
        let tab = makeTab()

        #expect(
            tab.paneToggleState(for: .terminal, terminalIsVisible: false, hasShell: false)
                == PaneToggleState(isOn: false, isEnabled: false))
    }

    /// A click that IS allowed actually flips `showsFiles` — the write-back
    /// half of `applyFilesToggleClick`, not just its no-op guard.
    @Test func aFilesClickWithBothHalvesVisibleTurnsFilesOff() {
        let tab = makeTab()

        tab.applyFilesToggleClick(terminalIsVisible: true, hasShell: true)

        #expect(tab.showsFiles == false)
    }

    /// Files is the only visible half when the terminal is hidden — clicking
    /// its toggle anyway must be a no-op (`PaneVisibility`'s lock), not a
    /// write this tab performs unconditionally.
    @Test func aFilesClickWithNoOtherHalfVisibleIsANoOp() {
        let tab = makeTab()
        #expect(tab.showsFiles)

        tab.applyFilesToggleClick(terminalIsVisible: false, hasShell: true)

        #expect(tab.showsFiles)
    }

    /// Turning the terminal back on (simulated here by passing
    /// `terminalIsVisible: true` — the tab itself never writes that flag,
    /// see `showsFiles`'s doc comment) unlocks Files again, the same way
    /// `PaneVisibility` unlocks both toggles once a second half reappears.
    @Test func turningTerminalBackOnUnlocksTheFilesToggleAgain() {
        let tab = makeTab()
        tab.applyFilesToggleClick(terminalIsVisible: true, hasShell: true)
        #expect(tab.showsFiles == false)

        #expect(
            tab.paneToggleState(for: .files, terminalIsVisible: true, hasShell: true)
                == PaneToggleState(isOn: false, isEnabled: true))
    }

    /// Review round 1, Critical: reproduces "hide Files, disconnect,
    /// reconnect" and pins that the RENDER decision (`effectivePaneVisibility`,
    /// which `detail` now reads instead of the two raw booleans it used to)
    /// never lands on "neither visible", and never disagrees with what the
    /// toolbar's `paneToggleState` reports for the SAME inputs.
    ///
    /// Before `effectivePaneVisibility` existed, `detail` read
    /// `tab.showsFiles`/`session.terminal.isVisible` directly. Both are
    /// `false` after this exact sequence — `showsFiles` because step 1 hid
    /// it, `terminalIsVisible` because a freshly reconnected
    /// `TerminalPanelViewModel` (step 3) defaults `isVisible` to `false`
    /// just like the one `shutdown()` (step 2) left behind — and reading
    /// them straight into two independent `if`s rendered NEITHER half,
    /// while `paneToggleState`, which already went through
    /// `PaneVisibility`'s repair, reported Files as on-and-locked. This
    /// test fails to build against the pre-fix `SessionTab` (no
    /// `effectivePaneVisibility` method existed) and would fail its own
    /// assertions against a version of that method which forwarded
    /// `terminalIsVisible` straight through without repairing it.
    @Test func reconnectAfterHidingFilesNeverRendersNeitherHalf() {
        let tab = makeTab()

        // 1. Hide Files while Terminal is shown -- allowed, the lock permits it.
        tab.applyFilesToggleClick(terminalIsVisible: true, hasShell: true)
        #expect(tab.showsFiles == false)

        // 2 + 3. Disconnect (`shutdown()` sets `isVisible = false`, nothing
        // resets `showsFiles`) and reconnect (`startSession` builds a
        // fresh `TerminalPanelViewModel`, whose `isVisible` also defaults
        // to `false`). Both steps collapse to the same observable fact for
        // this test: the terminal is now reporting `isVisible == false`,
        // same as `showsFiles`.
        let reconnectedTerminalIsVisible = false

        let rendered = tab.effectivePaneVisibility(
            terminalIsVisible: reconnectedTerminalIsVisible, hasShell: true)
        let filesToggle = tab.paneToggleState(
            for: .files, terminalIsVisible: reconnectedTerminalIsVisible, hasShell: true)

        // The window must show at least one half.
        #expect(rendered.showsFiles || rendered.showsTerminal)
        // And the render must agree with what the toolbar says: the Files
        // toggle reporting itself "on" while the render shows nothing is
        // exactly the bug this pins, even if the "not neither" assertion
        // above alone happened to pass.
        #expect(rendered.showsFiles == filesToggle.isOn)
    }
}
