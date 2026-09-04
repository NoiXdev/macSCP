import SwiftUI
import macSCPCore

/// The two names `SessionOverviewModel` renders but `StoredSession` does not
/// carry.
///
/// A session records a `groupID` and a `loginSetID`; the overview shows a
/// group and a login set by NAME, because a rendered UUID is worse than an
/// omitted row (Task 1's report). The lookup lives here, once, so the two
/// ids cannot be resolved one way at the detail pane and another way
/// somewhere else later.
///
/// An id that names nothing comes back as `nil`, never as the first entry of
/// the list: a group deleted out from under a session must drop the row, not
/// mislabel it. `SessionOverviewModel` omits a fact whose name is `nil` OR
/// empty, so both shapes of "no answer" reach the same place.
enum SessionOverviewNames {
    static func resolve(
        for session: StoredSession, groups: [StoredGroup], loginSets: [LoginSet]
    ) -> (group: String?, loginSet: String?) {
        (group: groups.first { $0.id == session.groupID }?.name,
         loginSet: loginSets.first { $0.id == session.loginSetID }?.name)
    }
}

/// The read-only overview of a stored session, shown in the detail area of a
/// not-yet-connected tab while the sidebar's selection names that session
/// (design: `docs/superpowers/specs/2026-09-04-session-overview-design.md`).
///
/// ## It shows; it does not decide
///
/// Everything on screen comes from `SessionOverviewModel`, a value built off
/// the main actor from the stored record, the known-hosts store, the audit
/// log and the snippet store. This view formats and lays out; it derives no
/// fact of its own. That is what keeps the interesting half — which facts a
/// backend shows, what a run of audit events means as a list of connections,
/// what is and is not a secret — reachable by `SessionOverviewModelTests`
/// and `ConnectionHistoryTests` in Core, where no view has to be rendered to
/// check it.
///
/// **No secret value can reach this file.** The model answers the credential
/// question as a `Bool?` (`hasStoredSecret`) through the `SecretPresence`
/// seam, which has no way of carrying a value, and the two URL-shaped fields
/// a user can type `scheme://KEY:SECRET@host` into are stripped in Core
/// before they become a fact. Nothing here reads a `SecretStore`.
///
/// ## The three actions are the window's, handed over as values
///
/// Connect, Edit and Diagnose add no fourth way to do any of the three: the
/// detail pane hands this view `connectFromSidebar`, `editStored` and
/// `showDiagnostics(for: .stored(…))`, the same entries the sidebar's own
/// row menu reaches, and `SessionOverviewWiringGuardTests` reads that wiring
/// rather than trusting this sentence.
///
/// Connect arrives as a `SessionRowConnectEffect`, not as a closure, and
/// this view cannot fire it directly: the effect's storage is `fileprivate`
/// to `SessionRowActivation.swift`, and the one function that runs one takes
/// an INPUT and picks the activation itself. See `SessionRowConnectEffect`'s
/// own doc comment for what that discipline does and does not buy — the
/// short version is that a one-token edit swapping Connect for another
/// effect stops compiling instead of shipping. Edit and Diagnose stay plain
/// callbacks under the same rule the sidebar applies to its own: neither
/// reaches the user's host (`showDiagnostics` opens a panel that measures
/// nothing until its own button is pressed, decision of 2026-09-02).
///
/// ## Responsive, because the pane is resizable
///
/// The head — name, kind badge, endpoint, the three actions — sits OUTSIDE
/// the `ScrollView`, so it is reachable at any window height; the facts, the
/// recent connections and the snippets scroll under it. The same split
/// `ConnectionFormView` got on 2026-09-04. Within it: the actions fall back
/// from one row to two, the facts grid from two columns to one, and the
/// recent-connections table drops its transfers column, each through its own
/// `ViewThatFits`; the snippets reflow through an adaptive `LazyVGrid`.
struct SessionOverviewView: View {
    let session: StoredSession
    /// Resolved by the window through `SessionOverviewNames` — see that
    /// type for why the model takes names rather than the ids the session
    /// carries.
    let groupName: String?
    let loginSetName: String?
    /// Named `onConnectSession` rather than `onConnect` for one reason,
    /// stated so the next reader does not "tidy" it: the sidebar's own
    /// hand-over of this same effect is pinned in `ContentView+Detail.swift`
    /// by `SessionRowActivationWiringTests`' Guard J, which requires exactly
    /// one line there spelling the sidebar's parameter label followed by the
    /// effect type — and finding `connectFromSidebar(` on it. A second
    /// surface taking a parameter of the SAME label in the same file would
    /// make that anchor ambiguous, and an ambiguous anchor on the one guard
    /// that keeps a stray click from dialling is not a trade worth making
    /// for a shorter name.
    let onConnectSession: SessionRowConnectEffect<StoredSession>
    let onEdit: (StoredSession) -> Void
    /// Both doors onto the diagnostics panel this view offers: the head's
    /// Diagnose control and a failed connection row's "Open diagnosis". One
    /// callback, because they are one door — the window's
    /// `showDiagnostics(for: .stored(…))`, reached with the same session.
    let onDiagnose: (StoredSession) -> Void
    /// A snippet card's "Run" (Task 3): connect, wait for this session's
    /// shell, then send. The window's `runSnippetAfterConnecting(_:on:)`,
    /// whose own dial is `connectFromSidebar` — the same entry
    /// `onConnectSession` above resolves to, so Run is not a second way onto
    /// the host but the existing one with something to do afterwards.
    ///
    /// A plain closure rather than a `SessionRowConnectEffect`, and the
    /// reason is what that discipline is for: it keeps a GESTURE whose
    /// meaning has to be inferred from turning into a dial. This is a button
    /// the user read the label of, its value is a `Snippet` and not a
    /// `StoredSession`, so it is not interchangeable with any of the effects
    /// or callbacks beside it by a one-token edit. What pins the far end is
    /// `SessionOverviewWiringGuardTests`, which reads both that this
    /// resolves to `runSnippetAfterConnecting` and that
    /// `runSnippetAfterConnecting`'s own body dials through nothing but
    /// `connectFromSidebar`.
    let onRunSnippet: (Snippet) -> Void

    /// `nil` until the stores have been read. The head draws immediately
    /// regardless; the sections below simply are not there yet, which is
    /// why none of them renders an "empty" sentence while `model` is `nil` —
    /// "No connections recorded yet." flashing before the log has been read
    /// would be a claim about a file nobody has opened.
    @State private var model: SessionOverviewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    factsSection
                    historySection
                    snippetsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keyed on the whole RECORD, not on its id: selecting another row
        // has to rebuild the model, and so does a change to the row already
        // selected — an inline rename or a save writes a new `StoredSession`
        // under the same id, and keying on the id alone would leave the
        // previous version's facts on screen. `StoredSession` is `Equatable`,
        // which is all `task(id:)` asks for, and the comparison runs only
        // when this view is re-evaluated.
        //
        // Everything the loader touches is disk or keychain, which is why it
        // is `nonisolated` and not a main-actor call — see
        // `load(session:groupName:loginSetName:)`.
        .task(id: session) {
            // Two lines that are not ceremony, both about the same window:
            // the one between a selection changing and its stores having
            // been read.
            //
            // The reset first, because `model` is `@State` and SwiftUI keeps
            // this view's identity across a selection change — without it,
            // session B's head (drawn straight from `session`) renders over
            // session A's facts, history and snippets, which is a page that
            // is wrong rather than a page that is incomplete. A blank body
            // under the right head is the honest in-between.
            //
            // The cancellation check second, because `load` is the slow half
            // and nothing else stops its result from arriving. `task(id:)`
            // cancels the previous body when the id changes, but a
            // cancelled task still RUNS to its next suspension and returns:
            // a keychain query started for selection N−1 can land after N's
            // has already been assigned, and the later write would lose to
            // the earlier one. Checking after the `await` is what makes the
            // last selection the one on screen.
            model = nil
            let loaded = await Self.load(
                session: session, groupName: groupName, loginSetName: loginSetName)
            guard !Task.isCancelled else { return }
            model = loaded
        }
    }

    // MARK: - The head (outside the scroll region)

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // "SSH"/"S3"/"WebDAV" through the backend descriptor, the
                // same way a sidebar row draws its badge — never picked
                // here, so a fourth backend needs a descriptor case and no
                // change at this site.
                Text(kindBadgeLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.inkTertiary)
                Spacer(minLength: 0)
            }

            // The model's, not re-derived here: the descriptor could answer
            // this synchronously, and a second computation of one fact is
            // the second copy this project's rules are about.
            if let endpoint = model?.endpointText, !endpoint.isEmpty {
                Text(endpoint)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    /// One row where the pane is wide enough, two where it is not — the
    /// fallback `DiagnosticsPanel`'s footer already uses, and for the same
    /// measured reason: below its natural width a `Button` wraps its title
    /// letter by letter rather than shrinking.
    ///
    /// Both layouts draw the SAME three control properties, so
    /// `.keyboardShortcut(.defaultAction)` appears exactly once in this file
    /// no matter which one `ViewThatFits` chooses.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectControl
                editControl
                diagnoseControl
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    connectControl
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    editControl
                    diagnoseControl
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var connectControl: some View {
        Button(L10n.string("connection.connect", "Connect")) { openConnection() }
            .buttonStyle(.polished)
            .keyboardShortcut(.defaultAction)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var editControl: some View {
        Button(L10n.string("sidebar.edit", "Edit…")) { onEdit(session) }
            .fixedSize(horizontal: true, vertical: false)
    }

    private var diagnoseControl: some View {
        Button(L10n.string("diagnostics.menu", "Diagnose…")) { onDiagnose(session) }
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The one place this view acts on the effect it holds.
    ///
    /// `.contextMenuEntry` is the input: the user did not make a gesture
    /// whose meaning has to be inferred, they read a button and pressed it —
    /// which is exactly what that case is for
    /// (`SessionRowInput.isMenuEntry`). The three other effect slots are
    /// no-ops constructed right here rather than parameters of this view, so
    /// this surface HOLDS no way to open a terminal, local or external, and
    /// `onSelect` has nothing to do: the overview is on screen because this
    /// row is already the selection.
    private func openConnection() {
        performSessionRowInput(
            .contextMenuEntry, on: session, isRenaming: false, isSelected: true,
            onSelect: SessionRowSelectEffect { _ in },
            onConnect: onConnectSession,
            onOpenTerminal: SessionRowTerminalEffect { _ in },
            onOpenExternalTerminal: SessionRowExternalTerminalEffect { _ in })
    }

    // MARK: - Facts

    /// One labelled line of the facts grid, after the App has resolved the
    /// model's label key out of its own catalogues.
    private struct Line: Identifiable {
        let id: String
        let label: String
        let text: String
        let isMonospaced: Bool
    }

    /// The model's facts plus the two answers it carries outside that list:
    /// what is known about the host key, and whether a secret is stored.
    ///
    /// Both are appended rather than emitted by Core because neither is a
    /// datum out of the stored record — one comes from the known-hosts
    /// store, the other from a keychain metadata query — and both have a
    /// state that means "there is nothing to say here", which drops the row
    /// instead of labelling a blank.
    private var lines: [Line] {
        guard let model else { return [] }
        var lines = model.facts.map {
            // A dynamic key, so the English source text cannot sit at this
            // call site the way `L10n.string("sidebar.edit", "Edit…")`'s
            // does; `en.lproj` holds it, and the id is the fallback if the
            // resource bundle cannot be found at all. Same shape as the
            // sidebar's own badge, which resolves
            // `descriptor.badgeLabelKey`.
            Line(id: $0.id, label: L10n.string($0.labelKey, $0.id), text: $0.text,
                 isMonospaced: $0.isMonospaced)
        }
        if let line = hostKeyLine(model.hostKey) { lines.append(line) }
        if let line = secretLine(model.hasStoredSecret) { lines.append(line) }
        return lines
    }

    /// `.notApplicable` yields no row at all: telling an S3 user their host
    /// key is unknown would be an answer to a question their protocol does
    /// not ask (`HostKeyStatus`' own doc comment).
    private func hostKeyLine(_ status: HostKeyStatus) -> Line? {
        let label = L10n.string("overview.hostKey", "Host key")
        switch status {
        case .known(let type, let fingerprint):
            return Line(id: "hostKey", label: label, text: "\(type) \(fingerprint)",
                        isMonospaced: true)
        case .unknown:
            return Line(
                id: "hostKey", label: label,
                text: L10n.string("overview.hostKey.unknown", "Not known yet — the next connect asks"),
                isMonospaced: false)
        case .notApplicable:
            return nil
        }
    }

    /// `nil` yields no row: a login that keeps its key in the ssh-agent
    /// stores nothing, and "no secret stored" would read there as a warning
    /// about a setup that is complete.
    private func secretLine(_ stored: Bool?) -> Line? {
        guard let stored else { return nil }
        return Line(
            id: "secret", label: L10n.string("overview.secret", "Password"),
            text: stored
                ? L10n.string("overview.secret.stored", "Saved in the keychain")
                : L10n.string("overview.secret.missing", "Not saved — asked at connect"),
            isMonospaced: false)
    }

    @ViewBuilder
    private var factsSection: some View {
        if model != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.string("overview.section.facts", "Details"))
                ViewThatFits(in: .horizontal) {
                    factsGrid(columns: 2)
                    factsGrid(columns: 1)
                }
            }
        }
    }

    /// The lines laid out `columns` at a time.
    ///
    /// Written once and called twice — `ViewThatFits` measures the
    /// two-column form first and falls through to the one-column form — so
    /// the cell itself, and everything it decides about type and selection,
    /// exists in exactly one place regardless of which one is drawn.
    ///
    /// A short last row is left short: `GridRow` fills the leading columns
    /// and leaves the rest empty, which is the wanted shape. There is no
    /// padding cell, and no row at all when there are no lines.
    private func factsGrid(columns: Int) -> some View {
        let all = lines
        let rows: [[Line]] = stride(from: 0, to: all.count, by: columns).map { start in
            Array(all[start..<min(start + columns, all.count)])
        }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { line in
                        factCell(line)
                    }
                }
            }
        }
    }

    private func factCell(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(line.label)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
            Text(line.text)
                .font(line.isMonospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(DesignTokens.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent connections

    @ViewBuilder
    private var historySection: some View {
        if let model {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.string("overview.section.history", "Recent connections"))
                if model.history.isEmpty {
                    Text(L10n.string("overview.history.empty", "Nothing recorded for this connection yet."))
                        .font(.callout)
                        .foregroundStyle(DesignTokens.inkTertiary)
                } else {
                    // The transfers column is what goes first when the pane
                    // narrows: it is a count beside an outcome, where the
                    // outcome is the sentence the row exists to say. The
                    // audit log remains the full record either way.
                    ViewThatFits(in: .horizontal) {
                        historyTable(model.history, showsTransfers: true)
                        historyTable(model.history, showsTransfers: false)
                    }
                }
            }
        }
    }

    private func historyTable(
        _ rows: [ConnectionHistory.Row], showsTransfers: Bool
    ) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                columnTitle(L10n.string("overview.history.column.started", "Started"))
                columnTitle(L10n.string("overview.history.column.outcome", "Outcome"))
                if showsTransfers {
                    columnTitle(L10n.string("overview.history.column.transfers", "Transfers"))
                }
                Color.clear.frame(height: 0)
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.inkSecondary)
                    outcomeCell(row.outcome)
                    if showsTransfers {
                        Text(transfersText(row))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                    // The failed row's own door onto the panel — the same
                    // `showDiagnostics(for: .stored(…))` the head's control
                    // reaches, with the same session.
                    if case .failed = row.outcome {
                        Button(L10n.string("overview.history.diagnose", "Open diagnosis")) {
                            onDiagnose(session)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeCell(_ outcome: ConnectionHistory.Row.Outcome) -> some View {
        switch outcome {
        case .connected(let duration):
            Text(
                duration.map(Self.durationText)
                    // No duration: the log carries a connect that was never
                    // closed — this session, or one the app did not shut
                    // down cleanly. "Still open" would be a claim about now
                    // that a finished log cannot support.
                    ?? L10n.string("overview.history.noEnd", "No disconnect recorded")
            )
            .font(.caption)
            .foregroundStyle(DesignTokens.inkSecondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(DesignTokens.statusLost)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func durationText(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    /// Uploads, downloads and failures as three counted symbols. Deliberately
    /// not a sentence with plurals: the three numbers are the point, and a
    /// symbol carries no plural category to get wrong in four languages.
    private func transfersText(_ row: ConnectionHistory.Row) -> String {
        String(
            format: L10n.string(
                "overview.history.transfers %1$lld %2$lld %3$lld", "↑%1$lld ↓%2$lld ✗%3$lld"),
            row.uploads, row.downloads, row.failedTransfers)
    }

    // MARK: - Snippets

    @ViewBuilder
    private var snippetsSection: some View {
        if let model {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.string("overview.section.snippets", "Snippets"))
                if model.snippets.isEmpty {
                    Text(L10n.string("overview.snippets.empty", "No snippets saved yet."))
                        .font(.callout)
                        .foregroundStyle(DesignTokens.inkTertiary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260))], alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(model.snippets) { snippet in
                            snippetCard(snippet)
                        }
                    }
                }
            }
        }
    }

    /// Run hands the snippet to the window and does nothing else (Task 3).
    /// Connecting, waiting for this session's shell, the variable prompt for
    /// a snippet that declares any, and the send itself all happen out
    /// there — see `onRunSnippet`. The card was shipped in Task 2 with this
    /// control drawn and disabled, so the layout it had to fit into was
    /// settled before the behaviour arrived; all that changed here is the
    /// action and the dropped `.disabled(true)`.
    private func snippetCard(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snippet.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(L10n.string("overview.snippets.run", "Run")) { onRunSnippet(snippet) }
                    .font(.caption)
            }
            Text(snippet.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignTokens.inkTertiary)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }

    // MARK: - Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignTokens.inkTertiary)
            .textCase(.uppercase)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignTokens.inkTertiary)
    }

    // MARK: - Loading

    /// Builds the model off the main actor.
    ///
    /// `nonisolated` and `async`, which under SE-0338 means it does NOT
    /// inherit the caller's actor: the three store reads and the keychain
    /// query below run on the cooperative pool while the main actor keeps
    /// drawing the head. Every one of them touches the disk (or, for the
    /// presence query, the keychain), and the keychain call is the one worth
    /// naming — a single click on a sidebar row must not be able to park the
    /// window on a Security framework call.
    ///
    /// A failed read is an empty answer rather than an error surface: an
    /// unreadable known-hosts file makes the host key "not known yet", an
    /// unreadable snippets file makes the snippet list empty, and
    /// `AuditLogStore.events(for:)` already answers a missing log with `[]`
    /// by contract. None of the three is a reason to refuse to describe a
    /// session, and the sheets that OWN those files (`KnownHostsSheet`,
    /// `SnippetsSheet`, `AuditLogSheet`) are where a broken one is reported.
    nonisolated static func load(
        session: StoredSession, groupName: String?, loginSetName: String?
    ) async -> SessionOverviewModel {
        let directory = SessionStore.defaultDirectory
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        // SSH only, and by the stored block rather than by `kind`: the
        // known-hosts store is keyed on the host and port this session
        // dials, and a record with no SSH block names neither.
        var knownKey: KnownHostKey?
        if let ssh = session.ssh {
            knownKey = try? KnownHostsStore(directory: directory)
                .find(host: ssh.host, port: ssh.port)
        }
        return SessionOverviewModel(
            session: session, descriptor: descriptor, knownKey: knownKey,
            secrets: KeychainSecretPresence(),
            events: AuditLogStore(directory: directory).events(for: session.id),
            snippets: (try? SnippetStore(directory: directory).all()) ?? [],
            groupName: groupName, loginSetName: loginSetName)
    }
}
