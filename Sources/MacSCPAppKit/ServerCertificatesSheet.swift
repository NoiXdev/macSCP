import SwiftUI
import macSCPCore

/// Wraps a `TrustedCertificate` the same way `KnownHostRow` wraps a
/// `KnownHostKey` — host+port is its natural key too, matching
/// `TrustedCertificateStore.remove(host:port:)`.
private struct TrustedCertificateRow: Identifiable {
    let certificate: TrustedCertificate
    var id: String { "\(certificate.host):\(certificate.port)" }
}

/// Server-certificate management sheet: lists every remembered TOFU server
/// certificate (`TrustedCertificateStore.allCertificates()`), with search
/// over host+fingerprint and multi-selection "Remove…" (forgets the
/// certificate — the next connect runs the normal TOFU prompt again).
///
/// A deliberate sibling of `KnownHostsSheet`, not a section inside it. M21
/// appended this table below the host-key table and grew that sheet to 700 pt
/// to fit; the result was one overlay holding two unrelated trust lists, a
/// large dead band between them, and five certificate columns squeezed into a
/// 720 pt frame until the fingerprint ran off the right edge. The two lists
/// are the same KIND of decision for two different transports, but they are
/// never consulted together, so they get one overlay each — the relationship
/// `LoginSetsSheet` and `HiddenImportsSheet` already have.
///
/// Everything else mirrors `KnownHostsSheet` on purpose (title, its own
/// `SheetSearchField` with the regex toggle, `Table` with `Set<String>`
/// selection, inline error line, caption footer with count + destructive
/// Remove + prominent Close, `confirmationDialog`, `.padding(20)`), so the
/// two files read as a pair.
///
/// The `knownHosts.cert.*` L10n keys are inherited from M21 and kept as they
/// are: the strings are already translated into all four languages, and
/// renaming keys buys nothing a reader of this file needs.
struct ServerCertificatesSheet: View {
    /// Defaults to the directory every call site already uses — `ContentView`
    /// builds this sheet without arguments, and the parameter stays for tests
    /// and for a future window-scoped store.
    var store: TrustedCertificateStore = TrustedCertificateStore(
        directory: SessionStore.defaultDirectory)

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [TrustedCertificateRow] = []
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var searchIsRegex = false
    @State private var errorMessage: String?
    @State private var isShowingRemoveConfirm = false

    /// `dd.MM.yyyy`, `en_US_POSIX`-pinned so the literal pattern renders
    /// identically regardless of the user's locale — same rationale as
    /// `KnownHostsSheet.dateFormatter` and `AuditLogSheet.timeFormatter`.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private var filteredRows: [TrustedCertificateRow] {
        let (predicate, _) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        return rows.filter {
            predicate.matches("\($0.certificate.host) \($0.certificate.fingerprintSHA256)")
        }
    }

    private var isUnfiltered: Bool { searchText.isEmpty }

    private var selectedRows: [TrustedCertificateRow] {
        filteredRows.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("knownHosts.section.certificates", "Server certificates"))
                .font(.headline)

            let (_, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            // Only claim "no certificates" when the list is GENUINELY empty
            // (same rule as `KnownHostsSheet.load()`): after a load error the
            // empty table must not suggest the store is empty — the red
            // message above is the truth. A non-empty `rows` with an empty
            // `filteredRows` means the search matched nothing.
            if filteredRows.isEmpty && errorMessage == nil {
                Spacer(minLength: 0)
                Text(rows.isEmpty
                    ? L10n.string("knownHosts.cert.empty", "No trusted certificates yet.")
                    : L10n.string("knownHosts.cert.noMatches", "No matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                Table(filteredRows, selection: $selection) {
                    TableColumn(L10n.string("knownHosts.cert.column.host", "Host")) { row in
                        Text(row.certificate.host)
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn(L10n.string("knownHosts.cert.column.port", "Port")) { row in
                        Text(String(row.certificate.port))
                    }
                    .width(min: 50, ideal: 60, max: 70)
                    TableColumn(L10n.string("knownHosts.cert.column.subject", "Subject")) { row in
                        Text(row.certificate.subject)
                    }
                    .width(min: 120, ideal: 160)
                    // Widest column by a distance: a fingerprint is
                    // "SHA256:" plus 43 base64 characters (50 in all), which
                    // needs roughly 350 pt at 11.5 pt monospaced. The M21
                    // section gave it 220 pt inside a 720 pt sheet, which is
                    // why it ran off the edge.
                    TableColumn(L10n.string("knownHosts.cert.column.fingerprint", "Fingerprint")) { row in
                        Text(row.certificate.fingerprintSHA256)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkSecondary)
                    }
                    .width(min: 300, ideal: 360)
                    TableColumn(L10n.string("knownHosts.cert.column.expires", "Expires")) { row in
                        Text(dateText(row.certificate.notAfter))
                    }
                    .width(min: 90, ideal: 100, max: 120)
                }
            }

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("knownHosts.cert.remove", "Remove…"), role: .destructive) {
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
        // Wider than `KnownHostsSheet`'s 720 because this table's five
        // columns are wider ones: 900 minus the 20 pt padding on each side
        // leaves 860 pt of table, which is exactly the sum of the ideal
        // widths above (180 + 60 + 160 + 360 + 100). The height matches
        // `KnownHostsSheet` — the surrounding chrome (title, search field,
        // footer) is identical and the table fills whatever is left.
        .frame(width: 900, height: 460)
        .onAppear { load() }
        .confirmationDialog(
            L10n.string("knownHosts.cert.remove.title", "Remove trusted certificate?"),
            isPresented: $isShowingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("knownHosts.cert.remove.confirm", "Remove"), role: .destructive) {
                removeSelected()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "\u{2014}" }
        return Self.dateFormatter.string(from: date)
    }

    private var footerText: String {
        let total = rows.count
        if isUnfiltered {
            return String(
                format: L10n.string("knownHosts.cert.count %lld", "%lld certificates"), total)
        }
        return String(
            format: L10n.string("knownHosts.cert.countFiltered %lld %lld", "%lld of %lld"),
            filteredRows.count, total)
    }

    private var removeConfirmMessage: String {
        if selectedRows.count > 1 {
            return String(
                format: L10n.string(
                    "knownHosts.cert.remove.messageMany %lld",
                    "%lld certificates will be treated as unknown on the next connect (new trust prompts)."),
                selectedRows.count)
        }
        return L10n.string(
            "knownHosts.cert.remove.message",
            "The certificate will be treated as unknown on the next connect (new trust prompt).")
    }

    private func load() {
        do {
            rows = try store.allCertificates().map(TrustedCertificateRow.init)
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = String(
                format: L10n.string(
                    "knownHosts.cert.loadError %@", "Could not load trusted certificates: %@"),
                String(describing: error))
        }
    }

    /// Removes every selected row, then reloads and clears the selection. The
    /// remove error is captured SEPARATELY and re-applied after the reload
    /// (pattern: `KnownHostsSheet.removeSelected`): `load()` clears
    /// `errorMessage` on its success path, and reading usually still works
    /// even when the write just failed — without this, a failed "forget this
    /// certificate" would silently show the row again with zero feedback.
    private func removeSelected() {
        var removeError: String?
        for row in selectedRows {
            do {
                try store.remove(host: row.certificate.host, port: row.certificate.port)
            } catch {
                removeError = String(
                    format: L10n.string(
                        "knownHosts.cert.removeError %@", "Could not remove the certificate: %@"),
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
