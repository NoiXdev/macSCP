import SwiftUI
import macSCPCore

/// The doors into the diff view (diff view plan, Task 12). Everything the
/// feature needed to be reachable at all was built by Tasks 1–11; this is
/// where a user's click enters it.
///
/// **Three doors, one function.** Either pane's context menu offers
/// `.compareWithOtherPane` for a single row and `.compareTwoSelected` for
/// exactly two selected files, and the menu bar compares the two panes'
/// current directories. All three end in `openComparison(on:…)`, which is
/// also the App's only call to `SessionTab.startComparison(…)`: a comparison
/// that ran with no window to show it would walk the connection for nobody.
///
/// **The window opens for the comparison that was just started.** Never for
/// a seed that was lying around — see `openComparison`'s own comment.
///
/// **Local is the left side, remote the right**, whichever pane the menu was
/// opened in. The window's two columns then stand where the window's two
/// panes do, and the same two folders read the same way whether the user
/// asked from the left or from the right. The two-row door is the exception
/// that proves the rule: both of ITS sides are one pane's, because the rows
/// it compares both came from there.
extension ContentView {
    /// Which of a tab's two file systems a `BrowserPaneSide` names. The two
    /// enumerations are deliberately separate types — `BrowserPaneSide` is
    /// Core's word for a pane, `SessionTab.ComparisonSide` is the App's word
    /// for a side of a comparison — so the crossing is spelled once, here.
    private func comparisonSide(of side: BrowserPaneSide) -> SessionTab.ComparisonSide {
        switch side {
        case .local: .local
        case .remote: .remote
        }
    }

    /// Starts a comparison on `tab` and opens the window that shows THAT
    /// comparison.
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
    func openComparison(
        on tab: SessionTab,
        left: SessionTab.ComparisonSide, leftRoot: String,
        right: SessionTab.ComparisonSide, rightRoot: String,
        kind: Comparison.Kind
    ) {
        guard let comparison = tab.startComparison(
            left: left, leftRoot: leftRoot,
            right: right, rightRoot: rightRoot,
            algorithm: settingsStore.checksumAlgorithm,
            kind: kind)
        else { return }
        openWindow(value: ComparisonSeed(tabID: tab.id, comparisonID: comparison.id))
    }

    /// "Compare with Other Pane", offered for ONE selected row: that row
    /// against the entry of the same NAME in the other pane's current
    /// directory. A directory row makes a folder comparison, anything else a
    /// file pair.
    ///
    /// The counterpart is a path this builds, not a row it looked up: the
    /// other pane may not have that name at all, and that is an answer the
    /// comparison itself gives (`.onlyLeft` / `.onlyRight`, or a root that
    /// cannot be listed) rather than a reason to withhold the action. The one
    /// case that IS withheld is decided in the menu model, where the other
    /// pane sits at a bucket list — `BrowserContextMenu.entries(…
    /// destination:)`.
    func compareWithOtherPane(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide,
        in tab: SessionTab, session: BrowserSession
    ) {
        guard selection.count == 1, let row = selection.first else { return }
        let otherDirectory = side == .local
            ? session.remote.currentPath
            : session.local.currentPath
        let counterpart = RemotePath.join(otherDirectory, row.name)
        let kind: Comparison.Kind = row.kind == .directory ? .folders : .filePair
        switch side {
        case .local:
            openComparison(
                on: tab, left: .local, leftRoot: row.path,
                right: .remote, rightRoot: counterpart, kind: kind)
        case .remote:
            openComparison(
                on: tab, left: .local, leftRoot: counterpart,
                right: .remote, rightRoot: row.path, kind: kind)
        }
    }

    /// "Compare the Two Selected Files", offered for exactly two selected
    /// FILES of one pane: those two against each other, in selection order.
    /// Both sides are that pane's side — the other pane has nothing to do
    /// with this one.
    func compareTwoSelected(
        _ selection: [RemoteFileItem], on side: BrowserPaneSide, in tab: SessionTab
    ) {
        guard selection.count == 2 else { return }
        let comparisonSide = comparisonSide(of: side)
        openComparison(
            on: tab,
            left: comparisonSide, leftRoot: selection[0].path,
            right: comparisonSide, rightRoot: selection[1].path,
            kind: .filePair)
    }

    /// The menu bar's "Compare Both Panes": the two panes' CURRENT
    /// DIRECTORIES, as folders. The menu bar has no selection to read, which
    /// is exactly why this door exists — it is the whole-folder comparison
    /// that needs nothing clicked first.
    func compareBothPanes(in tab: SessionTab, session: BrowserSession) {
        openComparison(
            on: tab,
            left: .local, leftRoot: session.local.currentPath,
            right: .remote, rightRoot: session.remote.currentPath,
            kind: .folders)
    }
}
