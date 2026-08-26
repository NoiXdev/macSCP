import SwiftUI
import macSCPCore

/// What a session row's "Snippet" context-menu entry shows (Terminal-Snippets
/// milestone, Task 7).
///
/// The routing question this type exists to answer: a sidebar row is NOT
/// necessarily the active tab. Its stored session could be open in a
/// background tab, open in no tab at all, or be exactly what is on screen
/// right now — and `SessionSidebar` has no visibility into background tabs
/// whatsoever. It is handed exactly one fact about tab state,
/// `activeSessionID` (mirrored from `SessionTab.activeStoredSessionID`,
/// which `ContentView` sets only for the ONE currently active tab), so it
/// cannot tell a session that is connected off-screen from one that is not
/// connected at all — both look identical from here.
///
/// Given that blind spot, guessing which shell "this session" should mean
/// whenever the row is not the visible one would risk exactly the failure
/// this milestone must not ship: the user reads the row, believes the bytes
/// go to ITS host, and they land on a different tab's shell instead — or on
/// nothing, if a stale reference were silently dropped. Both are worse than
/// not offering the entry. The decision made here is therefore the narrow
/// one: act ONLY when the row IS the active, connected tab (`.active`);
/// every other case is `.notTheActiveTab`, disabled with a reason the user
/// can read, never a silent no-op — see `SessionRow`'s context menu for
/// where that reason is rendered.
///
/// That "never a silent no-op" guarantee is about THIS type's own three
/// cases — which one `build` returns, and how `SessionRow` renders each —
/// not about everything a click on an `.active` entry triggers afterward.
/// `.active` still routes through `ContentView.triggerSnippet(_:execute:)`,
/// which can itself return early and silently (its own key-window and
/// terminal guards) if the window loses key status or the connection drops
/// between the menu opening and the click landing. That gap is pre-existing,
/// shared verbatim with the Terminal menu bar's identical entries, and is
/// not something this type's routing decision touches.
///
/// Untested claim: that `SessionRow` actually renders `.notTheActiveTab`'s
/// case as a disabled, non-empty menu entry rather than, say, an empty
/// submenu — this type only proves WHICH case `build` returns for a given
/// input, not what `SessionRow`'s `switch` draws for each case (view code,
/// no pixel harness in this project — see `SnippetMenuItems`'s own doc
/// comment for the same boundary).
enum SessionRowSnippetMenuPlan: Equatable {
    /// The backend has no shell at all (S3, WebDAV) — permanent, independent
    /// of tab state. The caller grays out the whole submenu for this case,
    /// the same way `toggleTerminal`/`openExternalTerminal` do in the
    /// Terminal menu, rather than opening it to a single explanatory line.
    case backendHasNoShell
    /// This session is not the active tab right now: either not connected at
    /// all, or connected in a tab that is not the one currently on screen.
    /// The submenu itself stays enabled (see this type's own doc comment) so
    /// the reason stays reachable instead of just greyed out.
    case notTheActiveTab
    /// The row IS the active, connected tab: safe to render the shared
    /// `SnippetMenuModel` — the SAME computation the Terminal menu bar and
    /// every other snippet trigger surface use, so this row shows one
    /// consistent set of decisions rather than a fifth hand-guessed one.
    case active(SnippetMenuModel)

    var isBackendHasNoShell: Bool {
        if case .backendHasNoShell = self { return true }
        return false
    }

    static func build(
        snippets: [Snippet], isActiveTab: Bool, supportsShell: Bool
    ) -> SessionRowSnippetMenuPlan {
        guard supportsShell else { return .backendHasNoShell }
        guard isActiveTab else { return .notTheActiveTab }
        return .active(
            SnippetMenuModel.build(snippets: snippets, isConnected: true, supportsShell: true))
    }
}

/// Whether a session row offers the two terminal entries — "Open Terminal"
/// and "Open in External Terminal" (P3c/T2).
///
/// A type rather than an `if` in the context menu's body, for the reason
/// this project has now paid for twice: a visibility decision that only
/// exists inside a SwiftUI body is a decision no test can reach. In P2 that
/// shape produced an empty window, and in P3a it made non-empty groups
/// disappear; both were found by reading, not by a red test. The `if` in
/// `SessionRow`'s menu is left with nothing to decide — it only renders the
/// case this answers.
///
/// HIDDEN, not disabled, for a backend without a shell: a permanently dead
/// "Open Terminal" on an S3 bucket explains nothing about why it is dead,
/// and unlike the "Snippet" submenu one case up there is no reason inside it
/// to keep reachable. The asymmetry with `SessionRowSnippetMenuPlan`'s
/// `.backendHasNoShell` (which greys the submenu rather than removing it) is
/// deliberate: that entry can be dead for a SECOND, temporary reason — the
/// row is not the active tab — so it has something to say; these two are
/// dead only ever permanently, per backend.
///
/// Takes the `ConnectionKind`, not a `supportsShell` boolean, so the whole
/// decision — including the descriptor lookup that answers it — is inside
/// the tested function. `SessionRowSnippetMenuPlan.build` takes the boolean
/// and leaves that lookup in the view; here the lookup IS the rule, and
/// nothing else about the row is involved.
///
/// Untested claim, stated rather than implied: that `SessionRow` really
/// renders both entries for `.shown` and neither for `.hidden`. This type
/// only proves WHICH case a kind maps to — the drawing is view code, and
/// this project has no rendering harness (same boundary
/// `SessionRowSnippetMenuPlan` states for itself).
enum SessionRowTerminalMenuPlan: Equatable {
    /// The backend has no shell (S3, WebDAV): neither entry is drawn at all.
    case hidden
    /// The backend has a shell (SSH): both entries are offered.
    case shown

    var isShown: Bool { self == .shown }

    static func build(for kind: ConnectionKind) -> SessionRowTerminalMenuPlan {
        BackendDescriptor.descriptor(for: kind).capabilities.supportsShell ? .shown : .hidden
    }
}

/// Left column: stored sessions, grouped into collapsible sections. A click
/// selects a session, a double click or Return connects it; context menus
/// cover connect/edit/rename/move/delete on sessions, rename/dissolve on
/// groups, and new-connection/new-group on the background. The phosphor dot
/// marks the active connection.
struct SessionSidebar: View {
    let viewModel: SessionListViewModel
    let importedHosts: [SSHConfigHost]
    let activeSessionID: UUID?
    let interactionsDisabled: Bool
    /// Opens a connection to one stored session.
    ///
    /// The first of this sidebar's three host-reaching callbacks, and all
    /// three are effect values rather than closures. This view cannot fire
    /// any of them: their `run` is private to the file that declares them,
    /// and `SessionRowActivation.apply` — the only code that runs one — is
    /// `fileprivate` there too. What is reachable from here is
    /// `performSessionRowInput`, which states an input and the two facts
    /// about the row and picks nothing.
    ///
    /// Fix round 2 gave `onConnect` that shape; round 3 put the firing
    /// decision out of reach; round 4 extended both to the two terminal
    /// callbacks, which had stayed plain closures while being connects —
    /// `onOpenTerminal(session)`, written into the function that moves the
    /// selection, dialled on every single click with the whole suite green.
    let onConnect: SessionRowConnectEffect<StoredSession>
    /// Performs the actual deletion and returns the jump-restoration outcome
    /// (M11a/T3) — the sidebar surfaces `secretFailures` as its own red
    /// inline message, same pattern as `LoginSetsSheet.deleteSelected()`.
    let onDelete: (StoredSession) -> SessionListViewModel.JumpRestoreResult
    let onNew: () -> Void
    let onSelectImported: (SSHConfigHost) -> Void
    let onEdit: (StoredSession) -> Void
    /// Session-row "Open Terminal" entry (P3c/T2) — connects exactly the way
    /// `onConnect` does and differs from it in the pane layout alone (the
    /// session comes up showing the terminal instead of the file browser).
    /// Only ever offered when the backend has a shell — see
    /// `SessionRowTerminalMenuPlan`. Because it connects, it is an effect
    /// value under the rule stated at `onConnect`, and the entry that runs
    /// it is an input (`.terminalMenuEntry`), not a callback the row holds.
    let onOpenTerminal: SessionRowTerminalEffect<StoredSession>
    /// Session-row "Open in External Terminal" entry (P3c/T2) — resolves the
    /// session's configuration and hands it to the external terminal;
    /// macSCP itself does NOT connect. Same visibility rule as
    /// `onOpenTerminal`, and the same effect-value rule: the dialling
    /// program differs, the host reached does not.
    let onOpenExternalTerminal: SessionRowExternalTerminalEffect<StoredSession>
    /// Sidebar export entries (M9a/T3): session/group/background context
    /// menus all funnel into this one callback with the scope they cover.
    let onExport: (SessionListViewModel.ExportScope) -> Void
    let onImport: () -> Void
    /// Sidebar session menu "Audit Log…" entry (M9b/T3) — opens the sheet
    /// for any stored session, connected or not.
    let onShowAuditLog: (StoredSession) -> Void
    /// The saved snippets, in store order (Terminal-Snippets, Task 7) — same
    /// list `MacSCPApp`'s Terminal menu reads from `tabCommands.snippetsLoad`,
    /// handed down here so the session row's "Snippet" submenu renders the
    /// identical `SnippetMenuModel` every other trigger surface does. See
    /// `SessionRowSnippetMenuPlan`'s doc comment for why only the row that IS
    /// the active, connected tab ever gets to act on it.
    let snippets: [Snippet]
    /// Fires one snippet against the ACTIVE tab's shell (Terminal-Snippets,
    /// Task 7) — safe to call unconditionally because the row's own "Snippet"
    /// submenu only ever offers an enabled entry when that row IS the active
    /// tab (`SessionRowSnippetMenuPlan.active`); at that point "the active
    /// tab" and "this row's session" name the same shell. Wired to
    /// `ContentView.triggerSnippet(_:execute:)`, the same method the Terminal
    /// menu bar (Task 6) calls.
    let onRunSnippet: (Snippet, Bool) -> Void
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

    /// The sidebar's host-tag filter (P3a/T6): `nil` means "show everything".
    /// A VIEW, not a setting — deliberately not persisted and not routed
    /// through `SettingsStore`, so it always starts cleared on relaunch and
    /// never desyncs from whatever the store's sessions/tags currently are.
    /// Fed to `SidebarVisibility.compute(activeTag:)` below, the ONE place
    /// this value is interpreted; nothing else in this file re-derives what
    /// it means.
    @State private var activeTag: String?

    /// Which session row the sidebar's selection sits on — the row a double
    /// click or Return connects, and the only thing a single click changes.
    ///
    /// View state, like `activeTag`, and for the same reason: a
    /// pointer position is not a setting. It is deliberately unrelated to
    /// `activeSessionID`, which says which session the ACTIVE TAB has
    /// connected; a user can point at one session while another is on
    /// screen, and both facts are drawn on the row (see
    /// `SessionRowHighlight`).
    @State private var selectedSessionID: UUID?
    /// Keyboard focus for the selected row, so Return reaches it.
    ///
    /// SwiftUI writes this as well as this view does — focus moves for
    /// reasons no code here initiates (a rename field taking over, Tab
    /// traversal under Full Keyboard Access, the window losing key status),
    /// which is why it is not enough to set it once and assume it stays.
    /// Two rules keep it and the selection from drifting apart: every write
    /// from this view moves both (`moveSelection(to:)`, and `endRename`
    /// giving the keyboard back afterwards), and a focus arriving from
    /// anywhere else pulls the selection after it (`onChange(of:
    /// focusedRowID)`). A row that holds the focus is therefore the row
    /// that is highlighted, which is the row Return connects.
    @FocusState private var focusedRowID: UUID?

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
        // The ONE place this decides what the sidebar shows (P3a/T6) — every
        // section, row list, imported-section gate, and empty state below
        // reads from `visibility`; nothing else in this file re-derives any
        // part of that decision from `session.tags` or `activeTag` directly.
        // See `SidebarVisibility.compute`'s own doc comment for the rules.
        let visibility = SidebarVisibility.compute(
            sessions: viewModel.sessions,
            groups: viewModel.groups,
            importedHostsCount: importedHosts.count,
            activeTag: activeTag)
        // Not part of `visibility`: whether the filter-chip ROW itself draws
        // at all is a separate question from what the row's chips filter —
        // `SidebarVisibility.compute` has no opinion on the row's own
        // visibility, only on what an already-chosen `activeTag` does to the
        // session list.
        let availableTags = SidebarVisibility.availableTags(in: viewModel.sessions)

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

            // Empty-store or filter-cleared: no session carries any tag, so
            // an empty chip row would be a frame drawn over nothing.
            if !availableTags.isEmpty {
                HostTagFilterRow(tags: availableTags, selection: $activeTag)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            List {
                Button(action: onNew) {
                    Label(L10n.string("sidebar.newConnection", "New connection"), systemImage: "plus")
                }
                .buttonStyle(.plain)

                switch visibility.emptiness {
                case .notEmpty:
                    sessionRows(visibility.ungrouped)

                    ForEach(visibility.groupSections, id: \.group.id) { section in
                        Section(isExpanded: Binding(
                            get: { !collapsedGroups.contains(section.group.id) },
                            set: { expanded in
                                if expanded { collapsedGroups.remove(section.group.id) }
                                else { collapsedGroups.insert(section.group.id) }
                            }
                        )) {
                            sessionRows(section.sessions)
                        } header: {
                            groupHeader(section.group)
                        }
                    }

                    if visibility.showsImportedSection {
                        importedSection
                    }
                case .noSessionsAtAll:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noSessions", "No saved connections yet."),
                        showsClearFilter: false)
                case .filterMatchesNothing:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noMatches", "No connection has this tag."),
                        showsClearFilter: true)
                }
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
                //
                // Deliberately NOT `endRename()`: the first responder went
                // somewhere else on purpose here, and handing the keyboard
                // back to the selected row would take it off whatever the
                // user just moved to.
                if newValue == nil, renamingID != nil {
                    renamingID = nil
                }
            }
            .onChange(of: focusedRowID) { _, newValue in
                // Focus reached a row by a path that is not `activate` —
                // Tab traversal under Full Keyboard Access is the one that
                // exists today. The selection follows, so a focused row is
                // never an invisible stop that Return does nothing on, and
                // the highlight keeps naming the row the keyboard acts on.
                // Only ever follows focus ONTO a row: focus leaving the
                // sidebar must not clear a selection the user can still see.
                if let newValue { selectedSessionID = newValue }
            }
            .onChange(of: viewModel.sessions) { _, sessions in
                // The active tag's last carrier was deleted, or retagged
                // away from it: fall back to "no filter" rather than hold a
                // selection nothing can ever match again.
                activeTag = SidebarVisibility.resolvedTag(activeTag, in: sessions)
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
                isSelected: session.id == selectedSessionID,
                isRenaming: renamingID == session.id,
                renameDraft: $renameDraft,
                focusedRenameID: $focusedRenameID,
                focusedRowID: $focusedRowID,
                groups: viewModel.groups,
                // Handed over as the activation method itself, not wrapped
                // in a closure: a closure here would be a second place
                // where an input could be swapped for another on its way
                // to the plan, and review round 2 planted exactly that.
                onInput: activate(_:on:),
                onEdit: { onEdit(session) },
                onStartRename: { startRename(id: session.id, currentName: session.name) },
                onCommitRename: { commitSessionRename(session) },
                onCancelRename: endRename,
                onMove: { groupID in viewModel.moveSession(session, toGroup: groupID) },
                onRequestNewGroupMove: { beginNewGroup(forMoving: session) },
                onRequestDelete: { sessionPendingDelete = session },
                onExport: { onExport(.single(session)) },
                onShowAuditLog: { onShowAuditLog(session) },
                snippets: snippets,
                onRunSnippet: onRunSnippet
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
                    .onExitCommand(perform: endRename)
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

    /// Gated at the call site by `visibility.showsImportedSection` (P3a/T6)
    /// — no `!importedHosts.isEmpty` check of its own any more, so there is
    /// exactly one place deciding whether this draws, not two that could
    /// disagree.
    ///
    /// These rows still answer a single click, and spell that count out like
    /// every other tap gesture in this file: a click here prefills the
    /// connection form, which is not connecting, so the rule that made a
    /// session row stop acting on one click does not reach them.
    @ViewBuilder
    private var importedSection: some View {
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
                .onTapGesture(count: 1) { onSelectImported(host) }
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

    /// The sidebar's empty state (P3a/T6) — this sidebar had none before:
    /// an empty store or a filter matching nothing both used to render as
    /// just the "New connection" button sitting above a blank list. Reads
    /// only `visibility.emptiness`'s two empty cases; the copy differs
    /// because the invitation differs (create a session vs. clear the
    /// filter), and only the filter case offers the clear-filter button.
    @ViewBuilder
    private func emptyStateRow(message: String, showsClearFilter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
            if showsClearFilter {
                Button(L10n.string("sidebar.empty.clearFilter", "Show all")) {
                    activeTag = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.remoteBlue)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
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

    // MARK: - Row activation

    /// Applies `SessionRowActivation.build`'s answer for one input on one
    /// row, and reports whether it did anything — the row's Return handler
    /// passes that on to SwiftUI as handled/ignored, so a key press this
    /// sidebar has no use for stays available to the rest of the window.
    ///
    /// Both facts the plan needs are read here rather than in the row: the
    /// row is renaming when it is THE renaming row, and selected when it is
    /// THE selected one, and this is the scope that holds both.
    ///
    /// All four effects are handed to `performSessionRowInput`, which is the
    /// only reachable code that runs any of them: this view cannot fire an
    /// effect, cannot pass one where another belongs, and — since `apply`
    /// stopped being reachable — cannot choose which activation gets fired
    /// either. It states the input and the two facts about the row, and the
    /// answer is not its to pick.
    ///
    /// Since fix round 4 that covers the two terminal entries as well, which
    /// used to reach their callbacks straight from the row. Two things
    /// changed for them besides being unreachable from a gesture: they now
    /// move the selection onto the row they act on, and they end an open
    /// rename the way every other acting input does.
    private func activate(_ input: SessionRowInput, on session: StoredSession) -> Bool {
        let isRenaming = renamingID == session.id
        let isSelected = selectedSessionID == session.id
        if SidebarRenameHandoff.endsOpenRename(
            renamingID: renamingID, input: input,
            isRenaming: isRenaming, isSelected: isSelected) {
            endRename()
        }
        return performSessionRowInput(
            input, on: session, isRenaming: isRenaming, isSelected: isSelected,
            onSelect: SessionRowSelectEffect(moveSelection(to:)),
            onConnect: onConnect,
            onOpenTerminal: onOpenTerminal,
            onOpenExternalTerminal: onOpenExternalTerminal)
    }

    /// Puts the sidebar's selection, and the keyboard with it, on one row.
    /// The two move together everywhere: a highlight the keyboard cannot
    /// reach is the "selection no key acts on" this task exists to avoid.
    private func moveSelection(to session: StoredSession) {
        selectedSessionID = session.id
        focusedRowID = session.id
    }

    // MARK: - Inline rename

    /// Deliberately NOT routed through `endRename()` when a rename is
    /// already open on another row — this is a rename MOVING, not one
    /// ending. Of the three pieces of state `endRename` owns, two
    /// (`renamingID` and `focusedRenameID`) are reassigned in this body
    /// anyway, and the third is the one that must not run here: handing
    /// `focusedRowID` back to the selected row would fight the field this
    /// call is about to focus for the first responder. The draft on the
    /// previous row is dropped, which is what this sidebar does with any
    /// draft not committed by Return or by the menu.
    private func startRename(id: UUID, currentName: String) {
        renamingID = id
        renameDraft = currentName
        focusedRenameID = id
    }

    /// The one deliberate end of an inline rename — commit, cancel and the
    /// hand-off in `activate` all go through it.
    ///
    /// The hand-back is the part that has to be in one place (fix round 1):
    /// a rename takes the keyboard away from the row, and SwiftUI clears
    /// `focusedRowID` when the text field takes over. Without giving it back
    /// the selection stays drawn on a row that Return no longer reaches —
    /// highlight and keyboard silently pointing at different things, with
    /// nothing on screen saying so. Ends on the SELECTED row rather than the
    /// renamed one, since those can differ and the selection is what the
    /// user can see.
    private func endRename() {
        renamingID = nil
        focusedRenameID = nil
        focusedRowID = selectedSessionID
    }

    private func commitSessionRename(_ session: StoredSession) {
        guard renamingID == session.id else { return }
        let draft = renameDraft
        endRename()
        viewModel.renameSession(session, to: draft)
    }

    private func commitGroupRename(_ group: StoredGroup) {
        guard renamingID == group.id else { return }
        let draft = renameDraft
        endRename()
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

/// The sidebar's host-tag filter row (P3a/T6): "All" plus one chip per tag
/// carried by any saved session (`tags`, already deduplicated and sorted by
/// `SidebarVisibility.availableTags` — this view does neither itself).
/// `selection == nil` reads as "All"; tapping a tag chip sets `selection` to
/// it, tapping it again does nothing special (tap "All" to clear).
///
/// Deliberately simpler than `SnippetTagFilterRow`: no per-tag counts (a
/// host tag's purpose is to narrow a short list by eye, not to report how
/// many sessions carry it) and no "No Tag" chip (`SidebarVisibility.compute`
/// has no untagged-only mode — a host tag filter is either "match this tag"
/// or "no filter", never "sessions with zero tags"). Both the pill
/// (`TagFilterChip`) and the horizontal-scroll shell around it
/// (`TagFilterScrollRow`) are shared with `SnippetTagFilterRow`; only the
/// chip SEQUENCE inside differs between the two rows.
private struct HostTagFilterRow: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        TagFilterScrollRow {
            TagFilterChip(
                title: L10n.string("sidebar.filter.all", "All"),
                isSelected: selection == nil,
                onSelect: { selection = nil })
            ForEach(tags, id: \.self) { tag in
                TagFilterChip(
                    title: tag,
                    isSelected: selection == tag,
                    onSelect: { selection = tag })
            }
        }
    }
}

/// A single session row: dot, name (or inline rename field),
/// hover/selection/active styling, drag source, context menu.
private struct SessionRow: View {
    let session: StoredSession
    let isActive: Bool
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    var focusedRenameID: FocusState<UUID?>.Binding
    /// Keyboard focus for the row itself, so its Return handler has
    /// something to fire on. Distinct from `focusedRenameID`, which belongs
    /// to the inline rename field inside this row.
    var focusedRowID: FocusState<UUID?>.Binding
    let groups: [StoredGroup]
    /// Every input this row can receive — its clicks, its Return, and the
    /// three menu entries that reach a host — forwarded raw with the
    /// session it happened on. What each of them MEANS is
    /// `SessionRowActivation`'s answer, given in `SessionSidebar.activate`,
    /// not this view's. Returns whether the input did anything, which the
    /// Return handler reports back to SwiftUI.
    ///
    /// The row holds no callback that starts a session on the user's host
    /// any more: the connect one went in fix round 2, the two terminal ones
    /// in round 4. One way in means the menu entries cannot drift from what
    /// the gestures do, and nothing here can put macSCP — or another
    /// program — onto that host except by naming an input. (The snippet
    /// submenu types into a shell this window already holds; it opens
    /// nothing.)
    let onInput: (SessionRowInput, StoredSession) -> Bool
    let onEdit: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onMove: (UUID?) -> Void
    let onRequestNewGroupMove: () -> Void
    let onRequestDelete: () -> Void
    let onExport: () -> Void
    let onShowAuditLog: () -> Void
    let snippets: [Snippet]
    let onRunSnippet: (Snippet, Bool) -> Void

    @State private var isHovering = false

    /// "SSH"/"S3" (M12/T7b), localized through the backend descriptor —
    /// never hand-picked here, so a future third `ConnectionKind` only needs
    /// a new `BackendDescriptor` case, not a change at every badge site.
    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    /// What this row's "Snippet" submenu shows (Terminal-Snippets, Task 7) —
    /// see `SessionRowSnippetMenuPlan`'s doc comment for the routing
    /// decision. `isActive` (this row's session equals `activeSessionID`,
    /// which `SessionSidebar` only ever sets to a stored session's id right
    /// after it actually connects — see `SessionTab.activeStoredSessionID`)
    /// stands in for BOTH "connected" and "the tab the entry would act on":
    /// there is no third state to represent, since a row that is not the
    /// active tab gets `.notTheActiveTab` regardless of whether its session
    /// happens to be open in some background tab.
    /// Whether this row offers the two terminal entries (P3c/T2) — the whole
    /// decision, descriptor lookup included, lives in
    /// `SessionRowTerminalMenuPlan.build`; see its doc comment for why it is
    /// a type and why the entries are hidden rather than disabled.
    private var terminalPlan: SessionRowTerminalMenuPlan {
        SessionRowTerminalMenuPlan.build(for: session.kind)
    }

    /// The two terminal entries' titles, hoisted out of their `Button`
    /// lines. Every other entry in this menu spells its `L10n.string` call
    /// inline; these two cannot, because their line has to carry the input
    /// they forward as well, and `SessionRowActivationWiringTests`' Guard A
    /// reads a handler and its input on ONE line — it fails closed on a
    /// handler split across lines, deliberately.
    private var openTerminalTitle: String {
        L10n.string("sidebar.openTerminal", "Open Terminal")
    }

    private var externalTerminalTitle: String {
        L10n.string("sidebar.openExternalTerminal", "Open in External Terminal")
    }

    /// The row's background — which of the reasons to draw one wins and
    /// which colour that is are both `SessionRowHighlight`'s, so this view
    /// decides nothing about its own highlight.
    private var highlightFill: Color {
        SessionRowHighlight.build(
            isActive: isActive, isSelected: isSelected, isHovering: isHovering).fill
    }

    private var snippetPlan: SessionRowSnippetMenuPlan {
        SessionRowSnippetMenuPlan.build(
            snippets: snippets, isActiveTab: isActive,
            supportsShell: BackendDescriptor.descriptor(for: session.kind).capabilities.supportsShell)
    }

    /// The backend's own `displaySummary` (M22/T11) — NOT the old hand-rolled
    /// "\(session.username)@\(session.host):\(session.port)", which read
    /// SSH-shaped fields S3 and WebDAV never fill. Historical now: a session
    /// written before M23 carried the `"unused"` placeholder in its flat
    /// host/username columns (so the tooltip read "unused@unused:22"), and
    /// one written between M23 and M26 read blank through `StoredSession`'s
    /// SSH-fallback accessors (so it would read "@:22") — accessors M26
    /// deleted. Neither was a connection summary, and `StoredSession` has had
    /// no host/username accessor to read at all since.
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
            RoundedRectangle(cornerRadius: 6).fill(highlightFill)
        )
        .contentShape(Rectangle())
        // Two independent modifiers rather than `TapGesture(count: 2)
        // .exclusively(before:)`, which is what `snippetRow` — the closer
        // precedent, and the one that argued this through — chose for its
        // own click pair. Its reason does not transfer: there, the count-1
        // gesture firing first means a double click SELECTS a row and then
        // opens a sheet on top of that a moment later, a visible flicker
        // and a selection change the user did not ask for. Here the count-1
        // gesture lands on the very row the double click is about to
        // connect, and the selection it leaves behind is the state that row
        // ends up in either way — the intermediate step is the final one,
        // not a flicker. What `exclusively` would cost is paid on the
        // gesture this task just made the sidebar's primary one: every
        // single click would wait out the double-click interval before the
        // selection appears. Both handlers only forward; the meaning of
        // each count is `SessionRowActivation`'s.
        .onTapGesture(count: 2) { _ = onInput(.doubleClick, session) }
        .onTapGesture(count: 1) { _ = onInput(.singleClick, session) }
        // Focusable only while it is not being renamed: the inline rename
        // field inside this row owns the keyboard while it is up, and a
        // focusable row around it would compete for Return with the field
        // that is being edited.
        .focusable(!isRenaming)
        // The selection background is this row's focus indicator; a
        // second, system-drawn ring on top of it would read as two
        // different marks for one state.
        .focusEffectDisabled()
        .focused(focusedRowID, equals: session.id)
        .onKeyPress(.return) { onInput(.returnKey, session) ? .handled : .ignored }
        .onHover { isHovering = $0 }
        .draggable(session.id.uuidString)
        .contextMenu {
            Button(L10n.string("sidebar.connect", "Connect")) { _ = onInput(.contextMenuEntry, session) }
            // The two terminal entries (P3c/T2), directly under "Connect"
            // because that is what they are: "Open Terminal" IS a connect
            // and differs only in which half of the window comes up, and
            // "Open in External Terminal" is the same host reached another
            // way. Whether they appear at all is `terminalPlan`'s decision,
            // not this `if`'s — see `SessionRowTerminalMenuPlan`.
            //
            // Both forward an input rather than calling a callback (fix
            // round 4): each starts a session on the user's host, which
            // makes them exactly as dangerous on a stray click as
            // "Connect", and the row holds nothing they could be called
            // through any more.
            if terminalPlan.isShown {
                Button(openTerminalTitle) { _ = onInput(.terminalMenuEntry, session) }
                Button(externalTerminalTitle) { _ = onInput(.externalTerminalMenuEntry, session) }
            }
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
            // "Snippet" submenu (Terminal-Snippets, Task 7): same shared
            // `SnippetMenuItems` rendering the Terminal menu bar (Task 6)
            // uses, gated by `snippetPlan` — see that property's and
            // `SessionRowSnippetMenuPlan`'s doc comments for the routing
            // decision. The submenu itself stays enabled (rather than
            // graying out) whenever this backend HAS a shell, so the
            // "not the active tab" reason inside it stays reachable; only a
            // shell-less backend (S3/WebDAV) grays the whole entry, matching
            // `toggleTerminal`/`openExternalTerminal` in the Terminal menu.
            //
            // `.active` with zero saved snippets is its own trap: `snippets`
            // is `[]`, `SnippetMenuModel.build` returns an empty `groups`,
            // and `SnippetMenuItems` — correctly, per its own contract —
            // draws nothing for an empty model, not even its leading
            // divider. Left alone that makes THIS submenu open onto a blank
            // popup with no way out, on a fresh install's very first
            // right-click. Of this milestone's three other trigger surfaces,
            // none of their answers transplants whole: the Terminal menu
            // bar's "keep the divider and 'Manage Snippets…' below" needs a
            // management entry this submenu has never had; the terminal
            // right-click's "attach no menu at all" answers a right-click
            // event, not one item inside a menu that already has Connect/
            // Edit/Move-to/Delete around it — hiding the "Snippet" entry
            // itself would look like the row lost a capability, not like an
            // empty list. What DOES transplant is the terminal header
            // popover's "No snippets yet." message, in the disabled-row
            // idiom this very switch already uses one case up for
            // `.notTheActiveTab` — same L10n key the popover already
            // reads, same "explain, don't strand" shape as that case,
            // extended to a second reason a `.active` submenu can be empty.
            Menu(L10n.string("sidebar.snippets", "Snippet")) {
                switch snippetPlan {
                case .backendHasNoShell:
                    EmptyView()
                case .notTheActiveTab:
                    Button(L10n.string(
                        "sidebar.snippets.onlyActiveTab", "Only Available for the Active Tab")
                    ) {}
                        .disabled(true)
                case .active(let model) where model.isEmpty:
                    Button(L10n.string("snippets.empty", "No snippets yet.")) {}
                        .disabled(true)
                case .active(let model):
                    // No leading divider: this submenu's entries are its
                    // ENTIRE content, with nothing of this menu's own above
                    // them to separate from (the sidebar row's other
                    // entries live one level up, in the parent context
                    // menu) — same reasoning `SSHTerminalView`'s right-click
                    // menu already applies via this same parameter.
                    SnippetMenuItems(model: model, leadingDivider: false) { snippet, execute in
                        onRunSnippet(snippet, execute)
                    }
                }
            }
            .disabled(snippetPlan.isBackendHasNoShell)
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
