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
/// **Two things stand between a person and a silent one-way door, and the
/// taken-name check is the first.** Core does not refuse a name the key
/// already owns: the rig answers a re-create with success, does not let the
/// lock header retrofit, and takes the versioning request that follows. So
/// creating "again" could switch versioning on for a bucket nobody meant to
/// touch, and report "created". The check is local, against the listing the
/// pane already holds (`listing(of:)`), and a list that was never read is not
/// an empty list (`listingIsKnown`).
///
/// **Corrected 2026-10-22 (F1 of the final whole-branch review).** The
/// paragraph above opened, verbatim: "**The taken-name check is the only
/// thing between a person and a silent one-way door.**" It stopped being the
/// only thing when `create` began reading back what it wrote (`readBack`):
/// the check looks at a listing that can be minutes old, and the read-back is
/// what catches the door the stale half lets through.
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

    /// Whether the action is offered, which is the whole rule and lives here:
    /// the connection's root is a list of buckets, AND the pane is showing
    /// that list right now (`paneBucket` is the bucket the pane is inside, or
    /// `nil` at the list).
    ///
    /// **Both halves are needed and neither implies the other.** The first is
    /// spec §6.1: a bucket made in a connection rooted in one bucket would be
    /// invisible afterwards. The second is what makes the taken-name check
    /// mean anything: on a bucket-list connection the pane can be INSIDE a
    /// bucket, where `session.remote`'s listing is that bucket's objects, and
    /// a proposed bucket name checked against object names would let through
    /// exactly the duplicate create the check exists to stop. The route's
    /// availability asks this (`ConnectionActionRoute.createBucket`).
    ///
    /// **Corrected 2026-10-21 (Task 11, fix round 1).** This function read,
    /// verbatim: `nonisolated static func isOffered(rootIsContainerList: Bool) -> Bool {
    /// rootIsContainerList }`, i.e. it returned its own argument and stated no
    /// rule, while the pane half sat in the route's arm.
    nonisolated static func isOffered(rootIsContainerList: Bool, paneBucket: String?) -> Bool {
        rootIsContainerList && paneBucket == nil
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

    /// **`existingNames` and `listingIsKnown` have no default value**, and are
    /// spelled at every construction site. A default of `true` is the answer
    /// that lets a create through, and a caller that forgot the argument would
    /// get it without a word; the same ruling the plan makes for
    /// `bucketHasObjectLock` (Task 11b).
    ///
    /// `name` is set here and not afterwards because a write to `name` clears
    /// a failure (see its observer): a sheet built in a failed state with the
    /// name it failed for has to be built that way.
    init(
        existingNames: [String], listingIsKnown: Bool, outcome: Outcome = .editing,
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

    /// Whether the versioning checkbox can be changed at all: the fields are
    /// editable and Object Lock is not holding it on.
    var versioningCanBeChanged: Bool { isEditable && !versioningIsLocked }

    /// The note under the versioning checkbox: the lock's reason while it
    /// holds versioning on, the one-way warning otherwise.
    var versioningNoteLine: CatalogueLine {
        versioningIsLocked ? Self.versioningHeldByObjectLockNote : Self.versioningNote
    }

    /// The one choice Core takes, folded from the two switches.
    var protection: BucketProtection {
        if objectLock { return .lockedAndVersioned }
        return versioning ? .versioned : .none
    }

    /// The same fold, over what the store ANSWERED rather than over what the
    /// two switches say: the protection a bucket read back has.
    ///
    /// **The lock is read first here too**, for the reason the property above
    /// gives: `BucketProtection` has no case that asks for the lock without
    /// versioning, so a store that answered a lock beside versioning which is
    /// not `.enabled` has no case of its own, and the lock is the fact that
    /// cannot be dropped -- naming the bucket `.none` there would say it
    /// enforces nothing when it enforces a lock nobody can switch off. A
    /// versioning that is `.suspended` or `.never` is not the versioning this
    /// sheet asks for, so it is not `.versioned`.
    nonisolated static func protection(
        hasObjectLock: Bool, versioning: BucketVersioning
    ) -> BucketProtection {
        if hasObjectLock { return .lockedAndVersioned }
        return versioning == .enabled ? .versioned : .none
    }

    /// How much protection a choice is, for telling the two DIRECTIONS of a
    /// mismatch apart.
    ///
    /// The three cases are a chain: `.none` is inside `.versioned` is inside
    /// `.lockedAndVersioned`, because Object Lock needs versioning and so
    /// cannot be had without it. That is what makes the comparison total --
    /// a read-back that does not match the request is either LESS than was
    /// asked for (a setting that was chosen and did not take) or MORE (the
    /// bucket carries protection nobody chose), and never something
    /// incomparable with two sentences competing for it.
    ///
    /// No `default`: a fourth `BucketProtection` case would have to be
    /// placed in the chain here rather than silently rank as something.
    nonisolated static func protectionRank(_ protection: BucketProtection) -> Int {
        switch protection {
        case .none: 0
        case .versioned: 1
        case .lockedAndVersioned: 2
        }
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

    /// Whether the "your list already has this name" line is shown. Not once
    /// the outcome says the bucket exists (made, or made in part, or the store
    /// said we own it): that line, "Choose a different name", would sit under
    /// "was created" and contradict it.
    var showsNameIsTaken: Bool { nameIsTakenKey != nil && !bucketMayExist }

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
    /// (`versioning(ofBucket:)`, a read, no write): found means a bucket of
    /// this name exists now; the store's own "no such bucket" means it does
    /// not; any other answer is not a fact, and the sentence says only that
    /// the bucket may exist. A create with no protection is one request, and
    /// its failure needs no look; its sentence says the request failed, which
    /// is all that was measured.
    ///
    /// **Corrected 2026-10-21 (Task 11, fix round 1, M2).** This paragraph
    /// read, verbatim: "found means the create had gone through". Withdrawn:
    /// the read answers existence, not authorship. The two come apart on a
    /// stale listing, or on a create refused for a bucket the key can still
    /// read.
    ///
    /// **A create the store ACCEPTED is read back before it is called done**
    /// (`readBack`, added for F1 of the final whole-branch review). Three
    /// outcomes follow from it: the settings are there (`.created`, the line
    /// as before); they are not (`settingsDidNotTakeTemplate`, and the audit
    /// line names what was read, not what was asked); or the read did not
    /// answer (`settingsUnconfirmedTemplate`, which claims neither). The last
    /// two are `.failed` with `bucketMayExist: true`, so the pane refreshes
    /// and the taken-name check holds the same sheet back from sending the
    /// re-create again.
    ///
    /// `recorder` is where the outcome is written (Task 12): a line when the
    /// request went through, a line with the sheet's own sentence when it did
    /// not, and nothing when the sheet refused before any request existed.
    /// **No default value**: see `BucketSettingsAuditTests`.
    func create(via settings: any S3BucketSettings, recorder: AuditRecorder?) async {
        guard canCreate else { return }
        let bucket = name
        let choice = protection
        outcome = .creating
        do {
            try await settings.createBucket(bucket, protection: choice)
            takenNames.insert(bucket)
            switch await Self.readBack(choice, ofBucket: bucket, via: settings) {
            case .asAsked:
                outcome = .created
                recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: nil)
            case .lessThanAsked(let actual):
                let sentence = Self.settingsDidNotTakeLine(bucket: bucket)
                outcome = .failed(sentence: sentence, bucketMayExist: true)
                // **`actual`, not `choice`.** The line records what was read
                // back. A trail claiming Object Lock on a bucket without it is
                // worse than a sheet claiming it, because it is the record
                // someone relies on afterwards, when the sheet is gone.
                recorder?.recordBucketCreated(
                    bucket: bucket, protection: actual, failure: sentence)
            case .moreThanAsked(let actual):
                // The inverse, and `actual` for the same reason read the other
                // way: a line that named only what was ASKED for would omit a
                // protection the bucket really enforces, which is the half of
                // "no line claims what is not there" that says nothing may be
                // left out either.
                let sentence = Self.protectionNotChosenLine(bucket: bucket)
                outcome = .failed(sentence: sentence, bucketMayExist: true)
                recorder?.recordBucketCreated(
                    bucket: bucket, protection: actual, failure: sentence)
            case .unconfirmed:
                let sentence = Self.settingsUnconfirmedLine(bucket: bucket)
                outcome = .failed(sentence: sentence, bucketMayExist: true)
                // `choice` here, and it is not the exception to the rule
                // above: nothing was read back, so there is no answer to
                // record, and the line is the ATTEMPT with the sentence that
                // says it was not confirmed beside it. The same shape the
                // four other paths use for a write whose read-back failed.
                recorder?.recordBucketCreated(
                    bucket: bucket, protection: choice, failure: sentence)
            }
        } catch {
            let refusal = await failure(for: error, bucket: bucket, protection: choice, via: settings)
            outcome = .failed(sentence: refusal.sentence, bucketMayExist: refusal.bucketMayExist)
            // The sentence the sheet now shows, which is a fixed one and never
            // the store's own words (`failure(for:...)`). Recorded from a bare
            // `catch`, like each of the other four apply methods:
            // `failure(for:...)` returns a `Refusal`, a type that can only be a
            // refusal, so there is no outcome to test and nothing for a later
            // arm to slip past. (Corrected: this read "like the other four
            // recording sites". Four is the number of apply methods; the
            // recording calls outside this one are more numerous than that,
            // because several of those methods record on more than one arm.)
            // (Withdrawn, verbatim: "if case .failed(let sentence, _) = outcome"
            // guarded this call, total only while every arm of `failure(for:...)`
            // returned `.failed`.)
            recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: refusal.sentence)
        }
    }

    /// What the bucket turned out to have, against what the create asked for.
    ///
    /// A type of its own rather than a `Bool`, because the question has three
    /// answers and the third is not a shade of the other two: a read that did
    /// not answer establishes nothing, and reporting it as either "as asked"
    /// or "not as asked" would be a claim nobody measured.
    private enum ReadBack {
        /// The bucket has exactly what the request asked for.
        case asAsked
        /// LESS than was asked for: a setting that was chosen did not take.
        /// `actual` is what was read.
        case lessThanAsked(BucketProtection)
        /// MORE than was asked for: the bucket was already there and carries
        /// protection nobody chose. `actual` is what was read.
        case moreThanAsked(BucketProtection)
        /// The read itself did not answer.
        case unconfirmed
    }

    /// Reads back the settings `choice` asked for, through the same capability
    /// the write used.
    ///
    /// **Why at all.** The spec's anti-goal (§3) is "A setting that silently
    /// did nothing. Every write is read back from the store, never assumed
    /// from a 200." `createBucket` is the one call where a 200 is measured NOT
    /// to mean the request was carried out: the rig answers a re-create of a
    /// bucket the key owns with success, does not let the Object Lock header
    /// retrofit a lock, and takes the versioning request that follows
    /// (`S3BucketSettings.createBucket`, measured 2026-10-19). So a success
    /// asserted from the absence of a throw can be a bucket with versioning
    /// switched on for good and no lock, reported as protected.
    ///
    /// **No pre-flight existence check.** Asking first whether the name is
    /// free is a time-of-check race, and it leaves the stale listing the
    /// taken-name check reads exactly as stale as it was. Reading AFTERWARDS
    /// answers the question that matters -- what does the bucket have now --
    /// whichever way the name got there.
    ///
    /// **What is read is what the BUCKET now has, and EVERY create reads
    /// it** — including a plain one, which asked for nothing. The lock goes
    /// first, so a lock read that fails stops the pair without spending the
    /// second request.
    ///
    /// **The plain create is the heaviest case, which is why it costs two
    /// requests it used to save.** A person creates `reports`, already owns
    /// that name, and its bucket has Object Lock and — because this branch
    /// ships the feature that sets them — perhaps a COMPLIANCE default
    /// retention. The create answers 200. They believe the bucket is new and
    /// ordinary, start writing files into it, and every object inherits that
    /// default: under COMPLIANCE nobody can delete those objects until their
    /// dates pass, not them and not the account owner. They chose nothing, so
    /// nothing warned them.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 3).** This paragraph said,
    /// verbatim: "`.none` claims no setting, so nothing is read and no
    /// request is spent: the failure path makes the same cut
    /// (`failure(for:...)`'s `protection != .none` guard)." The cut was
    /// wrong here and stays right there: the failure path is asking whether a
    /// bucket EXISTS, which a one-request create's own refusal already
    /// answered; this path is asking what the bucket HAS, and a plain create
    /// is exactly where nobody is watching for the answer.
    ///
    /// **The mirror is the heavier half, which is why `.versioned` reads the
    /// lock too.** A create asking for versioning only, answered with
    /// success, can land on a bucket that ALREADY has Object Lock — the
    /// stale-listing re-create with the switches the other way round. Object
    /// Lock cannot be switched off once a bucket has it, so reporting that
    /// create as asked leaves a person owning a protection they never chose
    /// and can never remove, with an audit line that does not mention it.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 2).** This paragraph read,
    /// verbatim: "**What is read is what was CLAIMED.** `.none` claims no
    /// setting, so nothing is read and no request is spent: the failure path
    /// makes the same cut (`failure(for:...)`'s `protection != .none`
    /// guard). `.versioned` sends no lock header and so claims nothing about
    /// Object Lock; only `.lockedAndVersioned` does, and only there is the
    /// lock read." The reach of that reasoning was wrong, not its logic: it
    /// assumed the only harm runs one way, a protection asked for and not
    /// applied. The property is "what the bucket now has is what the sheet
    /// and the audit line say it has".
    private static func readBack(
        _ choice: BucketProtection, ofBucket bucket: String, via settings: any S3BucketSettings
    ) async -> ReadBack {
        do {
            let hasLock = try await settings.hasObjectLock(ofBucket: bucket)
            let versioning = try await settings.versioning(ofBucket: bucket)
            let actual = protection(hasObjectLock: hasLock, versioning: versioning)
            guard actual != choice else { return .asAsked }
            // The direction decides which sentence is true of this person:
            // see `protectionRank`, and the two catalogue lines.
            return protectionRank(actual) > protectionRank(choice)
                ? .moreThanAsked(actual) : .lessThanAsked(actual)
        } catch {
            return .unconfirmed
        }
    }

    /// What a refused create comes to: the sentence the sheet shows and whether
    /// a bucket of this name may exist now. A type of its own, not an
    /// `Outcome`, so that `failure(for:...)` cannot return anything that is not
    /// a refusal and `create` can record its result without asking which.
    private struct Refusal {
        let sentence: String
        let bucketMayExist: Bool
    }

    private func failure(
        for error: any Error, bucket: String, protection: BucketProtection,
        via settings: any S3BucketSettings
    ) async -> Refusal {
        // Only the create request can say the name is taken, so no read is spent.
        //
        // "Already owned by you" is the store's own statement that a bucket of
        // this name exists in THIS account: the name is taken and the pane's
        // list, which did not hold it, is stale. It is at least as strong as
        // the "may exist" arm below and does at least as much. "Name taken" is
        // another account's bucket: not in "your list", and nothing here is
        // stale.
        //
        // **Corrected 2026-10-21 (Task 11, fix round 1, I1).** This arm read,
        // verbatim: "Only the create request can say the name is taken." and
        // returned `bucketMayExist: false` for both findings without touching
        // the taken names, so after `.bucketAlreadyOwnedByYou` the name was
        // free again and the list was never refreshed.
        if case RemoteFSError.finding(let finding) = error {
            if finding == .bucketAlreadyOwnedByYou {
                takenNames.insert(bucket)
                return Refusal(sentence: Self.refusalSentence(for: error), bucketMayExist: true)
            }
            if finding == .bucketNameTaken {
                return Refusal(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
            }
        }
        guard protection != .none else {
            return Refusal(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
        }
        do {
            _ = try await settings.versioning(ofBucket: bucket)
            takenNames.insert(bucket)
            return Refusal(
                sentence: Self.existsIncompletelyLine(bucket: bucket), bucketMayExist: true)
        } catch RemoteFSError.notFound {
            return Refusal(sentence: Self.refusalSentence(for: error), bucketMayExist: false)
        } catch {
            takenNames.insert(bucket)
            return Refusal(sentence: Self.mayExistLine.text, bucketMayExist: true)
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
    /// **Corrected 2026-10-21 (Task 11, fix round 1, M2).** This line read,
    /// verbatim: "The bucket could not be created." It is said for a create
    /// with no protection (one request, no follow-up read) and after a read
    /// that found nothing; the first asserts a non-event nothing checked. What
    /// was measured is that the request failed.
    static let notCreatedLine = CatalogueLine(
        key: "s3.createBucket.error.create", english: "The request to create the bucket failed.")
    static let deniedLine = CatalogueLine(
        key: "s3.createBucket.error.denied",
        english: "Your access key is not allowed to create buckets.")
    /// A bucket of this name exists and the create with the chosen settings
    /// did not complete. Says no more than the read found.
    ///
    /// **Corrected 2026-10-21 (Task 11, fix round 1; quoted in round 2).** The
    /// doc line above this one's first sentence replaced, verbatim: "The create
    /// went through and the versioning request after it did not." That is the
    /// authorship claim M2 withdraws.
    ///
    /// **Corrected 2026-10-21 (Task 11, fix round 1, M2).** This line was
    /// `createdIncompletelyTemplate`, key `s3.createBucket.error.createdIncompletely %@`,
    /// and read, verbatim: "The bucket “%@” was created, but switching on
    /// versioning failed. It may not have the settings you chose. Open
    /// Versioning and Object Lock for it to see what it has, and do not create
    /// it again." Its first two clauses assert authorship and which request
    /// failed; the read behind it establishes neither.
    static let existsIncompletelyTemplate = CatalogueLine(
        key: "s3.createBucket.error.existsIncompletely %@",
        english: "A bucket named “%@” exists now, but the request to create it with the settings you chose did not complete. It may not have those settings. Open Versioning and Object Lock for it to see what it has, and do not create it again.")
    /// Neither request can be told from the other, and the look that would
    /// tell them apart was refused too.
    static let mayExistLine = CatalogueLine(
        key: "s3.createBucket.error.mayExist",
        english: "Creating the bucket did not finish, and the bucket may exist now. Refresh the list; if it is there, open Versioning and Object Lock for it to see what it has.")

    /// The create was accepted and the READ-BACK found something else: a
    /// bucket of this name is there and does not carry what was asked for.
    ///
    /// A variant of `existsIncompletelyTemplate` rather than a new sentence
    /// (maintainer ruling, F1 of the final review): the second half is that
    /// line's, word for word, because it already says the one useful thing
    /// here. The first half differs because what was measured differs -- the
    /// request DID complete, so "did not complete" would be false, and the
    /// read establishes that the settings are absent, so the hedge "It may
    /// not have those settings" would be weaker than the evidence. It does
    /// not say the bucket "was created": the read answers existence, not
    /// authorship, which is the withdrawal `failure(for:...)` already carries.
    static let settingsDidNotTakeTemplate = CatalogueLine(
        key: "s3.createBucket.error.settingsDidNotTake %@",
        english: "A bucket named \u{201C}%@\u{201D} exists now, and it does not have the settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create it again.")
    /// The create was accepted and the read-back itself did not answer. Says
    /// no more than that: a bucket of this name is there and nothing is known
    /// about its settings. Neither "was created" (which would claim the
    /// settings) nor "the request failed" (the create was accepted).
    static let settingsUnconfirmedTemplate = CatalogueLine(
        key: "s3.createBucket.error.settingsUnconfirmed %@",
        english: "A bucket named \u{201C}%@\u{201D} exists now, but macSCP could not check whether it has the settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create it again.")
    /// The INVERSE of `settingsDidNotTakeTemplate`: the create was accepted
    /// and the read-back found MORE protection than was asked for, so a
    /// bucket of this name was already there and carries something nobody
    /// chose.
    ///
    /// **One sentence for both directions of "more" was the ruling**, and it
    /// covers a plain create as well as a versioned one, which is why it says
    /// nothing about "the settings you chose": on a plain create the person
    /// chose nothing, and `settingsDidNotTakeTemplate` stretched over that
    /// would be false of them.
    ///
    /// **It names the permanence here rather than leaving it to be
    /// inferred.** `objectLockNote` says the lock can never be switched off,
    /// but it is on the sheet the person has just dismissed, and someone who
    /// ticked nothing had no reason to read it. The clause is a property of
    /// Object Lock and not a claim about THIS bucket ("once a bucket has
    /// it"), so the one sentence stays true where what was found is
    /// versioning alone.
    ///
    /// Why it matters most on a plain create, which is the case that looks
    /// lightest: the person believes the bucket is new and ordinary and
    /// starts writing files into it. Every object inherits the bucket's
    /// default retention, and under COMPLIANCE no one can delete those
    /// objects until their dates pass -- not the person, not the account
    /// owner. This branch ships the feature that sets such a default.
    static let protectionNotChosenTemplate = CatalogueLine(
        key: "s3.createBucket.error.protectionNotChosen %@",
        english: "A bucket named \u{201C}%@\u{201D} already existed, and it carries protection you did not choose. Object Lock, once a bucket has it, can never be switched off. Open Versioning and Object Lock for it to see what it has, and do not create it again.")

    static func existsIncompletelyLine(bucket: String) -> String {
        String(format: existsIncompletelyTemplate.text, bucket)
    }

    static func settingsDidNotTakeLine(bucket: String) -> String {
        String(format: settingsDidNotTakeTemplate.text, bucket)
    }

    static func settingsUnconfirmedLine(bucket: String) -> String {
        String(format: settingsUnconfirmedTemplate.text, bucket)
    }

    static func protectionNotChosenLine(bucket: String) -> String {
        String(format: protectionNotChosenTemplate.text, bucket)
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
            existsIncompletelyTemplate, mayExistLine, settingsDidNotTakeTemplate,
            settingsUnconfirmedTemplate, protectionNotChosenTemplate,
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

    /// Where this sheet's writes are recorded: the tab's `auditRecorder`,
    /// captured when the sheet opens. **Required, with no default, and
    /// optional in its type.** `nil` is a real answer -- a tab whose stored
    /// session was deleted under it has none, see `BucketSettingsAuditTests`
    /// -- but it has to be given at the call site, not inherited from a
    /// default nobody read.
    let recorder: AuditRecorder?

    let settings: any S3BucketSettings
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateBucketModel

    /// `model` defaults to a fresh sheet over `listing`. The layout registry
    /// passes one already in a state, so a measurement does not wait on a
    /// request.
    init(
        recorder: AuditRecorder?, settings: any S3BucketSettings,
        listing: CreateBucketModel.Listing, onCreated: @escaping () -> Void = {},
        model: CreateBucketModel? = nil
    ) {
        self.recorder = recorder
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
                if model.showsNameIsTaken {
                    red(CreateBucketModel.nameIsTakenLine.text)
                }
                if model.listingUnknownKey != nil {
                    red(CreateBucketModel.listingUnknownLine.text)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CheckboxRow(CreateBucketModel.versioningLabel.text, isOn: $model.versioning)
                    .disabled(!model.versioningCanBeChanged)
                Text(model.versioningNoteLine.text)
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
                        await model.create(via: settings, recorder: recorder)
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
