import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The create-bucket sheet's decisions: which names it lets through, what the
/// two switches mean, which single choice reaches Core, and what it says when
/// the store does not do what was asked.
///
/// No test in this project draws a SwiftUI view; these are the decisions the
/// view reads, the catalogue entries it looks its text up in, and scans of
/// the sources for the wiring.
@Suite("Create bucket sheet")
struct CreateBucketSheetTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    // MARK: - The name

    @MainActor @Test func aNameTheStoreWouldRejectBlocksTheButtonAndSaysWhy() {
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "My_Bucket"
        #expect(model.canCreate == false)
        #expect(model.problem == .uppercase)
    }

    @MainActor @Test func aValidNameIsTheCaseTheTestAboveIsTheNegativeOf() {
        // The positive control for the test above, and for every refusal in
        // this file: a model that refuses every name satisfies all of them.
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        #expect(model.problem == nil)
        #expect(model.canCreate == true)
    }

    @MainActor @Test func nothingTypedYetIsNotAnErrorButIsNotCreatable() {
        // An empty field is "too short" to the validator, and a red sentence
        // on a sheet that has just opened tells the person nothing they did.
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(model.canCreate == false)
        #expect(model.problemLine == nil)
        model.name = "ab"
        #expect(model.problemLine?.key == "s3.createBucket.problem.tooShort")
    }

    @MainActor @Test func everyProblemTheValidatorReportsHasItsOwnSentence() {
        // One name per `BucketNameProblem` case, found by asking the validator
        // rather than by assuming it, so a case added to Core with no sentence
        // here is a red in `problemLine` (no `default`), not a silent blank.
        let samples: [String: BucketNameProblem] = [
            "ab": .tooShort, String(repeating: "a", count: 64): .tooLong, "Abc": .uppercase,
            "a_b": .invalidCharacter("_"), "192.168.0.1": .looksLikeAnIPAddress, "-ab": .badEdge,
        ]
        var keys = Set<String>()
        for (name, expected) in samples {
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = name
            #expect(model.problem == expected, "\(name)")
            #expect(model.canCreate == false, "\(name)")
            if let key = model.problemLine?.key { keys.insert(key) }
        }
        #expect(keys.count == samples.count)
        #expect(samples.count == 6)
    }

    @MainActor @Test func aNameAlreadyInTheListBlocksTheButton() {
        // MEASURED on the rig (Task 5's review): a second `createBucket` of a
        // bucket the key already owns SUCCEEDS, so only this check stands
        // between the person and a one-way switch on a bucket they did not
        // mean to touch.
        let model = CreateBucketModel(existingNames: ["macscp-seed", "macscp-second"], listingIsKnown: true)
        model.name = "macscp-seed"
        #expect(model.canCreate == false)
        #expect(model.problem == nil)  // the NAME is valid; it is taken
        #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
        model.name = "macscp-third"
        #expect(model.canCreate == true)  // the positive control
        #expect(model.nameIsTakenKey == nil)
    }

    @MainActor @Test func aTakenNameNeverReachesTheStoreEvenIfAskedTo() async {
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-seed"
        model.versioning = true
        await model.create(via: settings, recorder: nil)
        #expect(settings.creates.isEmpty)
    }

    @MainActor @Test func aListThatWasNeverReadCannotVouchForANameBeingFree() async {
        // An empty list is not "no buckets", it is "no answer yet", and the
        // sheet must not read it as the first.
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: [], listingIsKnown: false)
        model.name = "macscp-third"
        #expect(model.canCreate == false)
        #expect(model.listingUnknownKey == "s3.createBucket.listingUnknown")
        await model.create(via: settings, recorder: nil)
        #expect(settings.creates.isEmpty)
        let known = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(known.listingUnknownKey == nil)
    }

    // MARK: - The two switches

    @MainActor @Test func objectLockIsFinalAndTheSheetSaysSo() {
        // The note says Object Lock can never be turned off again and keeps
        // versioning on with it -- NOT that it can only be set at creation,
        // which spec §6.1 withdrew on 2026-10-19. The honest sentence is "if
        // you say yes, you cannot undo it", not "you must decide now".
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(model.objectLockNoteKey == "s3.createBucket.objectLockIsFinal")
    }

    @MainActor @Test func objectLockImpliesVersioning() {
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.objectLock = true
        #expect(model.versioning == true)
        #expect(model.versioningIsLocked == true)
    }

    @MainActor @Test func theLockRefusesToLetVersioningBeUntickedAndShowsItTicked() {
        // Found by a mutation probe (P9, 2026-10-21): with the observer that
        // refuses the write planted out, every other test stayed green,
        // because `protection` reads the lock first and so never shows the
        // checkbox's state. What a person sees is `versioning` itself.
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.objectLock = true
        model.versioning = false
        #expect(model.versioning == true)
        // And once the lock is off again, versioning is free to be unticked.
        model.objectLock = false
        model.versioning = false
        #expect(model.versioning == false)
    }

    @MainActor @Test func versioningIsFreeWhileObjectLockIsOff() {
        // The positive beside the one above.
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(model.versioningIsLocked == false)
        model.versioning = true
        #expect(model.versioning == true)
        model.versioning = false
        #expect(model.versioning == false)
    }

    @MainActor @Test func theModelHandsCoreTheOneChoiceCoreAccepts() {
        // Core deliberately has no pair of `Bool`s here:
        // `createBucket(_:protection:)` takes `BucketProtection`, so the
        // combination that cannot exist cannot be written. The sheet is where
        // the user's two checkboxes are folded back into the one choice, so
        // that is where it is pinned.
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(model.protection == .none)
        model.versioning = true
        #expect(model.protection == .versioned)
        model.objectLock = true
        #expect(model.protection == .lockedAndVersioned)
        model.versioning = false  // refused: the lock holds it on
        #expect(model.protection == .lockedAndVersioned)
    }

    @MainActor @Test func everyChoiceCoreAcceptsIsOneTheSheetCanProduce() {
        // The other direction: a `BucketProtection` case no pair of switches
        // reaches would be a choice the sheet can never make.
        var reached = Set<String>()
        for versioning in [false, true] {
            for lock in [false, true] {
                let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
                model.versioning = versioning
                model.objectLock = lock
                reached.insert("\(model.protection)")
            }
        }
        #expect(reached == Set(BucketProtection.allCases.map { "\($0)" }))
    }

    @MainActor @Test func theSwitchesAreSentToTheNamedBucketAsOneChoice() async {
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(
            settings.creates == [
                FakeBucketSettings.CreateCall(
                    bucket: "macscp-third", protection: .lockedAndVersioned)
            ])
        #expect(model.isCreated)
        #expect(model.bucketMayExist)
    }

    @MainActor @Test func aPlainBucketIsSentWithNoProtection() async {
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(settings.creates.map(\.protection) == [.none])
    }

    // MARK: - The gate

    @MainActor @Test func theActionIsOfferedOnlyInBucketListMode() {
        // Author's call, spec §6.1: a bucket made in single-bucket mode would
        // be invisible afterwards.
        //
        // **Changed 2026-10-21 (Task 11, fix round 1).** The calls read,
        // verbatim: `CreateBucketModel.isOffered(rootIsContainerList: true) == true`
        // and `CreateBucketModel.isOffered(rootIsContainerList: false) == false`.
        // The predicate gained the pane half (below); a single-bucket
        // connection has a pane bucket too, so both spellings are asked.
        #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: nil) == true)
        #expect(CreateBucketModel.isOffered(rootIsContainerList: false, paneBucket: nil) == false)
        #expect(
            CreateBucketModel.isOffered(rootIsContainerList: false, paneBucket: "macscp-seed")
                == false)
    }

    @MainActor @Test func theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList() {
        // The gate that makes the taken-name check above mean anything: on a
        // bucket-list connection the pane can be inside a bucket, where the
        // listing is that bucket's OBJECTS, not the account's buckets.
        #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: nil) == true)
        #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: "macscp-seed") == false)
        #expect(CreateBucketModel.isOffered(rootIsContainerList: false, paneBucket: nil) == false)
    }

    // MARK: - What the sheet says when the store does not do as asked

    @MainActor @Test func aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause() async throws {
        // A reason can carry the endpoint the user typed
        // (`scheme://KEY:SECRET@host`). The planted value is a named constant
        // and the `Bool` is computed before the expectation, so a failure
        // cannot print it (CLAUDE.md, "A value a test must not leak has two
        // exits, not one"); both halves are checked, the credential and the
        // host, as the sibling suites do.
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.protocolError(reason: planted)))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(model.isCreated == false)
        #expect(model.bucketMayExist == false)
        let sentence = try #require(model.failureSentence)
        let quoted = sentence.contains("SECRETEXAMPLE") || sentence.contains("store.invalid")
        #expect(sentence == CreateBucketModel.notCreatedLine.text)
        #expect(!quoted)
        // The failure frees the name again: nothing was made.
        #expect(model.canCreate == true)
    }

    @MainActor @Test func aFindingSaysItsOwnSentence() async throws {
        for finding in [RemoteFSFinding.bucketNameTaken, .bucketAlreadyOwnedByYou] {
            let settings = FakeBucketSettings(createFailure: .refused(RemoteFSError.finding(finding)))
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = "macscp-third"
            await model.create(via: settings, recorder: nil)
            #expect(model.failureSentence == finding.message, "\(finding.name)")
            // **Corrected 2026-10-21 (Task 11, fix round 1; quoted in round
            // 2).** This loop ended with `#expect(model.bucketMayExist == false)`
            // for both findings. Withdrawn: it is false of
            // `.bucketAlreadyOwnedByYou`, which the store says exists. The
            // per-finding expectations are the two tests below.
        }
    }

    /// The two findings differ in what they say about THIS account. "Already
    /// owned by you" is the store's own statement that the bucket exists in
    /// this account, so the name is taken, the pane's list is stale and the
    /// same sheet must not send it again. "Name taken" is another account's
    /// bucket: it is not in "your list", so the taken-name sentence ("Your
    /// list already has...") would be false, and nothing in this account is
    /// stale.
    ///
    /// Found by review (I1, 2026-10-21): the first version treated both as
    /// "nothing was made" and freed the name, leaving the sheet more cautious
    /// about a bucket that MAY exist than about one the store says DOES.
    @MainActor @Test func aBucketTheStoreSaysYouOwnIsTakenAndTheListIsStale() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.finding(.bucketAlreadyOwnedByYou)))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(model.bucketMayExist == true)  // the pane refreshes
        #expect(model.canCreate == false)
        #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
        #expect(model.showsNameIsTaken == false)  // the finding's own sentence says it
        #expect(model.failureSentence == RemoteFSFinding.bucketAlreadyOwnedByYou.message)
        #expect(settings.reads.isEmpty)  // the store has said; no read is spent
    }

    @MainActor @Test func aNameAnotherAccountOwnsIsNotInYourListAndNothingIsStale() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.finding(.bucketNameTaken)))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(model.bucketMayExist == false)
        #expect(model.canCreate == true)  // another name, or the same: the store will say
        #expect(model.nameIsTakenKey == nil)
    }

    /// The taken-name line and the outcome sentence must not be on screen
    /// together when the outcome already says the bucket exists: "was created,
    /// but ..." beside "Your list already has a bucket with this name. Choose
    /// a different name." contradict each other in tone (M8).
    @MainActor @Test func theTakenNameLineIsOnScreenOnlyWhenNothingElseSaysTheBucketExists() async {
        let free = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        free.name = "macscp-third"
        #expect(free.showsNameIsTaken == false)
        let taken = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        taken.name = "macscp-seed"
        #expect(taken.showsNameIsTaken == true)  // the positive control

        let partial = FakeBucketSettings(
            createFailure: .afterTheBucketExists(RemoteFSError.permissionDenied(path: "/x")))
        let afterPartial = CreateBucketModel(existingNames: [], listingIsKnown: true)
        afterPartial.name = "macscp-third"
        afterPartial.versioning = true
        await afterPartial.create(via: partial, recorder: nil)
        #expect(afterPartial.nameIsTakenKey != nil)  // it IS taken...
        #expect(afterPartial.showsNameIsTaken == false)  // ...and the outcome already says so

        let made = CreateBucketModel(existingNames: [], listingIsKnown: true)
        made.name = "macscp-third"
        await made.create(via: FakeBucketSettings(), recorder: nil)
        #expect(made.showsNameIsTaken == false)
    }

    @MainActor @Test func aMissingPermissionOnAPlainCreateHasItsOwnSentence() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.permissionDenied(path: "/macscp-third")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(model.failureSentence == CreateBucketModel.deniedLine.text)
    }

    @MainActor @Test func aFailureOfTheSecondRequestSaysTheBucketExists() async throws {
        // `createBucket` makes two requests when versioning is on, and a
        // failure of the SECOND leaves the bucket created and unversioned. The
        // call does not delete what it made, so "failed" would be false.
        let settings = FakeBucketSettings(
            createFailure: .afterTheBucketExists(RemoteFSError.permissionDenied(path: "/macscp-third")))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        await model.create(via: settings, recorder: nil)
        #expect(model.isCreated == false)
        #expect(model.bucketMayExist == true)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.existsIncompletelyLine(bucket: "macscp-third"))
        #expect(sentence.contains("macscp-third"))
        #expect(sentence != CreateBucketModel.notCreatedLine.text)
        // The bucket exists now, so the name is taken: a second click would
        // be exactly the re-create the taken-name check exists to stop.
        #expect(model.canCreate == false)
        #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
    }

    @MainActor @Test func aFailureWhoseCauseCannotBeTracedSaysItMayExist() async throws {
        // Two requests, the failure could be either, and the follow-up read
        // that would tell them apart is refused too: the one true thing left
        // to say is "it may exist". Not "was created", not "was not".
        let settings = FakeBucketSettings(
            readError: RemoteFSError.permissionDenied(path: "/macscp-third"),
            createFailure: .refused(RemoteFSError.permissionDenied(path: "/macscp-third")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        await model.create(via: settings, recorder: nil)
        #expect(model.failureSentence == CreateBucketModel.mayExistLine.text)
        #expect(model.bucketMayExist == true)
        #expect(model.canCreate == false)
    }

    @MainActor @Test func aRefusedCreateOfAProtectedBucketThatLeftNothingSaysNotCreated() async {
        // The same two-request call, but the read after the failure finds no
        // bucket (the store's own "no such bucket"): the FIRST request failed,
        // and that is a plain "not created".
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.protocolError(reason: "x")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(model.failureSentence == CreateBucketModel.notCreatedLine.text)
        #expect(model.bucketMayExist == false)
        #expect(settings.reads == ["macscp-third"])  // the read was made, once
    }

    @MainActor @Test func aTakenNameFindingNeedsNoFollowUpRead() async {
        // `.bucketNameTaken` can only come from the create itself, so the
        // sentence is the finding's own and no read is spent finding out.
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.finding(.bucketNameTaken)))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(model.failureSentence == RemoteFSFinding.bucketNameTaken.message)
        #expect(model.bucketMayExist == false)
        #expect(settings.reads.isEmpty)
    }

    // MARK: - What the store turned out to have (F1)

    /// **The one the finding is about.** The create is answered with success
    /// and the bucket has no Object Lock -- what the rig does to a re-create
    /// of a bucket the key already owns (`S3CreateBucketGatedTests`
    /// `.recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`:
    /// `second == nil`, `after?.hasLock == false`, `after?.versioning == .enabled`).
    /// A flat "was created" over that is the belief the whole Object Lock half
    /// of this work exists to make trustworthy, asserted from the absence of a
    /// throw.
    @MainActor @Test func aCreateWhoseObjectLockDidNotTakeIsNotSaidToBeDone() async throws {
        let settings = FakeBucketSettings(createEffect: .ignoresTheObjectLockHeader)
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        // The read-back was made, through the capability the other four
        // paths use, and after the create rather than before it.
        #expect(settings.hasLockReads == ["macscp-third"])
        #expect(model.isCreated == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.settingsDidNotTakeLine(bucket: "macscp-third"))
        #expect(sentence != model.createdSentence)
        // The bucket is there, so the list is stale and the name is taken:
        // a second click would be the re-create the check exists to stop.
        #expect(model.bucketMayExist == true)
        #expect(model.canCreate == false)
        #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
        #expect(model.showsNameIsTaken == false)
    }

    /// The positive control for the test above: with the same two switches and
    /// a store that does what it was asked, the sheet still says the bucket
    /// was created -- and the read-back is what said so.
    @MainActor @Test func aCreateWhoseSettingsTookIsStillSaidToBeDone() async {
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(model.isCreated)
        #expect(model.failureSentence == nil)
        #expect(settings.hasLockReads == ["macscp-third"])
        #expect(settings.reads == ["macscp-third"])
    }

    /// The versioning half of the same read-back.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 2).** The doc comment read,
    /// verbatim: "The versioning half of the same read-back, and the proof
    /// that the lock is read only where it was asked for: a `.versioned`
    /// create claims nothing about Object Lock, so nothing is spent asking."
    /// and the body asserted `#expect(settings.hasLockReads.isEmpty)`. Both
    /// were withdrawn: the lock is read on EVERY create that asks for any
    /// protection, because a `.versioned` create landing on a bucket that
    /// already has Object Lock is the mirror harm -- see
    /// `aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked`.
    @MainActor @Test func aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone() async throws {
        let settings = FakeBucketSettings(createEffect: .ignoresTheVersioningRequest)
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        await model.create(via: settings, recorder: nil)
        #expect(settings.reads == ["macscp-third"])
        #expect(settings.hasLockReads == ["macscp-third"])
        #expect(model.isCreated == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.settingsDidNotTakeLine(bucket: "macscp-third"))
        #expect(model.bucketMayExist == true)
    }

    /// **The mirror of the finding, and the heavier half.** A create that
    /// asks for versioning only, answered with success, on a bucket that
    /// already HAS Object Lock -- the stale-listing re-create again, with the
    /// switches the other way round. Reporting it as asked leaves a person
    /// owning a bucket with Object Lock they never chose and **can never
    /// remove**, with an audit line saying "with versioning" and nothing
    /// else. The property is not "what was asked for arrived" but "what the
    /// bucket now has is what the sheet and the audit line say it has".
    ///
    /// The sentence is `protectionNotChosen`, the inverse line: the bucket was
    /// already there and carries protection nobody chose, and it names the
    /// permanence rather than leaving it to `objectLockNote` on the sheet the
    /// person has just dismissed.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 3).** This doc paragraph read,
    /// verbatim: "The sentence is `settingsDidNotTake`, and it is true of
    /// this case: the sheet offers two switches and "the settings you chose"
    /// is the PAIR, so a lock the person unticked and got anyway is a setting
    /// the bucket does not match. Its second half, "Open Versioning and
    /// Object Lock for it to see what it has", points at the one place that
    /// shows the lock." The reading was accepted and then dropped, because
    /// the same sentence had to cover a PLAIN create, where the person chose
    /// nothing and a sentence about settings they chose is false of them.
    /// `settingsDidNotTake` now means only what its name says: a setting that
    /// was chosen and did not take.
    @MainActor @Test func aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked() async throws {
        // A bucket that already carries a lock. The create asks for
        // versioning and no lock, and the store accepts it: a create does not
        // take a lock off a bucket that has one.
        let settings = FakeBucketSettings(lock: .init(hasLock: true))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        #expect(model.protection == .versioned)  // no lock was asked for
        await model.create(via: settings, recorder: nil)
        // The lock is read even though no lock was asked for: that is the
        // whole of this case.
        #expect(settings.hasLockReads == ["macscp-third"])
        #expect(model.isCreated == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.protectionNotChosenLine(bucket: "macscp-third"))
        #expect(sentence != CreateBucketModel.settingsDidNotTakeLine(bucket: "macscp-third"))
        #expect(model.bucketMayExist == true)
        #expect(model.canCreate == false)
    }

    /// **The heaviest of the three, and the one that looks lightest.** A
    /// PLAIN create -- both switches off -- answered with success, on a name
    /// the person already owns, whose bucket has Object Lock and versioning.
    ///
    /// Walked to the end: they believe the bucket is new and ordinary and
    /// start writing files into it. Every object inherits the bucket's
    /// default retention, and under COMPLIANCE nobody can delete those
    /// objects until their dates pass -- not the person, not the account
    /// owner. This branch ships the feature that sets such a default. They
    /// chose nothing and, before this, were told nothing: the sheet said
    /// "was created" and the audit line said `created bucket macscp-third`,
    /// naming no protection, so nothing CLAIMED a protection that was not
    /// there and nothing mentioned the two that were.
    @MainActor @Test func aPlainCreateOntoAnAlreadyProtectedBucketIsNotSaidToBeDone() async throws {
        let settings = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: true))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        #expect(model.protection == .none)  // nothing was chosen
        await model.create(via: settings, recorder: nil)
        #expect(settings.hasLockReads == ["macscp-third"])
        #expect(settings.reads == ["macscp-third"])
        #expect(model.isCreated == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.protectionNotChosenLine(bucket: "macscp-third"))
        // The sentence names the permanence here, not on the sheet the person
        // has already dismissed, and it does not talk about settings they
        // chose, because they chose none.
        #expect(sentence.contains("macscp-third"))
        #expect(sentence != CreateBucketModel.settingsDidNotTakeLine(bucket: "macscp-third"))
        #expect(model.bucketMayExist == true)
        #expect(model.canCreate == false)
    }

    /// Which of the two sentences a mismatch gets, over every pair the two
    /// reads can produce: LESS protection than was asked for is a setting
    /// that did not take, MORE is protection nobody chose. The chain is
    /// total, so there is no pair both sentences or neither could claim.
    @MainActor @Test func theDirectionOfAMismatchDecidesWhichSentenceIsShown() {
        let ranks = BucketProtection.allCases.map { CreateBucketModel.protectionRank($0) }
        #expect(ranks == [0, 1, 2])  // the chain, in the enum's own order
        #expect(BucketProtection.allCases.count == 3)
        // Every ordered pair of distinct protections, and which way it runs.
        var less = 0
        var more = 0
        for asked in BucketProtection.allCases {
            for found in BucketProtection.allCases where found != asked {
                let askedRank = CreateBucketModel.protectionRank(asked)
                let foundRank = CreateBucketModel.protectionRank(found)
                #expect(askedRank != foundRank, "\(asked) vs \(found)")
                if foundRank > askedRank { more += 1 } else { less += 1 }
            }
        }
        #expect(more == 3)
        #expect(less == 3)
    }

    /// **The third outcome.** The create was accepted and the read-back
    /// itself was refused, so nothing is known about the settings. That is
    /// neither a success nor a failed create, and the sentence says exactly
    /// that -- it is not `settingsDidNotTake`, which asserts their absence.
    @MainActor @Test func aReadBackThatIsRefusedSaysTheSettingsCouldNotBeConfirmed() async throws {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            lock: .init(hasLock: true, hasLockError: RemoteFSError.protocolError(reason: planted)))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: settings, recorder: nil)
        #expect(model.isCreated == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.settingsUnconfirmedLine(bucket: "macscp-third"))
        #expect(sentence != CreateBucketModel.settingsDidNotTakeLine(bucket: "macscp-third"))
        #expect(sentence != CreateBucketModel.notCreatedLine.text)
        // The create itself went through, so the bucket is there.
        #expect(model.bucketMayExist == true)
        #expect(settings.creates.count == 1)
        // The refusal's own words never reach the sentence. A named constant
        // and the `Bool` first, so a failure here cannot print either half
        // (CLAUDE.md, "A value a test must not leak has two exits, not one").
        let quoted = sentence.contains("SECRETEXAMPLE") || sentence.contains("store.invalid")
        #expect(!quoted)
    }

    /// A create with no protection reads back too, and a bucket that turned
    /// out to carry nothing is said to be done. The positive control for the
    /// plain-create case above: the plain path is not simply always a
    /// failure now.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 3).** This test was named
    /// `aCreateWithNoProtectionSpendsNoReadBack`, its doc read, verbatim: "A
    /// create with no protection claims no setting, so there is nothing to
    /// read back and no request is spent on one. The guard against a
    /// read-back that quietly became unconditional.", and it asserted
    /// `settings.reads.isEmpty` and `settings.hasLockReads.isEmpty`. All of
    /// it is withdrawn. Saving the two requests cost the one case that
    /// matters most: a plain create landing on a bucket that already has
    /// Object Lock and a COMPLIANCE default.
    @MainActor @Test func aPlainCreateOntoAnEmptyNameIsStillSaidToBeDone() async {
        let settings = FakeBucketSettings()
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(model.isCreated)
        #expect(model.failureSentence == nil)
        #expect(settings.reads == ["macscp-third"])
        #expect(settings.hasLockReads == ["macscp-third"])
    }

    /// What a bucket READ BACK has, as the one choice Core takes, over every
    /// combination the two reads can answer. The lock is the stronger fact:
    /// `BucketProtection` has no case for a lock without enabled versioning,
    /// and a line that dropped the lock would under-state what the bucket
    /// enforces.
    @MainActor @Test func theProtectionReadBackIsNamedFromTheLockFirst() {
        #expect(
            CreateBucketModel.protection(hasObjectLock: true, versioning: .enabled)
                == .lockedAndVersioned)
        #expect(
            CreateBucketModel.protection(hasObjectLock: true, versioning: .never)
                == .lockedAndVersioned)
        #expect(
            CreateBucketModel.protection(hasObjectLock: false, versioning: .enabled) == .versioned)
        #expect(CreateBucketModel.protection(hasObjectLock: false, versioning: .never) == .none)
        #expect(CreateBucketModel.protection(hasObjectLock: false, versioning: .suspended) == .none)
    }

    @MainActor @Test func editingTheNameClearsAStaleFailure() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.protocolError(reason: "x")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings, recorder: nil)
        #expect(model.failureSentence != nil)
        model.name = "macscp-fourth"
        #expect(model.failureSentence == nil)
    }

    @MainActor @Test func aSheetBuiltInAFailedStateShowsTheFailureForItsName() {
        // Found by the layout guard (`entriesOfOneTypeMeasureDifferentStates`,
        // 2026-10-21): the observer on `name`, which clears a stale failure,
        // ALSO ran for the name the initialiser assigned, because observers
        // on an `@Observable` class's properties run in `init`. A sheet built
        // in a failed state with the name it failed for came up with no
        // failure on it.
        let model = CreateBucketModel(
            existingNames: [], listingIsKnown: true,
            outcome: .failed(sentence: "it did not work", bucketMayExist: true),
            name: "macscp-third")
        #expect(model.failureSentence == "it did not work")
        #expect(model.bucketMayExist)
        // The observer still does its job afterwards.
        model.name = "macscp-fourth"
        #expect(model.failureSentence == nil)
    }

    @MainActor @Test func aCreateInFlightIsNotStartedASecondTime() async {
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true, outcome: .creating)
        model.name = "macscp-third"
        #expect(model.canCreate == false)
        let settings = FakeBucketSettings()
        await model.create(via: settings, recorder: nil)
        #expect(settings.creates.isEmpty)
    }

    // MARK: - Where the list of names comes from

    @MainActor private static func bucketListBrowser(
        _ names: [String]
    ) throws -> (RemoteBrowserViewModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-bucket-\(UUID().uuidString)")
        for name in names {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return (RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: directory.path), directory)
    }

    @MainActor @Test func theListingHoldsEveryNameWhateverTheSearchIsHiding() async throws {
        let (browser, directory) = try Self.bucketListBrowser(["macscp-seed", "macscp-second", "photos"])
        defer { try? FileManager.default.removeItem(at: directory) }
        await browser.load()
        browser.searchMode = .filter
        browser.searchQuery = "photos"
        // The filter is hiding two of the three, which is what makes the next
        // line mean something.
        #expect(browser.items.map(\.name) == ["photos"])
        let listing = CreateBucketModel.listing(of: browser)
        #expect(listing.isKnown)
        #expect(Set(listing.names) == ["macscp-seed", "macscp-second", "photos"])
        // And the model built from it refuses a name the filter hid.
        let model = CreateBucketModel(listing: listing)
        model.name = "macscp-seed"
        #expect(model.canCreate == false)
        #expect(model.nameIsTakenKey != nil)
    }

    @MainActor @Test func aListingThatHasNotLoadedIsNotKnown() async throws {
        let (browser, directory) = try Self.bucketListBrowser(["macscp-seed"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let before: CreateBucketModel.Listing = CreateBucketModel.listing(of: browser)
        #expect(before.isKnown == false)
        #expect(before.names.isEmpty)  // not "no buckets": no answer
        await browser.load()
        let after: CreateBucketModel.Listing = CreateBucketModel.listing(of: browser)
        #expect(after.isKnown == true)
        #expect(after.names == ["macscp-seed"])
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let lines = Self.everyLine()
        for line in lines {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) {
                    L10n.string(line.key, sentinel)
                }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
            }
        }
        #expect(lines.count > 0)
    }

    @MainActor @Test func theEnglishCatalogueSaysTheDefault() {
        let lines = Self.everyLine()
        for line in lines {
            let english = L10n.$localeOverride.withValue("en") {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(english == line.english, "\(line.key)")
        }
        #expect(lines.count > 0)
    }

    @MainActor @Test func theTwoFinalSwitchesDoNotSayTheSameThing() {
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) {
                (
                    CreateBucketModel.versioningNote.text,
                    CreateBucketModel.objectLockNote.text,
                    CreateBucketModel.versioningHeldByObjectLockNote.text
                )
            }
            #expect(texts.0 != texts.1, "\(locale)")
            #expect(texts.1 != texts.2, "\(locale)")
            #expect(texts.0 != texts.2, "\(locale)")
        }
    }

    /// **Task 10's sentence, held to this sheet.** `s3.objectLock.notEnabledOnThisBucket`
    /// ends by saying Object Lock "can be chosen when a bucket is created".
    /// That is true only if this sheet offers a choice called what that
    /// sentence calls it, in every language. The sentence is read from the
    /// catalogue and the checkbox's label from the model, so renaming one
    /// without the other is red here.
    ///
    /// **Corrected 2026-10-21 (Task 11, fix round 1, M4).** This test pinned
    /// only that the sentence contains the label, so deleting the clause the
    /// sentence exists to keep ("...it can be chosen when a bucket is
    /// created") from all four catalogues left it green: the sentence still
    /// opens with the label. It now also requires the clause itself, in the
    /// shape all four catalogues share: a last part after a semicolon, naming
    /// the thing this sheet creates. That noun is DERIVED, not spelled: the
    /// words of the sheet's title that also occur in its name field's label.
    /// What this pins is that the clause exists and talks about buckets, not
    /// that it says "creation"; the label equality above carries the rest.
    @MainActor @Test func theObjectLockSentenceNamesWhatTheCheckboxIsCalled() {
        for locale in Self.locales {
            let (sentence, label, title, nameLabel) = L10n.$localeOverride.withValue(locale) {
                (
                    ObjectLockLines.notEnabledOnThisBucket.text, CreateBucketModel.objectLockLabel.text,
                    CreateBucketModel.titleLine.text, CreateBucketModel.nameLabelLine.text
                )
            }
            #expect(
                sentence.localizedCaseInsensitiveContains(label),
                "\(locale): \"\(sentence)\" does not name \"\(label)\"")

            let nouns = title.split(separator: " ").map(String.init).filter {
                $0.count >= 4 && nameLabel.localizedCaseInsensitiveContains($0)
            }
            #expect(!nouns.isEmpty, "\(locale): no noun shared by the title and the name label")
            let parts = sentence.split(separator: ";", omittingEmptySubsequences: false)
            #expect(parts.count >= 2, "\(locale): the clause after the semicolon is gone: \"\(sentence)\"")
            let clause = parts.last.map(String.init) ?? ""
            #expect(
                nouns.contains { clause.localizedCaseInsensitiveContains($0) },
                "\(locale): the last clause \"\(clause)\" names none of \(nouns)")
            if locale == "en" {
                // `en` is the source text the other catalogues are measured
                // against, so its clause's own words are pinned: that the
                // lock CAN BE CHOSEN when a bucket is CREATED, which is the
                // promise this sheet makes true. No cross-locale derivation of
                // those words exists (the French clause says "création", the
                // action says "Créer"), so this one is spelled, once, in the
                // source language. Without it a clause rewritten to say
                // anything else about buckets ("a bucket cannot be changed
                // afterwards") kept this test green.
                let words = clause.lowercased()
                #expect(words.contains("chosen"), "en: the clause no longer says the lock can be chosen: \"\(clause)\"")
                #expect(words.contains("created"), "en: the clause no longer says when: \"\(clause)\"")
            }
        }
    }

    // MARK: - What is on screen, not what the model computes

    /// The natural height of the sheet over `model`, in `locale`, at the width
    /// the sheet is granted. A line that is drawn adds height; a line that is
    /// not drawn adds none. Plain `Text` cannot be found in a hosted view (the
    /// accessibility tree is empty in a test process, see
    /// `BoundedViewStateOnScreenTests`), so presence is read from the height.
    @MainActor private static func height(of model: CreateBucketModel, in locale: String) -> CGFloat {
        SheetBound.$isSuspendedForMeasurement.withValue(true) {
            LayoutMeasure.minimumHeight(locale: locale, at: CreateBucketSheet.bound.grantedWidth) {
                CreateBucketSheet(
                    recorder: nil,
                    settings: FakeBucketSettings(), listing: BoundedViewRegistry.bucketListing,
                    model: model
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// **M8, at the view.** `showsNameIsTaken` is the model's decision, and the
    /// model-level tests read it. The sheet must also READ it: restoring the
    /// view's pre-fix condition (`if model.nameIsTakenKey != nil, !model.isCreated`)
    /// brought the defect back and stayed GREEN over 81 tests, because no
    /// registry entry had both a partial outcome and a taken name. Here the
    /// state is built both ways and the heights compared: when the outcome
    /// already says the bucket exists, a taken name adds no line.
    ///
    /// The positive control is the same comparison where the line SHOULD show
    /// (nothing else says the bucket exists): the taken name is then taller. A
    /// height that cannot see the line would pass the first half for nothing.
    @MainActor @Test func aTakenNameAddsNoLineBesideAnOutcomeThatAlreadySaysTheBucketExists() {
        for locale in LayoutMeasure.shippedLocales {
            let ours = Self.height(of: BoundedViewRegistry.ownedBucketModel(nameInList: true), in: locale)
            let control = Self.height(of: BoundedViewRegistry.ownedBucketModel(nameInList: false), in: locale)
            #expect(abs(ours - control) < 0.01, "\(locale): \(ours) pt with the name in the list, \(control) pt without")

            let taken = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
            taken.name = "macscp-seed"
            let free = CreateBucketModel(existingNames: [], listingIsKnown: true)
            free.name = "macscp-seed"
            let withLine = Self.height(of: taken, in: locale)
            let withoutLine = Self.height(of: free, in: locale)
            #expect(withLine > withoutLine, "\(locale): the taken-name line adds no height, so the comparison above proves nothing")
        }
    }

    // MARK: - Every sentence a person reads is read by a test

    /// Found by review (I2, 2026-10-21) with a probe that came back GREEN over
    /// 47 tests: `problemSentence` and `createdSentence` substitute an argument,
    /// nothing read either, and a literal `%@` on screen would have shipped in
    /// four languages. The sibling of the `versioning` observer hole (P9).
    @MainActor @Test func aSubstitutedSentenceNeverShowsItsPlaceholder() async {
        for locale in Self.locales {
            L10n.$localeOverride.withValue(locale) {
                let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
                model.name = "macscp_archive"
                let problem = model.problemSentence ?? ""
                #expect(problem.contains("_"), "\(locale): the character is not in \"\(problem)\"")
                #expect(!problem.contains("%"), "\(locale): \"\(problem)\"")

                let made = CreateBucketModel(
                    existingNames: [], listingIsKnown: true, outcome: .created, name: "macscp-archive")
                #expect(made.createdSentence.contains("macscp-archive"), "\(locale)")
                #expect(!made.createdSentence.contains("%"), "\(locale)")

                let partial = CreateBucketModel.existsIncompletelyLine(bucket: "macscp-archive")
                #expect(partial.contains("macscp-archive"), "\(locale)")
                #expect(!partial.contains("%"), "\(locale)")
            }
        }
    }

    @MainActor @Test func everyProblemSentenceIsPlainTextOnceFilledIn() {
        for name in ["ab", String(repeating: "a", count: 64), "Abc", "a_b", "192.168.0.1", "-ab"] {
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = name
            let sentence = model.problemSentence
            #expect(sentence != nil, "\(name.prefix(8))")
            #expect(sentence?.contains("%") == false, "\(name.prefix(8))")
        }
        // The positive: a valid name has no problem to say.
        let fine = CreateBucketModel(existingNames: [], listingIsKnown: true)
        fine.name = "macscp-third"
        #expect(fine.problemSentence == nil)
    }

    @MainActor @Test func theFieldsAreEditableExceptWhileCreatingAndOnceCreated() {
        func editable(_ outcome: CreateBucketModel.Outcome) -> Bool {
            CreateBucketModel(existingNames: [], listingIsKnown: true, outcome: outcome).isEditable
        }
        #expect(editable(.editing) == true)  // the positive control
        #expect(editable(.failed(sentence: "x", bucketMayExist: false)) == true)
        #expect(editable(.creating) == false)
        #expect(editable(.created) == false)
    }

    @MainActor @Test func theStateFlagsTheViewShowsAreTheOutcomeAndNothingElse() {
        func model(_ outcome: CreateBucketModel.Outcome) -> CreateBucketModel {
            CreateBucketModel(existingNames: [], listingIsKnown: true, outcome: outcome)
        }
        #expect(model(.creating).isCreating == true)
        #expect(model(.creating).isCreated == false)
        #expect(model(.created).isCreated == true)
        #expect(model(.created).isCreating == false)
        #expect(model(.editing).isCreating == false)
        #expect(model(.editing).isCreated == false)
        #expect(model(.failed(sentence: "x", bucketMayExist: true)).isCreated == false)
    }

    @MainActor @Test func theVersioningCheckboxAndItsNoteFollowTheLock() {
        let free = CreateBucketModel(existingNames: [], listingIsKnown: true)
        #expect(free.versioningCanBeChanged == true)
        #expect(free.versioningNoteLine == CreateBucketModel.versioningNote)
        free.objectLock = true
        #expect(free.versioningCanBeChanged == false)
        #expect(free.versioningNoteLine == CreateBucketModel.versioningHeldByObjectLockNote)
        let busy = CreateBucketModel(existingNames: [], listingIsKnown: true, outcome: .creating)
        #expect(busy.versioningCanBeChanged == false)
    }

    /// The lines the view shows as they stand, with no argument to fill in:
    /// each is among the lines the catalogue checks sweep, and none carries a
    /// placeholder in any language (a `%@` in a line nobody fills in would be
    /// shown as it is).
    @MainActor @Test func theLinesTheViewShowsAsTheyStandCarryNoPlaceholder() {
        let shown: [CatalogueLine] = [
            CreateBucketModel.titleLine, CreateBucketModel.nameLabelLine,
            CreateBucketModel.nameHintLine, CreateBucketModel.actionLine,
            CreateBucketModel.versioningLabel, CreateBucketModel.objectLockLabel,
            CreateBucketModel.nameIsTakenLine, CreateBucketModel.listingUnknownLine,
            CreateBucketModel.creatingLine,
        ]
        let swept = CreateBucketModel.allLines
        for line in shown {
            #expect(swept.contains(line), "\(line.key) is shown and not swept")
            #expect(!line.key.hasSuffix("%@"), "\(line.key)")
            for locale in Self.locales {
                let text = L10n.$localeOverride.withValue(locale) { line.text }
                #expect(!text.contains("%"), "\(line.key) in \(locale)")
                #expect(!text.isEmpty, "\(line.key) in \(locale)")
            }
        }
        #expect(shown.count == 9)
    }

    /// The identifiers in `text`: it split on every character that cannot be
    /// part of one, so a name is a token only when it is a whole word.
    nonisolated static func identifierTokens(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init))
    }

    /// **Corrected 2026-10-21 (Task 11, fix round 3, N5).** There was a
    /// `withoutStringLiterals(_:)` here: a hand-rolled quote toggler that did
    /// not understand regex literals. `#/"(s3\.createBucket\.[^"]+)"/#` in
    /// this file carries three quotes and inverted its in/out state from there
    /// to the end of the file, where it dropped code and kept string contents
    /// as tokens. Measured before it was removed (against 0ef4e3f5): a view
    /// member named only inside a string literal at the end of this file was
    /// GREEN (named without being tested), and one named only in code there
    /// was RED. `SourceCorpus.code(of:)` blanks comments and string literals
    /// correctly and is used by `Self.code` in this same file.
    ///
    /// Held by two fixtures at the END of this file, after the regex literal:
    /// a name inside a string (must not be a token of the blanked code) and a
    /// name in code (must be).
    @Test func theSweepSeesCodeAndNotStringsAtTheEndOfThisFile() throws {
        let code = try Self.code("Tests/macSCPAppKitTests/CreateBucketSheetTests.swift")
        let tokens = Self.identifierTokens(in: code)
        #expect(tokens.contains("sweepFixtureInCode"))  // the positive control
        #expect(!tokens.contains("sweepFixtureInsideAString"))
    }

    @Test func aPrefixOfAnIdentifierIsNotTheIdentifier() {
        let text = "model.nameIsTakenKey + showsNameIsTaken"
        let tokens = Self.identifierTokens(in: text)
        #expect(tokens.contains("nameIsTakenKey"))  // the positive control
        #expect(tokens.contains("showsNameIsTaken"))
        // The prefix is computed, not written: a literal spelling it would be
        // a token of THIS file, and the sweep above reads this file's strings
        // (it did: that made a probe naming a member exactly this GREEN, 2026-10-21).
        let prefix = String("nameIsTakenKey".dropLast(3))
        #expect(!tokens.contains(prefix))
        #expect(!tokens.contains("model.nameIsTakenKey"))
    }

    /// The sweep itself, so it does not have to be remembered: every member of
    /// the model that the VIEW reads (`model.x`, `CreateBucketModel.x` in the
    /// sheet's struct) is named somewhere in this suite. A mention is not an
    /// assertion, but a member nobody mentions is exactly the shape that hid
    /// `problemSentence`, and the positive half is that the scan found some.
    @MainActor @Test func everyMemberTheViewReadsIsNamedByATest() throws {
        let sheet = try Self.code("Sources/MacSCPAppKit/CreateBucketSheet.swift")
        let view = try #require(sheet.range(of: "struct CreateBucketSheet"))
        let viewCode = String(sheet[view.lowerBound...])
        let read = Set(
            viewCode.matches(of: #/(?:\bmodel|CreateBucketModel)\.(\w+)/#).map { String($0.output.1) })
        #expect(read.count >= 15, "the scan found \(read.count) members")
        let tests = try Self.code("Tests/macSCPAppKitTests/CreateBucketSheetTests.swift")
        // Whole tokens, not substrings: a member named `nameIsTaken` would be
        // "named" by `nameIsTakenKey` under a substring test (measured
        // 2026-10-21, GREEN where `zzzNothingNamesThis` was RED 3 of 3). The
        // text is split on every character that cannot be in an identifier,
        // and a member is named only if it is one of the tokens.
        let tokens = Self.identifierTokens(in: tests)
        #expect(!tokens.isEmpty, "the tokeniser found nothing")
        #expect(tokens.contains("canCreate"), "the tokeniser lost the code")
        let unnamed = read.filter { !tokens.contains($0) }.sorted()
        #expect(unnamed.isEmpty, "\(unnamed)")
    }

    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/CreateBucketSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(
            source.matches(of: #/"(s3\.createBucket\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let covered = Set(Self.everyLine().map(\.key))
        let uncovered = used.subtracting(covered).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// Every line the sheet can show.
    @MainActor private static func everyLine() -> [CatalogueLine] {
        CreateBucketModel.allLines
    }

    // MARK: - Wiring

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
    }

    /// The route's gate is `isOffered`, not a second spelling of it: a row
    /// whose arm asked `rootIsContainerList` itself would leave `isOffered`
    /// with no caller, which is the defect this task's brief was amended for.
    @Test func theRoutesGateAsksTheModelsRule() throws {
        let source = try Self.code("Sources/MacSCPAppKit/ConnectionActionRoute.swift")
        let start = try #require(source.range(of: "case .createBucket:"))
        let rest = source[start.upperBound...]
        let arm = rest[..<(rest.range(of: "case .")?.lowerBound ?? rest.endIndex)]
        #expect(arm.contains("CreateBucketModel.isOffered("))
        // The arm supplies BOTH facts the rule is made of: the connection's
        // root and the bucket the pane is inside. Handing it only the first
        // would leave the pane half unasked.
        #expect(arm.contains("rootIsContainerList: context.rootIsContainerList"))
        #expect(arm.contains("paneBucket: context.bucket"))
        // And the arm is not a neighbour's: it never asks for a bucket to
        // exist (`bucket != nil`), which would make the row unreachable.
        #expect(!arm.contains("context.bucket != nil"))
        // **Corrected 2026-10-21 (Task 11, fix round 1; quoted in round 2).**
        // The lines above this comment replaced these, verbatim: the comment
        // "And the arm is the inverse of its neighbours' bucket test: a row that
        // is live only AT the list." and the expectation
        // `#expect(arm.contains("context.bucket == nil"))`. Withdrawn because
        // the pane half of the rule moved into `isOffered`, so the arm no
        // longer spells `context.bucket == nil`; it hands the model the bucket.
    }

    /// The dispatcher builds the sheet's list from the pane's listing through
    /// `CreateBucketModel.listing(of:)`, so the taken-name check has a source
    /// that is not an empty array.
    @Test func theDispatcherHandsTheSheetTheRemotePanesListing() throws {
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
        let start = try #require(dispatcher.range(of: "case .createBucket:"))
        let rest = dispatcher[start.upperBound...]
        let arm = rest[..<(rest.range(of: "case .")?.lowerBound ?? rest.endIndex)]
        #expect(arm.contains("CreateBucketModel.listing(of: session.remote)"))
        // The sheet is presented with the same listing and refreshes the pane
        // when it made a bucket.
        let sheets = try Self.code("Sources/MacSCPAppKit/ContentView+Sheets.swift")
        let presentation = try #require(sheets.range(of: ".sheet(item: $createBucketSheetItem)"))
        let after = sheets[presentation.upperBound...]
        let closure = after[..<(after.range(of: ".sheet(")?.lowerBound ?? after.endIndex)]
        #expect(closure.contains("listing: item.listing"))
        #expect(closure.contains("onCreated: item.onCreated"))
    }

    /// The pane shows the bucket list, so a bucket that was made does not
    /// appear in it until the list is read again. Two links make that happen
    /// and neither is exercised by a model test: the dispatcher's closure
    /// refreshes the remote pane, and the sheet calls it when the bucket may
    /// exist (also after a partial failure, when the bucket is there).
    @Test func aMadeBucketRefreshesThePaneThatListsIt() throws {
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
        let start = try #require(dispatcher.range(of: "case .createBucket:"))
        let rest = dispatcher[start.upperBound...]
        let arm = rest[..<(rest.range(of: "case .")?.lowerBound ?? rest.endIndex)]
        #expect(arm.contains("onCreated:"))
        #expect(arm.contains("remote.refresh()"))
        let sheet = try Self.code("Sources/MacSCPAppKit/CreateBucketSheet.swift")
        let guarded = try #require(sheet.range(of: "if model.bucketMayExist { onCreated() }"))
        let create = try #require(sheet.range(of: "await model.create(via: settings, recorder: recorder)"))
        #expect(create.upperBound <= guarded.lowerBound)
    }
}

// The fixtures `theSweepSeesCodeAndNotStringsAtTheEndOfThisFile` reads. They sit
// at the end of the file on purpose: after the regex literal in
// `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover`, which inverted the old
// hand-rolled blanker from there on.
private let sweepFixtureInCode = "sweepFixtureInsideAString"
