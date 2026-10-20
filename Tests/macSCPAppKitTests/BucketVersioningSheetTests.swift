import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The versioning sheet's decisions: which state a bucket can move to, what the
/// sheet says before it moves, and what it shows when the store refuses.
///
/// No test in this project draws a SwiftUI view; these are the decisions the
/// view reads, the catalogue entries it looks its text up in, and one scan of
/// the view's own source for the keys it uses.
@Suite("Bucket versioning sheet")
struct BucketVersioningSheetTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    // MARK: - What can be offered

    @MainActor @Test func aNeverVersionedBucketOffersOnlyEnabling() {
        // Review Focus 4: "suspend" means nothing on a bucket that never kept
        // versions, and offering it would ask for a call that cannot be made.
        let model = BucketVersioningModel(current: .never)
        #expect(model.offeredStates == [.enabled])
    }

    @MainActor @Test func anEnabledBucketCanBeSuspendedAndNotUnset() {
        let model = BucketVersioningModel(current: .enabled)
        #expect(model.offeredStates == [.suspended])
    }

    @MainActor @Test func aSuspendedBucketCanBeTurnedBackOn() {
        let model = BucketVersioningModel(current: .suspended)
        #expect(model.offeredStates == [.enabled])
    }

    /// `.never` is a state the store reports and cannot be asked for; no state
    /// offers it. Paired with a total, so an empty offer cannot satisfy it.
    @MainActor @Test func noStateEverOffersNever() {
        var offered = 0
        for state in BucketVersioning.allCases {
            let states = BucketVersioningModel(current: state).offeredStates
            offered += states.count
            #expect(!states.contains(.never))
        }
        #expect(offered == BucketVersioning.allCases.count)
    }

    /// Until the read has answered, or after it failed, there is no state to
    /// move from and so nothing to offer.
    @MainActor @Test func nothingIsOfferedWithoutAKnownState() {
        #expect(BucketVersioningModel().offeredStates.isEmpty)
        #expect(BucketVersioningModel(loadFailure: "x").offeredStates.isEmpty)
        #expect(BucketVersioningModel().warningKey == nil)
    }

    // MARK: - What it says first

    @MainActor @Test func suspendingSaysWhatItDoesNotDo() {
        let model = BucketVersioningModel(current: .enabled)
        #expect(model.warningKey == "s3.versioning.suspendKeepsVersions")
    }

    /// Turning versioning on is the one-way door (it can be suspended, never
    /// returned to never-versioned), and the sheet says so before the click.
    /// A resumed bucket has nothing further to warn about. The answers differ
    /// from one another, so a model that returned one key for every state would
    /// not pass.
    @MainActor @Test func eachStateSaysItsOwnThingBeforeTheClick() {
        let never = BucketVersioningModel(current: .never).warningKey
        let enabled = BucketVersioningModel(current: .enabled).warningKey
        let suspended = BucketVersioningModel(current: .suspended).warningKey
        #expect(never != nil)
        #expect(enabled != nil)
        #expect(never != enabled)
        #expect(suspended == nil)
    }

    /// The warning about money says what suspending does AND what it does not
    /// do, in plain words, and names nothing about how the store works. The
    /// words below are the ones this sentence must not lean on; the positive
    /// halves are that the sentence is there and that it mentions cost.
    @MainActor @Test func theSuspendWarningIsPlainAndNamesNoMechanics() {
        let english = L10n.$localeOverride.withValue("en") {
            BucketVersioningModel(current: .enabled).warning?.text ?? ""
        }
        #expect(!english.isEmpty)
        let lowered = english.lowercased()
        for jargon in ["delete marker", "s3", "bucket policy", "lifecycle"] {
            let leaked = lowered.contains(jargon)
            #expect(!leaked)
        }
        let namesCost = lowered.contains("cost")
        #expect(namesCost)
    }

    // MARK: - Reading and writing

    @MainActor @Test func aReadFillsTheStateFromTheBucketItWasAskedAbout() async {
        let settings = FakeBucketSettings(versioning: .suspended)
        let model = BucketVersioningModel()
        await model.read(bucket: "macscp-seed", from: settings)
        #expect(model.current == .suspended)
        #expect(settings.reads == ["macscp-seed"])
        #expect(model.offeredStates == [.enabled])
    }

    @MainActor @Test func aRefusedReadSaysSoAndOffersNothing() async {
        let settings = FakeBucketSettings(readError: RemoteFSError.finding(.operationNotSupported))
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: settings)
        #expect(model.current == nil)
        #expect(model.offeredStates.isEmpty)
        #expect(model.load == .failed(RemoteFSFinding.operationNotSupported.message))
    }

    @MainActor @Test func enablingWritesOnceToTheNamedBucketAndShowsTheStoresAnswer() async {
        let settings = FakeBucketSettings(versioning: .never)
        let model = BucketVersioningModel(current: .never)
        await model.apply(.enabled, bucket: "macscp-second", via: settings)
        #expect(settings.writes == [FakeBucketSettings.Write(state: .enabled, bucket: "macscp-second")])
        #expect(model.current == .enabled)
        #expect(model.offeredStates == [.suspended])
        #expect(model.applyFailure == nil)
        #expect(!model.isApplying)
    }

    @MainActor @Test func suspendingWritesSuspended() async {
        let settings = FakeBucketSettings(versioning: .enabled)
        let model = BucketVersioningModel(current: .enabled)
        await model.apply(.suspended, bucket: "b", via: settings)
        #expect(settings.writes == [FakeBucketSettings.Write(state: .suspended, bucket: "b")])
        #expect(model.current == .suspended)
    }

    /// The model refuses a target it did not offer, before any request:
    /// `.never` cannot be written, and "suspend" on a never-versioned bucket is
    /// not on offer. The positive control is the offered write above.
    @MainActor @Test func aStateThatWasNotOfferedIsNeverSent() async {
        let settings = FakeBucketSettings(versioning: .never)
        let model = BucketVersioningModel(current: .never)
        await model.apply(.never, bucket: "b", via: settings)
        await model.apply(.suspended, bucket: "b", via: settings)
        #expect(settings.writes.isEmpty)
        #expect(model.current == .never)
    }

    @MainActor @Test func aRefusedWriteKeepsTheStateAndSaysWhy() async {
        let settings = FakeBucketSettings(
            versioning: .never, writeError: RemoteFSError.finding(.operationNotSupported))
        let model = BucketVersioningModel(current: .never)
        await model.apply(.enabled, bucket: "b", via: settings)
        #expect(settings.writes.count == 1)
        #expect(model.current == .never)
        #expect(model.applyFailure == RemoteFSFinding.operationNotSupported.message)
        #expect(!model.isApplying)
    }

    /// A raw `reason` can carry the endpoint the user typed, and that field
    /// takes `scheme://KEY:SECRET@host` as ordinary input. The message is a
    /// fixed sentence, so nothing of the error reaches the screen.
    ///
    /// The value is a named constant and the `Bool` is computed before the
    /// expectation, so a failure cannot print it (CLAUDE.md, "A value a test
    /// must not leak has two exits, not one").
    @MainActor @Test func aFailureNeverQuotesTheReasonItWasGiven() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            versioning: .never, writeError: RemoteFSError.protocolError(reason: planted))
        let model = BucketVersioningModel(current: .never)
        await model.apply(.enabled, bucket: "b", via: settings)
        let text = model.applyFailure ?? ""
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(!text.isEmpty)
        #expect(!quoted)
    }

    @MainActor @Test func aMissingPermissionHasItsOwnSentence() {
        let denied = BucketVersioningModel.message(
            for: RemoteFSError.permissionDenied(path: "/b"), applying: true)
        let generic = BucketVersioningModel.message(
            for: CocoaError(.fileReadUnknown), applying: true)
        #expect(!denied.isEmpty)
        #expect(!generic.isEmpty)
        #expect(denied != generic)
    }

    // MARK: - The catalogue

    /// Every line the sheet can show resolves in every shipped language: a key
    /// missing from one catalogue silently shows the English default there.
    /// The sentinel is absurd on purpose, so a hit can only be a real entry.
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

    /// The English default a line carries must be what the `en` catalogue
    /// says: a second copy of a string that disagrees with the first is how the
    /// English UI drifts from its default.
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

    /// The two warnings are the sheet's reason for existing, so they are held
    /// to more than "present": in every language they are not the same
    /// sentence, and the German one is not the English one.
    @MainActor @Test func theTwoWarningsAreDistinctInEveryLanguage() throws {
        let enable = try #require(BucketVersioningModel(current: .never).warning)
        let suspend = try #require(BucketVersioningModel(current: .enabled).warning)
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) { (enable.text, suspend.text) }
            #expect(texts.0 != texts.1, "\(locale)")
        }
        let inGerman = L10n.$localeOverride.withValue("de") { suspend.text }
        let inEnglish = L10n.$localeOverride.withValue("en") { suspend.text }
        #expect(inGerman != inEnglish)
    }

    /// The sheet's source is read for the keys it uses, so a key used in the
    /// view and absent from `everyLine()` (and therefore from the checks above)
    /// is a red here. The comment-free view keeps the string literals; the
    /// positive half is that the scan found some.
    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/BucketVersioningSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(
            source.matches(of: #/"(s3\.versioning\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let uncovered = used.subtracting(Set(Self.everyLine().map(\.key))).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// Every line the sheet can show, for every state it can be in.
    @MainActor private static func everyLine() -> [CatalogueLine] {
        var lines = BucketVersioningModel.fixedLines
        for state in BucketVersioning.allCases {
            lines += BucketVersioningModel(current: state).lines
        }
        return lines
    }
}
