import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// Write-only `FileDocument` wrapper for the audit log's plain-text export
/// (M9b/T3) — mirrors `SessionExportDocument`'s write-only contract
/// (`SessionExportImportSheets.swift`): the text is already assembled by the
/// time `fileExporter` is armed, and reading is never exercised.
struct AuditLogTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Per-session audit log viewer (M9b/T3) — opened from the sidebar's "Audit
/// Log…" context-menu entry, for any stored session, connected or not (it
/// reads straight from `store`, independent of any tab/connection). Loads
/// once on open; deliberately no live refresh while the sheet is up (spec
/// M9b §5/§7 — closing and reopening is enough, auto-refresh is an M9c
/// topic).
///
/// Each column is click-to-sort; the rules live in `AuditLogSorting`, which
/// also says why the log still opens newest-first, why the sort is applied
/// to the filter result, and why the chosen order is not remembered past
/// the sheet closing.
struct AuditLogSheet: BoundedView {
    /// The size `AuditLogSheet` bounds itself to, applied with `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .size(width: 640, height: 480)

    let session: StoredSession
    let store: AuditLogStore

    @Environment(\.dismiss) private var dismiss
    @State private var events: [AuditEvent] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var searchIsRegex = false
    @State private var sortOrder: [AuditEventComparator] = AuditLogSorting.defaultOrder
    @State private var isShowingClearConfirm = false
    @State private var isExporting = false
    @State private var exportDocument: AuditLogTextDocument?
    @State private var exportErrorMessage: String?

    /// Filter segments (spec M9b §1/§5): a single-selection dimension, not a
    /// cross-cut — "Errors" and "Transfers" are mutually exclusive choices
    /// here even though a failed transfer is both.
    /// Internal (not private) so the classification can be tested without
    /// drawing the sheet.
    enum Filter: CaseIterable {
        case all, transfers, fileOps, terminal, connection, errors

        /// The segment that lists `kind` besides All and Errors, or `nil`
        /// when no segment does.
        ///
        /// A `switch` over EVERY kind, with no catch-all arm: a kind added to
        /// `AuditEvent.Kind` does not compile until it is placed here, which is
        /// what `ConnectionHistory.rows` already demands of it. The segment
        /// filter used to end each of its four inner switches in a catch-all
        /// arm, and the four S3 bucket-settings kinds fell through them -- a
        /// COMPLIANCE retention, the one write macSCP makes that cannot be
        /// undone, was absent from the segment a user would open to find it.
        static func segment(of kind: AuditEvent.Kind) -> Filter? {
            switch kind {
            case .transferFinished, .transferFailed, .transferCancelled, .editUpload,
                .crossSessionTransfer:
                return .transfers
            // COORDINATOR RULING 19 (fix round 1b of Task 12), not a
            // requirement of the brief or a finding of the review: the four
            // S3 bucket-settings kinds are listed under File Ops. Reversible
            // in this one arm -- move the four names to another `return`.
            // That is the whole cost in the CODE; it is no longer the whole
            // cost: the user documentation (the audit log page in the
            // user-docs repository) says the four kinds are listed under
            // File Ops, so reversing this also costs a change to that page.
            // (That page is not read from this repository; the statement is
            // the coordinator's, 2026-10-22.)
            case .rename, .delete, .permissions, .newFolder, .newFile,
                .bucketCreated, .versioningChanged, .corsChanged, .objectLockChanged:
                return .fileOps
            case .snippetExecuted:
                return .terminal
            case .connected, .disconnected, .connectFailed:
                return .connection
            // Listed under no segment, as before: it shows under All and
            // Errors only. Spelled out here, not left to a catch-all, so that
            // this is a visible gap and not an accident of the switch.
            case .plaintextConfirmed:
                return nil
            }
        }

        func includes(_ event: AuditEvent) -> Bool {
            switch self {
            case .all:
                return true
            case .errors:
                return event.isError
            case .transfers, .fileOps, .terminal, .connection:
                return Self.segment(of: event.kind) == self
            }
        }
    }

    /// `dd.MM. HH:mm:ss`, local time zone (spec M9b §5) — `en_US_POSIX`
    /// pins the literal pattern so it renders identically regardless of the
    /// user's locale; `DateFormatter`'s default (nil) time zone already
    /// resolves to the system's local zone, which is what "local" means here.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM. HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private var filteredEvents: [AuditEvent] {
        let (predicate, _) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        return events.filter { filter.includes($0) && predicate.matches(searchString(for: $0)) }
    }

    /// What the table draws: the filter/search result in the user's chosen
    /// order, which starts out newest-first (spec M9b §5) — the order
    /// `store.events(for:)` hands over, reversed.
    private var sortedEvents: [AuditEvent] {
        AuditLogSorting.sorted(filteredEvents, using: sortOrder)
    }

    private var isUnfiltered: Bool {
        filter == .all && searchText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.name).font(.headline)

            // A menu, not `SegmentedChoice`. Measured 2026-10-18 by
            // `BoundedViewLayoutGuardTests`: these six labels as a segmented
            // picker held at its ideal need 874.0 pt in French and 901.0 pt in
            // Polish against `Self.bound`'s 640, past `MainWindowSizePlan.formSize`
            // as well, because a segmented control is as wide as ALL its labels
            // side by side. A pop-up button shows one label. `.fixedSize()`
            // keeps it uncompressible so a regression is measured rather than
            // squeezed.
            //
            // Not `RadioChoice`, the other control that answers this: a
            // radio group lists all six options and stacks them, so the sheet
            // would trade 874 pt of width for six rows of height above a log
            // that is the sheet's whole point. The picker is named after the
            // property it filters (the log's "Event" column), so assistive
            // technology announces what the control is for.
            Picker(L10n.string("audit.column.kind", "Event"), selection: $filter) {
                Text(L10n.string("audit.filter.all", "All")).tag(Filter.all)
                Text(L10n.string("audit.filter.transfers", "Transfers")).tag(Filter.transfers)
                Text(L10n.string("audit.filter.fileOps", "File Ops")).tag(Filter.fileOps)
                Text(L10n.string("audit.filter.terminal", "Terminal")).tag(Filter.terminal)
                Text(L10n.string("audit.filter.connection", "Connection")).tag(Filter.connection)
                Text(L10n.string("audit.filter.errors", "Errors")).tag(Filter.errors)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            let (_, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            // Genuinely empty (`events.isEmpty`, ignoring filter/search) gets
            // the "no entries yet" text; a non-empty log with zero rows
            // surviving the segment filter and/or search gets "no matches"
            // instead (M18/T2, same rule as `HiddenImportsSheet`).
            //
            // `KnownHostsSheet` followed this same two-way split until the
            // facet design (2026-08-29) gave it a second narrowing: with a
            // facet in play, "no matches" no longer says WHICH narrowing
            // emptied the list, so the three faceted sheets ask
            // `SheetNarrowing.emptiness` and draw `SheetListEmptyState`
            // instead. This sheet's segment filter is its own, older
            // mechanism and keeps the coarser sentence.
            if filteredEvents.isEmpty {
                Spacer(minLength: 0)
                Text(events.isEmpty
                    ? L10n.string("audit.empty", "No entries yet.")
                    : L10n.string("audit.noMatches", "No matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                Table(sortedEvents, sortOrder: $sortOrder) {
                    TableColumn(
                        L10n.string("audit.column.time", "Time"),
                        sortUsing: AuditEventComparator(key: .time)
                    ) { event in
                        rowText(Self.timeFormatter.string(from: event.timestamp), isError: event.isError)
                    }
                    .width(min: 100, ideal: 110, max: 130)
                    TableColumn(
                        L10n.string("audit.column.kind", "Event"),
                        sortUsing: AuditEventComparator(key: .kind)
                    ) { event in
                        rowText(AuditEventText.kindLabel(event.kind), isError: event.isError)
                    }
                    .width(min: 120, ideal: 150, max: 200)
                    TableColumn(
                        L10n.string("audit.column.detail", "Detail"),
                        sortUsing: AuditEventComparator(key: .detail)
                    ) { event in
                        // M9b/T4 review (finding 4): the error message was
                        // already in `errorMessage` (search and export both
                        // already include it), but the sheet's own detail
                        // cell silently dropped it — display only, no change
                        // to the stored event.
                        rowText(AuditEventText.detail(for: event), isError: event.isError, monospaced: true)
                    }
                }
            }

            if let exportErrorMessage {
                Text(exportErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("audit.clear", "Clear Log…"), role: .destructive) {
                    isShowingClearConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(events.isEmpty)
                Button(L10n.string("audit.export", "Export as Text…")) { performExport() }
                    .buttonStyle(.polished)
                    .disabled(filteredEvents.isEmpty)
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .onAppear { events = store.events(for: session.id) }
        .confirmationDialog(
            L10n.string("audit.clear.title", "Clear audit log?"),
            isPresented: $isShowingClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("audit.clear.confirm", "Clear"), role: .destructive) {
                store.clear(for: session.id)
                events = store.events(for: session.id)
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "audit.clear.message",
                "This removes every entry in this session's log. This cannot be undone."))
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "\(session.name) Audit Log"
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = String(
                    format: L10n.string("audit.export.error %@", "Could not write the export file: %@"),
                    String(describing: error))
            } else {
                exportErrorMessage = nil
            }
        }
    }

    @ViewBuilder
    private func rowText(_ text: String, isError: Bool, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
            .foregroundStyle(isError ? .red : (monospaced ? DesignTokens.inkSecondary : DesignTokens.ink))
    }

    private var footerText: String {
        let total = events.count
        if isUnfiltered {
            return String(format: L10n.string("audit.count %lld", "%lld entries"), total)
        }
        return String(
            format: L10n.string("audit.countFiltered %lld %lld", "%lld of %lld"),
            filteredEvents.count, total)
    }

    /// Mirrors exactly what the row renders (time + event kind + detail,
    /// the latter already including the error suffix) so a search matches
    /// whatever the user can actually see in the table (M18/T2 — same
    /// rationale as drawing the detail cell from `AuditEventText`, M9b/T4
    /// finding 4). Drawing, searching and sorting all read the row's text
    /// from `AuditEventText` for that reason.
    private func searchString(for event: AuditEvent) -> String {
        let kind = AuditEventText.kindLabel(event.kind)
        return "\(Self.timeFormatter.string(from: event.timestamp)) \(kind) \(AuditEventText.detail(for: event))"
    }

    /// Exports exactly what's currently on screen — filter and search
    /// applied, and in the order the table is showing, which is newest-first
    /// until the user clicks a header (spec M9b §5). One line per event,
    /// `[<ISO8601>] <KIND-rawValue> <detail>`, with an ` — error: <message>`
    /// suffix for error rows.
    private func performExport() {
        let lines = sortedEvents.map(exportLine)
        exportDocument = AuditLogTextDocument(text: lines.joined(separator: "\n"))
        isExporting = true
    }

    private func exportLine(_ event: AuditEvent) -> String {
        var line = "[\(Self.isoFormatter.string(from: event.timestamp))] \(event.kind.rawValue) \(event.detail)"
        if event.isError, let errorMessage = event.errorMessage {
            line += " — error: \(errorMessage)"
        }
        return line
    }
}
