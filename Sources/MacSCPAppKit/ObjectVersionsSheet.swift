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

    // MARK: Row actions (Task 9)

    static let actionOpen = CatalogueLine(
        key: "s3.versions.action.open", english: "Open (Read-Only)")
    static let actionCompare = CatalogueLine(
        key: "s3.versions.action.compare", english: "Compare with Current Version")
    static let actionDownload = CatalogueLine(
        key: "s3.versions.action.download", english: "Download…")
    static let actionRestore = CatalogueLine(
        key: "s3.versions.action.restore", english: "Restore as Current…")
    static let actionDelete = CatalogueLine(
        key: "s3.versions.action.delete", english: "Delete This Version…")

    static let refusalNoContent = CatalogueLine(
        key: "s3.versions.refusal.noContent",
        english: "A delete marker has no content.")
    static let refusalIsCurrent = CatalogueLine(
        key: "s3.versions.refusal.isCurrent",
        english: "This is the current version already.")
    static let refusalCurrentIsMarker = CatalogueLine(
        key: "s3.versions.refusal.currentIsMarker",
        english: "The file is deleted at the moment, so there is no current content to compare with.")
    static let refusalVersioningNotEnabled = CatalogueLine(
        key: "s3.versions.refusal.versioningNotEnabled",
        english: "Restoring needs versioning to be turned on for this bucket. While it is off or suspended, a restore would replace the current content instead of adding a version.")
    static let refusalVersioningNotConfirmed = CatalogueLine(
        key: "s3.versions.refusal.versioningNotConfirmed",
        english: "Restoring needs versioning to be turned on for this bucket, and macSCP could not confirm whether it is. Open the history again to retry.")
    static let refusalLocked = CatalogueLine(
        key: "s3.versions.refusal.locked",
        english: "This version is locked, so it cannot be deleted.")
    static let refusalLockNotConfirmed = CatalogueLine(
        key: "s3.versions.refusal.lockNotConfirmed",
        english: "The lock on this version has not been confirmed, so it cannot be deleted.")
    /// Says where a marker IS lifted: the browser's own row, behind the
    /// "Show deleted files" switch (Task 10). (Withdrawn wording, verbatim:
    /// "A delete marker is not a version with content, so it is not deleted
    /// here." -- it said what the sheet does not do and, because the row that
    /// does it had not been built, could not say where to go.)
    static let refusalMarker = CatalogueLine(
        key: "s3.versions.refusal.marker",
        english: "A delete marker is not a version with content, so it is not deleted here. To bring the file back, turn on “Show deleted files” and restore it from its row.")
    static let refusalBusy = CatalogueLine(
        key: "s3.versions.refusal.busy",
        english: "Another change to this file's history is still running.")
    static let refusalUnavailable = CatalogueLine(
        key: "s3.versions.refusal.unavailable",
        english: "This is not available here.")

    static let restoreTitle = CatalogueLine(
        key: "s3.versions.restore.title", english: "Restore this version?")
    static let restoreMessage = CatalogueLine(
        key: "s3.versions.restore.message %1$@ %2$@",
        english: "“%1$@” gets a new version with the content of the version from %2$@. Every version in the history is kept.")
    static let restoreButton = CatalogueLine(
        key: "s3.versions.restore.button", english: "Restore")
    static let deleteTitle = CatalogueLine(
        key: "s3.versions.delete.title", english: "Delete this version?")
    static let deleteMessage = CatalogueLine(
        key: "s3.versions.delete.message %1$@ %2$@ %3$@",
        english: "The version of “%1$@” from %2$@ (version ID %3$@) is deleted for good. This cannot be undone.")
    static let deleteButton = CatalogueLine(
        key: "s3.versions.delete.button", english: "Delete Version")

    static let outcomeRestored = CatalogueLine(
        key: "s3.versions.outcome.restored",
        english: "Restored. The file has a new current version.")
    static let outcomeDeleted = CatalogueLine(
        key: "s3.versions.outcome.deleted", english: "The version was deleted.")
    static let outcomeRestoreNotConfirmed = CatalogueLine(
        key: "s3.versions.outcome.restoreNotConfirmed",
        english: "The restore could not be confirmed. The history was read again: check it before trying again.")
    static let outcomeDeleteNotConfirmed = CatalogueLine(
        key: "s3.versions.outcome.deleteNotConfirmed",
        english: "The deletion could not be confirmed. The history was read again: check whether the version is still listed.")
    static let outcomeLocked = CatalogueLine(
        key: "s3.versions.outcome.locked",
        english: "The store refused: this version is locked. Nothing was changed.")
    static let outcomeGone = CatalogueLine(
        key: "s3.versions.outcome.gone",
        english: "This version is no longer in the history. Nothing was changed.")
    static let outcomeDenied = CatalogueLine(
        key: "s3.versions.outcome.denied",
        english: "Your access key is not allowed to do this. Nothing was changed.")
    static let outcomeUnsupported = CatalogueLine(
        key: "s3.versions.outcome.unsupported",
        english: "This store does not support that. Nothing was changed.")

    /// Every line, for the tests that hold each to all four catalogues.
    static let all: [CatalogueLine] = [
        title, reading, empty, noMatches, readFailed, denied, modifiedColumn, sizeColumn,
        stateColumn, versionIDColumn, filterLabel, filterAll, filterVersions,
        filterDeleteMarkers, filterLocked, current, earlier, deleteMarker, metadataOnly, locked,
        legalHold, lockUnknown, lockUnreadable, count, countFiltered,
        actionOpen, actionCompare, actionDownload, actionRestore, actionDelete,
        refusalNoContent, refusalIsCurrent, refusalCurrentIsMarker, refusalVersioningNotEnabled,
        refusalVersioningNotConfirmed,
        refusalLocked, refusalLockNotConfirmed, refusalMarker, refusalBusy, refusalUnavailable,
        restoreTitle, restoreMessage, restoreButton, deleteTitle, deleteMessage, deleteButton,
        outcomeRestored, outcomeDeleted, outcomeRestoreNotConfirmed, outcomeDeleteNotConfirmed,
        outcomeLocked, outcomeGone, outcomeDenied, outcomeUnsupported,
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

/// The five things a person can do with one row of the history.
enum VersionRowAction: CaseIterable, Equatable {
    case open, compareWithCurrent, download, restore, deleteVersion

    var line: CatalogueLine {
        switch self {
        case .open: ObjectVersionsLines.actionOpen
        case .compareWithCurrent: ObjectVersionsLines.actionCompare
        case .download: ObjectVersionsLines.actionDownload
        case .restore: ObjectVersionsLines.actionRestore
        case .deleteVersion: ObjectVersionsLines.actionDelete
        }
    }
}

/// Why an action is not offered on a row: a typed reason, so the menu can say
/// it and a test can read it, rather than a bare `false`.
///
/// It carries no text of its own and no foreign text: `line` is a catalogue
/// sentence this project wrote.
enum VersionActionRefusal: Equatable {
    /// The row is a delete marker, which stores no content to open, compare,
    /// download or restore.
    case deleteMarkerHasNoContent
    /// The row is the key's current entry.
    case isTheCurrentVersion
    /// The key's current entry is a delete marker: there is no current content.
    case currentIsADeleteMarker
    /// Restore needs the bucket's versioning to be `.enabled`, and nothing
    /// else will do. See `ObjectVersionsModel.refusal(of:on:)`.
    case versioningIsNotEnabled
    /// The bucket's versioning could not be read, so whether a restore is
    /// safe is not known. Refused like `.versioningIsNotEnabled`, and worded
    /// as what it is: not confirmed, not "off".
    case versioningNotConfirmed
    /// A retention in force or a legal hold forbids the delete.
    case lockedOrHeld
    /// The lock has not been read yet, or could not be.
    case lockNotConfirmed
    /// The row is a delete marker, which the delete here would undelete
    /// instead of deleting.
    case aMarkerIsNotDeletedHere
    /// A restore or a delete is already running (or waiting to be confirmed).
    case anotherWriteIsRunning
    /// Nothing is wired to do this: no window to open it in, or no store.
    case notAvailableHere

    var line: CatalogueLine {
        switch self {
        case .deleteMarkerHasNoContent: ObjectVersionsLines.refusalNoContent
        case .isTheCurrentVersion: ObjectVersionsLines.refusalIsCurrent
        case .currentIsADeleteMarker: ObjectVersionsLines.refusalCurrentIsMarker
        case .versioningIsNotEnabled: ObjectVersionsLines.refusalVersioningNotEnabled
        case .versioningNotConfirmed: ObjectVersionsLines.refusalVersioningNotConfirmed
        case .lockedOrHeld: ObjectVersionsLines.refusalLocked
        case .lockNotConfirmed: ObjectVersionsLines.refusalLockNotConfirmed
        case .aMarkerIsNotDeletedHere: ObjectVersionsLines.refusalMarker
        case .anotherWriteIsRunning: ObjectVersionsLines.refusalBusy
        case .notAvailableHere: ObjectVersionsLines.refusalUnavailable
        }
    }
}

/// What the person is asked before a write runs.
struct VersionConfirmation: Equatable {
    let action: VersionRowAction
    let title: CatalogueLine
    let message: CatalogueLine
    /// `message` with its arguments filled in, in the ambient language.
    let messageText: String
    let confirm: CatalogueLine
    /// Whether the confirm button is drawn as destructive.
    let isDestructive: Bool
}

/// How an action ended, said so that the wording cannot call an unconfirmed
/// write a failed one.
enum VersionActionOutcome: Equatable {
    /// Open, compare or download was handed to the window that does it.
    case handedOff(VersionRowAction)
    /// The store confirmed it by reading the history back.
    case restored, deleted
    /// The person said no (or the sheet went away while the question stood).
    case cancelled
    /// The action was not offered on that row. A menu does not offer it, so
    /// this is a stale menu or a caller that skipped `isEnabled`.
    case declined(VersionActionRefusal)
    /// The request was sent and the history did not confirm it, or the answer
    /// never came back. **Not "failed"**: the write may or may not have
    /// happened, and the history was read again so the person can see.
    case notConfirmed(VersionRowAction)
    /// The store (or Core) refused outright, so nothing was changed.
    case refused(VersionRowAction, why: CatalogueLine)

    /// The sentence for the status line under the table, or `nil` for an
    /// outcome that says nothing (the hand-offs and a "no").
    var line: CatalogueLine? {
        switch self {
        case .handedOff, .cancelled: nil
        case .restored: ObjectVersionsLines.outcomeRestored
        case .deleted: ObjectVersionsLines.outcomeDeleted
        case .declined(let refusal): refusal.line
        case .notConfirmed(let action): Self.notConfirmedLine(for: action)
        case .refused(_, let why): why
        }
    }

    /// The sentence for a write that could not be confirmed. One place, for
    /// the status line and for the trail.
    static func notConfirmedLine(for action: VersionRowAction) -> CatalogueLine {
        action == .restore
            ? ObjectVersionsLines.outcomeRestoreNotConfirmed
            : ObjectVersionsLines.outcomeDeleteNotConfirmed
    }
}

/// What opening, comparing and downloading do. They are the window's, not the
/// sheet's: each needs the tab, the session and the transfer queue, which the
/// sheet does not hold. `nil` means the window gave none, and the action is
/// then not offered (an enabled row that does nothing is worse than a
/// disabled one).
struct VersionActionHandlers {
    var open: (@MainActor (ObjectVersion) -> Void)?
    var compareWithCurrent: (@MainActor (ObjectVersion) -> Void)?
    var download: (@MainActor (ObjectVersion) -> Void)?

    init(
        open: (@MainActor (ObjectVersion) -> Void)? = nil,
        compareWithCurrent: (@MainActor (ObjectVersion) -> Void)? = nil,
        download: (@MainActor (ObjectVersion) -> Void)? = nil
    ) {
        self.open = open
        self.compareWithCurrent = compareWithCurrent
        self.download = download
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

    /// What the bucket's versioning is, as far as the sheet has read it; `nil`
    /// until the read has come back, or when it could not be made. Restore
    /// reads it (`refusal(of:on:)`), so an unknown state is a refusal.
    private(set) var bucketVersioning: BucketVersioning?
    /// How the last action ended, for the status line. Cleared when the next
    /// action starts.
    private(set) var lastOutcome: VersionActionOutcome?
    /// A restore or a delete is running, or its confirmation is on screen.
    private(set) var writeInProgress = false

    /// How many times `rowState` has been worked out, and how many times a row
    /// had to be FOUND in `versions` by searching for its id. Counters and not a
    /// clock: they pin the cost of building the table (`rows(...)`) as a figure
    /// a slow machine cannot change. Not observed, so reading or bumping them
    /// from a view's body tracks nothing.
    @ObservationIgnored private(set) var rowStateEvaluations = 0
    @ObservationIgnored private(set) var positionLookups = 0

    @ObservationIgnored private let provider: (any ObjectVersionProvider)?
    @ObservationIgnored private let versioningCache: BucketVersioningCache?
    /// Where a restore's and a delete's outcome is written. **Required, with
    /// no default, and optional in its type**, as the bucket-settings sheets'
    /// is (`BucketSettingsAuditTests`): `nil` is a real answer (a tab whose
    /// stored session was deleted has none), but it has to be given at the
    /// call site and not inherited from a default nobody read.
    @ObservationIgnored private let recorder: AuditRecorder?
    /// What opening, comparing and downloading do; set by the window.
    @ObservationIgnored var handlers: VersionActionHandlers
    /// Asks the person before a restore or a delete runs, and answers whether
    /// they agreed. **Fails closed**: until a window sets it, nothing is ever
    /// confirmed, so no write can run without a question having been asked.
    @ObservationIgnored var confirm: @MainActor (VersionConfirmation) async -> Bool = { _ in false }
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
    ///
    /// **`versioning` is required, with no default, like `recorder`.** `nil` is a
    /// real answer (a backend with no bucket settings has no cache), but it means
    /// the restore gate can never learn that versioning is on, so Restore is
    /// refused for the life of the sheet. A default would let a caller that
    /// merely forgot the argument ship exactly that, with no compiler complaint.
    /// (Withdrawn wording: the parameter was declared `versioning: … = nil`.)
    init(
        target: ObjectVersionsTarget, provider: any ObjectVersionProvider,
        recorder: AuditRecorder?, locks: LockBacking?, versioning: BucketVersioningCache?,
        handlers: VersionActionHandlers = VersionActionHandlers(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.target = target
        self.provider = provider
        self.recorder = recorder
        self.lockBacking = locks
        self.versioningCache = versioning
        self.handlers = handlers
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
        bucketVersioning: BucketVersioning? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.target = target
        self.provider = nil
        self.lockBacking = nil
        self.versioningCache = nil
        self.recorder = nil
        self.handlers = VersionActionHandlers()
        self.bucketVersioning = bucketVersioning
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
        await readBucketVersioning()
        await askWhetherTheBucketHasALock()
    }

    /// Reads the bucket's versioning state, which the restore gate needs and
    /// the listing does not. **Like the lock question, it cannot spoil the
    /// listing**: the rows are already in, and a read that fails leaves the
    /// state `nil`, which is "not known" and offers no restore. A cancelled
    /// read (the sheet closed) changes nothing.
    private func readBucketVersioning() async {
        guard let versioningCache else { return }
        do {
            bucketVersioning = try await versioningCache.versioning(target.bucket)
        } catch {
            if !Task.isCancelled { bucketVersioning = nil }
        }
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
        rowState(of: version, at: nil)
    }

    /// `rowState(of:)` for a caller that already knows where `version` sits in
    /// `versions` (`rows(...)` walks them in order). **Only the search is
    /// saved**: a position that does not name `version` is not trusted
    /// (`isMetadataOnly(_:at:)`), so a wrong one costs a lookup and not a wrong
    /// answer.
    func rowState(of version: ObjectVersion, at position: Int?) -> RowState {
        rowStateEvaluations += 1
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
        return isMetadataOnly(version, at: position) ? .metadataOnly : .plain
    }

    /// Whether `version` carries the same entity tag as the entry written just
    /// before it. A metadata change is a copy onto itself, which makes a new
    /// version with the bytes (and so the tag) of the one it was copied from
    /// (spec section 4.5), and this is the one signal the listing offers for
    /// it. It is a signal and not a proof: a restore of the version directly
    /// beneath looks the same, and a delete marker has no tag, so a marker
    /// between two versions breaks the pair.
    func isMetadataOnly(_ version: ObjectVersion) -> Bool {
        isMetadataOnly(version, at: nil)
    }

    /// `isMetadataOnly(_:)` for a caller that knows where `version` sits. The
    /// row is otherwise FOUND by searching `versions` for its id, which is a
    /// walk of string comparisons per row and so quadratic over a history that
    /// nothing caps. A position is used only if it names `version`; otherwise
    /// the search runs as before.
    func isMetadataOnly(_ version: ObjectVersion, at position: Int?) -> Bool {
        guard !version.isDeleteMarker, let tag = version.entityTag else { return false }
        let found: Int
        if let position, versions.indices.contains(position),
            versions[position].versionId == version.versionId
        {
            found = position
        } else {
            positionLookups += 1
            guard let searched = versions.firstIndex(where: { $0.versionId == version.versionId })
            else { return false }
            found = searched
        }
        guard versions.indices.contains(found + 1) else { return false }
        let before = versions[found + 1]
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
        stateText(
            of: version, state: rowState(of: version), metadataOnly: isMetadataOnly(version),
            localeCode: localeCode)
    }

    /// The text for a row whose state and metadata-only fact the caller has
    /// already worked out. **`rows(...)` is that caller**: asking
    /// `stateText(of:localeCode:)` for every row would work each row's state out
    /// a second time, and search for it a third.
    func stateText(
        of version: ObjectVersion, state: RowState, metadataOnly: Bool,
        localeCode: String? = L10n.localeOverride
    ) -> String {
        L10n.$localeOverride.withValue(localeCode) {
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
            if metadataOnly { parts.append(ObjectVersionsLines.metadataOnly.text) }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - The row actions

extension ObjectVersionsModel {
    /// Why `action` is not offered on `version`, or `nil` when it is.
    ///
    /// **Restore is gated on the bucket being `.enabled`, and on nothing
    /// wider.** The sheet itself opens on `.suspended` as well
    /// (`VersionsRowAvailability`), because a suspended bucket still HAS a
    /// history. A write to a suspended bucket, though, replaces the `null`
    /// version instead of adding one, so a restore there destroys the current
    /// content rather than preserving it. The two questions are different and
    /// have different answers; a state that is not known (`nil`) is not
    /// `.enabled` either.
    ///
    /// **"Is this the current version" is `version.isLatest`**, never
    /// `rowState(of:) == .current`: the state puts a lock ahead of `.current`,
    /// so a locked newest version is `.locked`, and a gate written against
    /// `.current` would offer a restore of the row that already is current.
    /// The delete gate reads the lock the other way round, on purpose: the
    /// lock states are the question there, and `rowState` answers them.
    ///
    /// A row that is a delete marker has no content, so the four actions that
    /// need content refuse it with a reason of their own, and the delete here
    /// refuses it too: `deleteVersion` is the request that UNDELETES a key when
    /// it names a marker, which is not what "delete this version" says.
    func refusal(of action: VersionRowAction, on version: ObjectVersion) -> VersionActionRefusal? {
        switch action {
        case .restore, .deleteVersion:
            if writeInProgress { return .anotherWriteIsRunning }
        case .open, .compareWithCurrent, .download:
            break
        }
        return gate(action, on: version)
    }

    func isEnabled(_ action: VersionRowAction, on version: ObjectVersion) -> Bool {
        refusal(of: action, on: version) == nil
    }

    /// The refusals that depend on the row and the sheet's state, without the
    /// one about another write running (which the write itself must be able to
    /// ask again, after its own question).
    private func gate(_ action: VersionRowAction, on version: ObjectVersion) -> VersionActionRefusal? {
        switch action {
        case .open:
            if version.isDeleteMarker { return .deleteMarkerHasNoContent }
            return handlers.open == nil ? .notAvailableHere : nil
        case .download:
            if version.isDeleteMarker { return .deleteMarkerHasNoContent }
            return handlers.download == nil ? .notAvailableHere : nil
        case .compareWithCurrent:
            if version.isDeleteMarker { return .deleteMarkerHasNoContent }
            if version.isLatest { return .isTheCurrentVersion }
            if versions.first(where: \.isLatest)?.isDeleteMarker == true {
                return .currentIsADeleteMarker
            }
            return handlers.compareWithCurrent == nil ? .notAvailableHere : nil
        case .restore:
            if version.isDeleteMarker { return .deleteMarkerHasNoContent }
            if version.isLatest { return .isTheCurrentVersion }
            if provider == nil { return .notAvailableHere }
            // Two different facts, and two sentences (the lock half of this
            // model has two states for the same reason): the state was read
            // and is not on, or it was not read and nothing is known. The
            // GATE is the same for both; only what the person is told differs.
            guard let bucketVersioning else { return .versioningNotConfirmed }
            return bucketVersioning == .enabled ? nil : .versioningIsNotEnabled
        case .deleteVersion:
            if version.isDeleteMarker { return .aMarkerIsNotDeletedHere }
            if provider == nil { return .notAvailableHere }
            switch rowState(of: version) {
            case .locked, .legalHold: return .lockedOrHeld
            case .lockUnknown, .lockUnreadable: return .lockNotConfirmed
            case .current, .plain, .metadataOnly, .deleteMarker: return nil
            }
        }
    }

    /// Does `action` on `version`. Open, compare and download are handed to the
    /// window; restore and delete ask first and write only on a yes.
    ///
    /// A row the action is not offered on is `.declined` and nothing happens:
    /// the menu does not offer it, so this is a stale menu or a caller that
    /// skipped `isEnabled`, and it is checked again here because the cost of
    /// trusting the menu is a destructive write.
    @discardableResult
    func action(_ action: VersionRowAction, on version: ObjectVersion) async -> VersionActionOutcome {
        lastOutcome = nil
        let outcome = await perform(action, on: version)
        lastOutcome = outcome
        return outcome
    }

    private func perform(
        _ action: VersionRowAction, on version: ObjectVersion
    ) async -> VersionActionOutcome {
        if let refusal = refusal(of: action, on: version) { return .declined(refusal) }
        switch action {
        case .open:
            guard let open = handlers.open else { return .declined(.notAvailableHere) }
            open(version)
            return .handedOff(action)
        case .compareWithCurrent:
            guard let compare = handlers.compareWithCurrent else { return .declined(.notAvailableHere) }
            compare(version)
            return .handedOff(action)
        case .download:
            guard let download = handlers.download else { return .declined(.notAvailableHere) }
            download(version)
            return .handedOff(action)
        case .restore, .deleteVersion:
            return await write(action, on: version)
        }
    }

    /// A restore or a delete: the question, then the request, then the history
    /// read again.
    ///
    /// **`writeInProgress` covers the question as well as the request**, so a
    /// second write cannot start while the first waits for its answer, and a
    /// retry of a restore that is still running cannot make a second copy.
    ///
    /// **The gate is asked again after the answer.** The question can stand for
    /// as long as the person likes, and the history can be read again under it;
    /// the answer was given about the row as it was.
    private func write(_ action: VersionRowAction, on version: ObjectVersion) async -> VersionActionOutcome {
        guard let provider else { return .declined(.notAvailableHere) }
        writeInProgress = true
        defer { writeInProgress = false }
        guard await confirm(confirmation(for: action, on: version)) else { return .cancelled }
        if let refusal = gate(action, on: version) { return .declined(refusal) }

        let outcome: VersionActionOutcome
        do {
            switch action {
            case .restore:
                try await provider.restore(
                    key: target.key, inBucket: target.bucket, toVersionId: version.versionId)
                outcome = .restored
            case .deleteVersion:
                try await provider.deleteVersion(
                    ofKey: target.key, inBucket: target.bucket, versionId: version.versionId)
                outcome = .deleted
            case .open, .compareWithCurrent, .download:
                return .declined(.notAvailableHere)
            }
        } catch {
            // A cancelled task is not a refusal either: the request may have
            // gone out, so it is as unconfirmed as a lost connection.
            outcome = Self.outcome(of: error, for: action)
        }
        // Written at the moment the request has been answered (or lost), before
        // the history is read again: a permanent delete leaves nothing to
        // reconstruct it from, and nothing after this line may lose its trace.
        record(outcome, of: action, on: version)
        if outcome.rereadsHistory, !Task.isCancelled { await load() }
        return outcome
    }

    /// One line in the session's trail for a write that was sent: done,
    /// refused, or not confirmed. **A write that was not sent records
    /// nothing** (a "no", a refused row), and this is only reached after the
    /// request.
    ///
    /// The failure text is the outcome's own catalogue sentence
    /// (`VersionActionOutcome.line`) and never the error's: a `reason` can
    /// carry the endpoint, and that field takes `scheme://KEY:SECRET@host` as
    /// ordinary input (`AuditRecorder.recordVersionRestored`). A catalogue
    /// line is as fixed as a literal, so nothing leaks, and it is in the
    /// reader's language like every other kind's trail
    /// (`ObjectLockSheet.apply` passes a catalogue sentence too). **The
    /// sentence is chosen once**, where the outcome is made, so a reason added
    /// later cannot be recorded under another's words, and this switch has no
    /// `default:` for the same reason: a new outcome is a compile error here.
    /// The unconfirmed sentence says "could not be confirmed" for the reason
    /// the sheet's wording does: the request went out and the history does not
    /// say what became of it.
    private func record(
        _ outcome: VersionActionOutcome, of action: VersionRowAction, on version: ObjectVersion
    ) {
        guard let recorder else { return }
        let failure: String?
        switch outcome {
        case .restored, .deleted:
            failure = nil
        case .notConfirmed(let attempted):
            failure = VersionActionOutcome.notConfirmedLine(for: attempted).text
        case .refused(_, let why):
            failure = why.text
        case .handedOff, .cancelled, .declined:
            return
        }
        switch action {
        case .restore:
            recorder.recordVersionRestored(
                key: target.key, bucket: target.bucket, versionId: version.versionId, failure: failure)
        case .deleteVersion:
            recorder.recordVersionDeleted(
                key: target.key, bucket: target.bucket, versionId: version.versionId, failure: failure)
        case .open, .compareWithCurrent, .download:
            return
        }
    }

    /// What the person is asked. The restore says what it does (it writes a
    /// NEW version and keeps every other), and the delete says it is for good
    /// and names the version id it is about to remove.
    private func confirmation(
        for action: VersionRowAction, on version: ObjectVersion
    ) -> VersionConfirmation {
        let when = ObjectVersionsFormat.date(version.modifiedAt)
        switch action {
        case .deleteVersion:
            return VersionConfirmation(
                action: action, title: ObjectVersionsLines.deleteTitle,
                message: ObjectVersionsLines.deleteMessage,
                messageText: String(
                    format: ObjectVersionsLines.deleteMessage.text, target.displayName, when,
                    version.versionId),
                confirm: ObjectVersionsLines.deleteButton, isDestructive: true)
        case .restore, .open, .compareWithCurrent, .download:
            return VersionConfirmation(
                action: action, title: ObjectVersionsLines.restoreTitle,
                message: ObjectVersionsLines.restoreMessage,
                messageText: String(
                    format: ObjectVersionsLines.restoreMessage.text, target.displayName, when),
                confirm: ObjectVersionsLines.restoreButton, isDestructive: false)
        }
    }

    /// What an error from a write means for the person.
    ///
    /// **Certain refusals say nothing was changed; everything else says the
    /// outcome could not be confirmed.** The store refusing for a lock, a
    /// missing version, a missing permission or a missing capability is an
    /// answer, and nothing was written. Anything else (Core's own
    /// "the history does not show it", a connection lost before the answer, a
    /// cancelled request) leaves the write possibly done, and "failed" would
    /// be a claim nobody has checked. The history is read again after it, so
    /// the sheet shows what the store holds.
    static func outcome(of error: any Error, for action: VersionRowAction) -> VersionActionOutcome {
        switch error {
        case RemoteFSError.finding(.objectUnderRetention), RemoteFSError.finding(.objectUnderLegalHold):
            return .refused(action, why: ObjectVersionsLines.outcomeLocked)
        case RemoteFSError.notFound:
            return .refused(action, why: ObjectVersionsLines.outcomeGone)
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return .refused(action, why: ObjectVersionsLines.outcomeDenied)
        case RemoteFSError.finding(.operationNotSupported):
            return .refused(action, why: ObjectVersionsLines.outcomeUnsupported)
        default:
            return .notConfirmed(action)
        }
    }
}

extension VersionActionOutcome {
    /// Whether the sheet reads the history again after this outcome: after a
    /// write that happened or may have, and after a refusal that says the row
    /// is gone (the list on screen is stale). Not after a refusal that leaves
    /// the history as it was.
    var rereadsHistory: Bool {
        switch self {
        case .restored, .deleted, .notConfirmed: true
        case .refused(_, let why): why == ObjectVersionsLines.outcomeGone
        case .handedOff, .cancelled, .declined: false
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
    ///
    /// **What "Locked" means, decided here and on purpose: the versions KNOWN to
    /// be locked.** It includes `.locked` (a retention in force) and
    /// `.legalHold`, and nothing else. `.lockUnknown` (the read has not come
    /// back) and `.lockUnreadable` (it came back and could not be completed) are
    /// left out, because including them would call a version locked on the
    /// strength of not knowing, the mirror image of the mistake the sheet's
    /// wording rule forbids (saying "unlocked", or "off", for a state that was
    /// never measured). Those two states are shown, as themselves, in the state
    /// column and under "All".
    ///
    /// **The cost, stated:** the filter is incomplete while lock reads are still
    /// in flight, and permanently so for a row whose read failed; a version that
    /// may well be locked is absent from it with no note saying so. Whether that
    /// should change (a third segment, a count of unconfirmed rows, a note under
    /// the table) is a design call for the maintainer and nothing here makes it:
    /// no measurement says people are misled.
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
        // Each row's state is worked out ONCE, with the position the walk
        // already has, and handed to the text: the sheet's body evaluates this on
        // every render, and every recorded lock reading re-renders it.
        let all = versions.enumerated().map { position, version in
            let state = rowState(of: version, at: position)
            return ObjectVersionRow(
                version: version, state: state,
                stateText: stateText(
                    of: version, state: state,
                    metadataOnly: isMetadataOnly(version, at: position), localeCode: localeCode),
                modifiedText: ObjectVersionsFormat.date(version.modifiedAt, localeCode: localeCode),
                sizeText: ObjectVersionsFormat.size(version.size), position: position)
        }
        return all.filter {
            filter.includes($0.version, state: $0.state) && predicate.matches($0.searchString)
        }
    }
}

/// The question a restore or a delete asks, between the model that wants an
/// answer and the dialog that shows it.
///
/// `ask` suspends until `answer` is called, and every way the question can go
/// away answers it with a "no": a task that is cancelled, a second question
/// arriving, the sheet disappearing. Nothing is ever left waiting, and nothing
/// is ever answered "yes" except by the person.
@MainActor
@Observable
final class VersionConfirmationBridge {
    /// The question on screen, or `nil`.
    private(set) var request: VersionConfirmation?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    /// Called on the main actor each time a question is put up. For a test
    /// that has to wait until it is on screen: it raises a signal and awaits
    /// it, instead of polling `request`.
    @ObservationIgnored var asked: (@MainActor () -> Void)?
    /// Called on the main actor each time a question is answered, after its
    /// asker has been resumed. For a test that has to wait until a withdrawal
    /// has landed, for the reason `asked` gives.
    @ObservationIgnored var answered: (@MainActor () -> Void)?
    /// The number of the question on screen (or the last one asked).
    private(set) var questionID = 0

    func ask(_ request: VersionConfirmation) async -> Bool {
        answer(false)
        questionID += 1
        let id = questionID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.request = request
                self.continuation = continuation
                asked?()
            }
        } onCancel: {
            // Carried by a hop, because the handler is not isolated. **The hop
            // is the only withdrawal, and it always lands:** an unstructured
            // task that holds `self`, so it runs whether or not anyone is
            // still waiting. For a task that was cancelled before it asked,
            // `onCancel` runs first and spawns the hop; the asker keeps the
            // main actor until it suspends on the continuation it has just
            // installed, so the hop lands after the install and resumes it.
            // The hop can also land after the NEXT question is up, so it names
            // the question it is for (`answer(_:forQuestion:)`).
            //
            // (Withdrawn wording, verbatim, from a check that stood in the
            // body: "A task that was cancelled before it got here had its
            // handler run BEFORE this body (`withTaskCancellationHandler` runs
            // `onCancel` at once for a cancelled task), when there was nothing
            // to withdraw. Nothing would resume the continuation installed
            // just now, and the write waiting on it would hold
            // `writeInProgress` for the life of the sheet. So it is looked at
            // again here, with the continuation in place." The premise was
            // false: the hop above resumes it, one turn later. The check only
            // ever answered the same already-cancelled case one turn before
            // the hop does, which is why the plant that deleted it ("no look
            // at cancellation once installed") came back GREEN in fix round
            // 1, and why it is gone.)
            Task { @MainActor in self.answer(false, forQuestion: id) }
        }
    }

    /// Answers the question on screen, once; a second call is a no-op. With
    /// `forQuestion`, only if that question is still the one on screen: a
    /// withdrawal that arrives late must not answer a later question.
    func answer(_ yes: Bool, forQuestion id: Int? = nil) {
        if let id, id != questionID { return }
        guard let continuation else { return }
        self.continuation = nil
        request = nil
        continuation.resume(returning: yes)
        answered?()
    }
}

/// The sheet behind the file context menu's "Show Versions…": one file's
/// history in a sortable table, filtered and searched, with a counting footer.
///
/// The shape is `AuditLogSheet`'s, chosen by the maintainer on 2026-10-23 from
/// three drawn alternatives: a `Table`, a `Picker` filter, the shared
/// `SheetSearchField`, and a footer that counts. The five actions on a row are
/// its context menu (`VersionRowAction`); of them only restore and delete
/// write, each after a question (`VersionConfirmationBridge`). (Withdrawn
/// wording, verbatim: "It reads; it writes nothing. The actions on a row come
/// with the row's context menu, which is a later task's.")
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
    @State private var selection: Set<ObjectVersionRow.ID> = []
    @State private var confirmations = VersionConfirmationBridge()
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

            if let line = model.lastOutcome?.line {
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            model.confirm = { [confirmations] request in await confirmations.ask(request) }
            if model.phase == .idle { await model.load() }
        }
        // A question still on screen when the sheet goes is a "no".
        .onDisappear { confirmations.answer(false) }
        .confirmationDialog(
            confirmations.request?.title.text ?? "",
            isPresented: Binding(
                get: { confirmations.request != nil },
                set: { if !$0 { confirmations.answer(false) } }),
            titleVisibility: .visible, presenting: confirmations.request
        ) { request in
            Button(request.confirm.text, role: request.isDestructive ? .destructive : nil) {
                confirmations.answer(true)
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                confirmations.answer(false)
            }
        } message: { request in
            Text(request.messageText)
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
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
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
        .contextMenu(forSelectionType: ObjectVersionRow.ID.self) { ids in
            actionMenu(for: ids)
        }
    }

    /// The row's five actions. A row an action is not offered on is drawn
    /// disabled with the reason as its tooltip, like the file menu's rows.
    @ViewBuilder private func actionMenu(for ids: Set<ObjectVersionRow.ID>) -> some View {
        if ids.count == 1, let id = ids.first,
            let version = model.versions.first(where: { $0.versionId == id })
        {
            actionButton(.open, on: version)
            actionButton(.compareWithCurrent, on: version)
            actionButton(.download, on: version)
            Divider()
            actionButton(.restore, on: version)
            actionButton(.deleteVersion, on: version)
        }
    }

    @ViewBuilder private func actionButton(
        _ action: VersionRowAction, on version: ObjectVersion
    ) -> some View {
        let refusal = model.refusal(of: action, on: version)
        Button(action.line.text, role: action == .deleteVersion ? .destructive : nil) {
            Task { await model.action(action, on: version) }
        }
        .disabled(refusal != nil)
        .help(refusal?.line.text ?? "")
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
