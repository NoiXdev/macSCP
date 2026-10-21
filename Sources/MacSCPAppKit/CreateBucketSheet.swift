import SwiftUI
import macSCPCore

/// What the create-bucket sheet knows and decides, apart from how it is drawn.
///
/// **Two checkboxes to the person, ONE choice to Core.** The sheet shows
/// versioning and Object Lock as two switches, because that is what a person
/// is choosing between. Core takes `BucketProtection`
/// (`S3BucketSettings.createBucket`), which has no case that asks for the lock
/// without versioning, so that the combination which cannot exist cannot be
/// written. `protection` is where the pair is folded back into that one
/// choice, and it is read from the lock first: whatever state the two
/// booleans were driven into, a lock reaches Core as `.lockedAndVersioned`.
///
/// **The taken-name check is the only thing between a person and a silent
/// one-way door.** Core does not refuse a name the key already owns: the rig
/// answers a re-create with success, does not let the lock header retrofit,
/// and takes the versioning request that follows. So creating "again" could
/// switch versioning on for a bucket nobody meant to touch, and report
/// "created". The check is local, against the listing the pane already holds
/// (`listing(of:)`), and a list that was never read is not an empty list
/// (`listingIsKnown`).
///
/// **A bucket that may exist is a name that is taken.** After a create that
/// failed when the bucket may have been made (`bucketMayExist`), the name is
/// added to the taken names, so the same sheet cannot send the re-create the
/// check above exists to stop.
@MainActor
@Observable
final class CreateBucketModel {
    /// Where the sheet is.
    enum Outcome: Equatable {
        case editing
        case creating
        case created
        /// The store did not do what was asked. `bucketMayExist` is whether a
        /// bucket of this name may be there now (see `create(via:)`).
        case failed(sentence: String, bucketMayExist: Bool)
    }

    /// The names the connection's bucket list holds, and whether that list
    /// was actually read.
    struct Listing: Equatable {
        let names: [String]
        let isKnown: Bool
    }

    /// The remote pane's listing as the sheet needs it.
    ///
    /// **`listedItems`, not `items`:** `items` is the listing after the
    /// pane's search filter, and a name the filter is hiding is a name that is
    /// still taken. Known only when the pane's listing has loaded: before
    /// that, or after a failed load, an empty array would read as "no buckets
    /// yet" and let any name through.
    static func listing(of browser: RemoteBrowserViewModel) -> Listing {
        Listing(names: browser.listedItems.map(\.name), isKnown: browser.state == .loaded)
    }

    /// Whether the action is offered for this connection at all: only when
    /// the root is the list of buckets. Spec §6.1: a bucket made in a
    /// connection rooted in one bucket would be invisible afterwards. The
    /// route's availability reads this (`ConnectionActionRoute.createBucket`).
    nonisolated static func isOffered(rootIsContainerList: Bool) -> Bool {
        rootIsContainerList
    }

    private(set) var outcome: Outcome
    private let listingIsKnown: Bool
    private var takenNames: Set<String>

    var name = "" {
        didSet {
            guard name != oldValue else { return }
            // A sentence about the previous name is not about this one.
            if case .failed = outcome { outcome = .editing }
        }
    }

    /// Versioning is wanted. Held on while `objectLock` is: a write of `false`
    /// is refused.
    var versioning = false {
        didSet {
            if objectLock && !versioning { versioning = true }
        }
    }

    /// Object Lock is wanted. Turning it on turns versioning on with it.
    var objectLock = false {
        didSet {
            if objectLock { versioning = true }
        }
    }

    /// `name` is set here and not afterwards because a write to `name` clears
    /// a failure (see its observer): a sheet built in a failed state with the
    /// name it failed for has to be built that way.
    init(
        existingNames: [String] = [], listingIsKnown: Bool = true, outcome: Outcome = .editing,
        name: String = ""
    ) {
        takenNames = Set(existingNames)
        self.listingIsKnown = listingIsKnown
        // The name goes in BEFORE the outcome: the observer on `name` clears a
        // failure, and observers on an `@Observable` class run in `init`, so
        // assigning the name last would erase the failure just given.
        self.outcome = .editing
        self.name = name
        self.outcome = outcome
    }

    convenience init(listing: Listing) {
        self.init(existingNames: listing.names, listingIsKnown: listing.isKnown)
    }

    // MARK: - What the switches mean

    /// Versioning cannot be unticked while Object Lock is ticked.
    var versioningIsLocked: Bool { objectLock }

    /// The one choice Core takes, folded from the two switches.
    var protection: BucketProtection {
        if objectLock { return .lockedAndVersioned }
        return versioning ? .versioned : .none
    }

    // MARK: - The name

    /// The first rule the name breaks, as Core's validator reports it. An
    /// empty name is "too short" to the validator; see `problemLine` for what
    /// the sheet says of it.
    var problem: BucketNameProblem? { S3BucketName.problem(with: name) }

    /// The sentence for the name's problem, or `nil` when it has none OR when
    /// nothing has been typed: a red sentence on a sheet that has just opened
    /// tells the person nothing they did.
    var problemLine: CatalogueLine? {
        guard !name.isEmpty, let problem else { return nil }
        return Self.line(for: problem)
    }

    /// The problem's sentence with its argument filled in.
    var problemSentence: String? {
        guard let line = problemLine else { return nil }
        if case .invalidCharacter(let character) = problem {
            return String(format: line.text, String(character))
        }
        return line.text
    }

    /// The key of the sentence saying the name is already in the list, or
    /// `nil` when it is not.
    var nameIsTakenKey: String? {
        takenNames.contains(name) ? Self.nameIsTakenLine.key : nil
    }

    /// The key of the sentence saying the list was never read, or `nil` when
    /// it was.
    var listingUnknownKey: String? {
        listingIsKnown ? nil : Self.listingUnknownLine.key
    }

    // MARK: - What can be done

    /// Whether Create can be pressed: a valid name that is free, in a list
    /// that was read, and nothing in flight or already done.
    var canCreate: Bool {
        switch outcome {
        case .creating, .created: return false
        case .editing, .failed: break
        }
        return listingIsKnown && problem == nil && !takenNames.contains(name)
    }

    /// Whether the fields can still be changed.
    var isEditable: Bool {
        switch outcome {
        case .creating, .created: false
        case .editing, .failed: true
        }
    }

    var isCreating: Bool { outcome == .creating }
    var isCreated: Bool { outcome == .created }

    /// Why the last create did not do what was asked, as a sentence.
    var failureSentence: String? {
        if case .failed(let sentence, _) = outcome { return sentence }
        return nil
    }

    /// Whether a bucket of this name may exist now, so the pane's listing is
    /// out of date: true after a create that succeeded and after a failure
    /// that may have made the bucket.
    var bucketMayExist: Bool {
        switch outcome {
        case .created: true
        case .failed(_, let mayExist): mayExist
        case .editing, .creating: false
        }
    }

    /// The sentence for a bucket that was made.
    var createdSentence: String { String(format: Self.createdLine.text, name) }

    // MARK: - Talking to the store

    /// Creates the bucket the sheet describes, if it can be created.
    ///
    /// Core makes two requests when versioning is on: the create, then the
    /// versioning. A failure of the SECOND leaves the bucket created and
    /// unversioned, and the error thrown is that request's own, so the error
    /// cannot say which request failed. After a failure with a protection
    /// asked for, the bucket is therefore looked up once
    /// (`versioning(ofBucket:)`, a read, no write): found means the create had
    /// gone through; the store's own "no such bucket" means it had not; any
    /// other answer is not a fact, and the sentence says only that the bucket
    /// may exist. A create with no protection is one request, and its failure
    /// needs no look.
    func create(via settings: any S3BucketSettings) async {
        guard canCreate else { return }
        let bucket = name
        let choice = protection
        outcome = .creating
        do {
            try await settings.createBucket(bucket, protection: choice)
            takenNames.insert(bucket)
            outcome = .created
        } catch {
            outcome = await failure(for: error, bucket: bucket, protection: choice, via: settings)
        }
    }

    private func failure(
        for error: any Error, bucket: String, protection: BucketProtection,
        via settings: any S3BucketSettings
    ) async -> Outcome {
        // Only the create request can say the name is taken.
        if case RemoteFSError.finding(let finding) = error,
            finding == .bucketNameTaken || finding == .bucketAlreadyOwnedByYou
        {
            return .failed(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
        }
        guard protection != .none else {
            return .failed(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
        }
        do {
            _ = try await settings.versioning(ofBucket: bucket)
            takenNames.insert(bucket)
            return .failed(
                sentence: Self.createdIncompletelyLine(bucket: bucket), bucketMayExist: true)
        } catch RemoteFSError.notFound {
            return .failed(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
        } catch {
            takenNames.insert(bucket)
            return .failed(sentence: Self.mayExistLine.text, bucketMayExist: true)
        }
    }

    /// The sentence for a create the store refused.
    ///
    /// A finding carries no foreign text and says its own sentence. A missing
    /// permission has one of its own. Anything else is a fixed sentence: the
    /// error is NEVER quoted, because a `reason` can carry the endpoint the
    /// user typed, and that field takes `scheme://KEY:SECRET@host` as ordinary
    /// input. None of the three promises a cause the store did not name.
    static func refusalSentence(for error: any Error) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            deniedLine.text
        default:
            notCreatedLine.text
        }
    }

    // MARK: - What the sheet says

    static let titleLine = CatalogueLine(key: "s3.createBucket.title", english: "Create Bucket")
    static let nameLabelLine = CatalogueLine(
        key: "s3.createBucket.nameLabel", english: "Bucket name")
    static let nameHintLine = CatalogueLine(
        key: "s3.createBucket.nameHint",
        english: "Use 3 to 63 lowercase letters, digits, hyphens or dots. A bucket cannot be renamed later.")
    static let actionLine = CatalogueLine(key: "s3.createBucket.action", english: "Create")

    static let versioningLabel = CatalogueLine(
        key: "s3.createBucket.versioning", english: "Versioning")
    static let objectLockLabel = CatalogueLine(
        key: "s3.createBucket.objectLock", english: "Object Lock")

    /// What to say about versioning BEFORE the tick: it can be suspended but
    /// not removed, and the versions it keeps cost money. The same facts as
    /// the versioning sheet's one-way warning, in the sheet's own key.
    static let versioningNote = CatalogueLine(
        key: "s3.createBucket.versioningIsOneWay",
        english: "Once switched on, versioning can be suspended later but not removed. While it is on, every earlier version of a file is kept and counts toward your storage costs.")
    /// Said while Object Lock holds versioning on.
    static let versioningHeldByObjectLockNote = CatalogueLine(
        key: "s3.createBucket.versioningHeldByObjectLock",
        english: "Object Lock needs versioning, so versioning is switched on with it and stays on.")
    /// **About irreversibility, not about timing.** Spec §6.1 withdrew the
    /// claim that Object Lock can only be set at creation (AWS permits it on
    /// an existing versioned bucket; macSCP offers no call for it, for scope).
    /// So the sentence is "if you say yes, you cannot undo it", never "you
    /// must decide now".
    static let objectLockNote = CatalogueLine(
        key: "s3.createBucket.objectLockIsFinal",
        english: "Object Lock can never be switched off for this bucket, and it keeps versioning on for good. If you switch it on here, you cannot undo it.")

    var objectLockNoteKey: String { Self.objectLockNote.key }

    static let nameIsTakenLine = CatalogueLine(
        key: "s3.createBucket.nameIsTaken",
        english: "Your list already has a bucket with this name. Choose a different name.")
    static let listingUnknownLine = CatalogueLine(
        key: "s3.createBucket.listingUnknown",
        english: "The list of buckets has not been loaded, so macSCP cannot check that this name is free. Refresh the list, then try again.")

    static let creatingLine = CatalogueLine(
        key: "s3.createBucket.creating", english: "Creating the bucket…")
    static let createdLine = CatalogueLine(
        key: "s3.createBucket.created %@", english: "The bucket “%@” was created.")
    static let notCreatedLine = CatalogueLine(
        key: "s3.createBucket.error.create", english: "The bucket could not be created.")
    static let deniedLine = CatalogueLine(
        key: "s3.createBucket.error.denied",
        english: "Your access key is not allowed to create buckets.")
    /// The create went through and the versioning request after it did not.
    static let createdIncompletelyTemplate = CatalogueLine(
        key: "s3.createBucket.error.createdIncompletely %@",
        english: "The bucket “%@” was created, but switching on versioning failed. It may not have the settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create it again.")
    /// Neither request can be told from the other, and the look that would
    /// tell them apart was refused too.
    static let mayExistLine = CatalogueLine(
        key: "s3.createBucket.error.mayExist",
        english: "Creating the bucket did not finish, and the bucket may exist now. Refresh the list; if it is there, open Versioning and Object Lock for it to see what it has.")

    static func createdIncompletelyLine(bucket: String) -> String {
        String(format: createdIncompletelyTemplate.text, bucket)
    }

    /// The sentence for each problem the validator reports. No `default`: a
    /// case added to Core without a sentence here does not compile.
    static func line(for problem: BucketNameProblem) -> CatalogueLine {
        switch problem {
        case .tooShort:
            CatalogueLine(
                key: "s3.createBucket.problem.tooShort",
                english: "A bucket name needs at least 3 characters.")
        case .tooLong:
            CatalogueLine(
                key: "s3.createBucket.problem.tooLong",
                english: "A bucket name can have at most 63 characters.")
        case .uppercase:
            CatalogueLine(
                key: "s3.createBucket.problem.uppercase",
                english: "A bucket name cannot contain uppercase letters.")
        case .invalidCharacter:
            CatalogueLine(
                key: "s3.createBucket.problem.invalidCharacter %@",
                english: "“%@” cannot be used in a bucket name. Use lowercase letters, digits, hyphens and dots.")
        case .looksLikeAnIPAddress:
            CatalogueLine(
                key: "s3.createBucket.problem.looksLikeAnIPAddress",
                english: "A bucket name cannot look like an IP address.")
        case .badEdge:
            CatalogueLine(
                key: "s3.createBucket.problem.badEdge",
                english: "A bucket name has to start and end with a lowercase letter or a digit.")
        }
    }

    /// One example of each problem, for enumerating their sentences.
    private static let everyProblem: [BucketNameProblem] = [
        .tooShort, .tooLong, .uppercase, .invalidCharacter("_"), .looksLikeAnIPAddress, .badEdge,
    ]

    /// Every line the sheet can show.
    static var allLines: [CatalogueLine] {
        [
            titleLine, nameLabelLine, nameHintLine, actionLine, versioningLabel, objectLockLabel,
            versioningNote, versioningHeldByObjectLockNote, objectLockNote, nameIsTakenLine,
            listingUnknownLine, creatingLine, createdLine, notCreatedLine, deniedLine,
            createdIncompletelyTemplate, mayExistLine,
        ] + everyProblem.map { line(for: $0) }
    }
}

/// The sheet behind the toolbar menu's "Create Bucket…" row: a name, the two
/// switches that cannot be taken back, and the button.
///
/// The capability, the bucket list and the refresh are captured when the sheet
/// opens (`ContentView.CreateBucketSheetItem`).
struct CreateBucketSheet: BoundedView {
    /// The size `CreateBucketSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(480)

    let settings: any S3BucketSettings
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateBucketModel

    /// `model` defaults to a fresh sheet over `listing`. The layout registry
    /// passes one already in a state, so a measurement does not wait on a
    /// request.
    init(
        settings: any S3BucketSettings, listing: CreateBucketModel.Listing,
        onCreated: @escaping () -> Void = {}, model: CreateBucketModel? = nil
    ) {
        self.settings = settings
        self.onCreated = onCreated
        _model = State(initialValue: model ?? CreateBucketModel(listing: listing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CreateBucketModel.titleLine.text)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(CreateBucketModel.nameLabelLine.text).font(.subheadline)
                TextField(CreateBucketModel.nameLabelLine.text, text: $model.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.isEditable)
                Text(CreateBucketModel.nameHintLine.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = model.problemSentence {
                    red(problem)
                }
                if model.nameIsTakenKey != nil, !model.isCreated {
                    red(CreateBucketModel.nameIsTakenLine.text)
                }
                if model.listingUnknownKey != nil {
                    red(CreateBucketModel.listingUnknownLine.text)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CheckboxRow(CreateBucketModel.versioningLabel.text, isOn: $model.versioning)
                    .disabled(!model.isEditable || model.versioningIsLocked)
                Text(
                    model.versioningIsLocked
                        ? CreateBucketModel.versioningHeldByObjectLockNote.text
                        : CreateBucketModel.versioningNote.text
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                CheckboxRow(CreateBucketModel.objectLockLabel.text, isOn: $model.objectLock)
                    .disabled(!model.isEditable)
                Text(CreateBucketModel.objectLockNote.text)
                    .font(.caption)
                    .foregroundStyle(model.objectLock ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            outcome

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                Button(CreateBucketModel.actionLine.text) {
                    Task {
                        await model.create(via: settings)
                        if model.bucketMayExist { onCreated() }
                    }
                }
                .buttonStyle(.polishedProminent)
                .disabled(!model.canCreate)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
    }

    @ViewBuilder private var outcome: some View {
        if model.isCreating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(CreateBucketModel.creatingLine.text).foregroundStyle(.secondary)
            }
        } else if model.isCreated {
            Text(model.createdSentence)
                .fixedSize(horizontal: false, vertical: true)
        } else if let failure = model.failureSentence {
            red(failure)
        }
    }

    private func red(_ sentence: String) -> some View {
        Text(sentence)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
