import SwiftUI
import macSCPCore

/// Left column: stored sessions, grouped into collapsible sections. Click
/// connects; context menus cover connect/edit/rename/move/delete on
/// sessions, rename/dissolve on groups, and new-connection/new-group on the
/// background. The phosphor dot marks the active connection.
struct SessionSidebar: View {
    let viewModel: SessionListViewModel
    let importedHosts: [SSHConfigHost]
    let activeSessionID: UUID?
    let interactionsDisabled: Bool
    let onSelect: (StoredSession) -> Void
    /// Performs the actual deletion and returns the jump-restoration outcome
    /// (M11a/T3) — the sidebar surfaces `secretFailures` as its own red
    /// inline message, same pattern as `LoginSetsSheet.deleteSelected()`.
    let onDelete: (StoredSession) -> SessionListViewModel.JumpRestoreResult
    let onNew: () -> Void
    let onSelectImported: (SSHConfigHost) -> Void
    let onEdit: (StoredSession) -> Void
    /// Sidebar export entries (M9a/T3): session/group/background context
    /// menus all funnel into this one callback with the scope they cover.
    let onExport: (SessionListViewModel.ExportScope) -> Void
    let onImport: () -> Void
    /// Sidebar session menu "Audit Log…" entry (M9b/T3) — opens the sheet
    /// for any stored session, connected or not.
    let onShowAuditLog: (StoredSession) -> Void
    /// Background context menu "Known Hosts…" entry (M10a/T2) — opens the
    /// known-hosts management sheet.
    let onShowKnownHosts: () -> Void
    /// Background context menu "Logins…" entry (M10b/T3) — opens the
    /// login-sets management sheet, directly below "Known Hosts…".
    let onShowLogins: () -> Void
    /// Imported-row context menu "Hide" entry (M11f/T2) — no confirmation
    /// dialog (spec); the row disappears from `importedHosts` as soon as
    /// `ContentView` recomputes it.
    let onHideImported: (SSHConfigHost) -> Void
    /// Background context menu "Hidden Imports…" entry (M11f/T2) — opens
    /// the hidden-imports management sheet, directly below "Logins…".
    let onShowHiddenImports: () -> Void
    /// Drives the "Hidden Imports…" entry's count suffix (M11f/T2) — see
    /// `hiddenImportsMenuTitle(count:)`.
    let hiddenImportsCount: Int
    /// Red inline message after `HiddenImportStore.hide`/`allHidden` throws
    /// (M11f/T2 review, findings 1+2) — rendered the same way as
    /// `jumpRestoreErrorMessage` below. Owned by `ContentView`, since both
    /// the "Hide" context-menu action and the startup/refresh read can set
    /// it, not just this view's own state.
    let hiddenImportsErrorMessage: String?

    /// Not persisted — resets to "all expanded" on relaunch.
    @State private var collapsedGroups: Set<UUID> = []

    /// Shared inline-rename state: works for both session rows and group
    /// headers, since only one row can be renaming at a time.
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var focusedRenameID: UUID?

    @State private var isShowingNewGroupAlert = false
    @State private var newGroupName: String = ""
    /// Set when "New group…" is triggered from a session's "Move to" menu —
    /// the session to move into the freshly created group. `nil` for the
    /// background/toolbar "New group…" entry, which only creates the group.
    @State private var sessionPendingGroupMove: StoredSession?

    @State private var sessionPendingDelete: StoredSession?
    /// Red inline message after a delete whose jump-restoration pass
    /// (M11a/T3) hit a keychain failure — same pattern as
    /// `LoginSetsSheet.deleteErrorMessage`.
    @State private var jumpRestoreErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("sidebar.header", "SESSIONS"))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(DesignTokens.inkTertiary)
                .padding(.top, 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, toGroup: nil)
                }

            List {
                Button(action: onNew) {
                    Label(L10n.string("sidebar.newConnection", "New connection"), systemImage: "plus")
                }
                .buttonStyle(.plain)

                sessionRows(viewModel.sessions(inGroup: nil))

                ForEach(viewModel.groups) { group in
                    Section(isExpanded: Binding(
                        get: { !collapsedGroups.contains(group.id) },
                        set: { expanded in
                            if expanded { collapsedGroups.remove(group.id) }
                            else { collapsedGroups.insert(group.id) }
                        }
                    )) {
                        sessionRows(viewModel.sessions(inGroup: group.id))
                    } header: {
                        groupHeader(group)
                    }
                }

                importedSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu {
                backgroundMenu
            }
            .onChange(of: focusedRenameID) { _, newValue in
                // Focus lost without an explicit commit (which already
                // clears `renamingID` itself) — cancel silently, never
                // commit on blur.
                if newValue == nil, renamingID != nil {
                    renamingID = nil
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(8)
            }

            if let jumpRestoreErrorMessage {
                Text(jumpRestoreErrorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .padding(8)
            }

            if let hiddenImportsErrorMessage {
                Text(hiddenImportsErrorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .disabled(interactionsDisabled)
        .padding(.top, 12)
        .background(DesignTokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            // Purely cosmetic edge — must never shadow scrollbar hits.
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .alert(
            L10n.string("sidebar.newGroup.title", "New group"),
            isPresented: $isShowingNewGroupAlert
        ) {
            TextField(L10n.string("sidebar.newGroup.placeholder", "Group name"), text: $newGroupName)
            Button(L10n.string("sidebar.newGroup.create", "Create")) {
                commitNewGroup()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                newGroupName = ""
                sessionPendingGroupMove = nil
            }
        }
        .confirmationDialog(
            String(
                format: L10n.string("sidebar.delete.confirmTitle %@", "Delete \u{201C}%@\u{201D}?"),
                sessionPendingDelete?.name ?? ""),
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { isPresented in if !isPresented { sessionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("sidebar.delete", "Delete"), role: .destructive) {
                if let session = sessionPendingDelete {
                    let result = onDelete(session)
                    // Partial keychain-restore failure (M11a/T3): surfaced
                    // as a red inline message, never silently dropped — same
                    // pattern as `LoginSetsSheet.deleteSelected()`.
                    jumpRestoreErrorMessage = result.secretFailures > 0
                        ? String(
                            format: L10n.string(
                                "sidebar.delete.jumpRestoreError %lld",
                                "Could not restore the stored password for %lld connections."),
                            result.secretFailures)
                        : nil
                }
                sessionPendingDelete = nil
            }
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    /// The confirmation dialog's message: the existing "credentials removed"
    /// notice, plus (M11a/T3, spec §4d) a count of sessions that reference
    /// this one as their jump host, when any do — they keep working after
    /// the delete because `SessionListViewModel.delete(_:)` restores their
    /// jump to concrete values first (spec §4 "delete = restoration").
    private var deleteConfirmMessage: String {
        let base = L10n.string(
            "sidebar.delete.confirmMessage", "The saved credentials are removed as well.")
        guard let session = sessionPendingDelete else { return base }
        // Restoration (and thus the "will keep its data directly" claim
        // below) only happens for an SSH bastion -- `SessionListViewModel
        // .delete` leaves the reference dangling for any other kind, so a
        // non-SSH session must not be counted here.
        let count = session.kind == .ssh ? viewModel.sessionsUsingAsJump(session.id).count : 0
        guard count > 0 else { return base }
        let jumpNote = String(
            format: L10n.string(
                "sidebar.delete.jumpUsage %lld",
                "%lld connections use this connection as their jump host and will keep its data directly."),
            count)
        return base + "\n\n" + jumpNote
    }

    // MARK: - Row builders

    @ViewBuilder
    private func sessionRows(_ sessions: [StoredSession]) -> some View {
        ForEach(sessions) { session in
            SessionRow(
                session: session,
                isActive: session.id == activeSessionID,
                isRenaming: renamingID == session.id,
                renameDraft: $renameDraft,
                focusedRenameID: $focusedRenameID,
                groups: viewModel.groups,
                onSelect: { onSelect(session) },
                onEdit: { onEdit(session) },
                onStartRename: { startRename(id: session.id, currentName: session.name) },
                onCommitRename: { commitSessionRename(session) },
                onCancelRename: cancelRename,
                onMove: { groupID in viewModel.moveSession(session, toGroup: groupID) },
                onRequestNewGroupMove: { beginNewGroup(forMoving: session) },
                onRequestDelete: { sessionPendingDelete = session },
                onExport: { onExport(.single(session)) },
                onShowAuditLog: { onShowAuditLog(session) }
            )
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 6))
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: StoredGroup) -> some View {
        HStack {
            if renamingID == group.id {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedRenameID, equals: group.id)
                    .onSubmit { commitGroupRename(group) }
                    .onExitCommand(perform: cancelRename)
            } else {
                // Display-only uppercase (spec: section labels are versal);
                // the stored group name keeps its original casing.
                Text(group.name)
                    .textCase(.uppercase)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.string("sidebar.rename", "Rename")) {
                startRename(id: group.id, currentName: group.name)
            }
            Button(L10n.string("export.menu.group", "Export Group…")) {
                onExport(.group(group))
            }
            Button(L10n.string("sidebar.group.dissolve", "Dissolve group")) {
                viewModel.dissolveGroup(group)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, toGroup: group.id)
        }
    }

    @ViewBuilder
    private var importedSection: some View {
        if !importedHosts.isEmpty {
            Section {
                ForEach(importedHosts, id: \.alias) { host in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(host.alias)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectImported(host) }
                    .help(L10n.string(
                        "sidebar.importedHelp",
                        "From ~/.ssh/config — fills the form (secrets are not imported)"))
                    .contextMenu {
                        Button(L10n.string("sidebar.imported.hide", "Hide")) {
                            onHideImported(host)
                        }
                    }
                }
            } header: {
                Text(L10n.string("sidebar.importedHeader", "IMPORTED"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
        }
    }

    @ViewBuilder
    private var backgroundMenu: some View {
        Button(L10n.string("sidebar.newConnection", "New connection")) { onNew() }
        Button(L10n.string("sidebar.newGroup", "New group…")) { beginNewGroup(forMoving: nil) }
        Divider()
        Button(L10n.string("menu.knownHosts", "Known Hosts…")) { onShowKnownHosts() }
        Button(L10n.string("menu.logins", "Logins…")) { onShowLogins() }
        Button(hiddenImportsMenuTitle(count: hiddenImportsCount)) { onShowHiddenImports() }
        Divider()
        Button(L10n.string("export.menu.all", "Export All…")) { onExport(.all) }
            .disabled(viewModel.sessions.isEmpty)
        Button(L10n.string("import.menu", "Import…")) { onImport() }
    }

    // MARK: - Inline rename

    private func startRename(id: UUID, currentName: String) {
        renamingID = id
        renameDraft = currentName
        focusedRenameID = id
    }

    private func cancelRename() {
        renamingID = nil
        focusedRenameID = nil
    }

    private func commitSessionRename(_ session: StoredSession) {
        guard renamingID == session.id else { return }
        let draft = renameDraft
        renamingID = nil
        focusedRenameID = nil
        viewModel.renameSession(session, to: draft)
    }

    private func commitGroupRename(_ group: StoredGroup) {
        guard renamingID == group.id else { return }
        let draft = renameDraft
        renamingID = nil
        focusedRenameID = nil
        viewModel.renameGroup(group, to: draft)
    }

    // MARK: - New group

    private func beginNewGroup(forMoving session: StoredSession?) {
        sessionPendingGroupMove = session
        newGroupName = ""
        isShowingNewGroupAlert = true
    }

    private func commitNewGroup() {
        defer {
            newGroupName = ""
            sessionPendingGroupMove = nil
        }
        guard let group = viewModel.createGroup(named: newGroupName) else { return }
        if let session = sessionPendingGroupMove {
            viewModel.moveSession(session, toGroup: group.id)
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ items: [String], toGroup groupID: UUID?) -> Bool {
        guard let raw = items.first, let sessionID = UUID(uuidString: raw) else { return false }
        guard let session = viewModel.sessions.first(where: { $0.id == sessionID }) else { return false }
        viewModel.moveSession(session, toGroup: groupID)
        return true
    }
}

/// A single session row: dot, name (or inline rename field), hover/active
/// styling, drag source, context menu.
private struct SessionRow: View {
    let session: StoredSession
    let isActive: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    var focusedRenameID: FocusState<UUID?>.Binding
    let groups: [StoredGroup]
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onMove: (UUID?) -> Void
    let onRequestNewGroupMove: () -> Void
    let onRequestDelete: () -> Void
    let onExport: () -> Void
    let onShowAuditLog: () -> Void

    @State private var isHovering = false

    /// "SSH"/"S3" (M12/T7b), localized through the backend descriptor —
    /// never hand-picked here, so a future third `ConnectionKind` only needs
    /// a new `BackendDescriptor` case, not a change at every badge site.
    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    /// The backend's own `displaySummary` (M22/T11) — NOT the old hand-rolled
    /// "\(session.username)@\(session.host):\(session.port)", which read
    /// SSH-shaped fields S3 and WebDAV never fill: a session written before M23
    /// carried the `"unused"` placeholder in `session.host`/`.username` (so the
    /// tooltip read "unused@unused:22"), and one written since leaves both
    /// empty (so it would read "@:22"). Neither is a connection summary.
    private var connectionSummary: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return descriptor.displaySummary(descriptor.sessionValues(session))
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? DesignTokens.statusPhosphor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused(focusedRenameID, equals: session.id)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(session.name)
                    .lineLimit(1)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? DesignTokens.remoteBlue : Color.primary)
            }

            // Protocol badge (M12/T7b): "SSH"/"S3" from the backend
            // descriptor — unobtrusive, same small-label typography as the
            // sidebar's own section headers above.
            Text(kindBadgeLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.inkTertiary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? DesignTokens.remoteSoft
                      : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onSelect() } }
        .onHover { isHovering = $0 }
        .draggable(session.id.uuidString)
        .contextMenu {
            Button(L10n.string("sidebar.connect", "Connect")) { onSelect() }
            Button(L10n.string("sidebar.edit", "Edit…")) { onEdit() }
            Button(L10n.string("export.menu.single", "Export…")) { onExport() }
            Button(L10n.string("sidebar.rename", "Rename")) { onStartRename() }
            Menu(L10n.string("sidebar.moveTo", "Move to")) {
                if session.groupID != nil {
                    Button(L10n.string("sidebar.noGroup", "No group")) { onMove(nil) }
                }
                ForEach(groups) { group in
                    Button {
                        onMove(group.id)
                    } label: {
                        if group.id == session.groupID {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                    .disabled(group.id == session.groupID)
                }
                Divider()
                Button(L10n.string("sidebar.newGroup", "New group…")) { onRequestNewGroupMove() }
            }
            Divider()
            Button(L10n.string("sidebar.auditLog", "Audit Log…")) { onShowAuditLog() }
            Divider()
            Button(L10n.string("sidebar.delete", "Delete"), role: .destructive) {
                onRequestDelete()
            }
        }
        // Pure data interpolation, backend-specific (user@host for SSH,
        // bucket @ endpoint-host for S3, user @ host for WebDAV) — no
        // natural-language words to translate, identical in every locale.
        .help(connectionSummary)
    }
}
