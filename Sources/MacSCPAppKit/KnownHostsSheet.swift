import AppKit
import SwiftUI
import macSCPCore

/// Wraps a `KnownHostKey` with a stable identity for `Table`/`List`
/// selection — `KnownHostKey` itself carries no id; host+port is its natural
/// key (the same pair `KnownHostsStore.remove(host:port:)` uses to identify
/// an entry).
private struct KnownHostRow: Identifiable {
    let key: KnownHostKey
    var id: String { "\(key.host):\(key.port)" }
}

/// Known-hosts management sheet (M10a/T2, mockup section 1): lists every
/// remembered TOFU host key (`KnownHostsStore.allKeys()`), with search over
/// host+fingerprint, multi-selection "Remove…" (forgets the host — the next
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
/// `EditButton`/selection-mode dance for the same behavior.
struct KnownHostsSheet: View {
    let store: KnownHostsStore

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [KnownHostRow] = []
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var searchIsRegex = false
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

    private var filteredRows: [KnownHostRow] {
        let (predicate, _) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        return rows.filter { predicate.matches("\($0.key.host) \($0.key.fingerprintSHA256)") }
    }

    private var isUnfiltered: Bool { searchText.isEmpty }

    private var selectedRows: [KnownHostRow] {
        filteredRows.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("knownHosts.title", "Known Hosts")).font(.headline)

            let (_, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            // Only claim "no known hosts" when the list is GENUINELY empty
            // (final review): after a load error the empty table must not
            // suggest the store is empty — the red message above is the truth.
            // A non-empty `rows` with an empty `filteredRows` means the
            // search matched nothing, not that the store is empty (M18/T2).
            if filteredRows.isEmpty && errorMessage == nil {
                Spacer(minLength: 0)
                Text(rows.isEmpty
                    ? L10n.string("knownHosts.empty", "No known hosts yet.")
                    : L10n.string("knownHosts.noMatches", "No matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                Table(filteredRows, selection: $selection) {
                    TableColumn(L10n.string("knownHosts.column.host", "Host")) { row in
                        Text(row.key.host)
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn(L10n.string("knownHosts.column.port", "Port")) { row in
                        Text(String(row.key.port))
                    }
                    .width(min: 50, ideal: 60, max: 70)
                    TableColumn(L10n.string("knownHosts.column.keyType", "Key type")) { row in
                        keyTypeBadge(row.key.keyType)
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn(L10n.string("knownHosts.column.fingerprint", "Fingerprint")) { row in
                        Text(row.key.fingerprintSHA256)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkSecondary)
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn(L10n.string("knownHosts.column.added", "Added")) { row in
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

    @ViewBuilder
    private func keyTypeBadge(_ keyType: String) -> some View {
        Text(keyType.uppercased())
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
