import SwiftUI
import macSCPCore

/// The file the version sheet is about: the bucket and key to ask the store
/// about, and the two names to show the person.
///
/// **The sheet names the object exactly as the pane's row named it.** The
/// person right-clicked a row; a sheet that renamed its subject would make
/// them check whether it opened on the right file. So `displayName` and
/// `displayPath` are the row's own `name` and `path`, handed over untouched,
/// and are never rebuilt from `bucket` and `key`. Those two are for the
/// requests only.
struct ObjectVersionsTarget: Equatable {
    let bucket: String
    let key: String
    /// The row's `name`, as the pane draws it.
    let displayName: String
    /// The row's `path`, as the pane holds it.
    let displayPath: String

    /// The target for `file`, or `nil` when it is not a file in a bucket (the
    /// bucket list itself, or a connection with no bucket configured). The
    /// bucket and key are worked out as `ObjectLockTarget` works them out, from
    /// the same two facts, so the two sheets cannot disagree about which
    /// object a row is.
    static func resolve(file: RemoteFileItem, in context: ConnectionActionContext) -> ObjectVersionsTarget? {
        guard let target = ObjectLockTarget.resolve(path: file.path, in: context) else { return nil }
        return ObjectVersionsTarget(
            bucket: target.bucket, key: target.key, displayName: file.name,
            displayPath: file.path)
    }
}

/// Every sentence the version sheet has, as data, so the tests can hold each
/// one to all four languages.
///
/// **Wording rule (the coordinator's ruling of 2026-11-02).** Where the sheet
/// reports something it could not confirm, it says it could not be
/// confirmed -- never that it failed. A lock state the sheet could not read is
/// "could not be confirmed": the object may well be locked, and the person
/// must not read the sentence as "unlocked" or as a broken sheet.
enum ObjectVersionsLines {
    static let title = CatalogueLine(
        key: "s3.versions.title %@", english: "Versions of “%@”")
    static let reading = CatalogueLine(
        key: "s3.versions.reading", english: "Reading the version history…")
    static let empty = CatalogueLine(
        key: "s3.versions.empty", english: "No versions were found for this file.")
    static let noMatches = CatalogueLine(
        key: "s3.versions.noMatches", english: "No versions match.")
    static let readFailed = CatalogueLine(
        key: "s3.versions.error.read", english: "The version history could not be read.")
    static let denied = CatalogueLine(
        key: "s3.versions.error.denied",
        english: "Your access key is not allowed to read this file's version history.")
    static let modifiedColumn = CatalogueLine(
        key: "s3.versions.column.modified", english: "Modified")
    static let sizeColumn = CatalogueLine(key: "s3.versions.column.size", english: "Size")
    static let stateColumn = CatalogueLine(key: "s3.versions.column.state", english: "State")
    static let versionIDColumn = CatalogueLine(
        key: "s3.versions.column.versionId", english: "Version ID")
    static let filterLabel = CatalogueLine(key: "s3.versions.filter.label", english: "Show")
    static let filterAll = CatalogueLine(key: "s3.versions.filter.all", english: "All")
    static let filterVersions = CatalogueLine(
        key: "s3.versions.filter.versions", english: "Versions")
    static let filterDeleteMarkers = CatalogueLine(
        key: "s3.versions.filter.deleteMarkers", english: "Delete markers")
    static let filterLocked = CatalogueLine(
        key: "s3.versions.filter.locked", english: "Locked")
    static let current = CatalogueLine(key: "s3.versions.state.current", english: "Current")
    static let earlier = CatalogueLine(
        key: "s3.versions.state.earlier", english: "Earlier version")
    static let deleteMarker = CatalogueLine(
        key: "s3.versions.state.deleteMarker", english: "Delete marker")
    static let metadataOnly = CatalogueLine(
        key: "s3.versions.state.metadataOnly", english: "Same content as the version before")
    static let locked = CatalogueLine(
        key: "s3.versions.state.locked %1$@ %2$@", english: "Locked until %2$@ (%1$@)")
    static let legalHold = CatalogueLine(
        key: "s3.versions.state.legalHold", english: "Legal hold")
    static let lockUnknown = CatalogueLine(
        key: "s3.versions.state.lockUnknown", english: "Checking lock…")
    static let lockUnreadable = CatalogueLine(
        key: "s3.versions.state.lockUnreadable", english: "Lock could not be confirmed")
    static let count = CatalogueLine(key: "s3.versions.count %lld", english: "%lld entries")
    static let countFiltered = CatalogueLine(
        key: "s3.versions.countFiltered %lld %lld", english: "%lld of %lld")

    /// Every line, for the tests that hold each to all four catalogues.
    static let all: [CatalogueLine] = [
        title, reading, empty, noMatches, readFailed, denied, modifiedColumn, sizeColumn,
        stateColumn, versionIDColumn, filterLabel, filterAll, filterVersions,
        filterDeleteMarkers, filterLocked, current, earlier, deleteMarker, metadataOnly, locked,
        legalHold, lockUnknown, lockUnreadable, count, countFiltered,
    ]

    /// The sentence for a failed listing. A finding carries no foreign text
    /// and says its own; a missing permission has one of its own; anything
    /// else is a fixed sentence. **The error is never quoted**: a `reason` can
    /// carry the endpoint the user typed, and that field takes
    /// `scheme://KEY:SECRET@host` as ordinary input.
    static func message(for error: any Error) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            return finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return denied.text
        default:
            return readFailed.text
        }
    }
}

/// What the version sheet knows and decides, apart from how it is drawn.
///
/// **The listing and the lock are two stages, and the second cannot spoil the
/// first.** `load()` reads the history and publishes the rows; only then does it
/// ask whether the bucket has Object Lock at all. A store without Object Lock,
/// or one that does not implement the call, leaves every row as the listing
/// described it. This is the first half's D1 lesson (reading the lock first and
/// unconditionally made a wholly successful operation on a store without Object
/// Lock report itself unconfirmed) applied before it can bite again.
///
/// **The per-version lock read is lazy and bounded.** Retention and legal hold
/// are two requests per version (`readLockState(of:)`), issued for the rows the
/// table realises and at most `lockReadLimit` rows at a time. A row whose read
/// has not come back is `.lockUnknown`, which is a different fact from
/// `.lockUnreadable` (the read came back and could not be completed), and
/// neither is "not locked".
///
/// **A version id can literally be the four characters `null`**, which S3
/// reports for an object written before versioning was enabled and for a write
/// while it is suspended. It is a real, displayable id: it is a row like any
/// other, it is sent as the id of the lock reads, and nothing here treats the
/// string as a missing value.
@MainActor
@Observable
final class ObjectVersionsModel {
    /// What a row is, for the person and for the actions Task 9 hangs on it.
    ///
    /// **One value per row, chosen by what the person can act on.** The order
    /// is: a delete marker; then a lock (it decides what may be deleted), in
    /// which the retention in force wins over a legal hold, and a lock that is
    /// not yet known or could not be confirmed is itself a state; then
    /// `.current`; then `.metadataOnly`; then `.plain`. So `.current` is NOT
    /// "this is the newest entry": a locked newest version is `.locked`. The
    /// question "is this the key's current entry" is `ObjectVersion.isLatest`,
    /// and "does this row look like the one before it" is
    /// `isMetadataOnly(_:)`; the sheet's state text is built from all three.
    enum RowState: Equatable {
        case current, plain, deleteMarker, metadataOnly
        case locked(until: Date, mode: RetentionMode), legalHold
        /// The lock read for this row has not come back yet, or the bucket's
        /// has not.
        case lockUnknown
        /// The store was asked and the answer could not be obtained. The
        /// object may well be locked.
        case lockUnreadable
    }

    /// Where the listing is.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Whether the bucket has Object Lock, as far as the sheet knows.
    enum BucketLock: Equatable {
        case notAsked
        case asking
        /// The bucket has Object Lock: each version's lock is read.
        case applies
        /// There is nothing to read: no Object Lock on the bucket, or a store
        /// that does not implement the call, or a backend without the
        /// capability.
        case notApplicable
        /// The question itself could not be answered.
        case undetermined
    }

    /// What reading one version's lock returned.
    enum LockReading: Equatable {
        case read(retention: ObjectRetention?, legalHold: Bool)
        case unreadable
    }

    /// What the lock reads need: the capability and the session's cache of
    /// whether a bucket has a lock.
    struct LockBacking {
        let settings: any S3BucketSettings
        let cache: ObjectLockStateCache
    }

    /// How many rows' locks are read at once.
    static let lockReadLimit = 4

    let target: ObjectVersionsTarget
    private(set) var phase: Phase
    /// The listing, newest first (`Self.ordered`).
    private(set) var versions: [ObjectVersion]
    private(set) var bucketLock: BucketLock
    private(set) var readings: [String: LockReading]

    @ObservationIgnored private let provider: (any ObjectVersionProvider)?
    @ObservationIgnored private let lockBacking: LockBacking?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let gate = ConcurrencyGate(limit: ObjectVersionsModel.lockReadLimit)
    /// Versions whose lock read is running now, so a cell that appears twice
    /// does not send the same two requests twice.
    @ObservationIgnored private var reading: Set<String> = []
    /// Called on the main actor each time a version's lock reading is recorded.
    /// For a test that has to wait until the reads it started have landed: it
    /// raises a signal and awaits it, instead of polling the model.
    @ObservationIgnored var lockReadRecorded: (@MainActor () -> Void)?

    /// A sheet that has not read anything yet.
    init(
        target: ObjectVersionsTarget, provider: any ObjectVersionProvider,
        locks: LockBacking?, now: @escaping () -> Date = { Date() }
    ) {
        self.target = target
        self.provider = provider
        self.lockBacking = locks
        self.now = now
        phase = .idle
        versions = []
        bucketLock = .notAsked
        readings = [:]
    }

    /// A sheet in a given state; reads nothing and can read nothing. The
    /// layout registry and the tests that need a state without a store use it.
    init(
        target: ObjectVersionsTarget, phase: Phase, versions: [ObjectVersion],
        bucketLock: BucketLock, readings: [String: LockReading] = [:],
        now: @escaping () -> Date = { Date() }
    ) {
        self.target = target
        self.provider = nil
        self.lockBacking = nil
        self.now = now
        self.phase = phase
        self.versions = Self.ordered(versions)
        self.bucketLock = bucketLock
        self.readings = readings
    }

    // MARK: - Order

    /// Newest first, explicitly: the store's order is "whatever the store
    /// returns" at the Core layer and nothing here relies on it. The entry the
    /// store flags as latest leads; the rest follow by date, newest first;
    /// an entry with no date sinks below the dated ones; ties keep the order
    /// they arrived in. A total order, so the sort is deterministic.
    static func ordered(_ versions: [ObjectVersion]) -> [ObjectVersion] {
        versions.enumerated().sorted { lhs, rhs in
            if lhs.element.isLatest != rhs.element.isLatest { return lhs.element.isLatest }
            switch (lhs.element.modifiedAt, rhs.element.modifiedAt) {
            case (let a?, let b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Loading

    /// Reads the history, publishes it, then asks whether the bucket has
    /// Object Lock. A failed listing is the only failure: the rows are not
    /// emptied by anything that happens after they are in.
    func load() async {
        guard let provider else { return }
        phase = .loading
        versions = []
        readings = [:]
        bucketLock = .notAsked
        let listed: [ObjectVersion]
        do {
            listed = try await provider.versions(ofKey: target.key, inBucket: target.bucket)
        } catch {
            // A cancelled read (the sheet closed) is not a failure to report.
            phase = Task.isCancelled ? .idle : .failed(ObjectVersionsLines.message(for: error))
            return
        }
        versions = Self.ordered(listed)
        phase = .loaded
        await askWhetherTheBucketHasALock()
    }

    private func askWhetherTheBucketHasALock() async {
        guard let lockBacking, versions.contains(where: { !$0.isDeleteMarker }) else {
            bucketLock = .notApplicable
            return
        }
        bucketLock = .asking
        do {
            bucketLock = try await lockBacking.cache.hasObjectLock(target.bucket)
                ? .applies : .notApplicable
        } catch {
            if Task.isCancelled {
                bucketLock = .notAsked
                return
            }
            switch error {
            // A store that does not implement the call has no locks to show,
            // and a bucket that reports none has none: not a failure.
            case RemoteFSError.finding(.operationNotSupported),
                RemoteFSError.finding(.objectLockNotConfigured):
                bucketLock = .notApplicable
            default:
                bucketLock = .undetermined
            }
        }
    }

    // MARK: - Reading a row's lock

    /// Reads one version's retention and legal hold, unless the bucket has no
    /// lock, the row is a delete marker (a marker stores no content and is not
    /// locked), or the row was read already.
    ///
    /// Bounded by `lockReadLimit`. A read whose task was cancelled records
    /// nothing, so the row stays `.lockUnknown` and is read again when it
    /// reappears; a read that came back with an error records
    /// `.lockUnreadable`. The id goes to the store exactly as listed, `null`
    /// included.
    func readLockState(of version: ObjectVersion) async {
        guard bucketLock == .applies, !version.isDeleteMarker, let lockBacking else { return }
        let id = version.versionId
        guard readings[id] == nil, !reading.contains(id) else { return }
        reading.insert(id)
        defer { reading.remove(id) }
        let settings = lockBacking.settings
        let bucket = target.bucket
        let key = target.key
        // The body always answers. A task cancelled before its slot came makes
        // `run` answer `nil`, and one cancelled while the store was being asked
        // is dropped by the check after it: either way nothing is recorded, and
        // the row stays unknown. (An error caught while cancelled would
        // otherwise be an `.unreadable` for a read nobody was waiting for.)
        let outcome = await gate.run { () async -> LockReading in
            do {
                let retention = try await settings.retention(
                    ofKey: key, inBucket: bucket, versionId: id)
                // The second request is only worth sending to someone who is
                // still waiting for it. A store whose call does not itself
                // refuse a cancelled task would otherwise answer it for a sheet
                // that has gone (`ObjectVersionsLockReadTests`).
                try Task.checkCancellation()
                let hold = try await settings.legalHold(ofKey: key, inBucket: bucket, versionId: id)
                return .read(retention: retention, legalHold: hold)
            } catch {
                return .unreadable
            }
        }
        guard let outcome, !Task.isCancelled else { return }
        readings[id] = outcome
        lockReadRecorded?()
    }

    /// `readLockState(of:)` for each of `versions`, together, still bounded.
    func readLockStates(of versions: [ObjectVersion]) async {
        await withTaskGroup(of: Void.self) { group in
            for version in versions {
                group.addTask { await self.readLockState(of: version) }
            }
        }
    }

    // MARK: - What a row is

    func rowState(of version: ObjectVersion) -> RowState {
        if version.isDeleteMarker { return .deleteMarker }
        switch bucketLock {
        case .notAsked, .asking:
            return .lockUnknown
        case .undetermined:
            return .lockUnreadable
        case .notApplicable:
            break
        case .applies:
            switch readings[version.versionId] {
            case nil:
                return .lockUnknown
            case .unreadable:
                return .lockUnreadable
            case .read(let retention, let hold)?:
                // A retention whose date has passed is no longer in force.
                if let retention, retention.retainUntil > now() {
                    return .locked(until: retention.retainUntil, mode: retention.mode)
                }
                if hold { return .legalHold }
            }
        }
        if version.isLatest { return .current }
        return isMetadataOnly(version) ? .metadataOnly : .plain
    }

    /// Whether `version` carries the same entity tag as the entry written just
    /// before it. A metadata change is a copy onto itself, which makes a new
    /// version with the bytes (and so the tag) of the one it was copied from
    /// (spec section 4.5), and this is the one signal the listing offers for
    /// it. It is a signal and not a proof: a restore of the version directly
    /// beneath looks the same, and a delete marker has no tag, so a marker
    /// between two versions breaks the pair.
    func isMetadataOnly(_ version: ObjectVersion) -> Bool {
        guard !version.isDeleteMarker, let tag = version.entityTag,
            let position = versions.firstIndex(where: { $0.versionId == version.versionId }),
            versions.indices.contains(position + 1)
        else { return false }
        let before = versions[position + 1]
        return !before.isDeleteMarker && before.entityTag == tag
    }

    // MARK: - Presentation

    /// The sentence for a loaded history that shows no rows, or `nil` when
    /// some are shown. **Two different facts:** the store listed nothing for
    /// this file (`empty`), or it listed entries and the filter and the search
    /// between them hid every one (`noMatches`). Neither is a failure, and
    /// the first must not read like one.
    func emptyLine(visibleRows: Int) -> CatalogueLine? {
        if visibleRows > 0 { return nil }
        return versions.isEmpty ? ObjectVersionsLines.empty : ObjectVersionsLines.noMatches
    }

    /// The state column's text: what the row is, in `localeCode`'s language
    /// (the ambient override by default), words and date alike. **One
    /// language:** every line resolves through the same code, so a caller whose
    /// code differs from the ambient override still gets a single language.
    ///
    /// `Current` leads when the entry is the key's current one, even when a
    /// lock is what `rowState` reports, and the metadata-only note follows
    /// whatever else is said. **A row under both a retention and a legal hold
    /// says both** (`rowState` keeps the retention, which a later task gates
    /// on): a version with a hold stays undeletable past the retention's date,
    /// so "Locked until <date>" alone would promise a date it will not be
    /// deletable on.
    func stateText(of version: ObjectVersion, localeCode: String? = L10n.localeOverride) -> String {
        L10n.$localeOverride.withValue(localeCode) {
            let state = rowState(of: version)
            if state == .deleteMarker {
                return ObjectVersionsLines.deleteMarker.text
            }
            var parts: [String] = []
            if version.isLatest { parts.append(ObjectVersionsLines.current.text) }
            switch state {
            case .current, .deleteMarker, .metadataOnly:
                break
            case .plain:
                parts.append(ObjectVersionsLines.earlier.text)
            case .locked(let until, let mode):
                parts.append(
                    String(
                        format: ObjectVersionsLines.locked.text,
                        ObjectLockLines.modeName(mode).text,
                        ObjectLockDates.text(until, localeCode: localeCode)))
                if case .read(_, legalHold: true)? = readings[version.versionId] {
                    parts.append(ObjectVersionsLines.legalHold.text)
                }
            case .legalHold:
                parts.append(ObjectVersionsLines.legalHold.text)
            case .lockUnknown:
                parts.append(ObjectVersionsLines.lockUnknown.text)
            case .lockUnreadable:
                parts.append(ObjectVersionsLines.lockUnreadable.text)
            }
            if isMetadataOnly(version) { parts.append(ObjectVersionsLines.metadataOnly.text) }
            return parts.joined(separator: " · ")
        }
    }
}

/// One row of the table: a version and everything the columns and the search
/// read off it, resolved at the moment the row is made.
struct ObjectVersionRow: Identifiable {
    /// The store's version id, `null` included: unique within one key's
    /// history, which is all this sheet ever shows.
    var id: String { version.versionId }
    let version: ObjectVersion
    let state: ObjectVersionsModel.RowState
    let stateText: String
    let modifiedText: String
    let sizeText: String
    /// Where the row sits in the listing, the last tiebreak of every order.
    let position: Int

    /// Sort keys: comparable stand-ins for the optional columns. A missing
    /// date sorts as the oldest, a missing size (a marker) as the smallest.
    var modifiedSort: Date { version.modifiedAt ?? .distantPast }
    var sizeSort: UInt64 { version.size ?? 0 }

    /// What the search matches: the row's text as the person sees it.
    var searchString: String {
        "\(modifiedText) \(sizeText) \(stateText) \(version.versionId)"
    }
}

/// The date and size columns' text.
enum ObjectVersionsFormat {
    static let missing = "—"

    static func date(_ date: Date?, localeCode: String? = L10n.localeOverride) -> String {
        guard let date else { return missing }
        let locale = localeCode.map(Locale.init(identifier:)) ?? .current
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return missing }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

extension ObjectVersionsModel {
    /// A single-selection filter dimension, like the audit log's segments.
    enum Filter: CaseIterable {
        case all, versions, deleteMarkers, locked

        var line: CatalogueLine {
            switch self {
            case .all: ObjectVersionsLines.filterAll
            case .versions: ObjectVersionsLines.filterVersions
            case .deleteMarkers: ObjectVersionsLines.filterDeleteMarkers
            case .locked: ObjectVersionsLines.filterLocked
            }
        }

        func includes(_ version: ObjectVersion, state: RowState) -> Bool {
            switch self {
            case .all: return true
            case .versions: return !version.isDeleteMarker
            case .deleteMarkers: return version.isDeleteMarker
            case .locked:
                switch state {
                case .locked, .legalHold: return true
                case .current, .plain, .deleteMarker, .metadataOnly, .lockUnknown, .lockUnreadable:
                    return false
                }
            }
        }
    }

    /// The rows for the table, before sorting: the listing in order, narrowed
    /// by the filter and the search.
    func rows(
        filter: Filter, matching predicate: FileSearch.FileSearchPredicate,
        localeCode: String? = L10n.localeOverride
    ) -> [ObjectVersionRow] {
        let all = versions.enumerated().map { position, version in
            ObjectVersionRow(
                version: version, state: rowState(of: version),
                stateText: stateText(of: version, localeCode: localeCode),
                modifiedText: ObjectVersionsFormat.date(version.modifiedAt, localeCode: localeCode),
                sizeText: ObjectVersionsFormat.size(version.size), position: position)
        }
        return all.filter {
            filter.includes($0.version, state: $0.state) && predicate.matches($0.searchString)
        }
    }
}

/// The sheet behind the file context menu's "Show Versions…": one file's
/// history in a sortable table, filtered and searched, with a counting footer.
///
/// The shape is `AuditLogSheet`'s, chosen by the maintainer on 2026-10-23 from
/// three drawn alternatives: a `Table`, a `Picker` filter, the shared
/// `SheetSearchField`, and a footer that counts. It reads; it writes nothing.
/// The actions on a row come with the row's context menu, which is a later
/// task's.
struct ObjectVersionsSheet: BoundedView {
    /// The size `ObjectVersionsSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .size(width: 640, height: 480)

    /// The sheet's inset on each side.
    static let padding: CGFloat = 20
    /// The narrowest each column is allowed to be, named so the table's
    /// minimum is a sum that can be held to the bound
    /// (`ObjectVersionsSheetTests.theColumnsFitTheSheetsOwnWidth`).
    static let modifiedMinimum: CGFloat = 110
    static let sizeMinimum: CGFloat = 60
    static let stateMinimum: CGFloat = 130
    static let versionIDMinimum: CGFloat = 90
    static var columnMinimums: CGFloat {
        modifiedMinimum + sizeMinimum + stateMinimum + versionIDMinimum
    }

    @Environment(\.dismiss) private var dismiss
    @State private var model: ObjectVersionsModel
    @State private var filter: ObjectVersionsModel.Filter = .all
    @State private var searchText = ""
    @State private var searchIsRegex = false
    @State private var sortOrder: [KeyPathComparator<ObjectVersionRow>] = [
        KeyPathComparator(\ObjectVersionRow.modifiedSort, order: .reverse)
    ]

    /// `model` is built by the caller: the window builds one over the file
    /// system it captured, and the layout registry passes one already in a
    /// state, so a measurement does not wait on a read.
    init(model: ObjectVersionsModel) {
        _model = State(initialValue: model)
    }

    private var rows: [ObjectVersionRow] {
        let (predicate, _) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        // The position is the last key of every order, so equal cells keep the
        // listing's order whichever column is clicked.
        return model.rows(filter: filter, matching: predicate)
            .sorted(using: sortOrder + [KeyPathComparator(\ObjectVersionRow.position)])
    }

    var body: some View {
        // Built once per render and handed to both users: the table and the
        // footer's count. Each build filters, formats every row's state text
        // and sorts.
        let shown = rows
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: ObjectVersionsLines.title.text, model.target.displayName))
                    .font(.headline)
                    .lineLimit(2)
                Text(model.target.displayPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // A menu and not a segmented control, for the reason
            // `AuditLogSheet` gives: a segmented control is as wide as all its
            // labels side by side, and the layout guard measures that.
            Picker(ObjectVersionsLines.filterLabel.text, selection: $filter) {
                ForEach(ObjectVersionsModel.Filter.allCases, id: \.self) { filter in
                    Text(filter.line.text).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            let (_, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            content(shown: shown)

            HStack {
                Text(footerText(shownCount: shown.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Self.padding)
        .sheetBound(Self.bound)
        .task {
            if model.phase == .idle { await model.load() }
        }
    }

    @ViewBuilder private func content(shown: [ObjectVersionRow]) -> some View {
        switch model.phase {
        case .idle, .loading:
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ObjectVersionsLines.reading.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        case .failed(let sentence):
            Spacer(minLength: 0)
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        case .loaded:
            if let emptyLine = model.emptyLine(visibleRows: shown.count) {
                // Genuinely empty (the store listed nothing) says so; a
                // history that the filter or the search emptied says that.
                Spacer(minLength: 0)
                Text(emptyLine.text)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                table(shown)
            }
        }
    }

    private func table(_ shown: [ObjectVersionRow]) -> some View {
        Table(shown, sortOrder: $sortOrder) {
            TableColumn(
                ObjectVersionsLines.modifiedColumn.text,
                sortUsing: KeyPathComparator(\ObjectVersionRow.modifiedSort)
            ) { row in
                Text(row.modifiedText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.ink)
            }
            .width(min: Self.modifiedMinimum, ideal: 130, max: 170)
            TableColumn(
                ObjectVersionsLines.sizeColumn.text,
                sortUsing: KeyPathComparator(\ObjectVersionRow.sizeSort)
            ) { row in
                Text(row.sizeText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.ink)
            }
            .width(min: Self.sizeMinimum, ideal: 75, max: 110)
            TableColumn(
                ObjectVersionsLines.stateColumn.text,
                sortUsing: KeyPathComparator(\ObjectVersionRow.stateText)
            ) { row in
                ObjectVersionStateCell(model: model, row: row)
            }
            .width(min: Self.stateMinimum, ideal: 230)
            TableColumn(
                ObjectVersionsLines.versionIDColumn.text,
                sortUsing: KeyPathComparator(\ObjectVersionRow.id)
            ) { row in
                Text(row.version.versionId)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.version.versionId)
            }
            .width(min: Self.versionIDMinimum, ideal: 150)
        }
    }

    private func footerText(shownCount: Int) -> String {
        let total = model.versions.count
        if filter == .all && searchText.isEmpty {
            return String(format: ObjectVersionsLines.count.text, total)
        }
        return String(format: ObjectVersionsLines.countFiltered.text, shownCount, total)
    }
}

/// The state cell. It is where the lock read for its row is requested: a
/// `Table` realises cells for the rows it shows, so the read follows the rows
/// on screen, and the task is cancelled when the cell goes away (a row
/// scrolled off, or the sheet closed).
private struct ObjectVersionStateCell: View {
    let model: ObjectVersionsModel
    let row: ObjectVersionRow

    var body: some View {
        Text(row.stateText)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(row.stateText)
            .task(id: row.id) { await model.readLockState(of: row.version) }
    }

    private var color: Color {
        switch row.state {
        case .lockUnreadable: .orange
        case .deleteMarker, .lockUnknown: DesignTokens.inkSecondary
        case .current, .plain, .metadataOnly, .locked, .legalHold: DesignTokens.ink
        }
    }
}
