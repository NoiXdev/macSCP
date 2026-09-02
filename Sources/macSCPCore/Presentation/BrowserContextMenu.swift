import Foundation

/// Which pane a context menu belongs to (M7b) — the editor entry exists
/// only on the remote side.
public enum BrowserPaneSide: Sendable { case local, remote }

/// Cross-session transfer target (M8b). Identifies a remote pane in another
/// tab as a destination for "Transfer" menu actions.
public struct CrossSessionTarget: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let remotePath: String
    /// The target session's protocol kind (M16) — carried through to
    /// `CrossBackendTarget` so the transfer row can show a backend badge.
    public let kind: ConnectionKind

    public init(id: UUID, title: String, remotePath: String, kind: ConnectionKind) {
        self.id = id
        self.title = title
        self.remotePath = remotePath
        self.kind = kind
    }
}

/// Context-menu entries in display order. The AppKit layer maps these to
/// localized NSMenuItems; keeping the decision logic here makes it unit-
/// testable (the test target only links macSCPCore — M7a lesson).
public enum BrowserMenuEntry: Equatable, Sendable {
    case transferToOtherPane   // submenu "Transfer" — see transferToSession for the M8b per-session targets
    case transferToSession(CrossSessionTarget)  // M8b: transfer to another tab's remote
    case openInEditor          // remote FILES only (M5e path)
    case rename                // single selection only
    case infoAndPermissions    // single, NEVER for symlinks (chmod follows links)
    case newFolder             // always (also on background click)
    case newFile               // always (also on background click) — M18a
    case copyPath              // any non-empty selection
    case computeChecksum       // any selection holding at least one FILE, and only where the backend can answer
    case delete                // any non-empty selection
    case backendFileAction(FileActionContribution)   // protocol-contributed file action (M14)
}

public enum BrowserContextMenu {
    /// Menu model for a selection. Empty selection = background click.
    /// The `crossSessionTargets` parameter lists remote panes from other tabs
    /// that can receive transfers — these appear in the submenu right after
    /// the "to other pane" item when `transferToOtherPane` is present.
    /// `supportsChecksum` says whether this pane's backend can answer the
    /// checksum question at all — `ChecksumAvailability.isOffered(for:)` for
    /// a remote pane, the local file system's own conformance for the local
    /// one. Where it is `false` the entry is ABSENT rather than present and
    /// disabled: a dead menu item is not an answer, and the answer that
    /// belongs to such a backend ("this server does not provide checksums")
    /// is shown in the info sheet, where there is room to say it.
    ///
    /// Defaulted to `false`, so a call site that predates checksums keeps
    /// exactly the menu it had.
    ///
    /// `scope` is the bucket-list gate (2026-09-02). It is a parameter of
    /// THIS function and of nothing else, because this function is already
    /// the ONE predicate both the context menu and the keyboard resolver
    /// consult — see `BrowserKeyCommand`, whose whole doc comment is about
    /// why those two must never drift. Defaulted to `.ordinary`, which is
    /// what every SSH, WebDAV and single-bucket S3 pane is.
    public static func entries(
        for selection: [RemoteFileItem], side: BrowserPaneSide,
        crossSessionTargets: [CrossSessionTarget] = [],
        fileActions: [FileActionContribution] = [],
        supportsChecksum: Bool = false,
        scope: BrowserScope = .ordinary
    ) -> [BrowserMenuEntry] {
        // A bucket is a container, not a folder. The design offers exactly
        // one action on a bucket row — OPEN it — and open is not an entry
        // here: it is the double-click and Cmd-O, which take a row and never
        // ask this model. Refresh is a pane button, likewise not a row
        // action. What is left that a bucket can actually answer is
        // `copyPath`, a clipboard write; everything else would mutate the
        // bucket, move bytes in or out of it, or ask it a question it has no
        // answer to — and `S3FileSystem` refuses those anyway
        // (`RemoteFSError.bucketLevelRefused`). An entry whose only possible
        // outcome is that refusal is not an offer.
        //
        // Read per ROW, not per pane, so a selection that somehow mixes
        // levels is held to the rule rather than escaping it.
        if selection.contains(where: { scope.isContainerRow(path: $0.path) }) {
            return [.copyPath]
        }
        // The background click at the bucket list: "New Folder" there means
        // a new BUCKET, which macSCP does not create, and `createDirectory`
        // at that level is refused. Same reasoning, one level up.
        guard !selection.isEmpty else {
            return scope.isContainerListRoot ? [] : [.newFolder, .newFile]
        }
        var entries: [BrowserMenuEntry] = []
        if selection.contains(where: { $0.kind != .symlink }) {
            entries.append(.transferToOtherPane)
            // M8b: append per-session targets (same transferability gate)
            entries.append(contentsOf: crossSessionTargets.map { .transferToSession($0) })
        }
        if selection.count == 1, let only = selection.first {
            if side == .remote && only.kind == .file {
                entries.append(.openInEditor)
            }
            entries.append(.rename)
            if only.kind != .symlink {
                entries.append(.infoAndPermissions)
            }
            if only.kind == .file {
                // M14: backend-contributed file actions (e.g. S3 presigned URL).
                entries.append(contentsOf: fileActions.map { .backendFileAction($0) })
            }
        }
        entries.append(.newFolder)
        entries.append(.newFile)
        entries.append(.copyPath)
        // Folders and symlinks have no digest, so a selection holding no
        // file offers nothing to compute. A MIXED selection keeps the entry
        // and the run covers its files — there is nothing to explain away
        // in that case, whereas hiding the entry would leave the user
        // guessing which of the selected rows caused it to vanish.
        if supportsChecksum, selection.contains(where: { $0.kind == .file }) {
            entries.append(.computeChecksum)
        }
        entries.append(.delete)
        return entries
    }
}
