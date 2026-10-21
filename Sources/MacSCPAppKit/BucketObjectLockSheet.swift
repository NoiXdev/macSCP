import SwiftUI
import macSCPCore

/// What the bucket-default Object Lock sheet knows and decides, apart from how
/// it is drawn.
///
/// A default is a mode and a number of days that every object written AFTER it
/// is set receives (measured on the rig 2026-10-19: an object already in the
/// bucket stays unlocked). It is not one file's lock but every future file's,
/// which is what makes a COMPLIANCE default the most far-reaching irreversible
/// choice on this branch, and why it is held to the same standard as the
/// per-file one (`ObjectLockModel`): an acknowledgement that is cleared by any
/// change to the days or the mode, spent by the write, and consulted through a
/// list of reasons with no `default`.
///
/// **There is no single date to name**, because each file is locked from the
/// moment it is saved. The acknowledgement therefore says what is the same for
/// every file -- that nobody can erase one's stored data for the number of days
/// set above -- and names the date a file saved right now would stay locked
/// until, so the person reads an actual day and not only a count.
///
/// A default expressed in YEARS is a default Core cannot report
/// (`S3BucketSettings.objectLockDefault` refuses it rather than convert it).
/// The sheet shows that as a failed read and offers no save: a save would
/// replace a default nobody was shown.
@MainActor
@Observable
final class BucketObjectLockModel {
    /// Whether the bucket has Object Lock at all, as far as the sheet knows.
    enum BucketLock: Equatable {
        case reading
        case present
        case absent
        case failed(String)
    }

    /// The default as the store reports it.
    typealias Default = (days: Int, mode: RetentionMode)

    /// Everything that can keep Save off; see `ObjectLockModel.RunBlocker`.
    enum SaveBlocker: CaseIterable, Equatable {
        case lockUnread
        case lockReadFailed
        case noLockOnBucket
        case currentUnread
        case daysOutOfRange
        case acknowledgementStale
        case complianceNotAcknowledged
        case unchanged
        case applying
    }

    /// The periods macSCP will set a default for: from one day to a hundred
    /// years' worth. The floor is Core's (`setObjectLockDefault` refuses fewer
    /// than one day); the ceiling is macSCP's own and not a claim about any
    /// store. Some ceiling is needed so the date arithmetic behind the
    /// acknowledgement cannot fail: for an absurd count `Calendar.date(byAdding:)`
    /// answers `nil`, and the sentence would then name the wrong day. That
    /// reason is for having one, not for this figure; 36,500 days is the choice
    /// macSCP made, and it is a policy figure, not the calendar's limit.
    ///
    /// **Corrected 2026-10-21 (fix round 1, Minor 7).** The second half of this
    /// comment read, verbatim: "It exists because the acknowledgement names the
    /// day a file added now stays locked until, and a period too long for the
    /// calendar to count would leave that sentence naming the wrong day."
    /// Withdrawn as an account of 36,500: a hundred years is well inside what
    /// the calendar counts; the sentence is true of a count near `Int.max`.
    static let dayRange = 1...36_500

    private let now: () -> Date

    private(set) var bucketLock: BucketLock
    /// The default now in force, once read; `nil` both before it is read and
    /// when the bucket has none (`currentRead` tells those apart).
    private(set) var current: Default?
    private(set) var currentRead: Bool
    private(set) var currentFailure: String?
    private(set) var isApplying = false
    private(set) var applyFailure: String?
    private(set) var isSaved = false

    var mode: RetentionMode = .governance {
        didSet {
            guard mode != oldValue else { return }
            acknowledged = false
            isSaved = false
        }
    }

    var days = 30 {
        didSet {
            guard days != oldValue else { return }
            acknowledged = false
            isSaved = false
        }
    }

    /// The tick on the COMPLIANCE sentence; valid only for the mode and days it
    /// was given for, and for the DAY it named (`acknowledgedDay`).
    var acknowledged = false {
        didSet {
            // As `mode` and `days` do: a second write of the same value (a binding
            // writing back) is not a new tick, and must not stamp a new day onto
            // an old one (fix round 2, NEW-3).
            guard acknowledged != oldValue else { return }
            acknowledgedDay = acknowledged ? acknowledgementDate : nil
        }
    }

    /// How many saves were refused. In production code only the stale blocker
    /// reads it; see there. (A test reads it too.)
    ///
    /// **Corrected 2026-10-21 (fix round 3, NEW-4).** This comment read,
    /// verbatim: "How many saves were refused. Only the stale blocker reads it;
    /// see there." True of `Sources`, and false of the tree: the test that holds
    /// the click reads it twice.
    private(set) var refusedSaves = 0

    /// The day the sentence named when the tick was given. The sentence is
    /// worked out from the clock, and the clock moves while the sheet is open:
    /// a tick for one day does not stand for another (fix round 1, Minor 2;
    /// `acknowledgementDate` used to be recomputed on every read while the tick
    /// stood). Compared on a DAY, not an instant, because a file added a
    /// minute from now is locked until a minute later than that, and a
    /// sentence that named the minute would be stale the moment it was read.
    private var acknowledgedDay: Date?

    /// A sheet that has not read the bucket yet.
    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        bucketLock = .reading
        currentRead = false
        current = nil
    }

    /// A sheet in a given state; the designated form the others forward to.
    init(
        bucketLock: BucketLock, currentRead: Bool, current: Default?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.now = now
        self.bucketLock = bucketLock
        self.currentRead = currentRead
        self.current = current
        if let current {
            days = current.days
            mode = current.mode
        }
        acknowledged = false
    }

    /// A sheet for a bucket whose lock and default are known.
    convenience init(
        bucketHasLock: Bool, current: Default?, now: @escaping () -> Date = { Date() }
    ) {
        self.init(
            bucketLock: bucketHasLock ? .present : .absent, currentRead: true, current: current,
            now: now)
    }

    /// A sheet whose lock read already failed with `loadFailure`.
    convenience init(loadFailure: String, now: @escaping () -> Date = { Date() }) {
        self.init(bucketLock: .failed(loadFailure), currentRead: false, current: nil, now: now)
    }

    // MARK: - Whether it can be saved

    func isActive(_ blocker: SaveBlocker) -> Bool {
        switch blocker {
        case .lockUnread:
            bucketLock == .reading
        case .lockReadFailed:
            if case .failed = bucketLock { true } else { false }
        case .noLockOnBucket:
            bucketLock == .absent
        case .currentUnread:
            !currentRead
        case .daysOutOfRange:
            !Self.dayRange.contains(days)
        case .acknowledgementStale:
            acknowledgementIsStale
        case .complianceNotAcknowledged:
            mode == .compliance && !acknowledged
        case .unchanged:
            if let current { current.days == days && current.mode == mode } else { false }
        case .applying:
            isApplying
        }
    }

    /// Ticked, for a day that is not the day the sentence names now. Reading
    /// `refusedSaves` is what lets a click on a stale tick redraw the sheet: the
    /// clock is not observable, so nothing else this reads changes when
    /// midnight passes.
    private var acknowledgementIsStale: Bool {
        _ = refusedSaves
        return mode == .compliance && acknowledged && acknowledgedDay != acknowledgementDate
    }

    var activeBlockers: [SaveBlocker] {
        SaveBlocker.allCases.filter { isActive($0) }
    }

    var canSave: Bool { activeBlockers.isEmpty }

    var unavailableReasonKey: String? {
        bucketLock == .absent ? ObjectLockLines.notEnabledOnThisBucket.key : nil
    }

    // MARK: - What the sheet says

    static let titleLine = CatalogueLine(
        key: "s3.objectLock.default.title %@", english: "Object Lock default for “%@”")
    static let currentNoneLine = CatalogueLine(
        key: "s3.objectLock.default.current.none",
        english: "This bucket has no default retention.")
    /// The days are a figure beside a label and never inside a plural: a
    /// sentence that counted them would need a plural form in four languages.
    static let currentLine = CatalogueLine(
        key: "s3.objectLock.default.current %1$@ %2$lld",
        english: "Current default: %1$@ mode, retention period in days: %2$lld.")
    static let daysLabel = CatalogueLine(
        key: "s3.objectLock.default.daysLabel", english: "Retention period in days")
    static let appliesLaterLine = CatalogueLine(
        key: "s3.objectLock.default.appliesLater",
        english: "The default applies to files added after it is set. Files already in the bucket are not changed.")
    static let complianceWarningLine = CatalogueLine(
        key: "s3.objectLock.default.complianceWarning",
        english: "Compliance cannot be undone. Every file added to this bucket from now on is locked for the number of days above, counted from the moment it is saved. Nobody can erase a locked file's stored data or shorten its retention before then — not you, not the account owner, not an administrator.")
    static let complianceAcknowledgementLine = CatalogueLine(
        key: "s3.objectLock.default.complianceAcknowledgement %@",
        english: "I understand that nobody, including me, can erase the stored data of any file added to this bucket from now on for the number of days set above, and that this cannot be undone. A file added now stays locked until %@.")
    static let saveLine = CatalogueLine(
        key: "s3.objectLock.default.action.save", english: "Save Default")
    /// The days are a figure and never inside a plural, as in `currentLine`.
    static let daysOutOfRangeLine = CatalogueLine(
        key: "s3.objectLock.default.blocked.daysOutOfRange %lld",
        english: "Enter a number of days from 1 to %lld.")
    static let notAcknowledgedLine = CatalogueLine(
        key: "s3.objectLock.default.blocked.notAcknowledged", english: "Tick the box to confirm.")
    /// The box is ticked and the day it was ticked for has gone by, so it
    /// confirms nothing: said as that, and not as "tick the box" beside a box
    /// that is ticked (fix round 2, NEW-1).
    static let staleLine = CatalogueLine(
        key: "s3.objectLock.default.blocked.acknowledgementStale",
        english: "The day has changed since you ticked the box. Untick it and tick it again to confirm the new day.")
    static let unchangedLine = CatalogueLine(
        key: "s3.objectLock.default.blocked.unchanged",
        english: "The bucket already has this default, so there is nothing to change.")

    /// Failures are the shared sentences, under the names the tests use.
    static var readFailedLine: CatalogueLine { ObjectLockLines.readFailed }
    static var applyFailedLine: CatalogueLine { ObjectLockLines.applyFailed }

    var acknowledgementKey: String { Self.complianceAcknowledgementLine.key }

    /// The day a file saved right now would stay locked until: a day, with no
    /// time of day (see `acknowledgedDay`).
    ///
    /// Only meaningful while `days` is in `dayRange`, which saving requires; out
    /// of it, the date is the clock's and nothing can be saved on it.
    var acknowledgementDate: Date {
        let calendar = Calendar.current
        let counted = min(max(days, Self.dayRange.lowerBound), Self.dayRange.upperBound)
        let later = calendar.date(byAdding: .day, value: counted, to: now()) ?? now()
        return calendar.startOfDay(for: later)
    }
    var acknowledgementDateText: String { ObjectLockDates.dayText(acknowledgementDate) }
    var acknowledgementSentence: String {
        String(format: Self.complianceAcknowledgementLine.text, acknowledgementDateText)
    }

    /// Where the bucket stands, as the template line (see `currentSentence`).
    var currentLine: CatalogueLine {
        current == nil ? Self.currentNoneLine : Self.currentLine
    }

    /// `currentLine` as a sentence.
    var currentSentence: String {
        guard let current else { return Self.currentNoneLine.text }
        return String(
            format: Self.currentLine.text, ObjectLockLines.modeName(current.mode).text,
            current.days)
    }

    var modeDetailLine: CatalogueLine {
        switch mode {
        case .governance: ObjectLockLines.governanceDetail
        case .compliance: Self.complianceWarningLine
        }
    }

    static func explanation(for blocker: SaveBlocker) -> CatalogueLine? {
        switch blocker {
        case .noLockOnBucket: ObjectLockLines.notEnabledOnThisBucket
        case .daysOutOfRange: daysOutOfRangeLine
        case .acknowledgementStale: staleLine
        case .complianceNotAcknowledged: notAcknowledgedLine
        case .unchanged: unchangedLine
        case .lockUnread, .lockReadFailed, .currentUnread, .applying: nil
        }
    }

    var explanation: CatalogueLine? {
        activeBlockers.lazy.compactMap { Self.explanation(for: $0) }.first
    }

    /// `explanation` as a sentence: the one line with a figure in it has it
    /// filled in.
    var explanationSentence: String? {
        guard let line = explanation else { return nil }
        if line.key == Self.daysOutOfRangeLine.key {
            return String(format: line.text, Self.dayRange.upperBound)
        }
        return line.text
    }

    static let fixedLines: [CatalogueLine] =
        ObjectLockLines.shared + [
            titleLine, currentNoneLine, currentLine, daysLabel, appliesLaterLine,
            complianceWarningLine, complianceAcknowledgementLine, saveLine, daysOutOfRangeLine,
            notAcknowledgedLine, staleLine, unchangedLine,
        ]

    var lines: [CatalogueLine] {
        [currentLine, modeDetailLine, explanation].compactMap { $0 }
    }

    // MARK: - Talking to the store

    /// Reads whether `bucket` has Object Lock (once per bucket, through the
    /// session's cache) and, if it does, its default; the fields start on the
    /// default the bucket has.
    func load(
        bucket: String, via settings: any S3BucketSettings, cache: ObjectLockStateCache
    ) async {
        bucketLock = .reading
        currentRead = false
        current = nil
        currentFailure = nil
        // A read starts the decision over, failed or not, as the per-file sheet's
        // does (fix round 2). This used to happen only at the end of a read that
        // succeeded, which left a tick from before standing after a failed one.
        acknowledged = false
        do {
            bucketLock = try await cache.hasObjectLock(bucket) ? .present : .absent
        } catch {
            bucketLock = .failed(ObjectLockLines.message(for: error, during: .reading))
            return
        }
        guard bucketLock == .present else { return }
        do {
            let read = try await settings.objectLockDefault(ofBucket: bucket)
            current = read
            currentRead = true
            if let read {
                days = read.days
                mode = read.mode
            }
        } catch {
            currentFailure = ObjectLockLines.message(for: error, during: .reading)
        }
    }

    /// Writes the default if and only if `canSave`. The sheet then shows what
    /// the store says now, read back, and the tick is spent.
    func save(bucket: String, via settings: any S3BucketSettings) async {
        // A refusal is counted so that the sheet, which cannot see the clock,
        // redraws and says why (a stale tick), instead of the click doing
        // nothing the person can see. The tick itself is left standing.
        //
        // **Changed 2026-10-21 (fix round 2).** This function first began,
        // verbatim: "A tick for another day is taken back here, where the person
        // sees the box clear and the sentence name the day it names now." and
        // cleared the tick. Withdrawn: the only sentence left to explain it was
        // the generic "Tick the box to confirm.", an instruction to redo what
        // they had just done.
        guard canSave else {
            refusedSaves += 1
            return
        }
        isApplying = true
        applyFailure = nil
        isSaved = false
        defer { isApplying = false }
        let written: Default = (days: days, mode: mode)
        do {
            try await settings.setObjectLockDefault(
                days: written.days, mode: written.mode, ofBucket: bucket)
            let readBack = (try? await settings.objectLockDefault(ofBucket: bucket)) ?? written
            current = readBack
            currentRead = true
            acknowledged = false
            isSaved = true
        } catch {
            applyFailure = ObjectLockLines.message(for: error, during: .applyingDefault)
        }
    }
}

/// The sheet behind the toolbar menu's "Object Lock…" row: the bucket's default
/// retention, which applies to files added from then on.
///
/// The bucket and the capability are captured when the sheet opens
/// (`ContentView.BucketObjectLockSheetItem`).
struct BucketObjectLockSheet: BoundedView {
    /// The size `BucketObjectLockSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(460)

    let bucket: String
    let settings: any S3BucketSettings
    let cache: ObjectLockStateCache

    @Environment(\.dismiss) private var dismiss
    @State private var model: BucketObjectLockModel

    init(
        bucket: String, settings: any S3BucketSettings, cache: ObjectLockStateCache,
        model: BucketObjectLockModel = BucketObjectLockModel()
    ) {
        self.bucket = bucket
        self.settings = settings
        self.cache = cache
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: BucketObjectLockModel.titleLine.text, bucket))
                .font(.headline)

            content

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                Button(BucketObjectLockModel.saveLine.text) {
                    Task { await model.save(bucket: bucket, via: settings) }
                }
                .buttonStyle(.polishedProminent)
                .disabled(!model.canSave)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .task {
            if case .reading = model.bucketLock {
                await model.load(bucket: bucket, via: settings, cache: cache)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.bucketLock {
        case .reading:
            progress
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

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(ObjectLockLines.reading.text).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var present: some View {
        if let failure = model.currentFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.currentRead {
            progress
        } else {
            Text(model.currentSentence)
                .fixedSize(horizontal: false, vertical: true)
            Text(BucketObjectLockModel.appliesLaterLine.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            form
            if let why = model.explanationSentence {
                Text(why)
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
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ObjectLockLines.modeLabel.text).font(.subheadline)
            RadioChoice(ObjectLockLines.modeLabel.text, selection: $model.mode) {
                ObjectLockLines.modeName($0).text
            }
            Text(model.modeDetailLine.text)
                .font(.caption)
                .foregroundStyle(model.mode == .compliance ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(BucketObjectLockModel.daysLabel.text).font(.subheadline)
            HStack(spacing: 8) {
                TextField("", value: $model.days, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityLabel(BucketObjectLockModel.daysLabel.text)
                Stepper("", value: $model.days, in: BucketObjectLockModel.dayRange)
                    .labelsHidden()
            }
            if model.mode == .compliance {
                CheckboxRow(model.acknowledgementSentence, isOn: $model.acknowledged, wraps: true)
            }
        }
    }
}
