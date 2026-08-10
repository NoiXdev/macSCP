import AppKit
import SwiftUI
import macSCPCore

/// Transfer actions split out of `ContentView.swift`: the upload/download
/// toolbar buttons, the context-menu and drag-and-drop enqueue paths (same
/// pane, another tab's session, or a Finder drop), "Copy Path", the Finder
/// promise provider, and double-click-to-edit.
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    // MARK: - Transfers

    /// Locally selected files/folders → current remote directory.
    /// Symlinks in the selection are skipped silently (not a meaningful
    /// transfer target); enabled when at least one non-symlink is selected.
    @ViewBuilder
    func uploadButton(in tab: SessionTab, session: BrowserSession) -> some View {
        let selected = session.local.selectedItems
        Button {
            transferSelection(selected, from: .local, in: tab, session: session)
        } label: {
            Label(L10n.string("browser.upload", "Upload"), systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(!selected.contains { $0.kind != .symlink })
        .help(L10n.string(
            "browser.uploadHelp", "Upload the selected local file/folder to the remote directory"))
    }

    /// Remotely selected files/folders → current local directory.
    /// Symlinks in the selection are skipped silently (not a meaningful
    /// transfer target); enabled when at least one non-symlink is selected.
    @ViewBuilder
    func downloadButton(in tab: SessionTab, session: BrowserSession) -> some View {
        let selected = session.remote.selectedItems
        Button {
            transferSelection(selected, from: .remote, in: tab, session: session)
        } label: {
            Label(L10n.string("browser.download", "Download"), systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(!selected.contains { $0.kind != .symlink })
        .help(L10n.string(
            "browser.downloadHelp", "Download the selected remote file/folder to the local directory"))
    }

    /// Context-menu transfer: same per-item enqueue the toolbar buttons use.
    func transferSelection(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide,
        in tab: SessionTab, session: BrowserSession
    ) {
        let queue = tab.transferQueue
        for item in selection where item.kind != .symlink {
            switch (side, item.kind) {
            case (.local, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.localFS, sourceDirectory: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.local, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.remote, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .download,
                    source: session.remoteFS, sourceDirectory: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            case (.remote, _):
                queue.enqueue(
                    fileName: item.name, direction: .download,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            }
        }
    }

    /// Context-menu transfer to ANOTHER tab's remote (M8b/T4): same
    /// per-item enqueue as `transferSelection`, but the destination is
    /// `target`'s remote file system/directory (frozen at menu-build time)
    /// instead of this tab's own other pane. Always enqueued on the SOURCE
    /// tab's queue (`tab.transferQueue`), regardless of which tab owns the
    /// destination. If the target tab disconnected between menu build and
    /// click, `targetTab.session` is `nil` — enqueue is silently skipped, no
    /// crash (Spec §5.3; the queue only surfaces an error for already
    /// in-flight jobs, not for a destination that was never enqueued).
    func transferToSession(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide, target: CrossSessionTarget,
        in tab: SessionTab, session: BrowserSession
    ) {
        guard let targetTab = tabsModel.tabs.first(where: { $0.id == target.id }),
              let targetSession = targetTab.session
        else { return }
        let queue = tab.transferQueue
        for item in selection where item.kind != .symlink {
            switch (side, item.kind) {
            case (.local, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.localFS, sourceDirectory: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.local, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.remote, .directory):
                // Remote→remote (crossRemote): direction stays `.upload` —
                // the destination is always a remote file system here, the
                // "download" branch only exists for remote→LOCAL transfers.
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.remoteFS, sourceDirectory: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.remote, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            }
        }
    }

    /// "Copy Path": one absolute path per line.
    func copyPaths(of selection: [RemoteFileItem]) {
        let text = selection.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Enqueues dropped file/folder URLs onto the tab's queue. Files run
    /// through `enqueue`, folders recursively through `enqueueTree`
    /// (M5b/T3/T4) — no directory filter, only URLs that no longer exist are
    /// discarded.
    func uploadDropped(_ urls: [URL], in tab: SessionTab, session: BrowserSession) {
        let queue = tab.transferQueue
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                queue.enqueueTree(
                    directoryName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourceDirectory: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                queue.enqueue(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        }
    }

    /// Promise fulfillment: loads a remote file through the tab's queue to
    /// the URL specified by the Finder — serializes with all other transfers
    /// of that tab.
    func remotePromiseProvider(
        for item: RemoteFileItem, in tab: SessionTab, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        let queue = tab.transferQueue
        return RemoteFilePromiseProvider(item: item) { item, url in
            try await queue.enqueueAndWait(
                fileName: url.lastPathComponent, direction: .download,
                source: session.remoteFS, sourcePath: item.path,
                destination: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false)
            )
        }
    }

    /// Double-click on a remote FILE (kind == .file; directories `cd` via
    /// `RemoteBrowserViewModel.open`, symlinks/other stay no-ops — unchanged,
    /// M5e/T4): downloads it into the session's edit temp dir via
    /// `editManager.beginEditing` (shows up as a download in the tab's queue
    /// bar), then opens it in the resolved application.
    ///
    /// Resolution is two-stage per the M5e plan: the extension-rule/default-
    /// editor lookup (`EditorResolver.applicationURL`) only needs the file
    /// name, so it runs BEFORE the download; the system-association fallback
    /// (`EditorResolver.systemApplicationURL`) needs the actual local file,
    /// so it runs AFTER the download completes. If neither yields an app,
    /// `NSWorkspace.shared.open(_:)` is asked to open the local file with
    /// whatever it can find, as a last resort.
    func openInEditor(
        _ item: RemoteFileItem, in tab: SessionTab, session: BrowserSession
    ) {
        let preResolvedAppURL = EditorResolver.applicationURL(
            forFileName: item.name, settings: settingsStore)
        Task {
            do {
                let localURL = try await session.editManager.beginEditing(
                    remotePath: item.path, fileName: item.name,
                    source: session.remoteFS, destinationForUploads: session.remoteFS)
                let appURL = preResolvedAppURL ?? EditorResolver.systemApplicationURL(for: localURL)
                if let appURL {
                    _ = try await NSWorkspace.shared.open(
                        [localURL], withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(localURL)
                }
                tab.editErrorMessage = nil
            } catch is CancellationError {
                // Teardown cancelled the download (disconnect while opening) —
                // the session is going away; a stale banner on the NEXT
                // session would be misattributed. Show nothing.
            } catch {
                tab.editErrorMessage = String(format: L10n.string(
                    "edit.openFailed", "Could not open file for editing: %@"),
                    TransferQueueViewModel.message(for: error))
            }
        }
    }
}
