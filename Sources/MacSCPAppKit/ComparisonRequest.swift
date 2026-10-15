import Foundation
import macSCPCore

/// What a door into the diff view DECIDED: which two sides of the tab's
/// session, which two roots, and which shape of comparison.
///
/// **Why the decision is a value and not three statements inside a view**
/// (fix round 1, F3). The three doors each make the same four-part routing
/// decision, and the first round pinned it with source scans that counted
/// anchors independently of one another: the arms were counted, the calls were
/// counted, both strings of a ternary were required to be PRESENT. A defect
/// that permutes anchors rather than removing one was therefore free, and the
/// reviewer planted three — an inverted ternary that compared every row
/// against itself, two switch arms whose bodies were swapped, and one arm
/// given the other's roots. All three came back green. As a value the routing
/// is ordinary `#expect`s in `ComparisonRequestTests`, which is the
/// structural boundary this project's rule about repeated anchors asks for;
/// the in-tree precedent is `TransferPlan` and `BrowserContextMenu`, and the
/// in-tree confession of the same unpinned defect is `handleTabMenuEntry`'s
/// own comment about a pair of numbers nobody would notice swapped.
///
/// **Local is the LEFT side and remote the RIGHT one**, whichever pane a door
/// was opened from, so the window's two columns stand where the window's two
/// panes do and the same two folders read the same way from either side. The
/// two-row door is the exception, necessarily: both of its rows came from one
/// pane, so both of its sides are that pane's.
///
/// **It decides nothing about ELIGIBILITY.** Whether an entry is offered at
/// all is `BrowserContextMenu.entries(for:side:…)`'s — including both symlink
/// exclusions, near and far, and the other pane's bucket list — and whether a
/// pair can actually be diffed is
/// `Comparison.diffUnmapped(leftPath:rightPath:)`'s, which both diff entry
/// points pass through. What the factories below refuse is a selection they
/// could not name a request for: `nil` rather than a request built out of a
/// row that is not there.
///
/// This paragraph said of `Comparison.diffFilePair()` that it is "the only
/// place the far side of a one-row comparison is ever looked at". False
/// twice since fix round 2: the MENU MODEL looks, from the other pane's
/// listing (`destinationRows`), and the check is in `diffUnmapped` rather
/// than in `diffFilePair()`, which delegates to it.
struct ComparisonRequest: Equatable {
    let left: SessionTab.ComparisonSide
    let leftRoot: String
    let right: SessionTab.ComparisonSide
    let rightRoot: String
    let kind: Comparison.Kind

    /// "Compare with Other Pane", for ONE selected row: that row against the
    /// entry of the same NAME in the other pane's current directory. A
    /// directory row makes a folder comparison, anything else a file pair.
    ///
    /// The counterpart is a path this SPELLS, and nothing in this factory
    /// looks at what is on the end of it. What DOES look is the MENU MODEL,
    /// since fix round 2: it is handed the other pane's loaded rows
    /// (`BrowserContextMenu.entries(… destinationRows:)`) and withholds the
    /// entry when the far row is listed as a symlink, the one kind `stat`
    /// cannot report. This factory is deliberately not given a second copy of
    /// that rule — the offer is the menu's decision, so a request built for a
    /// selection the entry was offered for is an honest request.
    ///
    /// A counterpart that is simply NOT THERE is answered differently by the
    /// two shapes, and that is the one claim this comment has had to correct.
    /// For `.folders` the comparison itself says so, as `.onlyLeft` /
    /// `.onlyRight` or as a root it cannot list. For `.filePair` — the branch
    /// a FILE row takes — there are no rows and no classification at all, so
    /// the answer comes from the diff: a refusal naming the side that is not
    /// an ordinary file, or the fetch's own error for a path that is not
    /// there. Fix round 1 wrote here that a missing counterpart "is an answer
    /// the comparison itself gives (`.onlyLeft` / `.onlyRight`, or a root
    /// that cannot be listed) rather than a reason to withhold the action",
    /// without qualification; that is true of `.folders` and false of
    /// `.filePair`, which produces no `ComparisonState` because
    /// `ComparisonState` comes from `FolderComparison.walk` and a file pair
    /// never runs it.
    static func forRow(
        _ selection: [RemoteFileItem], on side: BrowserPaneSide,
        localDirectory: String, remoteDirectory: String
    ) -> ComparisonRequest? {
        guard selection.count == 1, let row = selection.first else { return nil }
        let kind: Comparison.Kind = row.kind == .directory ? .folders : .filePair
        // The OTHER pane's directory, which is the whole point of the entry.
        let counterpart = RemotePath.join(
            side == .local ? remoteDirectory : localDirectory, row.name)
        switch side {
        case .local:
            return ComparisonRequest(
                left: .local, leftRoot: row.path,
                right: .remote, rightRoot: counterpart, kind: kind)
        case .remote:
            return ComparisonRequest(
                left: .local, leftRoot: counterpart,
                right: .remote, rightRoot: row.path, kind: kind)
        }
    }

    /// "Compare the Two Selected Files", for exactly two selected files of
    /// one pane: those two against each other, both sides that pane's, and
    /// the left-hand one is whichever stands HIGHER IN THE TABLE.
    ///
    /// **Corrected 2026-10-16. This read "those two against each other, in
    /// selection order, both sides that pane's."** It is not selection order
    /// and never was. The selection reaches here from
    /// `RemoteFileTableView`'s `currentSelection()` and `menuNeedsUpdate`,
    /// both of which read `table.selectedRowIndexes` — an `IndexSet`, which
    /// iterates in ascending row index — and map it through `items`. So the
    /// order is the table's, which is the SORT order: clicking a column
    /// header swaps which of the two files is the left-hand side of the diff.
    /// The order the user clicked the two rows in is not recorded anywhere.
    ///
    /// The behaviour is deliberately unchanged here, and whether it should
    /// change is `docs/BACKLOG.md`, row "Which of two selected files is the
    /// LEFT side of a diff is decided by the sort". The argument for leaving
    /// it: the table order is the one order both the user and the window can
    /// see, and a comparison is symmetric apart from which column a line
    /// lands in. The argument against: re-sorting the pane silently reverses
    /// every `-`/`+` in a diff that is already open.
    static func forTwoSelected(
        _ selection: [RemoteFileItem], on side: BrowserPaneSide
    ) -> ComparisonRequest? {
        guard selection.count == 2 else { return nil }
        let comparisonSide = Self.comparisonSide(of: side)
        return ComparisonRequest(
            left: comparisonSide, leftRoot: selection[0].path,
            right: comparisonSide, rightRoot: selection[1].path,
            kind: .filePair)
    }

    /// The menu bar's "Compare Both Panes": the two panes' CURRENT
    /// DIRECTORIES, as folders. The menu bar has no selection to read, which
    /// is why this door exists — it is the whole-folder comparison that needs
    /// nothing clicked first.
    static func forBothPanes(
        localDirectory: String, remoteDirectory: String
    ) -> ComparisonRequest {
        ComparisonRequest(
            left: .local, leftRoot: localDirectory,
            right: .remote, rightRoot: remoteDirectory,
            kind: .folders)
    }

    /// Whether the two panes can be compared as folders AT ALL, for the menu
    /// bar's entry to be enabled on (fix round 1, F2).
    ///
    /// A bucket list is not a directory: its rows are containers, and a
    /// folder comparison against it classifies every bucket whose name
    /// matches a local subdirectory as `.bothDirectories` — whereupon
    /// `FolderComparison.walk` descends and walks that whole bucket, one
    /// checksum per object. One click, an unbounded recursive walk. The entry
    /// is DISABLED rather than enabled-and-inert, because
    /// `TabCommands.activeTabTerminalToggleIsUnlocked`'s own doc comment
    /// already ruled a menu entry that is enabled and does nothing out of
    /// this tree.
    ///
    /// Both panes are asked although a LOCAL pane always answers "ordinary"
    /// today, for the reason `ContentView.remoteScope(_:)`'s neighbour gives:
    /// a gate that reads one pane cannot be checked against the other.
    static func panesAreComparable(local: BrowserScope, remote: BrowserScope) -> Bool {
        !local.isContainerListRoot && !remote.isContainerListRoot
    }

    /// Which of a tab's two file systems a `BrowserPaneSide` names. The two
    /// enumerations are deliberately separate types — `BrowserPaneSide` is
    /// Core's word for a pane, `SessionTab.ComparisonSide` is the App's word
    /// for a side of a comparison — so the crossing is spelled once, here.
    private static func comparisonSide(of side: BrowserPaneSide) -> SessionTab.ComparisonSide {
        switch side {
        case .local: .local
        case .remote: .remote
        }
    }
}
