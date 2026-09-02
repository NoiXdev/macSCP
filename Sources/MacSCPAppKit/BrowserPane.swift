import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// A file pane (local or remote): header with a side badge in the brand
/// color, path, up/refresh — the AppKit table underneath.
/// With `onDropURLs` set, the pane becomes a drop target for file URLs
/// (tint highlight).
struct BrowserPane: View {
    let title: String
    let tint: Color
    let softTint: Color
    let viewModel: RemoteBrowserViewModel
    /// Which pane this is (M7b) — passed through to the context menu model
    /// (the editor entry only ever shows on the remote side).
    let side: BrowserPaneSide
    var onDropURLs: (([URL]) -> Void)? = nil
    /// Double-click on a remote FILE row — wired only for the remote pane
    /// (M5e/T4); the local pane leaves this `nil` and keeps its existing
    /// no-op-on-file behavior.
    var onOpenFile: ((RemoteFileItem) -> Void)? = nil
    /// The pane's own file system, forwarded verbatim to `PathBar` for its
    /// Tab-completion listing (M11g/T2) — see its doc comment for why this
    /// is injected rather than reached through `viewModel`. Passed as the
    /// value itself (not a bespoke closure) so `side` stays the single
    /// source of truth for which pane this is (M11g/T2 review, finding M6).
    let fileSystem: any RemoteFileSystem
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil
    var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)? = nil
    /// Cross-session transfer targets for the context menu (M8b/T4) —
    /// forwarded verbatim to `RemoteFileTableView`; see its doc comment.
    var crossSessionTargets: (() -> [CrossSessionTarget])? = nil
    /// Protocol-contributed file actions for the context menu (M14/T5) —
    /// forwarded verbatim to `RemoteFileTableView`; see its doc comment.
    /// `nil` for the local pane's call site (`ContentView`), since the local
    /// file system never contributes any.
    var fileActions: (() -> [FileActionContribution])? = nil
    /// Which columns the file list shows (M11m/T2) — mirrors
    /// `SettingsStore.visibleColumns`, app-global like the other display
    /// settings (`showHiddenFiles` etc.), so both panes always show the
    /// same set. Forwarded verbatim to `RemoteFileTableView`; its own
    /// default keeps this optional at every call site that predates M11m.
    var visibleColumns: Set<FileColumn> = Set(FileColumn.allCases.filter(\.defaultVisible))
    /// Which digest procedure a checksum request asks for — mirrors
    /// `SettingsStore.checksumAlgorithm`, app-global like the other display
    /// settings.
    var checksumAlgorithm: ChecksumAlgorithm = .preferred
    /// Whether this pane's backend can answer the checksum question. The
    /// remote pane's call site reads the capability
    /// (`ChecksumAvailability.isOffered(for:)`); the local one asks the
    /// local file system, which has no descriptor to read. `false` removes
    /// the menu entry and turns the info sheet's block into the sentence
    /// that says why — never into a disabled control.
    var supportsChecksum: Bool = false

    /// What this pane is looking at, for every "is this action possible
    /// here" question (2026-09-02). Computed rather than injected: both
    /// halves are already in hand — the connection's own answer, and the
    /// directory the pane is showing — and a computed value cannot go stale
    /// against a navigation the way a parameter threaded from `ContentView`
    /// would. The local pane's `LocalFileSystem` takes the protocol default
    /// (`false`), so its menus are byte-identical to what they were.
    private var scope: BrowserScope {
        BrowserScope(
            rootIsContainerList: fileSystem.rootIsContainerList,
            currentPath: viewModel.currentPath)
    }

    /// Whether a local-file drop may land here at all: the pane has a drop
    /// handler AND this listing is not the bucket list. See
    /// `BrowserScope.acceptsDroppedFiles` for why the refusal Core already
    /// makes is not enough on its own.
    private var acceptsDroppedFiles: Bool {
        onDropURLs != nil && scope.acceptsDroppedFiles
    }

    @State private var isDropTargeted = false
    /// Whether this pane's search bar is showing (M11k/T2) — per-PANE, not
    /// shared: each `BrowserPane` instance owns its own `RemoteBrowserViewModel`
    /// (the search state lives there too), so this `@State` bool being local
    /// to the view is what makes two open panes search independently, by
    /// construction, with no extra plumbing needed.
    @State private var isSearchActive = false
    /// Bumped every time ⌘F fires (`RemoteFileTableView.onOpenSearch`),
    /// including while the bar is ALREADY open — see `FileSearchBar.focusToken`'s
    /// doc comment for why the bar needs this instead of relying solely on
    /// its own `.onAppear`.
    @State private var searchFocusToken = 0
    /// Bumped when the search bar closes, so the table reclaims first
    /// responder (M11k/T2 step 5) — forwarded to `RemoteFileTableView` as
    /// `focusRequestToken`; see that property's doc comment.
    @State private var tableFocusToken = 0
    // Sheet/alert state for the context-menu entries the pane handles
    // internally (M7b/T3): rename, info, new folder, new file, delete and
    // the checksum run — six, counted in the pass that writes this — never
    // reach the external `onMenuAction` callback; see the wrapper below.
    // This comment said "four" until the count was taken.
    @State private var renameTarget: RemoteFileItem?
    @State private var infoTarget: RemoteFileItem?
    @State private var deleteRequest: [RemoteFileItem]?
    @State private var showNewFolderSheet = false
    @State private var showNewFileSheet = false
    @State private var deleteErrorMessage: String?
    /// The selection's checksum run, from the moment the menu entry is
    /// chosen until the sheet is closed. Held here rather than built inside
    /// the sheet so the run and the sheet have the same lifetime.
    @State private var checksumBatch: ChecksumBatch?
    /// Set only when a symlink double-click's `navigate(to:)` call FAILS
    /// (M11h/T1 review fix — see `onOpenSymlink` below): forwarded to
    /// `PathBar`, which reuses its existing failure overlay to show the
    /// result instead of a second, bespoke error surface. Stays `nil` on
    /// success, so `PathBar` is never touched, never enters its edit state,
    /// and never steals focus for the (usual, successful) round-trip.
    @State private var symlinkNavigationFailure: SymlinkNavigationFailure?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.9)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(softTint, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                PathBar(
                    viewModel: viewModel,
                    caseSensitive: side == .remote,
                    fileSystem: fileSystem,
                    externalNavigationFailure: $symlinkNavigationFailure)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help(L10n.string("browser.pane.goUpHelp", "Parent directory"))

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help(L10n.string("browser.pane.refreshHelp", "Refresh"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Raises the whole header row above the LATER siblings in this
            // `VStack` (the hairline, then the file table `ZStack`) so the
            // path bar's inline candidates/error overlay paints over them
            // instead of being painted over (M11g/T2 review, finding C1) —
            // the counterpart to `PathBar`'s own `.zIndex(1)`, which handles
            // the same problem one level down against the up/refresh
            // buttons inside this HStack.
            .zIndex(1)

            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)

            // The search bar (M11k/T2): only present while `isSearchActive`
            // is `true` for THIS pane, so the resting look of an inactive
            // pane is byte-for-byte unchanged (design requirement, and the
            // reason `isSearchActive` defaults to `false`).
            if isSearchActive {
                FileSearchBar(
                    viewModel: viewModel,
                    focusToken: searchFocusToken,
                    onClose: {
                        viewModel.clearSearch()
                        isSearchActive = false
                        tableFocusToken += 1
                    }
                )
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
            }

            ZStack {
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPaths: Set(viewModel.selectedItems.map(\.path)),
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { viewModel.selectedItems = $0 },
                    onOpenFile: onOpenFile,
                    // No capability gate needed here either: the symlink
                    // marker/double-click is governed by
                    // `ProtocolCapabilities.supportsSymlinks`, and `item.kind`
                    // can never be `.symlink` for an S3 session — a
                    // `ListObjectsV2` response has no such shape to report,
                    // so nothing constructs one. Unlike the note below, this
                    // reason did NOT expire with M13; it is a property of the
                    // listing, not of what was implemented yet.
                    onOpenSymlink: { item in
                        Task {
                            // Navigates DIRECTLY (M11h/T1 review fix),
                            // mirroring `onOpen` two lines above: the success
                            // path never touches `PathBar`, so it never
                            // enters its edit state and never steals focus
                            // for this round-trip — the bug the review
                            // caught. Only a non-nil (failure) result is
                            // handed to `PathBar`, which then shows it
                            // exactly like a failed typed path.
                            let message = await viewModel.navigate(to: item.path)
                            if let message {
                                symlinkNavigationFailure = SymlinkNavigationFailure(
                                    path: item.path, message: message)
                            }
                        }
                    },
                    pasteboardWriter: pasteboardWriter,
                    side: side,
                    onMenuAction: { entry, selection in
                        switch entry {
                        case .rename: renameTarget = selection.first
                        // This comment used to say no capability gate was
                        // needed because an S3 session could never populate
                        // `selection` at all — every `S3FileSystem` operation
                        // threw "not supported yet (M13)". M13 shipped, so
                        // that premise expired, and the note it left behind
                        // read as a decision rather than as a wait. Corrected
                        // 2026-09-02, in the pass that added the bucket-row
                        // gate below it.
                        //
                        // What is true now, measured: `permissionModel` is
                        // read by no UI in the tree (`grep -rn permissionModel
                        // Sources/` — the only hits are the descriptors that
                        // declare it and this comment), so an S3 or WebDAV
                        // file DOES offer "Info & Permissions", whose apply
                        // then throws. A real gap, older and wider than this
                        // task — it is about a file inside a bucket, not
                        // about a bucket row — and deliberately left for the
                        // task that gates on the capability rather than
                        // widened into this one.
                        case .infoAndPermissions: infoTarget = selection.first
                        case .newFolder: showNewFolderSheet = true
                        case .newFile: showNewFileSheet = true
                        case .delete: deleteRequest = selection
                        case .computeChecksum:
                            checksumBatch = ChecksumBatch(
                                selection: selection, algorithm: checksumAlgorithm)
                        default: onMenuAction?(entry, selection)
                        }
                    },
                    onGoUp: { Task { await viewModel.goUp() } },
                    onOpenSearch: {
                        searchFocusToken += 1
                        isSearchActive = true
                    },
                    focusRequestToken: tableFocusToken,
                    crossSessionTargets: crossSessionTargets,
                    fileActions: fileActions,
                    supportsChecksum: supportsChecksum,
                    visibleColumns: visibleColumns,
                    sortKey: viewModel.sortKey,
                    sortAscending: viewModel.sortAscending,
                    onSortChange: { key, ascending in
                        viewModel.sortKey = key
                        viewModel.sortAscending = ascending
                    },
                    scope: scope
                )
                .allowsHitTesting(viewModel.state == .loaded)

                if viewModel.state == .loading {
                    ProgressView()
                }

                if case .failed(let message) = viewModel.state {
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                        Button(L10n.string("browser.pane.retry", "Try again")) {
                            Task { await viewModel.refresh() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint, lineWidth: isDropTargeted && acceptsDroppedFiles ? 2.5 : 0)
                    .padding(2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let onDropURLs, acceptsDroppedFiles else { return false }
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await provider.macscpFileURL() {
                            urls.append(url)
                        }
                    }
                    await MainActor.run { onDropURLs(urls) }
                }
                return true
            }
        }
        .task { await viewModel.load() }
        .sheet(item: $renameTarget) { target in
            NameEntrySheet(
                title: L10n.string("sheet.rename.title", "Rename"),
                confirmLabel: L10n.string("sheet.rename.confirm", "Rename"),
                initialName: target.name,
                onConfirm: { newName in
                    let error = await viewModel.rename(target, to: newName)
                    if error == nil {
                        // Dismiss immediately; the listing refresh must not
                        // hold the sheet open (M18a).
                        let path = RemotePath.join(viewModel.currentPath, newName)
                        Task { await viewModel.refreshAndSelect(path: path) }
                    }
                    return error
                })
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NameEntrySheet(
                title: L10n.string("sheet.newFolder.title", "New Folder"),
                confirmLabel: L10n.string("sheet.newFolder.confirm", "Create"),
                initialName: L10n.string("sheet.newFolder.defaultName", "untitled folder"),
                onConfirm: { name in
                    let error = await viewModel.createFolder(named: name)
                    if error == nil {
                        // Dismiss immediately; the listing refresh must not
                        // hold the sheet open (M18a).
                        let path = RemotePath.join(viewModel.currentPath, name)
                        Task { await viewModel.refreshAndSelect(path: path) }
                    }
                    return error
                })
        }
        .sheet(isPresented: $showNewFileSheet) {
            NameEntrySheet(
                title: L10n.string("sheet.newFile.title", "New File"),
                confirmLabel: L10n.string("sheet.newFile.confirm", "Create"),
                initialName: L10n.string("sheet.newFile.defaultName", "untitled.txt"),
                onConfirm: { name in
                    let error = await viewModel.createFile(named: name)
                    if error == nil {
                        // Dismiss immediately; the listing refresh must not
                        // hold the sheet open (M18a).
                        let path = RemotePath.join(viewModel.currentPath, name)
                        Task { await viewModel.refreshAndSelect(path: path) }
                    }
                    return error
                })
        }
        .sheet(item: $infoTarget) { target in
            InfoPermissionsSheet(
                item: target,
                onApply: { perms in await viewModel.applyPermissions(perms, to: target) },
                onApplyRecursively: { filePerms, dirPerms, progress in
                    await viewModel.applyPermissionsRecursively(
                        filePermissions: filePerms, directoryPermissions: dirPerms,
                        to: target, progress: progress)
                },
                checksumAlgorithm: checksumAlgorithm,
                supportsChecksum: supportsChecksum,
                onComputeChecksum: {
                    await viewModel.checksum(of: target, algorithm: checksumAlgorithm)
                })
        }
        .sheet(item: $checksumBatch) { batch in
            ChecksumBatchSheet(batch: batch) { item in
                await viewModel.checksum(of: item, algorithm: batch.algorithm)
            }
        }
        .alert(
            L10n.string("delete.title", "Delete?"),
            isPresented: Binding(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            ),
            presenting: deleteRequest
        ) { doomed in
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
            Button(L10n.string("delete.confirm", "Delete"), role: .destructive) {
                let items = doomed
                Task { @MainActor in
                    deleteErrorMessage = await viewModel.deleteItems(items)
                }
            }
        } message: { doomed in
            Text(deleteMessage(for: doomed))
        }
        .alert(
            L10n.string("delete.failedTitle", "Delete failed"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private func deleteMessage(for doomed: [RemoteFileItem]) -> String {
        let base: String
        if doomed.count == 1, let only = doomed.first {
            base = String(format: L10n.string(
                "delete.message.single", "“%@” will be deleted."), only.name)
        } else {
            base = String(format: L10n.string(
                "delete.message.many", "%lld items will be deleted."), Int64(doomed.count))
        }
        let folderHint = doomed.contains { $0.kind == .directory }
            ? " " + L10n.string(
                "delete.message.recursive", "Folders are deleted with their entire contents.")
            : ""
        return base + folderHint + " " + L10n.string(
            "delete.message.permanent", "This action cannot be undone.")
    }
}

fileprivate extension NSItemProvider {
    /// Extracts a file URL from the provider (drop payload).
    ///
    /// Main-actor isolated so the drop handler — which already runs there —
    /// does not have to hand the provider to another executor: `NSItemProvider`
    /// is not `Sendable`, and passing it out of the main actor is the data
    /// race the compiler objects to. `loadItem` starts its work asynchronously
    /// and calls back on a queue of its own choosing either way, so the await
    /// and the completion behave exactly as before; only the thread that
    /// *starts* the load changes.
    @MainActor
    func macscpFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
