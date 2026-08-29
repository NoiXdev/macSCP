import AppKit
import SwiftUI
import macSCPCore

/// Known-hosts management sheet (M10a/T2, mockup section 1): lists every
/// remembered TOFU host key (`KnownHostsStore.allKeys()`), with search over
/// host+fingerprint, an algorithm facet chained to that search (facet
/// design, 2026-08-29), multi-selection "Remove…" (forgets the host — the next
/// connect runs the normal TOFU prompt again, per `KnownHostsStore.remove`'s
/// doc comment) and single-selection fingerprint copy. Shape mirrors
/// `AuditLogSheet` (`Table` + caption footer + destructive
/// `confirmationDialog`) for consistency across the app's management sheets.
///
/// Server certificates used to live here too, as a second section appended
/// below (M21/T10). They now have their own overlay
/// (`ServerCertificatesSheet`, reachable from the Sessions menu): stacking
/// two unrelated tables in one 700 pt sheet left a large dead band between
/// them and squeezed the certificate table's five columns until the
/// fingerprint ran off the right edge. The two sheets are siblings now, the
/// way `LoginSetsSheet` and `HiddenImportsSheet` are.
///
/// `Table` with `Set<String>` selection (not `List`): the mockup's five
/// fixed columns (Host/Port/Key type/Fingerprint/Added) map directly onto
/// `TableColumn`s, and `Table` gives free multi-selection via
/// cmd/shift-click without any extra plumbing — a `List` would need its own
/// `EditButton`/selection-mode dance for the same behavior. Each column is
/// click-to-sort; the rules live in `KnownHostsSorting`, which also says
/// why the chosen order is not remembered past the sheet closing.
struct KnownHostsSheet: View {
    let store: KnownHostsStore

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [KnownHostRow] = []
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var searchIsRegex = false
    /// The algorithm quick filter (facet design, 2026-08-29). A view, not a
    /// setting: it starts cleared every time the sheet opens, so it can
    /// never name an algorithm no remembered host key carries any more.
    @State private var facet: SheetFacetFilter = .all
    @State private var sortOrder: [KnownHostComparator] = KnownHostsSorting.defaultOrder
    @State private var errorMessage: String?
    @State private var isShowingRemoveConfirm = false

    /// `dd.MM.yyyy` (spec) — `en_US_POSIX` pins the literal pattern so it
    /// renders identically regardless of the user's locale, same rationale
    /// as `AuditLogSheet.timeFormatter`.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    /// The search and the algorithm facet applied together — one call to the
    /// shared chaining (`SheetFacetFilter.narrowing`), so what the table
    /// draws, what the footer counts and what the empty state blames are
    /// three readings of the same pass rather than three filters.
    private var narrowing: SheetNarrowing<KnownHostRow> {
        let (predicate, _) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        return facet.narrowing(
            rows,
            search: predicate,
            searchText: { "\($0.key.host) \($0.key.fingerprintSHA256)" },
            facetValue: { Self.algorithmLabel($0.key.keyType) })
    }

    private var filteredRows: [KnownHostRow] { narrowing.visible }

    /// The algorithms this sheet's own rows carry — never a fixed list, so
    /// an algorithm nobody has remembered is not offered and a new one needs
    /// no edit here.
    private var facetValues: [String] {
        SheetFacetFilter.values(of: rows) { Self.algorithmLabel($0.key.keyType) }
    }

    /// What the table draws: the search result in the user's chosen order.
    private var sortedRows: [KnownHostRow] {
        KnownHostsSorting.sorted(filteredRows, using: sortOrder)
    }

    /// Both narrowings, not just the search. This read was `searchText
    /// .isEmpty` before the facet existed, which would have made the footer
    /// print a plain total while an algorithm filter was hiding rows.
    private var isUnfiltered: Bool { narrowing.isUnfiltered }

    private func clearNarrowings() {
        searchText = ""
        facet = .all
    }

    private var selectedRows: [KnownHostRow] {
        filteredRows.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("knownHosts.title", "Known Hosts")).font(.headline)

            let (_, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            SheetFacetPicker(
                values: facetValues,
                label: L10n.string("knownHosts.facet.algorithm", "Algorithm"),
                filter: $facet)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            // Only claim "no known hosts" when the list is GENUINELY empty
            // (final review): after a load error the empty table must not
            // suggest the store is empty — the red message above is the truth.
            // A non-empty `rows` with an empty `filteredRows` means a
            // narrowing matched nothing, and WHICH one is
            // `narrowing.emptiness`' answer rather than this view's (M18/T2,
            // extended by the facet design).
            if filteredRows.isEmpty && errorMessage == nil {
                Spacer(minLength: 0)
                SheetListEmptyState(
                    emptiness: narrowing.emptiness,
                    noRowsMessage: L10n.string("knownHosts.empty", "No known hosts yet."),
                    noSearchMatchesMessage: L10n.string("knownHosts.noMatches", "No matches."),
                    onShowAll: clearNarrowings)
                Spacer(minLength: 0)
            } else {
                Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(
                        L10n.string("knownHosts.column.host", "Host"),
                        sortUsing: KnownHostComparator(key: .host)
                    ) { row in
                        Text(row.key.host)
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn(
                        L10n.string("knownHosts.column.port", "Port"),
                        sortUsing: KnownHostComparator(key: .port)
                    ) { row in
                        Text(String(row.key.port))
                    }
                    .width(min: 50, ideal: 60, max: 70)
                    TableColumn(
                        L10n.string("knownHosts.column.keyType", "Key type"),
                        sortUsing: KnownHostComparator(key: .keyType)
                    ) { row in
                        keyTypeBadge(row.key.keyType)
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn(
                        L10n.string("knownHosts.column.fingerprint", "Fingerprint"),
                        sortUsing: KnownHostComparator(key: .fingerprint)
                    ) { row in
                        Text(row.key.fingerprintSHA256)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkSecondary)
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn(
                        L10n.string("knownHosts.column.added", "Added"),
                        sortUsing: KnownHostComparator(key: .added)
                    ) { row in
                        Text(dateText(row.key.addedAt))
                    }
                    .width(min: 90, ideal: 100, max: 120)
                }
            }

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("knownHosts.copyFingerprint", "Copy Fingerprint")) {
                    copyFingerprint()
                }
                .buttonStyle(.polished)
                .disabled(selectedRows.count != 1)
                Button(L10n.string("knownHosts.remove", "Remove…"), role: .destructive) {
                    isShowingRemoveConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(selectedRows.isEmpty)
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { load() }
        .confirmationDialog(
            L10n.string("knownHosts.remove.title", "Remove known host?"),
            isPresented: $isShowingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("knownHosts.remove.confirm", "Remove"), role: .destructive) {
                removeSelected()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
    }

    /// How a host key's algorithm is written wherever this sheet writes it —
    /// the badge and the facet both go through here, so the value the picker
    /// offers is character-for-character the value a row is matched on.
    static func algorithmLabel(_ keyType: String) -> String {
        keyType.uppercased()
    }

    @ViewBuilder
    private func keyTypeBadge(_ keyType: String) -> some View {
        Text(Self.algorithmLabel(keyType))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(DesignTokens.remoteBlue)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "\u{2014}" }
        return Self.dateFormatter.string(from: date)
    }

    private var footerText: String {
        let total = rows.count
        if isUnfiltered {
            return String(format: L10n.string("knownHosts.count %lld", "%lld hosts"), total)
        }
        return String(
            format: L10n.string("knownHosts.countFiltered %lld %lld", "%lld of %lld"),
            filteredRows.count, total)
    }

    private var removeConfirmMessage: String {
        if selectedRows.count > 1 {
            return String(
                format: L10n.string(
                    "knownHosts.remove.messageMany %lld",
                    "%lld hosts will be treated as unknown on the next connect (new trust prompts)."),
                selectedRows.count)
        }
        return L10n.string(
            "knownHosts.remove.message",
            "The host will be treated as unknown on the next connect (new trust prompt).")
    }

    private func load() {
        do {
            rows = try store.allKeys().map(KnownHostRow.init)
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = String(
                format: L10n.string("knownHosts.loadError %@", "Could not load known hosts: %@"),
                String(describing: error))
        }
    }

    /// Single-selection only (spec) — the button is disabled otherwise, this
    /// is just the belt-and-suspenders guard.
    private func copyFingerprint() {
        guard selectedRows.count == 1, let row = selectedRows.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.key.fingerprintSHA256, forType: .string)
    }

    /// Removes every selected row, then reloads and clears the selection
    /// (spec) — a partial failure mid-loop still reloads so the list stays
    /// consistent with what's actually left on disk. The remove error is
    /// captured SEPARATELY and re-applied after the reload (T2 review):
    /// `load()` clears `errorMessage` on its success path, and reading
    /// usually still works even when the write just failed — without this,
    /// a failed "forget this host" would silently show the row again with
    /// zero feedback.
    private func removeSelected() {
        var removeError: String?
        for row in selectedRows {
            do {
                try store.remove(host: row.key.host, port: row.key.port)
            } catch {
                removeError = String(
                    format: L10n.string("knownHosts.removeError %@", "Could not remove the host key: %@"),
                    String(describing: error))
            }
        }
        selection = []
        load()
        if let removeError {
            errorMessage = removeError
        }
    }
}
