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
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.protocolError(reason: "https://KEY:SECRET@host")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings)
        #expect(model.isCreated == false)
        #expect(model.bucketMayExist == false)
        let sentence = try #require(model.failureSentence)
        #expect(sentence == CreateBucketModel.notCreatedLine.text)
        // A reason can carry the endpoint the user typed (`scheme://KEY:SECRET@host`).
        #expect(!sentence.contains("SECRET"))
        // The failure frees the name again: nothing was made.
        #expect(model.canCreate == true)
    }

    @MainActor @Test func aFindingSaysItsOwnSentence() async throws {
        for finding in [RemoteFSFinding.bucketNameTaken, .bucketAlreadyOwnedByYou] {
            let settings = FakeBucketSettings(createFailure: .refused(RemoteFSError.finding(finding)))
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = "macscp-third"
            await model.create(via: settings)
            #expect(model.failureSentence == finding.message, "\(finding.name)")
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
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        await afterPartial.create(via: partial)
        #expect(afterPartial.nameIsTakenKey != nil)  // it IS taken...
        #expect(afterPartial.showsNameIsTaken == false)  // ...and the outcome already says so

        let made = CreateBucketModel(existingNames: [], listingIsKnown: true)
        made.name = "macscp-third"
        await made.create(via: FakeBucketSettings())
        #expect(made.showsNameIsTaken == false)
    }

    @MainActor @Test func aMissingPermissionOnAPlainCreateHasItsOwnSentence() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.permissionDenied(path: "/macscp-third")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings)
        #expect(model.failureSentence == CreateBucketModel.deniedLine.text)
    }

    @MainActor @Test func aFailureOfTheSecondRequestSaysTheBucketWasCreated() async throws {
        // `createBucket` makes two requests when versioning is on, and a
        // failure of the SECOND leaves the bucket created and unversioned. The
        // call does not delete what it made, so "failed" would be false.
        let settings = FakeBucketSettings(
            createFailure: .afterTheBucketExists(RemoteFSError.permissionDenied(path: "/macscp-third")))
        let model = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        await model.create(via: settings)
        #expect(model.failureSentence == RemoteFSFinding.bucketNameTaken.message)
        #expect(model.bucketMayExist == false)
        #expect(settings.reads.isEmpty)
    }

    @MainActor @Test func editingTheNameClearsAStaleFailure() async {
        let settings = FakeBucketSettings(
            createFailure: .refused(RemoteFSError.protocolError(reason: "x")))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: settings)
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
        await model.create(via: settings)
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
        #expect(CreateBucketModel.listing(of: browser).isKnown == false)
        await browser.load()
        #expect(CreateBucketModel.listing(of: browser).isKnown == true)
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
    @MainActor @Test func theObjectLockSentenceNamesWhatTheCheckboxIsCalled() {
        for locale in Self.locales {
            let (sentence, label) = L10n.$localeOverride.withValue(locale) {
                (ObjectLockLines.notEnabledOnThisBucket.text, CreateBucketModel.objectLockLabel.text)
            }
            #expect(
                sentence.localizedCaseInsensitiveContains(label),
                "\(locale): \"\(sentence)\" does not name \"\(label)\"")
        }
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
        let create = try #require(sheet.range(of: "await model.create(via: settings)"))
        #expect(create.upperBound <= guarded.lowerBound)
    }
}
