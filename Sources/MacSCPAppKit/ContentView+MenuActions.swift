import AppKit
import SwiftUI
import macSCPCore

// The sheet item sits at the TOP of this file, ahead of every function, and not
// at the end where it was first put: `ConnectionActionRouteTests` reads the
// body of `handleConnectionAction` as "from its declaration to the next
// function at the same indent, or the end of the file", and that function is
// the last in the file, so anything appended after it is read as part of its
// arms.

extension ContentView {
    /// The capability and the bucket list the sheet checks a name against,
    /// captured at presentation time for the reason
    /// `BucketVersioningSheetItem` gives, and the refresh to run when the
    /// sheet made a bucket.
    ///
    /// **Its initialiser is `fileprivate`, and this file is the only one that
    /// can call it: that is the boundary, not a convention.** The rule is that
    /// the sheet is built in exactly one place -- `handleConnectionAction`'s
    /// create-bucket arm, after it has re-asked availability -- so that the
    /// rule deciding whether the action is possible and the sheet it opens
    /// cannot come to disagree about a bucket nobody is looking at. A source
    /// scan for that kept buying one spelling and revealing another (a literal
    /// call, then a `.init(` behind a factory written through
    /// `$createBucketSheetItem.wrappedValue`); a type another file cannot
    /// construct does not have spellings. The access level is on the
    /// initialiser and not on the type, because every other file still has to
    /// HOLD the item (`ContentView.createBucketSheetItem`) and present it.
    struct CreateBucketSheetItem: Identifiable {
        let id = UUID()
        let recorder: AuditRecorder?
        let settings: any S3BucketSettings
        let listing: CreateBucketModel.Listing
        let onCreated: () -> Void

        fileprivate init(
            recorder: AuditRecorder?, settings: any S3BucketSettings,
            listing: CreateBucketModel.Listing, onCreated: @escaping () -> Void
        ) {
            self.recorder = recorder
            self.settings = settings
            self.listing = listing
            self.onCreated = onCreated
        }
    }
}

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
        case .restoreDeleted:
            restoreDeletedFiles(selection, side: side, in: tab, session: session)
        case .backendFileAction(let action):
            // Backend-contributed actions are keyed off `action.id` through
            // `BackendFileActionRoute`, the file menu's counterpart of
            // `ConnectionActionRoute`: the enum is the table, this `switch` has
            // no `default`, and the menu draws a row whose id has no case
            // disabled (`fileActionVerdict`). So a contribution cannot be
            // declared, offered and matched by nothing, which is what
            // `s3.versions` was while this was an `if`-chain with no `else`.
            // (This comment used to say, verbatim: "Backend-contributed
            // actions are keyed off `action.id` so a new contribution doesn't
            // need a new `BrowserMenuEntry` case, just another `if` here". It
            // still needs no new entry case; it now needs a route case, and
            // the compiler asks for the arm.)
            //
            // Every arm is gated alike: `selection.count == 1` mirrors the
            // menu-model gate (`BrowserContextMenu.entries`) that only ever
            // offers `backendFileAction` for a single selected file, and
            // `side` is asked because the local pane contributes none (its
            // `fileActions` is nil) -- the same shape as `openInEditor` above.
            guard let route = BackendFileActionRoute(action: action) else { break }
            switch route {
            case .presignedURL:
                // S3's presigned URL (M14/T5).
                if side == .remote,
                    selection.count == 1, let file = selection.first,
                    let provider = session.remoteFS as? PresignedURLProvider
                {
                    // Same "no leading slash" convention
                    // `S3FileSystem.objectKey(forPath:)` uses internally:
                    // normalize first (collapses any repeated slashes), then
                    // drop the single leading one.
                    let normalizedPath = RemotePath.normalizedAbsolute(file.path)
                    let key = normalizedPath == "/" ? "" : String(normalizedPath.dropFirst())
                    presignedSheetItem = PresignedSheetItem(itemKey: key, provider: provider)
                }
            case .retention, .legalHold:
                // The two Object Lock actions (S3 bucket settings, Task 10),
                // keyed off `action.id` through `ObjectLockFileAction`. The
                // target is worked out from the connection's own facts, so at
                // a bucket list the bucket is the path's first component.
                // Without all four of the file, the capability, the session's
                // cache and a target nothing opens: a COMPLIANCE write is never
                // reachable from a half-resolved path.
                if side == .remote, selection.count == 1, let file = selection.first,
                    let lockAction = ObjectLockFileAction(action: action),
                    let target = ObjectLockTarget.resolve(
                        path: file.path, in: connectionActionContext(in: tab, session: session)),
                    let settings = session.remoteFS as? any S3BucketSettings,
                    let states = session.objectLockStates
                {
                    objectLockSheetItem = ObjectLockSheetItem(
                        recorder: tab.auditRecorder, focus: lockAction.focus, target: target,
                        settings: settings, states: states)
                }
            case .versions:
                // The version history (S3 version history, Task 7). It needs
                // the version capability and a target; the bucket-settings
                // capability is optional, and without it the rows simply carry
                // no lock state. The lock cache is the session's, so this sheet
                // and the Object Lock sheets share one read per bucket; the
                // fallback is a cache of its own over the same capability.
                if side == .remote, selection.count == 1, let file = selection.first,
                    let provider = session.remoteFS as? any ObjectVersionProvider,
                    let target = ObjectVersionsTarget.resolve(
                        file: file, in: connectionActionContext(in: tab, session: session))
                {
                    let locks = (session.remoteFS as? any S3BucketSettings).map {
                        ObjectVersionsModel.LockBacking(
                            settings: $0,
                            cache: session.objectLockStates ?? ObjectLockStateCache(settings: $0))
                    }
                    objectVersionsSheetItem = ObjectVersionsSheetItem(
                        recorder: tab.auditRecorder, target: target, provider: provider,
                        locks: locks, versioning: session.bucketVersioning, tab: tab,
                        session: session)
                }
            case .metadata:
                // The metadata sheet (S3 metadata, Task 4). It needs BOTH
                // capabilities and a target, with no fallback for either: the
                // write adds a version, and a version on a bucket whose
                // default retention is COMPLIANCE is one nobody can erase, so
                // a sheet that could not read the bucket's lock default must
                // not exist (spec section 11.2), the way a COMPLIANCE write
                // is never reachable from a half-resolved path above. The two
                // caches are the session's, shared with the other S3 sheets;
                // the fallback is a cache of the sheet's own over the same
                // capability.
                if side == .remote, selection.count == 1, let file = selection.first,
                    let provider = session.remoteFS as? any ObjectMetadataProvider,
                    let settings = session.remoteFS as? any S3BucketSettings,
                    let target = ObjectLockTarget.resolve(
                        path: file.path, in: connectionActionContext(in: tab, session: session))
                {
                    objectMetadataSheetItem = ObjectMetadataSheetItem(
                        recorder: tab.auditRecorder, target: target, provider: provider,
                        settings: settings,
                        locks: session.objectLockStates ?? ObjectLockStateCache(settings: settings),
                        versioning: session.bucketVersioning
                            ?? BucketVersioningCache(settings: settings))
                }
            }
        }
    }

    /// The "Restore" entry of a deleted row (S3 version history, Task 10):
    /// lifts the delete marker each selected deleted row carries, then lists
    /// the pane again so the file appears and the deleted row goes. How it
    /// ended, when it did not end plainly, is the pane's notice.
    ///
    /// **Remote only, and only deleted rows**: the menu model offers the entry
    /// for a selection made wholly of deleted rows and the pane lists such rows
    /// only for a connection with the version capability, and both are asked
    /// again here because a restore is a write.
    func restoreDeletedFiles(
        _ selection: [RemoteFileItem], side: BrowserPaneSide, in tab: SessionTab,
        session: BrowserSession
    ) {
        guard side == .remote else { return }
        let rows = selection.filter(\.isDeleted)
        guard !rows.isEmpty else { return }
        let context = connectionActionContext(in: tab, session: session)
        let remote = session.remote
        guard let provider = session.remoteFS as? any ObjectVersionProvider else {
            remote.deletedFilesNotice = .restoreUnavailable
            return
        }
        let restorer = DeletedFileRestorer(provider: provider, recorder: tab.auditRecorder)
        Task { @MainActor in
            let notice = await restorer.restore(rows, in: context)
            await remote.refresh()
            // After the refresh, which clears the notice as it starts.
            if let notice { remote.deletedFilesNotice = notice }
        }
    }

    /// What the file context menu does with `action` now: offered, or drawn
    /// disabled with the sentence that says why.
    ///
    /// Asked at each menu build, and **synchronous**: it reads only what the
    /// session already knows (`BucketVersioningCache.knownVersioning(_:)`),
    /// never starts a read, and a bucket whose versioning has not been read
    /// OFFERS the row (`BackendFileActionRoute.verdict(bucketVersioning:)`
    /// gives the policy and its stated limit). The bucket is the one the
    /// remote pane is standing in, from the same context the connection
    /// actions use.
    func fileActionVerdict(
        _ action: FileActionContribution, in tab: SessionTab, session: BrowserSession
    ) -> FileActionVerdict {
        BackendFileActionRoute.verdict(
            for: action, bucket: connectionActionContext(in: tab, session: session).bucket,
            cache: session.bucketVersioning)
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
    ///
    /// **That is a copy, and it is only the live connection's bucket because
    /// nothing edits a connected tab's form.** Three facts keep it so, each in
    /// another file: `formTarget()` gives a connected tab's form-filling
    /// actions a fresh tab instead; the detail pane constructs
    /// `ConnectionFormView` only in the arm taken while `tab.session` is `nil`;
    /// and `connect(in:stored:)` tears an existing session down before it
    /// fills the form. A change that breaks one reintroduces the divergence
    /// silently, and the end of it is an irreversible write on a bucket the
    /// person was not looking at. `ConnectedTabFormInvariantTests` reads
    /// those three places and goes red if any of them moves.
    func connectionActionContext(
        in tab: SessionTab, session: BrowserSession
    ) -> ConnectionActionContext {
        ConnectionActionContext(
            settings: session.remoteFS as? any S3BucketSettings,
            rootIsContainerList: session.remoteFS.rootIsContainerList,
            remotePath: session.remote.currentPath,
            configuredBucket: tab.connectionViewModel.values[S3Field.bucket])
    }

    /// Opens the create-bucket sheet from somewhere other than the toolbar
    /// menu -- the empty bucket list's own button (F3 of the final
    /// whole-branch review).
    ///
    /// **It goes THROUGH the route, not beside it.** The contribution is
    /// looked up in the backend's own descriptor and handed to
    /// `handleConnectionAction`, which re-asks availability and builds the
    /// sheet. So the rule that decides whether the action is possible, and
    /// the construction of the sheet, are each spelled exactly once; a second
    /// copy here is how the two would come to disagree about a bucket nobody
    /// is looking at. A backend that contributes no such action gets nothing,
    /// which is also why this cannot be reached on the local pane.
    func openCreateContainerSheet(in tab: SessionTab, session: BrowserSession) {
        guard
            let action = ConnectionActionRoute.contribution(
                of: .createBucket, for: tab.connectionViewModel.kind)
        else { return }
        handleConnectionAction(action, in: tab, session: session)
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
                // The session's lock-state cache, so this sheet and the Object
                // Lock sheet share one read per bucket. The fallback is a
                // cache of its own over the same capability: the session
                // always has one when `settings` is non-nil (both come from the
                // same file system, `BrowserSession.objectLockStates(for:)`),
                // but a sheet that cannot ask whether the bucket has a lock
                // has no button and nothing to say, and that is worse than one
                // extra read.
                //
                // The versioning cache is told when this sheet writes
                // (`BucketVersioningModel.apply`), so the "Show Versions" row
                // stops answering for the state from before it. The same
                // fallback applies, and is harmless for the same reason: a
                // cache nobody else reads is merely one that is invalidated
                // for nobody -- but the session always has one when
                // `settings` is non-nil (`BrowserSession.bucketVersioning(for:)`).
                versioningSheetItem = BucketVersioningSheetItem(
                    recorder: tab.auditRecorder, bucket: bucket, settings: settings,
                    states: session.objectLockStates ?? ObjectLockStateCache(settings: settings),
                    versioning: session.bucketVersioning
                        ?? BucketVersioningCache(settings: settings))
            }
        case .cors:
            if let settings = context.settings, let bucket = context.bucket {
                corsSheetItem = BucketCORSSheetItem(
                    recorder: tab.auditRecorder, bucket: bucket, settings: settings)
            }
        case .objectLock:
            if let settings = context.settings, let bucket = context.bucket,
                let states = session.objectLockStates
            {
                bucketObjectLockSheetItem = BucketObjectLockSheetItem(
                    recorder: tab.auditRecorder, bucket: bucket, settings: settings,
                    states: states)
            }
        case .createBucket:
            // The mirror of the three arms above: they need a bucket, this one
            // is live only where there is none. The sheet is handed the
            // pane's own listing of the bucket list, which is what the row's
            // availability guarantees the pane is showing; the listing itself
            // is read by `CreateBucketModel.listing(of:)`. A made bucket
            // refreshes that listing, so it appears.
            if let settings = context.settings {
                createBucketSheetItem = CreateBucketSheetItem(
                    recorder: tab.auditRecorder, settings: settings,
                    listing: CreateBucketModel.listing(of: session.remote),
                    onCreated: { [remote = session.remote] in
                        Task { await remote.refresh() }
                    })
            }
        }
    }
}
