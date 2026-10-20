import AppKit
import SwiftUI
import macSCPCore

/// The ONE router every pane's context menu sends through (diff view fix
/// round 3, N1): one switch over `BrowserMenuEntry`, with the side the pane
/// handed over.
///
/// **Its own file, and that was measured rather than chosen.** The first
/// attempt put this function in `ContentView+Transfers.swift`, beside the
/// `transferSelection`, `copyPaths` and `openInEditor` it routes to. That
/// turned `ToolbarTransferConfirmationGuardTests` red: the file is required
/// to hold exactly three `transferSelection(` — the declaration, the plan's
/// `.transferNow` case and the confirm action — "no fourth route to the
/// transfer in this file", and that bound is what its own mutation self-test
/// plants against, so raising it to four would have disarmed the self-test.
/// The router lives here, the toolbar file keeps its property, and the guard
/// that caught it is unchanged.
extension ContentView {
    /// Everything a pane's context menu does NOT handle itself, for BOTH
    /// panes, with the side the pane handed over (diff view fix round 3, N1).
    ///
    /// **Why one function.** There were two of these, one per pane, each
    /// spelling `.local` or `.remote` in every arm that needed a side — and
    /// giving the local block the remote arms, or the reverse, left every
    /// anchor a source scan counts present exactly once while both doors of
    /// both panes acted on the wrong file system. The reviewer planted it and
    /// it was green against the whole AppKit target. One switch removes the
    /// per-pane copy; `side` arriving from `BrowserPane` rather than from the
    /// call site removes the last place a caller could get it wrong.
    ///
    /// **`side` is this pane, always.** No arm reads a literal side; the two
    /// arms that are about one pane only (`openInEditor`, the S3 presigned
    /// URL) ask `side` rather than assuming, and the menu model is still the
    /// decision — neither entry is ever emitted for the other pane.
    func handleBrowserMenuEntry(
        _ entry: BrowserMenuEntry, selection: [RemoteFileItem], side: BrowserPaneSide,
        in tab: SessionTab, session: BrowserSession
    ) {
        switch entry {
        case .transferToOtherPane:
            transferSelection(selection, from: side, in: tab, session: session)
        case .transferToSession(let target):
            transferToSession(
                selection, from: side, target: target, in: tab, session: session)
        case .copyPath:
            copyPaths(of: selection)
        case .openInEditor:
            // Remote only — the menu model never emits it for the local pane,
            // and the gate here says so rather than relying on it.
            if side == .remote, let item = selection.first {
                openInEditor(item, in: tab, session: session)
            }
        // The two diff-view doors (Task 12). Both are forwarded by
        // `BrowserPane`, which handles neither itself; the handlers are in
        // `ContentView+Comparison.swift`.
        case .compareWithOtherPane: compareWithOtherPane(selection, from: side, in: tab, session: session)
        case .compareTwoSelected: compareTwoSelected(selection, on: side, in: tab)
        case .rename, .infoAndPermissions, .newFolder, .newFile,
            .delete, .computeChecksum:
            break   // handled inside BrowserPane, never forwarded
        case .compressTo, .extractArchive:
            break   // handled inside BrowserPane (BrowserPane+Archive.swift), never forwarded
        case .userFileAction:
            break   // handled inside BrowserPane (BrowserPane+FileActions.swift), never forwarded
        case .backendFileAction(let action):
            // Currently the only backend-contributed action is S3's presigned
            // URL (M14/T5) — keyed off `action.id` so a future second
            // contribution doesn't need a new `BrowserMenuEntry` case, just
            // another `if` here. `selection.count == 1` mirrors the menu-model
            // gate (`BrowserContextMenu.entries`) that only ever offers
            // `backendFileAction` for a single selected file, and `side` is
            // asked because the local pane contributes none (its
            // `fileActions` is nil) — the same shape as `openInEditor` above.
            if side == .remote, action.id == "s3.presignedURL",
                selection.count == 1, let file = selection.first,
                let provider = session.remoteFS as? PresignedURLProvider
            {
                // Same "no leading slash" convention
                // `S3FileSystem.objectKey(forPath:)` uses internally:
                // normalize first (collapses any repeated slashes), then drop
                // the single leading one.
                let normalizedPath = RemotePath.normalizedAbsolute(file.path)
                let key = normalizedPath == "/" ? "" : String(normalizedPath.dropFirst())
                presignedSheetItem = PresignedSheetItem(itemKey: key, provider: provider)
            }
        }
    }
}

/// The toolbar menu's connection-level actions (S3 bucket settings, Task 8):
/// which rows are live, and what choosing one does.
///
/// Routed by contribution **id**, through `ConnectionActionRoute`, exactly as
/// the file actions above route by `action.id` -- never by `ConnectionKind`.
/// The route enum is the table: an id it has no case for is unavailable, and
/// the menu disables that row.
extension ContentView {
    /// The connection facts a row's availability is decided from. The one
    /// place the session's capability, its root mode, the remote pane's path
    /// and the configured bucket are read together.
    ///
    /// The configured bucket comes from the tab's own connection form, which is
    /// what the dial was built from (`connect(in:stored:)` fills it, then
    /// dials); the file system itself does not expose it. It matters only for
    /// a connection rooted in one bucket -- at the bucket list the path names
    /// the bucket.
    func connectionActionContext(
        in tab: SessionTab, session: BrowserSession
    ) -> ConnectionActionContext {
        ConnectionActionContext(
            settings: session.remoteFS as? any S3BucketSettings,
            rootIsContainerList: session.remoteFS.rootIsContainerList,
            remotePath: session.remote.currentPath,
            configuredBucket: tab.connectionViewModel.values[S3Field.bucket])
    }

    /// Whether the menu row for `action` can be carried out now; what the
    /// menu's `.disabled` reads for every row.
    func connectionActionIsAvailable(
        _ action: ConnectionActionContribution, in tab: SessionTab, session: BrowserSession
    ) -> Bool {
        ConnectionActionRoute.isAvailable(
            action, in: connectionActionContext(in: tab, session: session))
    }

    /// Carries out the connection action the user chose.
    ///
    /// Availability is asked again before anything opens: the remote pane may
    /// have moved between the menu being drawn and the click, and a row that
    /// was live then may not be now. The `switch` has no `default`, so a route
    /// added without an arm does not compile.
    func handleConnectionAction(
        _ action: ConnectionActionContribution, in tab: SessionTab, session: BrowserSession
    ) {
        let context = connectionActionContext(in: tab, session: session)
        guard ConnectionActionRoute.isAvailable(action, in: context),
            let route = ConnectionActionRoute(action: action)
        else { return }
        switch route {
        case .versioning:
            if let settings = context.settings, let bucket = context.bucket {
                versioningSheetItem = BucketVersioningSheetItem(bucket: bucket, settings: settings)
            }
        }
    }
}
