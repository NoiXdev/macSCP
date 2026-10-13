import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The folder overview's words (diff view, Task 10): what each state is
/// called, why each undetermined row is undetermined, how many rows sit in
/// each state, and what a failed comparison says failed.
///
/// Everything here is a pure function of a value, tested without a view. The
/// one rule the file exists for: an `undetermined` row never renders as
/// `same`. It is asserted on the LABELS and on the CATALOGUE KEYS, each with
/// a positive check that the text resolved to something — so the test cannot
/// pass because a lookup returned a key name or an empty string, and cannot
/// pass because two keys both fell back to the same blank.
///
/// **Language.** `swift test` runs in whatever language the machine is set
/// to, so no assertion here compares a label with an English sentence.
/// "Resolved" means: equal to what the catalogue bundle itself answers for
/// the key in the active language, and different from the sentinel it answers
/// with for a key it does not hold. The English source text is held against
/// `en.lproj` separately, by reading the file.
///
/// No test asserts how long anything took.
@Suite("Comparison overview", .timeLimit(.minutes(1)))
@MainActor
struct ComparisonOverviewTests {
    private typealias Presentation = ComparisonOverviewPresentation

    // MARK: - Fixtures

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let appKit = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
    private static let core = repoRoot.appendingPathComponent("Sources/macSCPCore")
    private static let locales = ["en", "de", "fr", "pl"]

    private static func catalogue(_ locale: String) throws -> [String: String] {
        let url = appKit.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private static let missing = "ZZ-NOT-IN-THE-CATALOGUE-ZZ"

    /// What the catalogue bundle answers for `key` in the active language,
    /// or `nil` when it holds nothing. Independent of `L10n.string`.
    private static func resolved(_ key: String) -> String? {
        let answer = L10n.bundle.localizedString(forKey: key, value: missing, table: nil)
        return answer == missing ? nil : answer
    }

    /// Every `UndeterminedReason`, written out. `expectedReasonKey(_:)` below
    /// is an exhaustive switch in THIS file, so a case added in Core fails to
    /// compile here until someone has decided what it is called;
    /// `theReasonListNamesEveryCaseTheEnumDeclares` then holds this list to
    /// the enum as it is on disk.
    private static let allReasons: [UndeterminedReason] = [
        .checksumUnavailable, .algorithmUnavailable(.sha256), .algorithmsDiffer,
        .etagIsNotAFileHash, .unsupportedKind, .unreadable,
    ]

    /// The states a row can carry. NOT `.bothDirectories`; see its own tests.
    private static let rowStates: [ComparisonState] =
        [.onlyLeft, .onlyRight, .same, .differs, .typeMismatch]
        + allReasons.map { ComparisonState.undetermined($0) }

    /// The key each state is expected to be spelled by. Exhaustive, no
    /// `default:`.
    nonisolated private static func expectedStateKey(_ state: ComparisonState) -> String? {
        switch state {
        case .onlyLeft: "compare.state.onlyLeft"
        case .onlyRight: "compare.state.onlyRight"
        case .same: "compare.state.same"
        case .differs: "compare.state.differs"
        case .typeMismatch: "compare.state.typeMismatch"
        case .undetermined: "compare.state.undetermined"
        case .bothDirectories: nil
        }
    }

    nonisolated private static func expectedReasonKey(_ reason: UndeterminedReason) -> String {
        switch reason {
        case .checksumUnavailable: "compare.reason.checksumUnavailable"
        case .algorithmUnavailable: "compare.reason.algorithmUnavailable %@"
        case .algorithmsDiffer: "compare.reason.algorithmsDiffer"
        case .etagIsNotAFileHash: "compare.reason.etagIsNotAFileHash"
        case .unsupportedKind: "compare.reason.unsupportedKind"
        case .unreadable: "compare.reason.unreadable"
        }
    }

    // MARK: - The one rule

    @Test func anUndeterminedRowNeverCarriesTheSameLabelOrTheSameKey() throws {
        let sameKey = try #require(Presentation.key(for: .same))
        let sameLabel = Presentation.label(for: .same)
        // Positive half: the `same` side resolves to text in its own right.
        #expect(Self.resolved(sameKey) != nil)
        #expect(!sameLabel.isEmpty)
        #expect(sameLabel != sameKey)

        for reason in Self.allReasons {
            let state = ComparisonState.undetermined(reason)
            let key = try #require(Presentation.key(for: state))
            let label = Presentation.label(for: state)

            #expect(Self.resolved(key) != nil, "\(key) is not in the catalogue")
            #expect(!label.isEmpty)
            #expect(label != key, "the label is the key name: the lookup fell back")
            #expect(label == Self.resolved(key))

            #expect(key != sameKey)
            #expect(label != sameLabel)
        }
    }

    @Test func noTwoStateKindsShareAKeyOrAText() throws {
        // One representative per kind: the six `undetermined` rows share a
        // state, and tell their reasons apart elsewhere.
        let kinds: [ComparisonState] =
            [.onlyLeft, .onlyRight, .same, .differs, .typeMismatch, .undetermined(.unreadable)]
        let keys = try kinds.map { try #require(Presentation.key(for: $0)) }
        let labels = kinds.map { Presentation.label(for: $0) }

        #expect(keys.count == 6)
        #expect(Set(keys).count == keys.count, "two states share a catalogue key")
        #expect(Set(labels).count == labels.count, "two states share a label")
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func everyRowStateIsSpelledByItsExpectedKeyAndResolves() throws {
        // A negative-looking check ("nobody falls back") needs the positive
        // one beside it: the list it walks is not empty and names every kind.
        #expect(Self.rowStates.count == 5 + Self.allReasons.count)
        for state in Self.rowStates {
            let key = try #require(Presentation.key(for: state))
            #expect(key == Self.expectedStateKey(state))
            #expect(Self.resolved(key) != nil, "\(key) is not in the catalogue")
            #expect(Presentation.label(for: state) == Self.resolved(key))
        }
    }

    /// The fallback the catalogue lookup lands on when a key is missing is
    /// the English sentence, never the key's own name. The keys the shipped
    /// catalogues hold never reach it, so it is driven with one they do not.
    @Test func aKeyTheCatalogueDoesNotHoldFallsBackToEnglishNotToItsOwnName() {
        let absent = Presentation.Wording(
            key: "compare.test.thisKeyIsInNoCatalogue", english: "The English sentence")
        #expect(Self.resolved(absent.key) == nil)
        #expect(absent.text == "The English sentence")
        #expect(absent.text != absent.key)
    }

    // MARK: - bothDirectories

    @Test func bothDirectoriesHasNoKeyAndNoCatalogueEntry() throws {
        #expect(Presentation.key(for: .bothDirectories) == nil)
        #expect(Presentation.label(for: .bothDirectories) == Presentation.unexpectedLabel)

        // The marker is not a word any real state is called.
        for state in Self.rowStates {
            #expect(Presentation.label(for: state) != Presentation.unexpectedLabel)
        }
        // Positive half: the five real state keys ARE in the English
        // catalogue, so a scan that finds nothing for `bothDirectories` is
        // reading a catalogue that holds the others.
        let english = try Self.catalogue("en")
        for state in Self.rowStates {
            #expect(english[try #require(Presentation.key(for: state))] != nil)
        }
        #expect(!english.keys.contains { $0.lowercased().contains("bothdirectories") })
        #expect(!english.values.contains(Presentation.unexpectedLabel))
    }

    // MARK: - Reasons

    @Test func everyReasonHasItsOwnKeyAndTextAndNoReasonSharesOne() throws {
        #expect(Self.allReasons.count == 6)
        var keys: [String] = []
        var texts: [String] = []
        for reason in Self.allReasons {
            let key = Presentation.key(for: reason)
            let text = Presentation.text(for: reason)
            #expect(key == Self.expectedReasonKey(reason))
            #expect(Self.resolved(key) != nil, "\(key) is not in the catalogue")
            #expect(!text.isEmpty)
            #expect(text != key)
            #expect(!text.contains("%@"), "the placeholder was not filled")
            keys.append(key)
            texts.append(text)
        }
        #expect(Set(keys).count == keys.count, "two reasons share a key")
        #expect(Set(texts).count == texts.count, "two reasons share a text")
    }

    @Test func aReasonIsRenderedWithItsOwnPayloadNotAnotherCasesText() {
        // The algorithm named is the one the reason carries.
        let sha = Presentation.text(for: .algorithmUnavailable(.sha256))
        let md5 = Presentation.text(for: .algorithmUnavailable(.md5))
        #expect(sha.contains(ChecksumAlgorithm.sha256.displayName))
        #expect(md5.contains(ChecksumAlgorithm.md5.displayName))
        #expect(!sha.contains(ChecksumAlgorithm.md5.displayName))
        #expect(sha != md5)
        // Rendering one reason as another is the defect: each text is also
        // different from every other reason's.
        #expect(sha != Presentation.text(for: .algorithmsDiffer))
        #expect(sha != Presentation.text(for: .checksumUnavailable))
    }

    /// `.unreadable` is the one reason that is not about comparing, and its
    /// English says what could not be read. Held against the English file,
    /// since the other three languages are not this test's to parse.
    @Test func unreadableSaysItCouldNotReadAndTheOthersSayNotCompared() throws {
        let english = try Self.catalogue("en")
        let unreadable = try #require(english[Presentation.key(for: .unreadable)])
        #expect(unreadable.lowercased().contains("could not read"))
        #expect(!unreadable.hasPrefix("Not compared"))

        let comparing: [UndeterminedReason] = [
            .checksumUnavailable, .algorithmUnavailable(.sha256), .algorithmsDiffer,
            .etagIsNotAFileHash, .unsupportedKind,
        ]
        for reason in comparing {
            let text = try #require(english[Presentation.key(for: reason)])
            #expect(text.hasPrefix("Not compared"), "\(text)")
        }
    }

    @Test func theReasonListNamesEveryCaseTheEnumDeclares() throws {
        let code = try SourceCorpus.code(
            of: Self.core.appendingPathComponent("Compare/ComparisonState.swift"))
        let start = try #require(code.range(of: "enum UndeterminedReason"))
        let end = try #require(code.range(of: "enum ComparisonState"))
        let body = String(code[start.upperBound..<end.lowerBound])
        let declared = body.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ")
        }
        // Positive half first: the scan found the enum at all.
        #expect(!declared.isEmpty)
        #expect(declared.count == Self.allReasons.count, "\(declared)")
    }

    // MARK: - Counts

    private static func rows(_ states: [ComparisonState]) -> [ComparisonRow] {
        states.enumerated().map { ComparisonRow(relativePath: "p\($0.offset)", state: $0.element) }
    }

    @Test func countsPinEachState() {
        let counts = Presentation.counts(
            of: Self.rows([
                .onlyLeft, .onlyLeft, .onlyRight, .same, .same, .same, .differs,
                .typeMismatch, .typeMismatch,
                .undetermined(.checksumUnavailable), .undetermined(.unreadable),
                .undetermined(.unreadable), .undetermined(.etagIsNotAFileHash),
            ]))

        #expect(counts.onlyLeft == 2)
        #expect(counts.onlyRight == 1)
        #expect(counts.same == 3)
        #expect(counts.differs == 1)
        #expect(counts.typeMismatch == 2)
        #expect(counts.undetermined == 4)
        #expect(counts.unexpected == 0)
        #expect(counts.total == 13)
    }

    /// The bug the rule is about, at the counting layer: undetermined rows
    /// are not `same` rows, however many there are.
    @Test func undeterminedRowsAreNeverCountedAsSame() {
        let counts = Presentation.counts(
            of: Self.rows(Self.allReasons.map { ComparisonState.undetermined($0) }))

        #expect(counts.undetermined == Self.allReasons.count)
        #expect(counts.same == 0)
        #expect(counts.differs == 0)
        #expect(counts.total == Self.allReasons.count)
    }

    @Test func countsDropNoRowAndASurprisingStateIsCountedAsSurprising() {
        let states: [ComparisonState] = [.same, .bothDirectories, .differs, .bothDirectories]
        let counts = Presentation.counts(of: Self.rows(states))

        #expect(counts.unexpected == 2)
        #expect(counts.same == 1)
        #expect(counts.differs == 1)
        // Every row lands in exactly one bucket.
        #expect(counts.total == states.count)
        let buckets: [Int] = [
            counts.onlyLeft, counts.onlyRight, counts.same, counts.differs,
            counts.typeMismatch, counts.undetermined, counts.unexpected,
        ]
        #expect(buckets.reduce(0, +) == states.count)
    }

    @Test func noRowsCountsNothing() {
        let counts = Presentation.counts(of: [])
        #expect(counts.total == 0)
        #expect(counts == Presentation.Counts())
    }

    /// `counts(of:)` is built on `count(for:)`, which the view reads per
    /// state; the two agree for every state a row can carry.
    @Test func theCountForAStateIsTheCountOfItsBucket() {
        let counts = Presentation.counts(
            of: Self.rows([.onlyLeft, .same, .same, .undetermined(.unreadable)]))

        #expect(counts.count(for: .onlyLeft) == 1)
        #expect(counts.count(for: .same) == 2)
        #expect(counts.count(for: .undetermined(.algorithmsDiffer)) == 1)
        #expect(counts.count(for: .differs) == 0)
        #expect(counts.count(for: .bothDirectories) == counts.unexpected)
    }

    // MARK: - Progress

    @Test func progressNamesTheNumberItWasGiven() {
        let text = Presentation.progressText(
            ComparisonProgress(directoriesVisited: 3, rowsProduced: 4_127))
        #expect(!text.isEmpty)
        #expect(text.contains("4127") || text.contains("4,127") || text.contains("4.127"))
        #expect(!text.contains("%"))
    }

    // MARK: - The catalogues

    /// Every key the presentation spells, derived from the presentation
    /// itself: nothing here is a list of keys written down a second time.
    private static var usedKeys: [String] {
        let stateKeys = rowStates.compactMap { Presentation.key(for: $0) }
        let reasonKeys = allReasons.map { Presentation.key(for: $0) }
        return Array(Set(stateKeys + reasonKeys + Presentation.otherKeys)).sorted()
    }

    @Test func everyKeyIsInAllFourCataloguesAndTranslated() throws {
        #expect(Self.usedKeys.count >= 6 + 6 + 3)
        let english = try Self.catalogue("en")
        for locale in Self.locales {
            let catalogue = try Self.catalogue(locale)
            for key in Self.usedKeys {
                let value = try #require(catalogue[key], "\(locale) lacks \(key)")
                #expect(!value.isEmpty, "\(locale) \(key) is empty")
                if locale != "en" {
                    #expect(value != english[key], "\(locale) \(key) is the English text")
                }
                // The same placeholders, so a format string cannot lose one.
                #expect(
                    Self.placeholders(in: value) == Self.placeholders(in: try #require(english[key])),
                    "\(locale) \(key) changes its placeholders")
            }
        }
    }

    @Test func theEnglishDefaultsTheCodeCarriesAreTheEnglishCatalogue() throws {
        let english = try Self.catalogue("en")
        let stateWordings: [Presentation.Wording] = Self.rowStates.compactMap {
            (state: ComparisonState) in Presentation.wording(for: state)
        }
        let reasonWordings: [Presentation.Wording] = Self.allReasons.map {
            (reason: UndeterminedReason) in Presentation.wording(for: reason)
        }
        let wordings = stateWordings + reasonWordings + Presentation.otherWordings
        #expect(wordings.count >= 6 + 6 + 3)
        for wording in wordings {
            #expect(english[wording.key] == wording.english, "\(wording.key)")
        }
    }

    private static func placeholders(in value: String) -> [String] {
        value.components(separatedBy: "%").dropFirst().compactMap { piece in
            if piece.hasPrefix("@") { return "%@" }
            if piece.hasPrefix("lld") { return "%lld" }
            return piece.isEmpty ? nil : "%?"
        }
    }

    // MARK: - A failed comparison says what failed

    @Test func everyKindOfFailureReachesANonEmptyCauseWithNoPlaceholderLeft() {
        for name in TransferFailureKind.Name.allCases {
            let kind = TransferFailureLabelGuardTests.sample(name)
            let cause = Presentation.failureCause(of: kind)
            #expect(!cause.isEmpty, "\(name)")
            #expect(!cause.contains("%@"), "\(name): \(cause)")
        }
    }

    @Test func aMissingFolderIsAFolderNotAFile() {
        let cause = Presentation.failureCause(for: RemoteFSError.notFound(path: "/srv/gone"))
        #expect(cause.contains("/srv/gone"))
        #expect(cause == Presentation.failureCause(of: .notFound(path: "/srv/gone")))
        // Core's sentence for the same kind says "File not found".
        #expect(cause != TransferFailureKind.notFound(path: "/srv/gone").message)
    }

    @Test func aFailureCarriesItsReportedDetailUnderTheComparisonsOwnFrame() {
        let cause = Presentation.failureCause(
            for: RemoteFSError.protocolError(reason: "the server answered with garbage"))
        #expect(cause.contains("the server answered with garbage"))
        // Not the transfer frame: nothing was being transferred.
        let transfer = TransferFailureKind.protocolError(detail: "x").message
        let transferFrame = transfer.replacingOccurrences(of: "x", with: "")
        #expect(!cause.hasPrefix(transferFrame))
        #expect(
            cause != TransferFailureKind.protocolError(detail: "the server answered with garbage").message)
    }

    @Test func aForeignErrorIsShownAsItsSentenceNotAsADescription() {
        struct Foreign: LocalizedError {
            var errorDescription: String? { "the disk said no" }
        }
        let cause = Presentation.failureCause(for: Foreign())
        #expect(cause.contains("the disk said no"))
        #expect(!cause.contains("Foreign"), "the type name leaked: \(cause)")
        #expect(!cause.contains("error 1"), "Foundation's default sentence leaked: \(cause)")
    }

    @Test func aFailureWithNoDetailSaysSoInsteadOfPrintingAnEmptyFrame() {
        let empty = Presentation.failureCause(for: RemoteFSError.protocolError(reason: ""))
        #expect(!empty.isEmpty)
        #expect(!empty.hasSuffix(": "))
        #expect(!empty.hasSuffix(":"))
        // Positive half: with a detail the same path DOES carry it.
        let withDetail = Presentation.failureCause(for: RemoteFSError.protocolError(reason: "because"))
        #expect(withDetail.contains("because"))
        #expect(empty != withDetail)
    }

    @Test func aStrayCancellationIsNamedAsOneNobodyAskedFor() {
        let cause = Presentation.failureCause(for: CancellationError())
        #expect(!cause.isEmpty)
        #expect(cause == Self.resolved("compare.failure.interrupted"))
        #expect(!cause.contains("CancellationError"))
        #expect(!cause.contains("Swift."))
    }

    @Test func aCredentialInAnEndpointNeverReachesTheCause() {
        let cause = Presentation.failureCause(
            for: RemoteFSError.connectionFailed(reason: "could not reach https://KEYID:HUNTER2@host.example/x"))
        #expect(cause.contains("host.example"))
        #expect(!cause.contains("HUNTER2"))
        #expect(!cause.contains("KEYID"))
    }

    @Test func aFindingThatIsNotAConnectionFailureCarriesItsOwnSentence() {
        let cause = Presentation.failureCause(for: RemoteFSError.finding(.outOfStorage))
        #expect(cause.contains(RemoteFSFinding.outOfStorage.message))
    }

    // MARK: - Wiring

    private static func code(_ file: String) throws -> String {
        try SourceCorpus.code(of: appKit.appendingPathComponent(file))
    }

    /// The overview spells no `default:` arm. A negative check, so the
    /// positive one beside it: the file does switch over the state and does
    /// name `bothDirectories` explicitly.
    @Test func theOverviewSwitchesNameEveryCaseAndNoneFallsThroughADefault() throws {
        let code = try Self.code("ComparisonOverview.swift")
        #expect(code.contains("switch state"))
        #expect(code.contains("switch reason"))
        #expect(code.contains("case .bothDirectories"))
        #expect(code.contains("case .undetermined"))
        #expect(!code.contains("default:"))
    }

    @Test func theViewReadsItsWordsAndCountsFromThePresentation() throws {
        let code = try Self.code("ComparisonOverview.swift")
        #expect(code.contains("struct ComparisonOverviewView"))
        #expect(code.contains("ComparisonOverviewPresentation.label(for:"))
        #expect(code.contains("ComparisonOverviewPresentation.text(for:"))
        #expect(code.contains("ComparisonOverviewPresentation.counts(of:"))
    }

    @Test func theWindowShowsTheOverviewAndTheFailureCause() throws {
        let window = try Self.code("ComparisonWindow.swift")
        #expect(window.contains("ComparisonOverviewView("))
        #expect(window.contains("ComparisonOverviewPresentation.failureCause(for:"))
        // The generic notice used to be the whole message; a raw rendering of
        // the error is not what replaces it.
        #expect(!window.contains("localizedDescription"))
        #expect(!window.contains("String(describing:"))
    }
}
