import Testing
@testable import macSCPCore

@Suite("Tab context menu")
struct TabContextMenuTests {
    private static let bothVisible = PaneToggleState(isOn: true, isEnabled: true)
    private static let visibleAndLocked = PaneToggleState(isOn: true, isEnabled: false)
    private static let hidden = PaneToggleState(isOn: false, isEnabled: true)
    /// What `PaneVisibility.toggleState(for: .terminal, hasShell: false)`
    /// answers: nothing to show, and no way to ask for it.
    private static let unavailable = PaneToggleState(isOn: false, isEnabled: false)

    @Test func aLoneTabOffersNothingButClosing() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable) == [.close])
    }

    @Test func theFirstOfThreeCannotMoveLeft() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            == [.close, .closeOthers, .move(.right)])
    }

    @Test func theLastOfThreeCannotMoveRight() {
        #expect(TabContextMenu.entries(
            atIndex: 2, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            == [.close, .closeOthers, .move(.left)])
    }

    @Test func aMiddleTabMovesBothWays() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            == [.close, .closeOthers, .move(.left), .move(.right)])
    }

    @Test func aVisiblePaneOffersHidingItAndAHiddenOneOffersShowing() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func theOnlyVisibleHalfOffersNoEntryAtAll() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.hidden)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.files, .show)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func aDisconnectedTabOffersNoPaneEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: false,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.terminal, .hide)))
        #expect(!entries.contains(.openExternalTerminal))
    }

    @Test func theExternalTerminalNeedsAShellAndAConnection() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
    }

    @Test func bothHalvesVisibleOffersBothHidingEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .hide)))
    }

    @Test func savingIsOfferedOnlyForAConnectedAdHocTab() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: true, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            .contains(.saveAsSession))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: true, isConnected: false,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            .contains(.saveAsSession))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            .contains(.saveAsSession))
    }

    @Test func theOrderIsFixedRegardlessOfWhichEntriesApply() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: true, isAdHoc: true, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            == [.close, .closeOthers, .move(.left), .move(.right),
                .pane(.files, .hide), .pane(.terminal, .show),
                .openExternalTerminal, .saveAsSession])
    }
}
