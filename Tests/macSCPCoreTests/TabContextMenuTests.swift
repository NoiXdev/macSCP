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
            == [.close, .closeOthers, .move(.right), .moveToNewWindow])
    }

    @Test func theLastOfThreeCannotMoveRight() {
        #expect(TabContextMenu.entries(
            atIndex: 2, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            == [.close, .closeOthers, .move(.left), .moveToNewWindow])
    }

    @Test func aMiddleTabMovesBothWays() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            == [.close, .closeOthers, .move(.left), .move(.right), .moveToNewWindow])
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

    /// The mirror of the test above, and not a restatement of it: the
    /// locked half is the TERMINAL this time. That layout is not
    /// hypothetical — it is exactly what the sidebar row's "Open Terminal"
    /// entry produces (`PaneVisibility.terminalOnly`), so a menu that
    /// offered "Hide Terminal" there would empty the window on the one
    /// route that reaches it most often.
    @Test func theOnlyVisibleHalfOffersNoEntryEitherWayRound() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.hidden, terminalToggle: Self.visibleAndLocked)
        #expect(!entries.contains(.pane(.terminal, .hide)))
        #expect(!entries.contains(.pane(.terminal, .show)))
        #expect(entries.contains(.pane(.files, .show)))
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

    /// A lone tab is offered no move into a new window: it would close the
    /// window it is in and open another holding the same tab. The App
    /// layer's Window-menu entry greys itself out on the same count (see
    /// `TabCommands.canMoveTabToNewWindow`) — this menu omits rather than
    /// greys, which is the difference between the two surfaces, not between
    /// two rules.
    @Test func aLoneTabIsNotOfferedAWindowOfItsOwn() {
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.unavailable)
            .contains(.moveToNewWindow))
    }

    /// The positive beside it, and at BOTH ends of the strip: unlike
    /// `.move(_:)`, this entry needs no neighbour on a particular side —
    /// only that there is another tab at all.
    @Test func anyTabBesideAnotherIsOfferedAWindowOfItsOwn() {
        for index in 0..<3 {
            #expect(TabContextMenu.entries(
                atIndex: index, ofTabCount: 3,
                supportsShell: false, isAdHoc: false, isConnected: false,
                filesToggle: Self.unavailable, terminalToggle: Self.unavailable)
                .contains(.moveToNewWindow))
        }
    }

    /// A connection is not a precondition: an unconnected form tab moves
    /// into a window of its own like any other. It is the same entry a
    /// connected tab gets, which is what makes "a move never touches the
    /// connection" a statement about every tab rather than about the
    /// connected ones.
    @Test func anUnconnectedTabMovesIntoAWindowOfItsOwnToo() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 2,
            supportsShell: false, isAdHoc: false, isConnected: false,
            filesToggle: Self.unavailable, terminalToggle: Self.unavailable)
            .contains(.moveToNewWindow))
    }

    @Test func theOrderIsFixedRegardlessOfWhichEntriesApply() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: true, isAdHoc: true, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            == [.close, .closeOthers, .move(.left), .move(.right), .moveToNewWindow,
                .pane(.files, .hide), .pane(.terminal, .show),
                .openExternalTerminal, .saveAsSession])
    }
}
