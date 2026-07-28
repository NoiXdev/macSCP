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
struct AuditLogSheet: View {
    let session: StoredSession
    let store: AuditLogStore

    @Environment(\.dismiss) private var dismiss
    @State private var events: [AuditEvent] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isShowingClearConfirm = false
    @State private var isExporting = false
    @State private var exportDocument: AuditLogTextDocument?
    @State private var exportErrorMessage: String?

    /// Filter segments (spec M9b §1/§5): a single-selection dimension, not a
    /// cross-cut — "Errors" and "Transfers" are mutually exclusive choices
    /// here even though a failed transfer is both.
    private enum Filter: CaseIterable {
        case all, transfers, fileOps, connection, errors
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

    /// Newest first (spec M9b §5) — `store.events(for:)` returns
    /// chronological order.
    private var sortedEvents: [AuditEvent] {
        events.sorted { $0.timestamp > $1.timestamp }
    }

    private var filteredEvents: [AuditEvent] {
        sortedEvents.filter { matchesFilter($0) && matchesSearch($0) }
    }

    private var isUnfiltered: Bool {
        filter == .all && searchText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.name).font(.headline)

            Picker("", selection: $filter) {
                Text(L10n.string("audit.filter.all", "All")).tag(Filter.all)
                Text(L10n.string("audit.filter.transfers", "Transfers")).tag(Filter.transfers)
                Text(L10n.string("audit.filter.fileOps", "File Ops")).tag(Filter.fileOps)
                Text(L10n.string("audit.filter.connection", "Connection")).tag(Filter.connection)
                Text(L10n.string("audit.filter.errors", "Errors")).tag(Filter.errors)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(L10n.string("audit.search", "Search"), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredEvents.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string("audit.empty", "No entries yet."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                Table(filteredEvents) {
                    TableColumn(L10n.string("audit.column.time", "Time")) { event in
                        rowText(Self.timeFormatter.string(from: event.timestamp), isError: event.isError)
                    }
                    .width(min: 100, ideal: 110, max: 130)
                    TableColumn(L10n.string("audit.column.kind", "Event")) { event in
                        rowText(kindLabel(event.kind), isError: event.isError)
                    }
                    .width(min: 120, ideal: 150, max: 200)
                    TableColumn(L10n.string("audit.column.detail", "Detail")) { event in
                        rowText(event.detail, isError: event.isError, monospaced: true)
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
        .frame(width: 640, height: 480)
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
        let total = sortedEvents.count
        if isUnfiltered {
            return String(format: L10n.string("audit.count %lld", "%lld entries"), total)
        }
        return String(
            format: L10n.string("audit.countFiltered %lld %lld", "%lld of %lld"),
            filteredEvents.count, total)
    }

    private func matchesFilter(_ event: AuditEvent) -> Bool {
        switch filter {
        case .all:
            return true
        case .transfers:
            switch event.kind {
            case .transferFinished, .transferFailed, .transferCancelled, .editUpload,
                 .crossSessionTransfer:
                return true
            default:
                return false
            }
        case .fileOps:
            switch event.kind {
            case .rename, .delete, .permissions, .newFolder:
                return true
            default:
                return false
            }
        case .connection:
            switch event.kind {
            case .connected, .disconnected:
                return true
            default:
                return false
            }
        case .errors:
            return event.isError
        }
    }

    private func matchesSearch(_ event: AuditEvent) -> Bool {
        guard !searchText.isEmpty else { return true }
        if event.detail.localizedCaseInsensitiveContains(searchText) { return true }
        if let errorMessage = event.errorMessage,
            errorMessage.localizedCaseInsensitiveContains(searchText)
        {
            return true
        }
        return false
    }

    /// Kind labels are the only localized part of an event row — `detail`
    /// (and `errorMessage`) are finished English plain text and are always
    /// shown verbatim (spec M9b §1).
    private func kindLabel(_ kind: AuditEvent.Kind) -> String {
        L10n.string("audit.kind.\(kind.rawValue)", kind.rawValue)
    }

    /// Exports exactly what's currently on screen (filter + search applied,
    /// newest-first) — one line per event, `[<ISO8601>] <KIND-rawValue>
    /// <detail>`, with an ` — error: <message>` suffix for error rows (spec
    /// M9b §5).
    private func performExport() {
        let lines = filteredEvents.map(exportLine)
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
