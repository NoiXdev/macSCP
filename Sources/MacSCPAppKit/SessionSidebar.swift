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

/// Left column: stored connections and folders, drawn as a tree of arbitrary
/// depth. A click selects a connection, a double click or Return connects it;
/// context menus cover connect/edit/rename/duplicate/move/delete on connections,
/// rename/export/sort/dissolve on folders, and new-connection/new-group on
/// the background. The phosphor dot marks the active connection.
///
/// **This view derives no place for anything.** Which rows sit under which
/// parent, and in which order, is `SidebarVisibility.children(of:)`'s answer;
/// where a dropped row lands is `SessionListViewModel.move(_:before:)`'s or
/// `move(_:intoGroup:)`'s, each given two identities. See
/// `SidebarOrdering`'s doc comment for why an index carried through a view
/// was the defect class this shape removed, and `SidebarTreeWiringTests` for
/// the guard that keeps one from creeping back in here.
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
    /// Which STORED session the sidebar is pointing at, reported upward every
    /// time the user points at one — not only when the id changes (session
    /// overview plan, Task 2).
    ///
    /// The window shows a read-only overview of this session in the detail
    /// area of an unconnected tab, so "the selection" has to be a fact the
    /// window can read; `selectedSessionID` is `@State` here and stays that
    /// way, because where the pointer is remains this view's own business.
    /// `nil` says the sidebar points at no stored session: the
    /// "New connection" row, or an entry from `~/.ssh/config`, both of which
    /// put the FORM on screen and would be contradicted by an overview
    /// hanging on behind it.
    ///
    /// Fired on every activation rather than on a change, deliberately:
    /// clicking the row that is already selected is how a user gets the
    /// overview back after opening the form from it, and an
    /// `onChange(of:)`-shaped report would answer that click with silence.
    ///
    /// A plain callback and not an effect value, under the rule stated at
    /// `onConnect`: a selection reaches nothing but this window.
    let onSelectSession: (UUID?) -> Void
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
    /// Sidebar session menu "Diagnose…" entry (design §1, the session menu's
    /// door) — opens the diagnostics panel for any stored session, connected
    /// or not.
    ///
    /// A plain callback rather than a `SessionRowConnectEffect`, and the rule
    /// for that split is what the entry DOES: opening the panel reaches no
    /// host. The probes inside it — including an SSH dial that authenticates
    /// — run when the user presses the panel's own button, never when a menu
    /// entry is clicked (decision of 2026-09-02). Same category as `onEdit`
    /// and `onShowAuditLog`; if this ever opened a panel that ran on appear,
    /// it would belong with `onConnect` instead.
    let onDiagnose: (StoredSession) -> Void
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
    /// Closes `hiddenImportsErrorBanner` (dev-build follow-up, 2026-09-03:
    /// the other two red captions got a close button and a six-second
    /// auto-dismiss in `ece5aaf9`, this one did not) — a callback rather
    /// than a direct write because `hiddenImportsErrorMessage` above is a
    /// plain `let`, not `@State`: this view has no property of its own to
    /// clear. `ContentView.dismissHiddenImportsError()` is the same
    /// `hiddenImportsErrorMessage = nil` `refreshImportedHosts()`'s success
    /// path already performs on the next successful read.
    let onDismissHiddenImportsError: () -> Void
    /// Compact sidebar mode (sidebar-polish plan, Task 2) —
    /// `SettingsStore.sidebarCompact`, read by `ContentView` and handed
    /// over as a plain fact, same pattern as `showsTagFilterBar` right
    /// below: nothing in this file has to know a settings layer exists.
    /// Forwarded to each `SessionRow` as `isCompact`; changes row padding
    /// and the protocol badge's visibility only — no ordering, no
    /// selection behaviour, no keyboard handling. The default (non-compact)
    /// row is unchanged from what it was before this setting existed —
    /// see `SessionRow.isCompact`'s own doc comment.
    let sidebarCompact: Bool
    /// Whether the tag FILTER is offered at all (E1) —
    /// `SettingsStore.sidebarTagFilterEnabled`, read by `ContentView` and
    /// handed over as a plain fact so nothing in this file has to know a
    /// settings layer exists.
    ///
    /// It hides the filter, never the tags: a session's tags stay assignable
    /// and visible while it is edited, so switching this off gives up a way
    /// of narrowing the list and nothing else. Switching it off also clears
    /// whatever was selected — see the `onChange` in `body`.
    let showsTagFilterBar: Bool

    /// Not persisted — resets to "all expanded" on relaunch.
    ///
    /// Read and written through `SidebarFolderDisclosure` and nowhere else:
    /// while a search narrows the tree it is neither consulted (every folder
    /// draws open) nor changed, so the folders the user closed are closed
    /// again the moment the field is empty. A search overlays this set; it
    /// never rewrites it.
    @State private var collapsedGroups: Set<UUID> = []

    /// The sidebar's search (D3), and the regex switch `SheetSearchField`
    /// brings with it. View state for the same reason `tagFilter` below is:
    /// a query is not a setting, so it starts empty on every relaunch.
    ///
    /// Compiled into a predicate in `body` through the same
    /// `sheetSearchPredicate` every other search surface in this app uses —
    /// which is also where an invalid regular expression becomes a
    /// matches-everything predicate plus an error text, so a half-typed
    /// pattern says so instead of emptying the list.
    @State private var searchText: String = ""
    @State private var searchIsRegex = false

    /// The sidebar's host-tag filter (P3a/T6, a set of tags plus a join
    /// since E2): empty means "show everything".
    /// A VIEW, not a setting — deliberately not persisted and not routed
    /// through `SettingsStore`, so it always starts cleared on relaunch and
    /// never desyncs from whatever the store's sessions/tags currently are.
    /// The SETTING beside it (`showsTagFilterBar`) says whether the filter is
    /// offered at all; what is selected is never stored.
    /// Fed to `SidebarVisibility.compute(tagFilter:)` below, the ONE place
    /// this value is interpreted; nothing else in this file re-derives what
    /// it means.
    @State private var tagFilter: SidebarTagFilter = .none

    /// Which session row the sidebar's selection sits on — the row a double
    /// click or Return connects, and the only thing a single click changes.
    ///
    /// View state, like `tagFilter`, and for the same reason: a
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

    /// The sidebar's shared note of which row a drag is carrying — written
    /// by each row's own drag payload, read when a drop is targeted on
    /// another. See `SidebarDragOrigin` for why it is a box rather than
    /// state, and for what it is worth.
    @State private var dragOrigin = SidebarDragOrigin()

    @State private var sessionPendingDelete: StoredSession?
    /// Red inline message after a delete whose jump-restoration pass
    /// (M11a/T3) hit a keychain failure — same pattern as
    /// `LoginSetsSheet.deleteErrorMessage`.
    @State private var jumpRestoreErrorMessage: String?

    var body: some View {
        // The ONE place this decides what the sidebar shows (P3a/T6) — every
        // section, row list, imported-section gate, and empty state below
        // reads from `visibility`; nothing else in this file re-derives any
        // part of that decision from `session.tags` or `tagFilter` directly.
        // See `SidebarVisibility.compute`'s own doc comment for the rules.
        //
        // The search is compiled once here, next to the one decision it feeds
        // — never per row — and the tag filter and the query go into the SAME
        // call, because typing searches within what the tag filter left.
        let (searchPredicate, searchError) = sheetSearchPredicate(
            text: searchText, isRegex: searchIsRegex)
        let visibility = SidebarVisibility.compute(
            sessions: viewModel.sessions,
            groups: viewModel.groups,
            importedHostsCount: importedHosts.count,
            tagFilter: tagFilter,
            search: searchPredicate)
        // Not part of `visibility`: whether the filter ROW itself draws at
        // all is a separate question from what the row's chips filter —
        // `SidebarVisibility.compute` has no opinion on the row's own
        // visibility, only on what an already-chosen `tagFilter` does to the
        // session list. Which of its two drawings the row uses is not decided
        // here either; `SidebarTagFilterBar` asks Core.
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
                // The one place a row can be sent back to the top level:
                // dropping it on the sidebar's own title. A folder that fills
                // the whole list would otherwise leave nothing outside itself
                // to drop onto.
                .dropDestination(for: String.self) { payload, _ in
                    drop(payload, intoGroup: nil)
                }

            // An empty store has nothing to search, and this project shows
            // only what is possible. The gate reads the STORE, not what
            // survived the filter, so the field never disappears under the
            // user mid-query.
            if !viewModel.sessions.isEmpty {
                SheetSearchField(
                    text: $searchText, isRegex: $searchIsRegex, errorText: searchError)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            // Two gates, and they say different things. `showsTagFilterBar`
            // is the user's own (E1): they do not want to filter by tag, so
            // the control is gone — the tags themselves are untouched and
            // stay assignable in the connection form. The second is the same
            // "show only what is possible" rule the search field above obeys:
            // no session carries any tag, so an empty chip row would be a
            // frame drawn over nothing.
            if showsTagFilterBar, !availableTags.isEmpty {
                SidebarTagFilterBar(tags: availableTags, filter: $tagFilter)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            List {
                Button(action: startNewConnection) {
                    Label(L10n.string("sidebar.newConnection", "New connection"), systemImage: "plus")
                }
                .buttonStyle(.plain)

                switch visibility.emptiness {
                case .notEmpty:
                    rows(under: nil, visibility: visibility)

                    if visibility.showsImportedSection {
                        importedSection
                    }
                case .noSessionsAtAll:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noSessions", "No saved connections yet."),
                        showsClearFilter: false)
                case .filterMatchesNothing:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noMatches", "No connection matches the filter."),
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
                if let newValue {
                    selectedSessionID = newValue
                    // The report follows the selection here too: this is the
                    // one path that moves it without going through
                    // `moveSelection(to:)`, and a detail pane left on the
                    // previous row's overview while the highlight sits on
                    // another is precisely the drift this branch exists to
                    // repair.
                    onSelectSession(newValue)
                }
            }
            .onChange(of: viewModel.sessions) { _, sessions in
                // A selected tag's last carrier was deleted, or retagged
                // away from it: drop that tag rather than hold a selection
                // nothing can ever match again. The join is kept — losing a
                // tag is not a reason to forget how the rest are joined.
                tagFilter = tagFilter.resolved(in: sessions)
            }
            .onChange(of: showsTagFilterBar) { _, isShown in
                // The filter bar was switched off (E1): clear what it had
                // selected. Otherwise the sidebar would go on filtering with
                // its control gone, and a list narrowed by something
                // invisible cannot be told apart from a list that lost
                // entries.
                if !isShown { tagFilter = tagFilter.cleared() }
            }

            groupMoveErrorBanner

            jumpRestoreErrorBanner

            hiddenImportsErrorBanner
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

    // MARK: - Error banners

    /// How long a dismissible red caption in this sidebar stays before it
    /// clears itself (dev-build follow-up, 2026-09-03: the maintainer saw
    /// `core.session.groupMoveCycle` sit on screen with nothing to close
    /// it). Six seconds is long enough to read a sentence, short enough that
    /// a resolved refusal does not linger. Named so
    /// `SessionSidebarErrorGuardTests` can read it from the source instead
    /// of pinning a repeated literal.
    private static let errorAutoDismissDelay: Duration = .seconds(6)

    /// The body every one of this sidebar's three dismissible red captions
    /// shares (`groupMoveErrorBanner`, `jumpRestoreErrorBanner`,
    /// `hiddenImportsErrorBanner` below) — pulled out after two review
    /// rounds (`ece5aaf9`, `c4558e9b`) flagged the three near-identical
    /// `HStack`/close-button/`.task(id:)` bodies as a follow-up. Each of the
    /// three calls this once, passing its own message and its own way of
    /// clearing it: `viewModel.dismissError()`, a direct `@State` write, or
    /// `onDismissHiddenImportsError()` — only the first is backed by a class
    /// the others can reach directly.
    ///
    /// The close button calls `onDismiss()` directly, and `.task(id:
    /// message)` restarts the six-second countdown every time the caller's
    /// message itself changes — a new refusal after an old one was
    /// dismissed gets its own full six seconds, since SwiftUI cancels and
    /// re-runs a `.task(id:)` whose id changed. The countdown is cancelled,
    /// and so never fires, whenever the calling banner stops calling this at
    /// all — including the moment its own message becomes `nil`, since that
    /// is exactly when its `if let` stops drawing it.
    @ViewBuilder
    private func sidebarErrorBanner(
        message: String, onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
            .accessibilityLabel(L10n.string("sidebar.error.dismiss", "Dismiss"))
        }
        .padding(8)
        .task(id: message) {
            do {
                try await Task.sleep(for: Self.errorAutoDismissDelay)
                onDismiss()
            } catch {
                // Cancelled by a message change or the view going away —
                // either way, not this task's job to clear anything.
            }
        }
    }

    /// `viewModel.errorMessage` (`core.session.groupMoveCycle` and the other
    /// `SessionListViewModel` failures) through the shared
    /// `sidebarErrorBanner(message:onDismiss:)` above — dismissal goes
    /// straight to `viewModel.dismissError()`, the one call that actually
    /// clears this particular message.
    @ViewBuilder
    private var groupMoveErrorBanner: some View {
        if let errorMessage = viewModel.errorMessage {
            sidebarErrorBanner(message: errorMessage) {
                viewModel.dismissError()
            }
        }
    }

    /// Same shared treatment as `groupMoveErrorBanner`, for the partial
    /// keychain-restore notice set at `sessionPendingDelete` above
    /// (M11a/T3) — local `@State`, so dismissal writes
    /// `jumpRestoreErrorMessage` directly rather than going through the view
    /// model.
    @ViewBuilder
    private var jumpRestoreErrorBanner: some View {
        if let jumpRestoreErrorMessage {
            sidebarErrorBanner(message: jumpRestoreErrorMessage) {
                self.jumpRestoreErrorMessage = nil
            }
        }
    }

    /// Same shared treatment as the two banners above, for
    /// `hiddenImportsErrorMessage` (dev-build follow-up, 2026-09-03) — the
    /// one caption `ece5aaf9` left open. Unlike `jumpRestoreErrorBanner`,
    /// there is no local `@State` to write: `hiddenImportsErrorMessage`
    /// reaches this view as a plain `let` from `ContentView`, so dismissal
    /// goes through `onDismissHiddenImportsError()` instead.
    @ViewBuilder
    private var hiddenImportsErrorBanner: some View {
        if let hiddenImportsErrorMessage {
            sidebarErrorBanner(message: hiddenImportsErrorMessage) {
                onDismissHiddenImportsError()
            }
        }
    }

    // MARK: - Row builders

    /// The rows directly under one folder (`nil` = the top level), in the
    /// order `visibility` hands them over — and, for a folder, its own rows
    /// below it by asking again.
    ///
    /// The recursion is what makes the depth arbitrary; `AnyView` is what
    /// makes the recursion compile, since a `View` whose body contains itself
    /// has an infinite type and one link in the chain has to be erased. A
    /// sidebar is a handful of rows, which is the size at which that cost is
    /// cheaper than a second data structure built to avoid it.
    ///
    /// Both lookups (`session(_:)`, `group(_:)`) answer from the same
    /// filtered snapshot `children(of:)` walks, so a row named here always
    /// resolves; the `if let` is what happens to nothing rather than a case
    /// with a meaning.
    private func rows(under parentID: UUID?, visibility: SidebarVisibility) -> AnyView {
        AnyView(
            ForEach(visibility.children(of: parentID)) { item in
                switch item {
                case .session(let id):
                    if let session = visibility.session(id) {
                        sessionRow(session)
                    }
                case .group(let id):
                    if let group = visibility.group(id) {
                        DisclosureGroup(
                            isExpanded: expansion(
                                of: group.id, expandsFolders: visibility.expandsFolders)
                        ) {
                            rows(under: group.id, visibility: visibility)
                        } label: {
                            groupRow(group)
                        }
                    }
                }
            }
        )
    }

    /// Whether one folder is open. Not persisted — every folder starts open
    /// again on relaunch, the same as before folders could nest.
    ///
    /// Both halves are `SidebarFolderDisclosure`'s answer, not this view's:
    /// what the folder draws as, and what the triangle writes — including
    /// the case where it writes nothing at all, which is what keeps a search
    /// from rearranging the user's folders behind their back. `nil` back
    /// from `collapsed(_:setting:open:expandsFolders:)` is "do not write",
    /// and this is the only writer of `collapsedGroups` there is.
    private func expansion(of groupID: UUID, expandsFolders: Bool) -> Binding<Bool> {
        Binding(
            get: {
                SidebarFolderDisclosure.isOpen(
                    groupID, collapsed: collapsedGroups, expandsFolders: expandsFolders)
            },
            set: { open in
                if let updated = SidebarFolderDisclosure.collapsed(
                    collapsedGroups, setting: groupID, open: open,
                    expandsFolders: expandsFolders)
                {
                    collapsedGroups = updated
                }
            })
    }

    @ViewBuilder
    private func groupRow(_ group: StoredGroup) -> some View {
        SidebarGroupRow(
            group: group,
            isRenaming: renamingID == group.id,
            renameDraft: $renameDraft,
            focusedRenameID: $focusedRenameID,
            dragOrigin: dragOrigin,
            // The REAL children, not the ones a tag filter left on screen:
            // the sort rewrites the whole folder, so a folder showing one row
            // while holding three has something to sort. What the count means
            // is `SidebarSortMenuPlan`'s answer, not this line's.
            sortPlan: SidebarSortMenuPlan.build(childCount: viewModel.children(of: group.id).count),
            onStartRename: { startRename(id: group.id, currentName: group.name) },
            onCommitRename: { commitGroupRename(group) },
            onCancelRename: endRename,
            onExport: { onExport(.group(group)) },
            onSortByName: { viewModel.sortChildrenByName(of: group.id) },
            onDissolve: { viewModel.dissolveGroup(group) },
            onDrop: { payload in drop(payload, intoGroup: group.id) })
    }

    @ViewBuilder
    private func sessionRow(_ session: StoredSession) -> some View {
        SessionRow(
            session: session,
            isActive: session.id == activeSessionID,
            isSelected: session.id == selectedSessionID,
            isRenaming: renamingID == session.id,
            renameDraft: $renameDraft,
            focusedRenameID: $focusedRenameID,
            focusedRowID: $focusedRowID,
            groups: viewModel.groups,
            isCompact: sidebarCompact,
            // Handed over as the activation method itself, not wrapped
            // in a closure: a closure here would be a second place
            // where an input could be swapped for another on its way
            // to the plan, and review round 2 planted exactly that.
            onInput: activate(_:on:),
            onEdit: { onEdit(session) },
            onStartRename: { startRename(id: session.id, currentName: session.name) },
            onCommitRename: { commitSessionRename(session) },
            onCancelRename: endRename,
            // The same call a drop onto a folder makes, so the menu and
            // the gesture put a connection in the same place — at the end
            // of that folder, with the ranks rewritten. The plain field
            // write (`moveSession`) leaves the connection's old rank
            // behind, which reads as an arbitrary place in its new folder.
            onMove: { groupID in viewModel.move(.session(session.id), intoGroup: groupID) },
            onRequestNewGroupMove: { beginNewGroup(forMoving: session) },
            onDuplicate: { duplicate(session) },
            onRequestDelete: { sessionPendingDelete = session },
            onExport: { onExport(.single(session)) },
            onShowAuditLog: { onShowAuditLog(session) },
            onDiagnose: { onDiagnose(session) },
            dragOrigin: dragOrigin,
            onDrop: { payload in drop(payload, before: .session(session.id)) },
            snippets: snippets,
            onRunSnippet: onRunSnippet
        )
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
                .onTapGesture(count: 1) { selectImported(host) }
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
    ///
    /// One button clears BOTH narrowings, which is why its message names
    /// neither: the tag and the query can be on at once, and an invitation
    /// that cleared only one of them would leave the list just as empty.
    @ViewBuilder
    private func emptyStateRow(message: String, showsClearFilter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
            if showsClearFilter {
                Button(L10n.string("sidebar.empty.clearFilter", "Show all")) {
                    tagFilter = tagFilter.cleared()
                    searchText = ""
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
        Button(L10n.string("sidebar.newConnection", "New connection")) { startNewConnection() }
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

    /// Stores a copy of one connection and points at it.
    ///
    /// Two lines, and neither of them decides anything: what the copy
    /// carries — and, the half worth naming, that it reaches no Keychain
    /// slot of the template's — is `SessionDuplication`'s answer, asked
    /// through the view model. Nothing here derives a name, a group or an
    /// identifier, for the reason this file already gives about places:
    /// a rule spelled in a menu body is one no test reaches.
    ///
    /// The selection move is what makes the entry worth having: a copy
    /// written without being pointed at is a row the user has to go find
    /// among the others. It goes through `moveSelection(to:)` so the
    /// keyboard follows the highlight, like every other selection write in
    /// this file.
    private func duplicate(_ session: StoredSession) {
        guard let copy = viewModel.duplicateSession(session) else { return }
        moveSelection(to: copy)
    }

    /// "New connection", from either of the two entries that offer it.
    ///
    /// Clears the selection BEFORE forwarding, so the highlight and the
    /// detail pane agree: the window is about to show an empty form, and a
    /// stored session left highlighted behind it would name a session that
    /// form is not about. The keyboard focus is deliberately left where it
    /// is — `focusedRowID` is SwiftUI's as much as this view's, and taking it
    /// off a row is not this entry's business.
    private func startNewConnection() {
        selectedSessionID = nil
        onSelectSession(nil)
        onNew()
    }

    /// An entry from `~/.ssh/config`: fills the form, and is therefore the
    /// same kind of statement "New connection" is — the detail pane stops
    /// being about a stored session. Same clearing, same reason.
    private func selectImported(_ host: SSHConfigHost) {
        selectedSessionID = nil
        onSelectSession(nil)
        onSelectImported(host)
    }

    /// Puts the sidebar's selection, and the keyboard with it, on one row.
    /// The two move together everywhere: a highlight the keyboard cannot
    /// reach is the "selection no key acts on" this task exists to avoid.
    private func moveSelection(to session: StoredSession) {
        selectedSessionID = session.id
        focusedRowID = session.id
        onSelectSession(session.id)
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
            viewModel.move(.session(session.id), intoGroup: group.id)
        }
    }

    // MARK: - Drag & drop

    /// A row was let go on a folder, or on the sidebar's own title: it goes
    /// inside, after whatever is already there.
    ///
    /// Both halves of the gesture are identities — which row was picked up,
    /// which folder it was let go on — and the place it ends up in is derived
    /// by `SidebarOrdering` in the same instant it is used. A payload naming
    /// no row of this sidebar (a tab dragged out of the strip, a text
    /// clipping) ends the gesture; so does a refusal, and a refusal the user
    /// can provoke on purpose — a folder into its own sub-folder — already
    /// says so on screen through `viewModel.errorMessage`, so nothing is
    /// reported a second time here.
    private func drop(_ payload: [String], intoGroup parentID: UUID?) -> Bool {
        guard let item = SidebarDragPayload.item(from: payload) else { return false }
        return viewModel.move(item, intoGroup: parentID) == nil
    }

    /// A row was let go on a connection: it takes that connection's place
    /// among its siblings, adopting its folder. Same rules as the other
    /// half of the gesture above.
    private func drop(_ payload: [String], before target: SidebarItem) -> Bool {
        guard let item = SidebarDragPayload.item(from: payload) else { return false }
        return viewModel.move(item, before: target) == nil
    }
}

/// One folder row: its name (or the inline rename field), its drag payload,
/// its drop target, and its context menu.
///
/// A view of its own rather than a `@ViewBuilder` on the sidebar because it
/// owns one piece of state per folder — whether a drag is over THIS row —
/// which a shared builder has nowhere to put.
///
/// It renders what it is handed and decides nothing: the highlight is
/// `SidebarDropTargetPlan`'s answer, whether the sort entry appears is
/// `SidebarSortMenuPlan`'s, and where a dropped row lands is decided behind
/// `onDrop`, in Core.
private struct SidebarGroupRow: View {
    let group: StoredGroup
    let isRenaming: Bool
    @Binding var renameDraft: String
    var focusedRenameID: FocusState<UUID?>.Binding
    /// The sidebar's shared note of which row a drag is carrying — written
    /// by this row's own payload, read when a drop is targeted here.
    let dragOrigin: SidebarDragOrigin
    let sortPlan: SidebarSortMenuPlan
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onExport: () -> Void
    let onSortByName: () -> Void
    let onDissolve: () -> Void
    let onDrop: ([String]) -> Bool

    /// Whether a drag is over this row right now — the raw answer of the
    /// drop's `isTargeted:` closure, kept raw so that what it MEANS is
    /// `SidebarDropTargetPlan`'s to say.
    @State private var isDropTargeted = false

    private var dropPlan: SidebarDropTargetPlan {
        SidebarDropTargetPlan.build(
            row: .group(group.id), isTargeted: isDropTargeted,
            dragged: dragOrigin.draggedItem)
    }

    var body: some View {
        HStack {
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused(focusedRenameID, equals: group.id)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                // Display-only uppercase (spec: folder labels are versal);
                // the stored group name keeps its original casing.
                Text(group.name)
                    .textCase(.uppercase)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        // Both the surface and the border are `SidebarDropTargetPlan`'s
        // answer, drawn without a condition of this view's own: the answer
        // for "nothing is over this row" is a clear fill and a clear border,
        // so there is nothing to switch on here.
        .background(RoundedRectangle(cornerRadius: 6).fill(dropPlan.fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropPlan.borderColor, lineWidth: 2))
        .contentShape(Rectangle())
        .draggable(dragPayload())
        .dropDestination(for: String.self) { payload, _ in
            onDrop(payload)
        } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button(L10n.string("sidebar.rename", "Rename")) { onStartRename() }
            Button(L10n.string("export.menu.group", "Export Group…")) { onExport() }
            // Offered only where it can do something — see
            // `SidebarSortMenuPlan`; this project hides what cannot act
            // rather than greying it out.
            if sortPlan.isShown {
                Button(L10n.string("sidebar.group.sortByName", "Sort by Name")) { onSortByName() }
            }
            Button(L10n.string("sidebar.group.dissolve", "Dissolve group")) { onDissolve() }
        }
    }

    /// The payload a drag of this row carries — and the one moment the
    /// sidebar can learn WHICH row is being carried, because a drop
    /// destination is told only that something is over it.
    ///
    /// `draggable(_:)` takes its payload as an `@autoclosure @escaping`
    /// closure, so this runs when a drag begins rather than when the body is
    /// built. What happens if that ever stops holding is `SidebarDragOrigin`'s
    /// doc comment, and it is the reason that type has the shape it has.
    private func dragPayload() -> String {
        dragOrigin.draggedItem = .group(group.id)
        return SidebarDragPayload.text(for: .group(group.id))
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
    /// Compact sidebar mode (sidebar-polish plan, Task 2) — handed down as a
    /// plain fact the same way `SessionSidebar.showsTagFilterBar` is, so
    /// this row does not need to know a settings layer exists.
    ///
    /// Ruling on the fix round that reopened this task (coordinator,
    /// 2026-09-04): the DEFAULT (non-compact) row must not change at all —
    /// an earlier attempt drew `connectionSummary` as a second line
    /// whenever this was `false`, which changed what every user sees by
    /// default; that line is gone. `false` (the default) is the row
    /// exactly as it was before this setting existed: one line, the
    /// protocol badge shown, `.padding(.vertical, 5)`. `true` tightens
    /// that same one line to `.padding(.vertical, 2)` and hides the
    /// protocol badge — the row's only other secondary element once the
    /// subtitle attempt was reverted. No ordering, no selection behaviour,
    /// no keyboard handling changes either way —
    /// `onInput`/`SessionRowActivation` are untouched by this flag.
    let isCompact: Bool
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
    /// "Duplicate" — stores a copy of this connection and selects it.
    ///
    /// A plain callback rather than an input routed through `onInput`, and
    /// the rule for that split is what the entry DOES: duplicating writes a
    /// record and reaches no host, so a stray click costs an unused row
    /// rather than a login attempt on someone's server. Same category as
    /// `onEdit`, `onExport` and `onRequestDelete`.
    let onDuplicate: () -> Void
    let onRequestDelete: () -> Void
    let onExport: () -> Void
    let onShowAuditLog: () -> Void
    let onDiagnose: () -> Void
    /// The sidebar's shared note of which row a drag is carrying — written
    /// by this row's own payload, read when a drop is targeted here.
    let dragOrigin: SidebarDragOrigin
    /// A row was let go on this one. What that does — it takes this row's
    /// place among its siblings — is decided in Core behind this closure;
    /// this row supplies neither a place nor a rule.
    let onDrop: ([String]) -> Bool
    let snippets: [Snippet]
    let onRunSnippet: (Snippet, Bool) -> Void

    @State private var isHovering = false
    /// Whether a drag is over this row right now — the raw answer of the
    /// drop's `isTargeted:` closure, kept raw so that what it MEANS is
    /// `SidebarDropTargetPlan`'s to say.
    @State private var isDropTargeted = false

    private var dropPlan: SidebarDropTargetPlan {
        SidebarDropTargetPlan.build(
            row: .session(session.id), isTargeted: isDropTargeted,
            dragged: dragOrigin.draggedItem)
    }

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
            // sidebar's own section headers above. Compact mode's one
            // secondary element to shed (sidebar-polish plan, Task 2 fix
            // round): the default row carries no other decoration to
            // gate, and the ruling that reopened this task is explicit
            // that the default row's appearance must not change at all —
            // so this is the ONE thing `isCompact` hides, never the
            // subtitle line the earlier attempt drew (that line is gone;
            // `connectionSummary` reaches the user only through
            // `.help(connectionSummary)` below, exactly as before this
            // task).
            if !isCompact {
                Text(kindBadgeLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.inkTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, isCompact ? 2 : 5)
        .padding(.horizontal, 10)
        // Two surfaces, stacked rather than chosen between: the drop
        // target's is drawn in front and is `Color.clear` whenever nothing
        // is over this row (`SidebarDropTargetPlan.none`), so no condition
        // here decides which of the two wins. The border is the second
        // channel, drawn unconditionally and clear for the same case.
        .background(RoundedRectangle(cornerRadius: 6).fill(dropPlan.fill))
        .background(RoundedRectangle(cornerRadius: 6).fill(highlightFill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropPlan.borderColor, lineWidth: 2))
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
        // Reordering by dragging, in two halves: this row carries its own
        // identity, and a row dropped on this one takes this one's place.
        // No position travels either way — see `SidebarDragPayload` for what
        // the payload says and `SidebarOrdering` for who derives the place.
        .draggable(dragPayload())
        .dropDestination(for: String.self) { payload, _ in
            onDrop(payload)
        } isTargeted: { isDropTargeted = $0 }
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
            // Directly under Rename, in the menu that also holds Delete —
            // where the design puts it, among the entries that act on the
            // stored record rather than on what it connects to. No gate: a
            // stored connection can always be copied, and this project hides
            // what cannot act instead of greying it out, so there is nothing
            // here to hide either.
            Button(L10n.string("sidebar.duplicate", "Duplicate")) { onDuplicate() }
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
            // Under the audit log, in the group of entries that ask
            // this connection a question rather than change it. No
            // gate: the panel opens for a connection that has never
            // been dialled — that is exactly the case it is for — and
            // opening it puts nothing on anyone's host.
            Button(L10n.string("diagnostics.menu", "Diagnose…")) { onDiagnose() }
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

    /// The payload a drag of this row carries — and the one moment the
    /// sidebar can learn WHICH row is being carried, because a drop
    /// destination is told only that something is over it. Same shape, and
    /// the same `@autoclosure` reasoning, as `SidebarGroupRow`'s.
    private func dragPayload() -> String {
        dragOrigin.draggedItem = .session(session.id)
        return SidebarDragPayload.text(for: .session(session.id))
    }
}
