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
    let onDelete: (StoredSession) -> Void
    let onNew: () -> Void
    let onSelectImported: (SSHConfigHost) -> Void
    let onEdit: (StoredSession) -> Void
    /// Sidebar export entries (M9a/T3): session/group/background context
    /// menus all funnel into this one callback with the scope they cover.
    let onExport: (SessionListViewModel.ExportScope) -> Void
    let onImport: () -> Void

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
                    onDelete(session)
                }
                sessionPendingDelete = nil
            }
        } message: {
            Text(L10n.string(
                "sidebar.delete.confirmMessage", "The saved credentials are removed as well."))
        }
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
                onExport: { onExport(.single(session)) }
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

    @State private var isHovering = false

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
            Button(L10n.string("sidebar.delete", "Delete"), role: .destructive) {
                onRequestDelete()
            }
        }
        // Pure data interpolation (user@host:port) — no natural-language
        // words to translate, identical in every locale.
        .help("\(session.username)@\(session.host):\(String(session.port))")
    }
}
