import SwiftUI
import macSCPCore

/// One line of text the sheet can show: its catalogue key and the English
/// source text that seeds `en.lproj` and that `L10n.string` falls back to.
///
/// Held as data, and not spelled at the `Text(...)` that shows it, so the
/// tests can enumerate every line the sheet has and hold each to all four
/// languages (`BucketVersioningSheetTests`).
struct CatalogueLine: Equatable, Sendable {
    let key: String
    let english: String

    var text: String { L10n.string(key, english) }
}

/// What the versioning sheet knows and decides, apart from how it is drawn.
///
/// **Three states, not two.** A bucket is never-versioned, enabled or
/// suspended, and the sheet never presents suspension as "off": a suspended
/// bucket keeps every version it already stored and keeps paying for them. The
/// states a bucket can move to follow from that. `.never` cannot be written at
/// all (the store has no request that returns a bucket to it), so no state
/// offers it; "suspend" means nothing on a bucket that never kept versions, so
/// a never-versioned bucket is offered only "enable".
///
/// The model talks to the capability (`S3BucketSettings`) through `read` and
/// `apply`, both of which take the bucket as an argument: a connection started
/// at the account's bucket list has no single bucket of its own.
@MainActor
@Observable
final class BucketVersioningModel {
    /// Where the sheet is: reading the bucket, showing a known state, or
    /// showing why the read failed.
    enum Load: Equatable {
        case reading
        case known(BucketVersioning)
        case failed(String)
    }

    private(set) var load: Load
    /// Whether the bucket has Object Lock, once the sheet has read it; `nil`
    /// until then. **Three states, and `nil` is not `false`**: `false` is the
    /// store's own "this bucket has no lock" (`ObjectLockStateCache`), `nil` is
    /// that nobody has asked yet, and a model that read one as the other would
    /// offer a suspension on a bucket it knows nothing about.
    ///
    /// **Two writers, and a settled sheet CAN still be waiting on a second
    /// answer.** `read` sets it together with `load` going to `.known`, and
    /// `apply` asks again for the one bucket `read` is allowed to leave
    /// unread: a bucket that was not enabled, whose lock could not be read,
    /// is a bucket the answer did not matter for until the write made it
    /// matter. This doc comment said "never after it, so a settled sheet is
    /// never waiting on a second answer" until `d0bafd4f` added that second
    /// ask. A model built for a state (`init(current:bucketHasObjectLock:)`)
    /// is handed it; the other two inits have none, because a sheet that is
    /// still reading or whose read failed has no state to be locked in.
    private(set) var bucketHasObjectLock: Bool?
    /// The lock was asked for and the ask failed. **Distinct from `nil` with
    /// this `false`**, which is "not asked yet": an enabled bucket whose lock
    /// could not be read is offered nothing either way, but only this one has
    /// something to say about why (`blockedReason`). Set by `read` for a bucket
    /// that is not enabled (where the failure costs nothing) and by `apply`
    /// when its second ask fails too.
    private(set) var lockReadFailed = false
    /// A write is in flight.
    private(set) var isApplying = false
    /// Why the last write was refused, as a sentence; `nil` after a write that
    /// succeeded or before any.
    private(set) var applyFailure: String?

    /// A sheet that has not read the bucket yet.
    init() { load = .reading }

    /// A sheet whose bucket is known to be in `current`, and whose Object Lock
    /// is `bucketHasObjectLock` (`nil` for "not read yet"). **No default value**:
    /// a default is what lets a call site keep the behaviour from before the
    /// parameter existed without saying so, which here is offering a
    /// suspension a lock-bearing bucket cannot have.
    init(current: BucketVersioning, bucketHasObjectLock: Bool?) {
        load = .known(current)
        self.bucketHasObjectLock = bucketHasObjectLock
    }

    /// A sheet whose read already failed with `loadFailure`.
    init(loadFailure: String) { load = .failed(loadFailure) }

    /// The bucket's state, once it is known.
    var current: BucketVersioning? {
        if case .known(let state) = load { return state }
        return nil
    }

    /// The states the sheet offers to move to: one, or none while the state is
    /// unknown, and none from an enabled bucket whose Object Lock is locked or
    /// unread. Never `.never`.
    ///
    /// **Corrected 2026-10-21 (Task 11b).** This comment read, verbatim: "The
    /// states the sheet offers to move to: one, or none while the state is
    /// unknown. Never `.never`." Withdrawn: an enabled bucket was offered
    /// `.suspended` unconditionally, which is a call a bucket under Object Lock
    /// cannot take (AWS's documentation, spec section 4; not measured on this
    /// project's rig). Enabling is never gated by the lock.
    var offeredStates: [BucketVersioning] {
        switch current {
        case .never, .suspended: [.enabled]
        case .enabled: bucketHasObjectLock == false ? [.suspended] : []
        case nil: []
        }
    }

    /// Why an enabled bucket is offered nothing; `nil` in every other state.
    ///
    /// **Corrected 2026-10-21 (Task 11b, fix round 1, I1).** This comment
    /// read, verbatim: "Why an enabled bucket is offered nothing, when the
    /// reason is that it uses Object Lock; `nil` in every other state."
    /// Withdrawn: there are now two reasons. A lock READ as `true` gives
    /// `objectLockKeepsItOnLine`; a lock whose read FAILED gives
    /// `lockReadFailedLine`, because the failure no longer ends the load for
    /// every state (`read`), so an enabled bucket can stand settled with an
    /// unreadable lock, and a sheet with one state line and no button must
    /// say why.
    ///
    /// **Only for a lock that was READ or that FAILED to be.** An unread state
    /// (`nil`, `lockReadFailed == false`) offers nothing and says nothing
    /// about locks, because naming Object Lock there would assert a fact
    /// nobody has read. The lock sentence says what is true (this bucket uses
    /// Object Lock, so its versioning cannot be switched off) and does not say
    /// the store refuses anything: that versioning cannot be suspended under a
    /// lock is AWS's documentation, not something this project observed.
    var blockedReason: CatalogueLine? {
        guard current == .enabled else { return nil }
        if bucketHasObjectLock == true { return Self.objectLockKeepsItOnLine }
        if bucketHasObjectLock == nil, lockReadFailed { return Self.lockReadFailedLine }
        return nil
    }

    var blockedReasonKey: String? { blockedReason?.key }

    // MARK: - What the sheet says

    /// Where the bucket stands, in a sentence.
    var stateLine: CatalogueLine? {
        switch current {
        case .never:
            CatalogueLine(
                key: "s3.versioning.state.never",
                english: "Versioning has never been switched on for this bucket, so only the current version of each file is kept.")
        case .enabled:
            CatalogueLine(
                key: "s3.versioning.state.enabled",
                english: "Versioning is on. Every time a file is changed or deleted, the earlier version is kept.")
        case .suspended:
            CatalogueLine(
                key: "s3.versioning.state.suspended",
                english: "Versioning is suspended. Changes no longer keep earlier versions, but the versions stored before stay.")
        case nil:
            nil
        }
    }

    /// What to say BEFORE the click, about money.
    ///
    /// Suspending says what it does and what it does not do: it stops new
    /// versions being kept, it removes none that exist, and what exists keeps
    /// counting toward the bill. Enabling says it is a one-way door. Resuming
    /// a suspended bucket says what the click starts again: versions are kept
    /// on every change from then on, and they cost. It must not say the
    /// one-way thing -- that door is already shut by then. All three are plain
    /// words and name nothing of how the store works.
    ///
    /// **Corrected 2026-10-20 (Task 8 review, Minor 5).** This comment read,
    /// verbatim: "Resuming a suspended bucket has nothing further to warn
    /// about." Withdrawn: resuming was the one offered action that said
    /// nothing about cost, and `.suspended` returned `nil` here.
    var warning: CatalogueLine? {
        switch current {
        case .never:
            CatalogueLine(
                key: "s3.versioning.enableIsOneWay",
                english: "Once switched on, versioning can be suspended later but not removed. While it is on, every earlier version of a file is kept and counts toward your storage costs.")
        // An enabled bucket with no suspension on offer (a lock, or a lock
        // not known) warns about nothing: the warning describes a click that is
        // not there, and `blockedReason` stands in its place.
        case .enabled where !offeredStates.contains(.suspended):
            nil
        case .enabled:
            CatalogueLine(
                key: "s3.versioning.suspendKeepsVersions",
                english: "Suspending stops new versions from being kept. It does not remove any version that is already stored: every earlier version stays, and keeps counting toward your storage costs until it is deleted.")
        case .suspended:
            CatalogueLine(
                key: "s3.versioning.resumeKeepsVersions",
                english: "Turning versioning back on keeps the earlier version again every time a file is changed or deleted, and those versions count toward your storage costs.")
        case nil:
            nil
        }
    }

    var warningKey: String? { warning?.key }

    /// The button that moves the bucket to `target`. `nil` for `.never`, which
    /// no button moves a bucket to.
    static func actionLine(for target: BucketVersioning) -> CatalogueLine? {
        switch target {
        case .enabled:
            CatalogueLine(key: "s3.versioning.action.enable", english: "Turn On Versioning")
        case .suspended:
            CatalogueLine(key: "s3.versioning.action.suspend", english: "Suspend Versioning")
        case .never:
            nil
        }
    }

    static let titleLine = CatalogueLine(
        key: "s3.versioning.title %@", english: "Versioning for “%@”")
    static let readingLine = CatalogueLine(
        key: "s3.versioning.reading", english: "Checking the bucket's versioning…")
    static let readFailedLine = CatalogueLine(
        key: "s3.versioning.error.read", english: "The versioning of this bucket could not be read.")
    static let applyFailedLine = CatalogueLine(
        key: "s3.versioning.error.apply", english: "The versioning of this bucket could not be changed.")
    static let objectLockKeepsItOnLine = CatalogueLine(
        key: "s3.versioning.objectLockKeepsItOn",
        english: "This bucket uses Object Lock, so its versioning cannot be switched off.")
    static let lockReadFailedLine = CatalogueLine(
        key: "s3.versioning.error.lockRead",
        english: "Whether this bucket uses Object Lock could not be read, so its versioning cannot be changed here.")
    static let deniedLine = CatalogueLine(
        key: "s3.versioning.error.denied",
        english: "Your access key is not allowed to read or change the versioning of this bucket.")

    /// The lines that do not depend on the bucket's state.
    static let fixedLines: [CatalogueLine] = [
        titleLine, readingLine, readFailedLine, applyFailedLine, deniedLine, lockReadFailedLine,
    ]

    /// The lines this model shows in its current state, other than the fixed
    /// ones: where the bucket stands, the warning, the reason nothing is
    /// offered, and the offered buttons.
    ///
    /// **Corrected 2026-10-21 (Task 11b, fix round 1, M2).** This comment read,
    /// verbatim: "where the bucket stands, the warning, and the offered
    /// buttons". Withdrawn: three sources listed, four in the body
    /// (`stateLine`, `warning`, `blockedReason` and the buttons).
    var lines: [CatalogueLine] {
        [stateLine, warning, blockedReason].compactMap { $0 }
            + offeredStates.compactMap { Self.actionLine(for: $0) }
    }

    // MARK: - Talking to the store

    /// Reads `bucket`'s versioning AND whether it has Object Lock, and shows
    /// both together, or shows why one could not be read.
    ///
    /// **One load, two answers.** `offeredStates` is `[]` while the sheet is
    /// reading, and the sheet draws its action only once the load settles. If
    /// the lock answer arrived after the versioning one, a settled sheet would
    /// lose its only button for no stated reason; so `load` stays `.reading`
    /// until both are in, and `bucketHasObjectLock` is set before `load` is.
    /// The lock answer comes from the session's cache, so a second sheet on the
    /// same bucket does not read it again.
    ///
    /// **Corrected 2026-10-21 (Task 11b, fix round 1, I1).** This paragraph
    /// read, verbatim: "A failed lock read is a failed load, with its own
    /// sentence (`lockReadFailedLine`): the alternative, an unread lock beside
    /// a known state, is a sheet with no button and nothing to say about why."
    /// Withdrawn as stated for every state. The lock answer changes nothing
    /// the sheet offers or says for a bucket that is not enabled (enabling is
    /// never gated by it), so a failed ask there settles the load with
    /// `lockReadFailed` set, and only for an ENABLED bucket, where the answer
    /// is the whole decision, is it a failed load with its own sentence
    /// (`lockReadFailedLine`). Either way the sheet says why there is no
    /// button. The error is never quoted (see `message(for:applying:)`).
    func read(
        bucket: String, from settings: any S3BucketSettings, locks: ObjectLockStateCache
    ) async {
        load = .reading
        bucketHasObjectLock = nil
        lockReadFailed = false
        let state: BucketVersioning
        do {
            state = try await settings.versioning(ofBucket: bucket)
        } catch {
            load = .failed(Self.message(for: error, applying: false))
            return
        }
        let lock: Bool?
        do {
            lock = try await locks.hasObjectLock(bucket)
        } catch {
            if state == .enabled {
                load = .failed(Self.lockReadFailedLine.text)
                return
            }
            lock = nil
        }
        bucketHasObjectLock = lock
        lockReadFailed = lock == nil
        load = .known(state)
    }

    /// Moves `bucket` to `target`, if `target` is one of the offered states;
    /// anything else is dropped before a request exists.
    ///
    /// After a write the sheet shows what the store says now, read back, and
    /// not what was sent. If the read-back fails after the write succeeded the
    /// target is shown: the store accepted it.
    ///
    /// **A lock that was not read is asked for again here** (`locks`, required
    /// like `read`'s): `read` lets a bucket that was not enabled settle with an
    /// unreadable lock, and this write is what turns it into one that is. The
    /// cache keeps no failure, so this is a real second ask. If that fails
    /// too, `lockReadFailed` is set and the enabled bucket says so
    /// (`blockedReason`) instead of standing settled and silent.
    func apply(
        _ target: BucketVersioning, bucket: String, via settings: any S3BucketSettings,
        locks: ObjectLockStateCache
    ) async {
        guard !isApplying, offeredStates.contains(target) else { return }
        isApplying = true
        applyFailure = nil
        defer { isApplying = false }
        do {
            try await settings.setVersioning(target, ofBucket: bucket)
            let now = (try? await settings.versioning(ofBucket: bucket)) ?? target
            if bucketHasObjectLock == nil {
                do {
                    bucketHasObjectLock = try await locks.hasObjectLock(bucket)
                    lockReadFailed = false
                } catch {
                    lockReadFailed = true
                }
            }
            load = .known(now)
        } catch {
            applyFailure = Self.message(for: error, applying: true)
        }
    }

    /// The sentence for a failure.
    ///
    /// A finding carries no foreign text and says its own sentence. A missing
    /// permission has one of its own. Anything else is a fixed sentence: the
    /// error is NEVER quoted, because a `reason` can carry the endpoint the
    /// user typed, and that field takes `scheme://KEY:SECRET@host` as ordinary
    /// input.
    static func message(for error: any Error, applying: Bool) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            deniedLine.text
        default:
            (applying ? applyFailedLine : readFailedLine).text
        }
    }
}

/// The sheet behind the toolbar menu's "Versioning…" row: shows a bucket's
/// versioning state, what changing it does, and the one change on offer.
///
/// The bucket and the capability are captured when the sheet opens
/// (`ContentView.BucketVersioningSheetItem`), so it keeps talking to the file
/// system it was opened against.
struct BucketVersioningSheet: BoundedView {
    /// The size `BucketVersioningSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(420)

    let bucket: String
    let settings: any S3BucketSettings
    /// The session's lock-state cache (`BrowserSession.objectLockStates`),
    /// which the read asks whether the bucket has Object Lock. **Required, with
    /// no default**: a sheet that could be built without one could be built
    /// that never asks.
    let locks: ObjectLockStateCache

    @Environment(\.dismiss) private var dismiss
    @State private var model: BucketVersioningModel

    /// `model` defaults to a sheet that has not read the bucket yet. That
    /// default is safe where a default lock state would not be: such a model
    /// offers nothing until `read` has answered, and `read` takes its lock
    /// answer from `locks`, which has no default. The layout registry passes
    /// one already in a state, so a measurement does not wait for a read.
    init(
        bucket: String, settings: any S3BucketSettings, locks: ObjectLockStateCache,
        model: BucketVersioningModel = BucketVersioningModel()
    ) {
        self.bucket = bucket
        self.settings = settings
        self.locks = locks
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: BucketVersioningModel.titleLine.text, bucket))
                .font(.headline)

            content

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                if let target = model.offeredStates.first,
                    let line = BucketVersioningModel.actionLine(for: target)
                {
                    Button(line.text) {
                        Task { await model.apply(target, bucket: bucket, via: settings, locks: locks) }
                    }
                    .buttonStyle(.polishedProminent)
                    .disabled(model.isApplying)
                }
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .task {
            if case .reading = model.load {
                await model.read(bucket: bucket, from: settings, locks: locks)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.load {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(BucketVersioningModel.readingLine.text)
                    .foregroundStyle(.secondary)
            }
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .known:
            if let state = model.stateLine {
                Text(state.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.warning {
                Text(warning.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocked = model.blockedReason {
                Text(blocked.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.applyFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
