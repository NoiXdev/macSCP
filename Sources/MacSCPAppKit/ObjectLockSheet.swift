import SwiftUI
import macSCPCore

/// A date written for the reader: the locale's own long date and short time.
///
/// Every date in a sentence of the Object Lock sheets goes through here and is
/// never interpolated raw. `localeCode` is the catalogue the text is being
/// drawn in (`L10n.localeOverride`, which only a test sets); `nil` means the
/// user's own locale.
enum ObjectLockDates {
    static func text(_ date: Date, localeCode: String? = L10n.localeOverride) -> String {
        let locale = localeCode.map(Locale.init(identifier:)) ?? .current
        return date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale))
    }
}

/// The lines both Object Lock sheets share: the sentences about a bucket that
/// has no lock, the failures, and the two modes.
///
/// **No sentence here names how the store works.** A person reading these has
/// a file, a bucket and a date; "bypass", "header" and a status code are the
/// store's vocabulary, and a sentence that used them would tell the person
/// nothing they can act on.
enum ObjectLockLines {
    static let reading = CatalogueLine(
        key: "s3.objectLock.reading", english: "Checking Object Lock…")
    /// Said when the bucket has no Object Lock. The last sentence is macSCP's
    /// own scope (`S3BucketSettings` offers no call that switches it on for an
    /// existing bucket), and it is worded as that: the store would accept it.
    static let notEnabledOnThisBucket = CatalogueLine(
        key: "s3.objectLock.notEnabledOnThisBucket",
        english: "Object Lock is not switched on for this bucket, so nothing in it can be locked. macSCP does not switch it on for a bucket that already exists; it can be chosen when a bucket is created.")
    static let readFailed = CatalogueLine(
        key: "s3.objectLock.error.read", english: "Object Lock could not be read.")
    static let applyFailed = CatalogueLine(
        key: "s3.objectLock.error.apply", english: "The change could not be saved.")
    static let denied = CatalogueLine(
        key: "s3.objectLock.error.denied",
        english: "Your access key is not allowed to read or change this.")
    /// The sentence for a refused retention. A refusal reaches the app as a
    /// missing permission, and two different things produce one: a key that
    /// may not set retentions, and a retention already in force that may not be
    /// shortened. The sentence says both, as possibilities, because the answer
    /// does not tell them apart.
    static let retentionRefused = CatalogueLine(
        key: "s3.objectLock.error.refused",
        english: "The change was refused. A retention that is already in force may not be shortened, and your access key may not be allowed to change it.")
    static let saved = CatalogueLine(key: "s3.objectLock.saved", english: "Saved.")
    static let modeLabel = CatalogueLine(key: "s3.objectLock.modeLabel", english: "Mode")
    static let governance = CatalogueLine(
        key: "s3.objectLock.mode.governance", english: "Governance")
    static let compliance = CatalogueLine(
        key: "s3.objectLock.mode.compliance", english: "Compliance")
    static let governanceDetail = CatalogueLine(
        key: "s3.objectLock.mode.governance.detail",
        english: "Someone with the right permission can still shorten or remove a governance retention.")

    /// The name of a mode, as the person reads it.
    static func modeName(_ mode: RetentionMode) -> CatalogueLine {
        switch mode {
        case .governance: governance
        case .compliance: compliance
        }
    }

    static let shared: [CatalogueLine] = [
        reading, notEnabledOnThisBucket, readFailed, applyFailed, denied, retentionRefused, saved,
        modeLabel, governance, compliance, governanceDetail,
    ]

    /// What the person is doing when something fails.
    enum Phase { case reading, applyingDefault, applyingRetention, applyingHold }

    /// The sentence for a failure.
    ///
    /// A finding carries no foreign text and says its own sentence. A missing
    /// permission has one of its own, and a refused retention a more careful
    /// one. Anything else is a fixed sentence: the error is NEVER quoted,
    /// because a `reason` can carry the endpoint the user typed, and that field
    /// takes `scheme://KEY:SECRET@host` as ordinary input.
    static func message(for error: any Error, during phase: Phase) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            return finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return (phase == .applyingRetention ? retentionRefused : denied).text
        default:
            return (phase == .reading ? readFailed : applyFailed).text
        }
    }
}

/// A file the sheet is about: the bucket it is in and its key.
///
/// Worked out from the pane's path with the same two facts the connection
/// actions use (`ConnectionActionContext`): at a bucket list the first
/// component is the bucket, in one bucket the configured bucket is, and the
/// rest of the path is the key either way.
struct ObjectLockTarget: Equatable {
    let bucket: String
    let key: String

    /// The file's own name, for the title.
    var fileName: String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    /// `path` as a bucket and a key, or `nil` when it is not a file in a
    /// bucket: the bucket list itself, a bucket, or a connection with no
    /// bucket configured.
    static func resolve(path: String, in context: ConnectionActionContext) -> ObjectLockTarget? {
        let components = RemotePath.normalizedAbsolute(path).split(separator: "/").map(String.init)
        if context.rootIsContainerList {
            guard let bucket = components.first, components.count > 1 else { return nil }
            return ObjectLockTarget(bucket: bucket, key: components.dropFirst().joined(separator: "/"))
        }
        let bucket = context.configuredBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty, !components.isEmpty else { return nil }
        return ObjectLockTarget(bucket: bucket, key: components.joined(separator: "/"))
    }
}

/// The two context-menu actions this sheet answers, by the `id` the S3
/// descriptor gives them. Routed by id and never by `ConnectionKind`, as the
/// presigned-URL action beside them is.
///
/// Each action opens the same sheet for one thing only: the retention action
/// cannot place a legal hold and the legal-hold action cannot place a
/// retention. A sheet that carried both would let a click meant to lift a hold
/// sit one field away from a COMPLIANCE write.
enum ObjectLockFileAction: String, CaseIterable {
    case retention = "s3.retention"
    case legalHold = "s3.legalHold"

    init?(action: FileActionContribution) {
        self.init(rawValue: action.id)
    }

    var focus: ObjectLockModel.Focus {
        switch self {
        case .retention: .retention
        case .legalHold: .legalHold
        }
    }
}

/// What the per-file Object Lock sheet knows and decides, apart from how it is
/// drawn.
///
/// **One thing at a time.** The sheet is opened for a `Focus`: a retention, or
/// a legal hold. Only that one is read, shown and written.
///
/// **COMPLIANCE is the one choice here that cannot be taken back**, and the
/// model is built around that. A COMPLIANCE retention is lifted by nobody
/// before its date -- not the account owner, not with the bypass (measured on
/// the rig 2026-10-19). So it needs an acknowledgement that NAMES the date, and
/// the acknowledgement is a statement about one date and one mode:
///
/// - changing the date or the mode takes it back (`acknowledged` is cleared,
///   not compared), so a tick cannot stand for a date nobody read;
/// - a write spends it, so a second COMPLIANCE write is a second decision;
/// - `canRun` is the only thing `run` consults, and it consults all of
///   `RunBlocker` -- a `switch` with no `default`, so a reason added to the
///   list cannot compile without saying when it applies.
///
/// GOVERNANCE and a legal hold are both reversible and get no such ceremony.
@MainActor
@Observable
final class ObjectLockModel {
    /// What the sheet is for.
    enum Focus: CaseIterable, Equatable {
        case retention
        case legalHold
    }

    /// Whether the bucket has Object Lock at all, as far as the sheet knows.
    enum BucketLock: Equatable {
        case reading
        case present
        case absent
        case failed(String)
    }

    /// What the store says about the file: its retention (read for the
    /// retention focus) and its hold (read for the legal-hold focus). The half
    /// that is not this sheet's is left at its empty value and never shown.
    struct Current: Equatable {
        var retention: ObjectRetention?
        var legalHold: Bool
    }

    /// Everything that can keep the button off. A reason per case, and
    /// `isActive(_:)` says when each applies; there is no `default` anywhere,
    /// so adding one here does not compile until both say what it means.
    enum RunBlocker: CaseIterable, Equatable {
        case lockUnread
        case lockReadFailed
        case noLockOnBucket
        case currentUnread
        case dateNotInFuture
        case complianceNotAcknowledged
        case holdUnchanged
        case applying
    }

    let focus: Focus
    private let now: () -> Date

    private(set) var bucketLock: BucketLock
    private(set) var current: Current?
    private(set) var currentFailure: String?
    private(set) var isApplying = false
    private(set) var applyFailure: String?
    private(set) var isSaved = false

    /// GOVERNANCE until the person picks otherwise: the reversible choice is
    /// the one the sheet starts on.
    var mode: RetentionMode = .governance {
        didSet {
            guard mode != oldValue else { return }
            acknowledged = false
            isSaved = false
        }
    }

    /// The date the retention runs to. A change takes the acknowledgement back.
    var retainUntil: Date {
        didSet {
            guard retainUntil != oldValue else { return }
            acknowledged = false
            isSaved = false
        }
    }

    /// The tick on the COMPLIANCE sentence. Meaningful only in COMPLIANCE, and
    /// valid only for the mode and date it was given for (see the type).
    var acknowledged = false

    /// Whether the person wants the file under a legal hold.
    var legalHold = false {
        didSet {
            if legalHold != oldValue { isSaved = false }
        }
    }

    /// A sheet that has not read anything yet.
    init(focus: Focus = .retention, now: @escaping () -> Date = { Date() }) {
        self.focus = focus
        self.now = now
        bucketLock = .reading
        current = nil
        retainUntil = Self.defaultDate(from: now())
    }

    /// A sheet in a given state; the designated form the others forward to.
    init(
        focus: Focus = .retention, bucketLock: BucketLock, current: Current?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.focus = focus
        self.now = now
        self.bucketLock = bucketLock
        self.current = current
        retainUntil = Self.defaultDate(from: now())
    }

    /// A sheet for a bucket whose lock is known, over a file with nothing set.
    convenience init(
        focus: Focus = .retention, bucketHasLock: Bool, now: @escaping () -> Date = { Date() }
    ) {
        self.init(
            focus: focus, bucketLock: bucketHasLock ? .present : .absent,
            current: Current(retention: nil, legalHold: false), now: now)
    }

    /// A sheet whose lock read already failed with `loadFailure`.
    convenience init(
        focus: Focus = .retention, loadFailure: String, now: @escaping () -> Date = { Date() }
    ) {
        self.init(focus: focus, bucketLock: .failed(loadFailure), current: nil, now: now)
    }

    /// A week ahead, to the whole minute: the shortest of the usual choices, so
    /// the sheet does not start on a long lock, and a time with no seconds,
    /// because the picker edits hours and minutes and the sentence names them.
    /// A date that carried seconds the sentence does not show would be a lock
    /// that ends later than the person was told.
    private static func defaultDate(from now: Date) -> Date {
        let calendar = Calendar.current
        let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return calendar.dateInterval(of: .minute, for: week)?.start ?? week
    }

    /// The earliest date the picker offers.
    var earliestDate: Date { now() }

    // MARK: - Whether it can run

    func isActive(_ blocker: RunBlocker) -> Bool {
        switch blocker {
        case .lockUnread:
            bucketLock == .reading
        case .lockReadFailed:
            if case .failed = bucketLock { true } else { false }
        case .noLockOnBucket:
            bucketLock == .absent
        case .currentUnread:
            current == nil
        case .dateNotInFuture:
            focus == .retention && retainUntil <= now()
        case .complianceNotAcknowledged:
            focus == .retention && mode == .compliance && !acknowledged
        case .holdUnchanged:
            focus == .legalHold && legalHold == (current?.legalHold ?? false)
        case .applying:
            isApplying
        }
    }

    var activeBlockers: [RunBlocker] {
        RunBlocker.allCases.filter { isActive($0) }
    }

    var canRun: Bool { activeBlockers.isEmpty }

    /// The catalogue key of the sentence that says this bucket has no lock;
    /// `nil` while it has one or the answer is not in.
    var unavailableReasonKey: String? {
        bucketLock == .absent ? ObjectLockLines.notEnabledOnThisBucket.key : nil
    }

    // MARK: - What the sheet says

    static let complianceWarningLine = CatalogueLine(
        key: "s3.objectLock.complianceWarning",
        english: "Compliance cannot be undone. Once it is saved, nobody can erase this file's stored data or shorten the retention until the date below has passed — not you, not the account owner, not an administrator.")
    static let complianceAcknowledgementLine = CatalogueLine(
        key: "s3.objectLock.complianceAcknowledgement %@",
        english: "I understand that nobody, including me, can erase this file's stored data or shorten this retention before %@, and that this cannot be undone.")
    static let untilLabel = CatalogueLine(
        key: "s3.objectLock.untilLabel", english: "Keep until")
    static let holdToggleLine = CatalogueLine(
        key: "s3.objectLock.legalHold.toggle", english: "Keep this file under a legal hold")
    static let holdDetailLine = CatalogueLine(
        key: "s3.objectLock.legalHold.detail",
        english: "A legal hold keeps the file's stored data from being erased until the hold is lifted. It has no end date and can be lifted at any time.")
    static let noRetentionLine = CatalogueLine(
        key: "s3.objectLock.current.noRetention", english: "This file has no retention.")
    static let retentionLine = CatalogueLine(
        key: "s3.objectLock.current.retention %1$@ %2$@",
        english: "Current retention: %1$@, until %2$@.")
    static let holdOnLine = CatalogueLine(
        key: "s3.objectLock.current.legalHoldOn", english: "This file is under a legal hold.")
    static let holdOffLine = CatalogueLine(
        key: "s3.objectLock.current.legalHoldOff", english: "This file is not under a legal hold.")
    static let setRetentionLine = CatalogueLine(
        key: "s3.objectLock.action.setRetention", english: "Set Retention")
    static let placeHoldLine = CatalogueLine(
        key: "s3.objectLock.action.placeHold", english: "Place Legal Hold")
    static let liftHoldLine = CatalogueLine(
        key: "s3.objectLock.action.liftHold", english: "Lift Legal Hold")
    static let retentionTitleLine = CatalogueLine(
        key: "s3.objectLock.title.retention %@", english: "Retention for “%@”")
    static let holdTitleLine = CatalogueLine(
        key: "s3.objectLock.title.legalHold %@", english: "Legal Hold for “%@”")
    static let datePastLine = CatalogueLine(
        key: "s3.objectLock.blocked.datePast", english: "Choose a date and time that is still ahead.")
    static let notAcknowledgedLine = CatalogueLine(
        key: "s3.objectLock.blocked.notAcknowledged", english: "Tick the box to confirm.")
    static let holdUnchangedLine = CatalogueLine(
        key: "s3.objectLock.blocked.holdUnchanged",
        english: "The legal hold is already set this way, so there is nothing to change.")

    static func titleLine(for focus: Focus) -> CatalogueLine {
        switch focus {
        case .retention: retentionTitleLine
        case .legalHold: holdTitleLine
        }
    }

    /// The sentence the tick answers, with the date it is about written for
    /// the reader.
    var acknowledgementKey: String { Self.complianceAcknowledgementLine.key }
    var acknowledgementDateText: String { ObjectLockDates.text(retainUntil) }
    var acknowledgementSentence: String {
        String(format: Self.complianceAcknowledgementLine.text, acknowledgementDateText)
    }

    /// The line that says where the file stands. For a retention it is the
    /// template (`retentionLine`) with two arguments, filled in at drawing time
    /// by `currentSentence`.
    var currentLine: CatalogueLine? {
        guard let current else { return nil }
        switch focus {
        case .retention:
            return current.retention == nil ? Self.noRetentionLine : Self.retentionLine
        case .legalHold:
            return current.legalHold ? Self.holdOnLine : Self.holdOffLine
        }
    }

    /// `currentLine` as a sentence: the retention's mode and date are filled in
    /// at the moment of drawing, in the reader's language.
    var currentSentence: String? {
        guard let current else { return nil }
        switch focus {
        case .retention:
            guard let retention = current.retention else { return Self.noRetentionLine.text }
            return String(
                format: Self.retentionLine.text, ObjectLockLines.modeName(retention.mode).text,
                ObjectLockDates.text(retention.retainUntil))
        case .legalHold:
            return (current.legalHold ? Self.holdOnLine : Self.holdOffLine).text
        }
    }

    /// The detail under the mode choice: the plain note for GOVERNANCE, and for
    /// COMPLIANCE the warning that it cannot be undone.
    var modeDetailLine: CatalogueLine? {
        guard focus == .retention else { return nil }
        switch mode {
        case .governance: return ObjectLockLines.governanceDetail
        case .compliance: return Self.complianceWarningLine
        }
    }

    static func explanation(for blocker: RunBlocker) -> CatalogueLine? {
        switch blocker {
        case .noLockOnBucket: ObjectLockLines.notEnabledOnThisBucket
        case .dateNotInFuture: datePastLine
        case .complianceNotAcknowledged: notAcknowledgedLine
        case .holdUnchanged: holdUnchangedLine
        case .lockUnread, .lockReadFailed, .currentUnread, .applying: nil
        }
    }

    /// Why the button is off, when a sentence can say it. Silence is for the
    /// blockers the sheet already shows as progress or as a red sentence.
    var explanation: CatalogueLine? {
        activeBlockers.lazy.compactMap { Self.explanation(for: $0) }.first
    }

    /// The button's label.
    var actionLine: CatalogueLine {
        switch focus {
        case .retention: Self.setRetentionLine
        case .legalHold: legalHold ? Self.placeHoldLine : Self.liftHoldLine
        }
    }

    /// The lines that do not depend on the model's state.
    static let fixedLines: [CatalogueLine] =
        ObjectLockLines.shared + [
            complianceWarningLine, complianceAcknowledgementLine, untilLabel, holdToggleLine,
            holdDetailLine, noRetentionLine, retentionLine, holdOnLine, holdOffLine,
            setRetentionLine, placeHoldLine, liftHoldLine, retentionTitleLine, holdTitleLine,
            datePastLine, notAcknowledgedLine, holdUnchangedLine,
        ]

    /// The lines this model shows in its current state.
    var lines: [CatalogueLine] {
        [currentLine, modeDetailLine, explanation, actionLine].compactMap { $0 }
    }

    // MARK: - Talking to the store

    /// Reads whether `bucket` has Object Lock (once per bucket, through the
    /// session's cache) and, if it does, the file's current state.
    func load(
        key: String, bucket: String, via settings: any S3BucketSettings,
        cache: ObjectLockStateCache
    ) async {
        bucketLock = .reading
        current = nil
        currentFailure = nil
        do {
            bucketLock = try await cache.hasObjectLock(bucket) ? .present : .absent
        } catch {
            bucketLock = .failed(ObjectLockLines.message(for: error, during: .reading))
            return
        }
        guard bucketLock == .present else { return }
        do {
            switch focus {
            case .retention:
                let retention = try await settings.retention(
                    ofKey: key, inBucket: bucket, versionId: nil)
                current = Current(retention: retention, legalHold: false)
            case .legalHold:
                let held = try await settings.legalHold(ofKey: key, inBucket: bucket, versionId: nil)
                current = Current(retention: nil, legalHold: held)
                legalHold = held
            }
        } catch {
            currentFailure = ObjectLockLines.message(for: error, during: .reading)
        }
    }

    /// Writes what the sheet is for -- the retention or the hold, never both --
    /// if and only if `canRun`.
    ///
    /// The COMPLIANCE write is the date that was acknowledged: the fields it
    /// reads are the ones whose change clears the tick. After a write the
    /// sheet shows what the store says now, read back, and the tick is spent.
    func run(key: String, bucket: String, via settings: any S3BucketSettings) async {
        guard canRun else { return }
        isApplying = true
        applyFailure = nil
        isSaved = false
        defer { isApplying = false }
        switch focus {
        case .retention:
            let written = ObjectRetention(mode: mode, retainUntil: retainUntil)
            do {
                try await settings.setRetention(
                    written, ofKey: key, inBucket: bucket, versionId: nil)
                let readBack =
                    (try? await settings.retention(ofKey: key, inBucket: bucket, versionId: nil))
                    ?? written
                current = Current(retention: readBack, legalHold: current?.legalHold ?? false)
                acknowledged = false
                isSaved = true
            } catch {
                applyFailure = ObjectLockLines.message(for: error, during: .applyingRetention)
            }
        case .legalHold:
            let wanted = legalHold
            do {
                try await settings.setLegalHold(wanted, ofKey: key, inBucket: bucket, versionId: nil)
                let readBack =
                    (try? await settings.legalHold(ofKey: key, inBucket: bucket, versionId: nil))
                    ?? wanted
                current = Current(retention: current?.retention, legalHold: readBack)
                legalHold = readBack
                isSaved = true
            } catch {
                applyFailure = ObjectLockLines.message(for: error, during: .applyingHold)
            }
        }
    }
}

/// The sheet behind the file context menu's "Retention…" and "Legal Hold…":
/// shows what a file is locked with, and sets it.
///
/// The target and the capability are captured when the sheet opens
/// (`ContentView.ObjectLockSheetItem`), so it keeps talking to the file system
/// it was opened against.
struct ObjectLockSheet: BoundedView {
    /// The size `ObjectLockSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(460)

    let target: ObjectLockTarget
    let settings: any S3BucketSettings
    let cache: ObjectLockStateCache

    @Environment(\.dismiss) private var dismiss
    @State private var model: ObjectLockModel

    /// `model` defaults to a sheet that has not read anything yet. The layout
    /// registry passes one already in a state, so a measurement does not wait
    /// for a read.
    init(
        focus: ObjectLockModel.Focus, target: ObjectLockTarget, settings: any S3BucketSettings,
        cache: ObjectLockStateCache, model: ObjectLockModel? = nil
    ) {
        self.target = target
        self.settings = settings
        self.cache = cache
        _model = State(initialValue: model ?? ObjectLockModel(focus: focus))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: ObjectLockModel.titleLine(for: model.focus).text, target.fileName))
                .font(.headline)
                .lineLimit(2)

            content

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                Button(model.actionLine.text) {
                    Task { await model.run(key: target.key, bucket: target.bucket, via: settings) }
                }
                .buttonStyle(.polishedProminent)
                .disabled(!model.canRun)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .task {
            if case .reading = model.bucketLock {
                await model.load(
                    key: target.key, bucket: target.bucket, via: settings, cache: cache)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.bucketLock {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ObjectLockLines.reading.text).foregroundStyle(.secondary)
            }
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .absent:
            Text(ObjectLockLines.notEnabledOnThisBucket.text)
                .fixedSize(horizontal: false, vertical: true)
        case .present:
            present
        }
    }

    @ViewBuilder private var present: some View {
        if let failure = model.currentFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let sentence = model.currentSentence {
            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
            switch model.focus {
            case .retention: retentionForm
            case .legalHold: legalHoldForm
            }
            if let why = model.explanation {
                Text(why.text)
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
            if model.isSaved {
                Text(ObjectLockLines.saved.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ObjectLockLines.reading.text).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var retentionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ObjectLockLines.modeLabel.text).font(.subheadline)
            RadioChoice(ObjectLockLines.modeLabel.text, selection: $model.mode) {
                ObjectLockLines.modeName($0).text
            }
            if let detail = model.modeDetailLine {
                Text(detail.text)
                    .font(.caption)
                    .foregroundStyle(model.mode == .compliance ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ObjectLockModel.untilLabel.text).font(.subheadline)
            DatePicker(
                ObjectLockModel.untilLabel.text, selection: $model.retainUntil,
                in: model.earliestDate..., displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .fixedSize()
            if model.mode == .compliance {
                CheckboxRow(model.acknowledgementSentence, isOn: $model.acknowledged, wraps: true)
            }
        }
    }

    @ViewBuilder private var legalHoldForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            CheckboxRow(ObjectLockModel.holdToggleLine.text, isOn: $model.legalHold)
            Text(ObjectLockModel.holdDetailLine.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
