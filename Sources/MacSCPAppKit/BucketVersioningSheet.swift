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
    /// A write is in flight.
    private(set) var isApplying = false
    /// Why the last write was refused, as a sentence; `nil` after a write that
    /// succeeded or before any.
    private(set) var applyFailure: String?

    /// A sheet that has not read the bucket yet.
    init() { load = .reading }

    /// A sheet whose bucket is known to be in `current`.
    init(current: BucketVersioning) { load = .known(current) }

    /// A sheet whose read already failed with `loadFailure`.
    init(loadFailure: String) { load = .failed(loadFailure) }

    /// The bucket's state, once it is known.
    var current: BucketVersioning? {
        if case .known(let state) = load { return state }
        return nil
    }

    /// The states the sheet offers to move to: one, or none while the state is
    /// unknown. Never `.never`.
    var offeredStates: [BucketVersioning] {
        switch current {
        case .never, .suspended: [.enabled]
        case .enabled: [.suspended]
        case nil: []
        }
    }

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
    /// counting toward the bill. Enabling says it is a one-way door. Both are
    /// plain words and name nothing of how the store works. Resuming a
    /// suspended bucket has nothing further to warn about.
    var warning: CatalogueLine? {
        switch current {
        case .never:
            CatalogueLine(
                key: "s3.versioning.enableIsOneWay",
                english: "Once switched on, versioning can be suspended later but not removed. While it is on, every earlier version of a file is kept and counts toward your storage costs.")
        case .enabled:
            CatalogueLine(
                key: "s3.versioning.suspendKeepsVersions",
                english: "Suspending stops new versions from being kept. It does not remove any version that is already stored: every earlier version stays, and keeps counting toward your storage costs until it is deleted.")
        case .suspended, nil:
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
    static let deniedLine = CatalogueLine(
        key: "s3.versioning.error.denied",
        english: "Your access key is not allowed to read or change the versioning of this bucket.")

    /// The lines that do not depend on the bucket's state.
    static let fixedLines: [CatalogueLine] = [
        titleLine, readingLine, readFailedLine, applyFailedLine, deniedLine,
    ]

    /// The lines this model shows in its current state, other than the fixed
    /// ones: where the bucket stands, the warning, and the offered buttons.
    var lines: [CatalogueLine] {
        [stateLine, warning].compactMap { $0 }
            + offeredStates.compactMap { Self.actionLine(for: $0) }
    }

    // MARK: - Talking to the store

    /// Reads `bucket`'s versioning and shows it, or shows why it could not.
    func read(bucket: String, from settings: any S3BucketSettings) async {
        load = .reading
        do {
            load = .known(try await settings.versioning(ofBucket: bucket))
        } catch {
            load = .failed(Self.message(for: error, applying: false))
        }
    }

    /// Moves `bucket` to `target`, if `target` is one of the offered states;
    /// anything else is dropped before a request exists.
    ///
    /// After a write the sheet shows what the store says now, read back, and
    /// not what was sent. If the read-back fails after the write succeeded the
    /// target is shown: the store accepted it.
    func apply(
        _ target: BucketVersioning, bucket: String, via settings: any S3BucketSettings
    ) async {
        guard !isApplying, offeredStates.contains(target) else { return }
        isApplying = true
        applyFailure = nil
        defer { isApplying = false }
        do {
            try await settings.setVersioning(target, ofBucket: bucket)
            load = .known((try? await settings.versioning(ofBucket: bucket)) ?? target)
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

    @Environment(\.dismiss) private var dismiss
    @State private var model: BucketVersioningModel

    /// `model` defaults to a sheet that has not read the bucket yet. The
    /// layout registry passes one already in a state, so a measurement does
    /// not wait for a read.
    init(
        bucket: String, settings: any S3BucketSettings,
        model: BucketVersioningModel = BucketVersioningModel()
    ) {
        self.bucket = bucket
        self.settings = settings
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
                        Task { await model.apply(target, bucket: bucket, via: settings) }
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
                await model.read(bucket: bucket, from: settings)
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
            if let failure = model.applyFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
