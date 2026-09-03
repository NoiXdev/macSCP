import Foundation
import Observation
import macSCPCore

/// The import-preview sheet's half of a third-party import (design §4):
/// what the source's folder holds, judged against this window's sessions,
/// plus the three decisions the sheet lets the user make before anything is
/// written.
///
/// **Nothing here reads a secret.** `takeSecrets` travels through to
/// `SessionExportPayload.includesSecrets`; the keychain items themselves are
/// read by the applier (`ContentView.applyExternalImport`) through
/// `CyberduckSecretReader`, at the moment the user presses Import, so the
/// macOS consent prompt belongs to that click rather than to a sheet opening.
///
/// **The folder is read once, by `load(source:folder:)`, before the sheet is
/// presented.** The sheet does no work when it appears — SwiftUI decides how
/// often that happens, and a folder read has nowhere to report a failure from
/// inside a view body. `ImportFromCyberduckGuardTests` holds both halves.
///
/// Window scope, not a singleton (CLAUDE.md, "Architecture invariants"): the
/// sessions and groups it plans against are the ones the window's
/// `SessionListViewModel` holds at the moment the sheet opens, taken as a
/// value the way `DiagnosticsTarget` takes its connection.
@MainActor
@Observable
final class ImportFromSourceViewModel: Identifiable {
    /// Fresh per presentation, so asking twice re-presents the sheet.
    let id = UUID()

    // MARK: - What was read

    /// The preview, in the order the source handed its bookmarks over.
    private(set) var rows: [PreviewRow] = []

    /// Set when the folder could not be listed at all (design §5). A folder
    /// that simply holds no bookmarks leaves this nil and `rows` empty —
    /// "nothing there" and "could not look" are different sentences, and the
    /// sheet says each of them.
    private(set) var loadError: String?

    /// The source's own id (`BookmarkSource.id`), written into every
    /// imported session's `importSource` by the planner.
    private(set) var sourceID = ""

    /// The source's human-readable name, resolved through the catalog key
    /// the source declares. Used for the sheet's title and as the default
    /// group name — which is why it is resolved here rather than in the
    /// view: a group name is a value that gets written, not a label.
    private(set) var sourceName = ""

    // MARK: - What the user decided

    /// The planner's switches, assembled from the three controls below.
    /// Read by `payload()` and by the applier (for `takeSecrets`); written
    /// only through those controls, so there is one copy of each decision.
    private(set) var switches = ImportSwitches()

    /// The first switch: read passwords and S3 secret keys out of the
    /// source's keychain items. Off by default (design §0 item 1).
    ///
    /// Changing it does not re-plan: the planner never sees a secret, and no
    /// row's status depends on one.
    var takeSecrets: Bool {
        get { switches.takeSecrets }
        set { switches.takeSecrets = newValue }
    }

    /// The second switch, which governs BOTH halves of one line the
    /// maintainer accepted as one decision (design §4): the group the import
    /// files into, and whether the source's labels become tags. Off, the
    /// sessions land ungrouped and untagged and the picker is disabled.
    ///
    /// Changing it DOES re-plan: with labels in play, a bookmark whose
    /// labels differ from its session's tags stops being unchanged.
    var takesGroupAndLabels: Bool {
        get { storedTakesGroupAndLabels }
        set {
            guard newValue != storedTakesGroupAndLabels else { return }
            storedTakesGroupAndLabels = newValue
            rebuildSwitches()
            replan()
        }
    }

    /// Which group the import files into while the switch above is on.
    var groupChoice: GroupChoice {
        get { storedGroupChoice }
        set {
            guard newValue != storedGroupChoice else { return }
            storedGroupChoice = newValue
            rebuildSwitches()
        }
    }

    /// The two above are computed over private storage rather than stored
    /// with a `didSet`: `@Observable` rewrites a stored property into a
    /// computed one of its own, and a property observer on such a property
    /// is not a shape the macro is defined over. Written this way, the
    /// storage is what the macro tracks and the setter is plain code.
    private var storedTakesGroupAndLabels = false
    private var storedGroupChoice: GroupChoice = .ungrouped

    /// The group a row lands in. Deliberately NOT spelled `none`: an
    /// `Optional`-shaped case name makes `contains(.none)` and
    /// `choice == .none` ambiguous at every call site, and the ambiguity
    /// resolves silently to whichever one type inference likes.
    enum GroupChoice: Hashable {
        case ungrouped
        /// A group already on record, by its store id.
        case existing(UUID)
        /// A group to create on import, by name — `ImportSwitches
        /// .createGroupNamed`, which the downstream planner either matches to
        /// an existing group of that name or creates once for the whole run.
        case create(String)
    }

    /// What the picker offers: no group, every group on record, and — only
    /// when no group of that name exists yet — a new one named after the
    /// source.
    private(set) var groupChoices: [GroupChoice] = []

    // MARK: - What it plans against

    private let sessions: [StoredSession]
    private let groups: [StoredGroup]

    /// Rows the user ticked or unticked by hand, so a re-plan can put them
    /// back. Without it, flipping the labels switch would silently undo
    /// every decision made before it.
    private var manualSelection: [String: Bool] = [:]

    init(sessions: [StoredSession], groups: [StoredGroup]) {
        self.sessions = sessions
        self.groups = groups
    }

    // MARK: - Loading

    /// Reads `folder` through `source` and plans the preview.
    ///
    /// Generic over the source rather than taking an existential, so
    /// `Source.id` and `Source.displayNameKey` — both static requirements —
    /// are reachable, and so a second source (FileZilla, Transmit) needs
    /// nothing here but its own conformer.
    func load<Source: BookmarkSource>(source: Source, folder: URL) {
        sourceID = Source.id
        // The catalog key is the source's own; the fallback is derived from
        // its id rather than written out, so a source that ships without a
        // catalog entry still names itself instead of naming this file's
        // guess about it.
        sourceName = L10n.string(Source.displayNameKey, Source.id.capitalized)
        groupChoices = Self.choices(named: sourceName, in: groups)
        groupChoice = Self.defaultChoice(named: sourceName, in: groups)
        rebuildSwitches()

        do {
            bookmarks = try source.read(from: folder)
            loadError = nil
        } catch {
            bookmarks = []
            loadError = String(
                format: L10n.string(
                    "import.cyberduck.error.folder %@", "Could not read the folder: %@"),
                String(describing: error))
        }
        manualSelection = [:]
        replan()
    }

    private var bookmarks: [ExternalBookmark] = []

    /// Re-runs the planner and restores every tick the user made by hand.
    /// The planner's own defaults apply to every row the user has not
    /// touched, including rows whose status just changed.
    private func replan() {
        var planned = ImportPreviewPlanner.preview(
            bookmarks, against: sessions, switches: switches)
        for index in planned.indices {
            guard let manual = manualSelection[planned[index].id],
                  planned[index].isSelectable
            else { continue }
            planned[index].selected = manual
        }
        rows = planned
    }

    private func rebuildSwitches() {
        switches.takeLabelsAsTags = takesGroupAndLabels
        guard takesGroupAndLabels else {
            switches.groupID = nil
            switches.createGroupNamed = nil
            return
        }
        switch groupChoice {
        case .ungrouped:
            switches.groupID = nil
            switches.createGroupNamed = nil
        case .existing(let id):
            switches.groupID = id
            switches.createGroupNamed = nil
        case .create(let name):
            switches.groupID = nil
            switches.createGroupNamed = name
        }
    }

    private static func existingGroup(named name: String, in groups: [StoredGroup]) -> StoredGroup? {
        groups.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private static func choices(named name: String, in groups: [StoredGroup]) -> [GroupChoice] {
        var choices: [GroupChoice] = [.ungrouped]
        choices.append(contentsOf: groups
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { .existing($0.id) })
        if existingGroup(named: name, in: groups) == nil {
            choices.append(.create(name))
        }
        return choices
    }

    /// The group named after the source when there is one, and a new group
    /// of that name otherwise (design §4). Never a second group of the same
    /// name: the downstream planner matches groups BY NAME, so creating one
    /// beside an existing namesake would resolve back onto it anyway — with
    /// the user unable to see which.
    private static func defaultChoice(named name: String, in groups: [StoredGroup]) -> GroupChoice {
        if let existing = existingGroup(named: name, in: groups) { return .existing(existing.id) }
        return .create(name)
    }

    /// The name of a chosen group, for the picker's own labels.
    func groupName(for choice: GroupChoice) -> String? {
        switch choice {
        case .ungrouped: return nil
        case .existing(let id): return groups.first { $0.id == id }?.name
        case .create(let name): return name
        }
    }

    // MARK: - Ticking

    /// Flips one row. A row the planner marked unimportable is left alone —
    /// `PreviewRow.selected` is a `var`, so nothing but this check stands
    /// between a click and an entry `payload(for:)` would have to refuse a
    /// second time.
    func toggle(row: PreviewRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }),
              rows[index].isSelectable
        else { return }
        rows[index].selected.toggle()
        manualSelection[rows[index].id] = rows[index].selected
    }

    func selectAll() { setAllSelectable(to: true) }

    func selectNone() { setAllSelectable(to: false) }

    private func setAllSelectable(to selected: Bool) {
        for index in rows.indices where rows[index].isSelectable {
            rows[index].selected = selected
            manualSelection[rows[index].id] = selected
        }
    }

    /// Whether the Import button does anything.
    var canImport: Bool { rows.contains { $0.selected } }

    // MARK: - The summary line

    /// The four numbers under the table (design §4).
    struct Summary: Equatable {
        /// Rows that will be written.
        var importing: Int
        /// How many of those overwrite a session already on record —
        /// including a ticked unchanged row, which is a provenance-only
        /// update and which the downstream planner counts as replaced.
        var updating: Int
        /// Importable rows the user left unticked.
        var skipped: Int
        /// Rows nothing can import: an unsupported protocol, or a file that
        /// would not parse. Counted together because the table greys both,
        /// and because the number's job is "rows you cannot tick".
        var unimportable: Int
    }

    var summary: Summary {
        var summary = Summary(importing: 0, updating: 0, skipped: 0, unimportable: 0)
        for row in rows {
            guard row.isSelectable else {
                summary.unimportable += 1
                continue
            }
            guard row.selected else {
                summary.skipped += 1
                continue
            }
            summary.importing += 1
            if row.status.storedSessionID != nil { summary.updating += 1 }
        }
        return summary
    }

    // MARK: - Handing over

    /// The payload the existing import path takes, built from the ticked
    /// rows only.
    ///
    /// The store's group catalogue is passed because `SessionImportPlanner`
    /// resolves `ExportedSession.groupID` against the payload's OWN groups
    /// and drops a reference the payload does not carry.
    func payload() -> SessionExportPayload {
        ImportPreviewPlanner.payload(
            for: rows, sessions: sessions, groups: groups, switches: switches)
    }

    /// The bookmark behind each ticked row, keyed by the id the planner
    /// writes into `ExportedSession.importID`. The applier needs it to ask
    /// the keychain with, and this is the only place that pairing exists —
    /// an `ExportedSession` carries no host/account of its own shape the
    /// keychain query wants.
    var selectedBookmarksByID: [String: ExternalBookmark] {
        Dictionary(
            rows.filter { $0.selected }.map { ($0.bookmark.id, $0.bookmark) },
            uniquingKeysWith: { first, _ in first })
    }
}
