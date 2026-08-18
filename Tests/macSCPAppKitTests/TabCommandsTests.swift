import Foundation
import Testing
@testable import MacSCPAppKit

/// The menu bridge's own decisions (P2 terminal-chrome milestone;
/// whole-phase review, Fix 2).
///
/// `TabCommands` is what `MacSCPApp`'s `.commands` Scene observes — it
/// cannot see `tabsModel`, so every condition its entries are enabled or
/// disabled on has to arrive here as a mirrored value. That makes this type
/// the one place the menu's enabled state is testable at all; the
/// `.disabled(…)` expression itself is a SwiftUI Scene this project has no
/// tool to instantiate (see `PaneVisibilityWiringGuardTests`, which scans
/// that the expression actually reads what is tested here).
@Suite("TabCommands")
@MainActor
struct TabCommandsTests {
    /// The ordinary enabled case: connected, a backend with a shell, and the
    /// terminal is not the last visible half.
    @Test func aConnectedShellTabWithBothHalvesCanToggleTheTerminal() {
        let commands = TabCommands()
        commands.isActiveTabConnected = true
        commands.activeTabSupportsShell = true
        commands.activeTabTerminalToggleIsUnlocked = true

        #expect(commands.canToggleTerminal)
    }

    /// The regression this fix is about: the terminal is the LAST visible
    /// half, so `toggleTerminal`'s closure refuses the click. Before the
    /// mirror existed the entry stayed enabled and the click silently did
    /// nothing — contradicting `PaneToggleState`'s "disabled rather than
    /// silently inert" and the project's rule against silent no-ops.
    @Test func aLockedTerminalHalfDisablesTheEntry() {
        let commands = TabCommands()
        commands.isActiveTabConnected = true
        commands.activeTabSupportsShell = true
        commands.activeTabTerminalToggleIsUnlocked = false

        #expect(commands.canToggleTerminal == false)
    }

    /// The two pre-existing conditions still gate the entry on their own —
    /// the new flag was added to them, it did not replace them.
    @Test func theOlderTwoConditionsStillGateTheEntry() {
        let disconnected = TabCommands()
        disconnected.isActiveTabConnected = false
        disconnected.activeTabSupportsShell = true
        disconnected.activeTabTerminalToggleIsUnlocked = true
        #expect(disconnected.canToggleTerminal == false)

        let shellless = TabCommands()
        shellless.isActiveTabConnected = true
        shellless.activeTabSupportsShell = false
        shellless.activeTabTerminalToggleIsUnlocked = true
        #expect(shellless.canToggleTerminal == false)
    }

    /// A fresh bridge — before any mirror has run — must behave exactly as
    /// the menu did before this flag existed: only the connection state
    /// speaks. A default of `false` would grey the entry out on every launch
    /// until the first `.onChange` fired.
    @Test func theLockDefaultsToUnlockedSoTheMirrorCanOnlyEverRestrict() {
        let commands = TabCommands()

        #expect(commands.activeTabTerminalToggleIsUnlocked)
        #expect(commands.canToggleTerminal == false, "not connected yet")

        commands.isActiveTabConnected = true
        #expect(commands.canToggleTerminal)
    }
}
