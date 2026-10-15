import SwiftUI
import macSCPCore

/// The doors into the diff view (diff view plan, Task 12). Everything the
/// feature needed to be reachable at all was built by Tasks 1–11; this is
/// where a user's click enters it.
///
/// **Three doors, one function.** Either pane's context menu offers
/// `.compareWithOtherPane` for a single row and `.compareTwoSelected` for
/// exactly two selected files, and the menu bar compares the two panes'
/// current directories. All three end in `openComparison(_:on:)`, which is
/// also the App's only call to `SessionTab.startComparison(…)`: a comparison
/// that ran with no window to show it would walk the connection for nobody.
///
/// **The routing itself is not here.** What each door decides — the two
/// sides, the two roots, the shape — is a `ComparisonRequest`, a value with
/// its own tests, for the reason that type's doc comment gives (fix round 1,
/// F3). The functions below read this window's pane state, ask for a request
/// and hand it on; there is no third place where a side meets a root.
///
/// **The window opens for the comparison that was just started.** Never for
/// a seed that was lying around — see `openComparison`'s own comment.
extension ContentView {
    /// Starts the comparison `request` names on `tab` and opens the window
    /// that shows THAT comparison.
    ///
    /// The seed is built from the `Comparison` this call just got back. A
    /// window resolves its seed exactly once
    /// (`ComparisonWindowModel.resolve(seed:registry:)`), so a seed naming
    /// anything else latches onto whatever that id still means in the tab —
    /// or onto nothing, and says "no longer available" about a comparison
    /// that was never started.
    ///
    /// `startComparison` answers `nil` when the tab has no session or a
    /// teardown is running. Then NOTHING opens: there is no comparison to
    /// show, and an empty window saying so would be this file inventing a
    /// failure the tab already declined to produce.
    func openComparison(_ request: ComparisonRequest, on tab: SessionTab) {
        guard let comparison = tab.startComparison(
            left: request.left, leftRoot: request.leftRoot,
            right: request.right, rightRoot: request.rightRoot,
            algorithm: settingsStore.checksumAlgorithm,
            kind: request.kind)
        else { return }
        openWindow(value: ComparisonSeed(tabID: tab.id, comparisonID: comparison.id))
    }

    /// "Compare with Other Pane", for ONE selected row — see
    /// `ComparisonRequest.forRow(_:on:localDirectory:remoteDirectory:)` for
    /// what it compares. Both pane directories are read HERE, at click time,
    /// rather than captured when the menu was built.
    func compareWithOtherPane(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide,
        in tab: SessionTab, session: BrowserSession
    ) {
        guard let request = ComparisonRequest.forRow(
            selection, on: side,
            localDirectory: session.local.currentPath,
            remoteDirectory: session.remote.currentPath)
        else { return }
        openComparison(request, on: tab)
    }

    /// "Compare the Two Selected Files", for exactly two selected files of
    /// one pane. Needs no pane directory: both rows carry their own path.
    func compareTwoSelected(
        _ selection: [RemoteFileItem], on side: BrowserPaneSide, in tab: SessionTab
    ) {
        guard let request = ComparisonRequest.forTwoSelected(selection, on: side) else { return }
        openComparison(request, on: tab)
    }

    /// The menu bar's "Compare Both Panes". Whether the entry is offered at
    /// all is `ComparisonRequest.panesAreComparable(local:remote:)`, mirrored
    /// onto `TabCommands` and read by the item's `.disabled` — not re-decided
    /// here, which would be a menu entry that is enabled and does nothing.
    func compareBothPanes(in tab: SessionTab, session: BrowserSession) {
        openComparison(
            ComparisonRequest.forBothPanes(
                localDirectory: session.local.currentPath,
                remoteDirectory: session.remote.currentPath),
            on: tab)
    }

    /// Mirrored into `tabCommands.activeTabPanesAreComparable` via
    /// `.onChange` in `ContentView.body` (fix round 1, F2), the same
    /// rationale and mechanism as `activeTabSupportsShell` and
    /// `activeTabTerminalToggleIsUnlocked`: `MacSCPApp`'s menu lives in a
    /// separate Scene that cannot see `tabsModel`.
    ///
    /// `true` while nothing is connected — there are no panes to ask about,
    /// and `isActiveTabConnected` already disables the entry. Reads the same
    /// two scopes the panes themselves are built from
    /// (`localScope(_:)`/`remoteScope(_:)`), so the menu and the panes cannot
    /// disagree about where either one is looking.
    var activeTabPanesAreComparable: Bool {
        guard let session = activeTab.session else { return true }
        return ComparisonRequest.panesAreComparable(
            local: localScope(session), remote: remoteScope(session))
    }
}
