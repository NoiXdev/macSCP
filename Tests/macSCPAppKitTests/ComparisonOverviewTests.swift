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

    /// `.other` is also what a listing answers when a type was NOT REPORTED,
    /// so an ordinary file can carry `unsupportedKind`. The text may not say
    /// the entry IS a link or a special entry, and keeps the third branch.
    @Test func unsupportedKindDoesNotClaimTheEntryIsALinkAndKeepsTheUnreportedBranch() throws {
        let english = try Self.catalogue("en")
        let text = try #require(english[Presentation.key(for: .unsupportedKind)])
        #expect(text.contains("could not tell"))
        #expect(text.contains("its type was not reported"))
        #expect(text.contains("a link"))
        #expect(!text.contains("this is a link"))
    }

    /// The third branch of `unsupportedKind` ("or its type was not reported"),
    /// and the "at least one side" of the two reasons that say it, in EACH
    /// catalogue's own words. A branch deleted from one translation must not
    /// hide behind the English one being intact.
    private static let ownWords: [String: (unreported: String, atLeastOne: String)] = [
        "en": ("its type was not reported", "at least one side"),
        "de": ("sein Typ wurde nicht gemeldet", "Mindestens eine Seite"),
        "fr": ("son type n’a pas été signalé", "au moins un côté"),
        "pl": ("jego typ nie został zgłoszony", "co najmniej jedna strona"),
    ]

    @Test func everyCatalogueCarriesTheUnreportedTypeBranchAndTheAtLeastOneSide() throws {
        #expect(Set(Self.ownWords.keys) == Set(Self.locales))
        for locale in Self.locales {
            let words = try #require(Self.ownWords[locale])
            let catalogue = try Self.catalogue(locale)
            let unsupported = try #require(catalogue[Presentation.key(for: .unsupportedKind)])
            let etag = try #require(catalogue[Presentation.key(for: .etagIsNotAFileHash)])
            let checksum = try #require(catalogue[Presentation.key(for: .checksumUnavailable)])
            #expect(unsupported.contains(words.unreported), "\(locale): \(unsupported)")
            #expect(etag.localizedCaseInsensitiveContains(words.atLeastOne), "\(locale): \(etag)")
            #expect(
                checksum.localizedCaseInsensitiveContains(words.atLeastOne), "\(locale): \(checksum)")
        }
    }

    /// Both sides of an S3-to-S3 pair can be multipart.
    @Test func theEtagReasonSaysAtLeastOneSide() throws {
        let english = try Self.catalogue("en")
        let text = try #require(english[Presentation.key(for: .etagIsNotAFileHash)])
        #expect(text.contains("at least one side"))
        let checksum = try #require(english[Presentation.key(for: .checksumUnavailable)])
        #expect(checksum.contains("at least one side"))
    }

    @Test func theReasonListNamesEveryCaseTheEnumDeclares() throws {
        let code = try SourceCorpus.code(
            of: Self.core.appendingPathComponent("Compare/ComparisonState.swift"))
        let start = try #require(code.range(of: "enum UndeterminedReason"))
        let end = try #require(code.range(of: "enum ComparisonState"))
        let body = String(code[start.upperBound..<end.lowerBound])
        let declared = Self.caseNames(inEnumBody: body)
        // Positive half first: the scan found the enum at all.
        #expect(!declared.isEmpty)
        #expect(declared.count == Self.allReasons.count, "\(declared)")
    }

    /// The reader counts CASES, not lines: `case a, b` is two, and a comma
    /// inside an associated value's parentheses separates nothing.
    @Test func theCaseReaderCountsCasesNotLines() {
        #expect(Self.caseNames(inEnumBody: "case a\ncase b(X)\n").count == 2)
        #expect(Self.caseNames(inEnumBody: "case a, b\ncase c\n").count == 3)
        #expect(Self.caseNames(inEnumBody: "case a(X, Y), b\n").count == 2)
        #expect(Self.caseNames(inEnumBody: "var x: Int { 1 }\n").isEmpty)
    }

    private static func caseNames(inEnumBody body: String) -> [String] {
        var names: [String] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            var depth = 0
            var current = ""
            for character in trimmed.dropFirst("case ".count) {
                switch character {
                case "(": depth += 1; current.append(character)
                case ")": depth -= 1; current.append(character)
                case "," where depth == 0:
                    names.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                default: current.append(character)
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                names.append(current.trimmingCharacters(in: .whitespaces))
            }
        }
        return names
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
        let text = Presentation.progressText(entriesFound: 4_127)
        #expect(!text.isEmpty)
        #expect(text.contains("4127") || text.contains("4,127") || text.contains("4.127"))
        #expect(!text.contains("%"))
    }

    // MARK: - What is drawn at all

    @Test func aFolderComparisonShowsTheOverviewAndAFilePairDoesNot() {
        #expect(Presentation.showsOverview(for: .folders))
        #expect(!Presentation.showsOverview(for: .filePair))
    }

    /// The most dangerous sentence on this surface is "found no files and no
    /// differences": it is a RESULT. It may appear for a walk that ended
    /// normally with no row and for nothing else — each other outcome gets a
    /// negative check, and the positive one is beside them.
    @Test func theEmptyNoticeIsShownOnlyForACompletedWalkWithNoRows() {
        let failure = Comparison.Outcome.failed(CancellationError())
        // Positive: the one case that shows it.
        #expect(Presentation.showsEmptyNotice(rowCount: 0, outcome: .completed))
        // Still running (no outcome yet), stopped, failed: the list is empty
        // because it is incomplete.
        #expect(!Presentation.showsEmptyNotice(rowCount: 0, outcome: nil))
        #expect(!Presentation.showsEmptyNotice(rowCount: 0, outcome: .cancelled))
        #expect(!Presentation.showsEmptyNotice(rowCount: 0, outcome: failure))
        // A completed walk that produced rows has something to show instead.
        #expect(!Presentation.showsEmptyNotice(rowCount: 1, outcome: .completed))
    }

    /// A row is labelled with ITS OWN state, for every state a row can carry.
    @Test func aRowIsLabelledWithItsOwnStateAndNoOtherRowSharesItsLabel() {
        var labels: [String] = []
        for state in Self.rowStates {
            let row = ComparisonRow(relativePath: "p", state: state)
            #expect(Presentation.label(forRow: row) == Presentation.label(for: state))
            if case .undetermined = state { continue }
            labels.append(Presentation.label(forRow: row))
        }
        #expect(labels.count == 5)
        #expect(Set(labels).count == labels.count)
        let sameRow = ComparisonRow(relativePath: "p", state: .same)
        let undeterminedRow = ComparisonRow(relativePath: "p", state: .undetermined(.unreadable))
        #expect(Presentation.label(forRow: undeterminedRow) != Presentation.label(forRow: sameRow))
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

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The overview file split at its three views: the list-and-summary view,
    /// the figure and the row. Everything above them is the presentation.
    private static func viewCode() throws -> (view: String, figure: String, row: String) {
        let source = try Self.code("ComparisonOverview.swift")
        let viewStart = try #require(source.range(of: "struct ComparisonOverviewView"))
        let figureStart = try #require(source.range(of: "struct ComparisonOverviewFigure"))
        let rowStart = try #require(source.range(of: "struct ComparisonOverviewRow"))
        #expect(viewStart.lowerBound < figureStart.lowerBound)
        #expect(figureStart.lowerBound < rowStart.lowerBound)
        return (
            String(source[viewStart.lowerBound..<figureStart.lowerBound]),
            String(source[figureStart.lowerBound..<rowStart.lowerBound]),
            String(source[rowStart.lowerBound...])
        )
    }

    // MARK: - What the view maps over

    /// The list as the view gets it with nothing under way and a live session.
    private static func entries(
        _ rows: [ComparisonRow], settle: Presentation.SettleTracker = .init(),
        canFetch: Bool = true
    ) -> [Presentation.RowEntry] {
        Presentation.rowEntries(rows, settle: settle, canFetch: canFetch)
    }

    private static let mixedRows: [ComparisonRow] = rows([
        .onlyLeft, .onlyRight, .same, .same, .differs, .typeMismatch,
        .undetermined(.checksumUnavailable), .undetermined(.unreadable),
        .undetermined(.algorithmUnavailable(.md5)), .same, .onlyLeft,
    ])

    /// The property "the figures account for every row", stated once: what the
    /// view draws is this list, so it holds here and nowhere else.
    @Test func theFiguresAccountForEveryRow() throws {
        for fixture in [Self.mixedRows, [], Self.rows([.undetermined(.unreadable)])] {
            let counts = Presentation.counts(of: fixture)
            let figures = Presentation.summaryFigures(counts)

            #expect(figures.map(\.number).reduce(0, +) == counts.total)
            #expect(counts.total == fixture.count)
            // Each figure's number is its own bucket and its label its own
            // state's.
            for figure in figures {
                #expect(figure.number == counts.count(for: figure.state))
                #expect(figure.label == Presentation.label(for: figure.state))
            }
        }
    }

    @Test func everyStateAppearsOnceAndTheUnexpectedFigureOnlyWhenSomethingIsInIt() throws {
        let expectedKeys = Set(
            try [ComparisonState.onlyLeft, .onlyRight, .same, .differs, .typeMismatch,
                 .undetermined(.unreadable)]
            .map { try #require(Presentation.key(for: $0)) })
        #expect(expectedKeys.count == 6)

        let figures = Presentation.summaryFigures(Presentation.counts(of: Self.mixedRows))
        #expect(figures.count == 6)
        #expect(Set(figures.map(\.id)) == expectedKeys)
        #expect(Set(figures.map(\.label)).count == 6)
        #expect(!figures.contains { $0.state == .bothDirectories })

        // With a surprising row: a seventh figure, last, counting it.
        let surprising = Presentation.summaryFigures(
            Presentation.counts(of: Self.mixedRows + Self.rows([.bothDirectories, .bothDirectories])))
        #expect(surprising.count == 7)
        #expect(surprising.last?.state == .bothDirectories)
        #expect(surprising.last?.number == 2)
        #expect(Set(surprising.map(\.id)).count == 7)
        #expect(surprising.map(\.number).reduce(0, +) == Self.mixedRows.count + 2)
    }

    @Test func theListHoldsEveryRowInOrderEachWithItsOwnLabel() throws {
        let entries = Self.entries(Self.mixedRows)

        // Same rows, same order: none hidden, none added.
        #expect(entries.count == Self.mixedRows.count)
        #expect(entries.map(\.path) == Self.mixedRows.map(\.relativePath))

        for (row, entry) in zip(Self.mixedRows, entries) {
            #expect(entry.label == Presentation.label(for: row.state))
            #expect(entry.isMatch == (row.state == .same))
            if case .undetermined(let reason) = row.state {
                #expect(entry.reason == Presentation.text(for: reason))
            } else {
                #expect(entry.reason == nil)
            }
        }
    }

    /// The sentence the whole subsystem exists to keep off rows nothing
    /// measured: a row that is not `same` never carries the `same` label, and
    /// an undetermined one always carries a reason beside its own label.
    @Test func noRowButASameRowReadsAsSameAndEveryUndeterminedRowSaysWhy() throws {
        let entries = Self.entries(Self.mixedRows)
        let sameLabel = Presentation.label(for: .same)
        #expect(entries.filter { $0.label == sameLabel }.count == 3)
        #expect(entries.filter { $0.isMatch }.count == 3)
        for (row, entry) in zip(Self.mixedRows, entries) where row.state != .same {
            #expect(entry.label != sameLabel, "\(row.relativePath)")
        }
        let undetermined = entries.filter { $0.reason != nil }
        #expect(undetermined.count == 3)
        #expect(undetermined.allSatisfy { $0.label == Presentation.label(for: .undetermined(.unreadable)) })
        #expect(Set(undetermined.compactMap(\.reason)).count == 3)
    }

    // MARK: - Compare anyway: who is offered it

    /// Every reason there is, read from the enum: `allReasons` is held to the
    /// enum's declared cases by `theReasonListNamesEveryCaseTheEnumDeclares`.
    /// The line is `canBeSettledByBytes`, which is not re-decided here; the
    /// positive and the negative examples sit beside the loop so that a loop
    /// over a list that matched nothing could not pass.
    @Test func aSettleableReasonOffersTheActionAndAnUnsettleableOneDoesNot() throws {
        var offered: [UndeterminedReason] = []
        var withheld: [UndeterminedReason] = []
        for reason in Self.allReasons {
            let entry = Self.entries([ComparisonRow(relativePath: "p", state: .undetermined(reason))])[0]
            #expect((entry.settleButton != nil) == reason.canBeSettledByBytes, "\(reason)")
            if entry.settleButton != nil { offered.append(reason) } else { withheld.append(reason) }
            // A row that cannot be settled still says why.
            #expect(entry.reason == Presentation.text(for: reason))
        }
        #expect(offered.count == 4)
        #expect(withheld == [.unsupportedKind, .unreadable])
    }

    @Test func theButtonCarriesTheActionsOwnTitleAndIsEnabledUnlessThatRowIsPending() throws {
        let rows = [
            ComparisonRow(relativePath: "a", state: .undetermined(.checksumUnavailable)),
            ComparisonRow(relativePath: "b", state: .undetermined(.checksumUnavailable)),
        ]
        var tracker = Presentation.SettleTracker()
        tracker.begin("b")
        let entries = Self.entries(rows, settle: tracker)

        #expect(entries[0].settleButton == .init(title: Presentation.compareAnyway.text, isEnabled: true))
        #expect(entries[1].settleButton == .init(title: Presentation.compareAnyway.text, isEnabled: false))
        #expect(!Presentation.compareAnyway.text.isEmpty)
        // Pending is said on the pending row only.
        #expect(entries[0].settleNote == nil)
        #expect(entries[1].settleNote == Presentation.settlePending.text)
    }

    @Test func noOtherStateOffersTheActionOrCarriesANoteAndNoSessionMeansNoButton() throws {
        let others: [ComparisonState] = [.onlyLeft, .onlyRight, .same, .differs, .typeMismatch]
        var tracker = Presentation.SettleTracker()
        tracker.begin("p")
        tracker.fail("p", text: "stale failure")
        for state in others {
            let entry = Self.entries([ComparisonRow(relativePath: "p", state: state)], settle: tracker)[0]
            #expect(entry.settleButton == nil, "\(state)")
            #expect(entry.settleNote == nil, "\(state)")
        }
        // Positive: the same tracker DOES put its note on an undetermined row.
        let undetermined = ComparisonRow(relativePath: "p", state: .undetermined(.checksumUnavailable))
        #expect(Self.entries([undetermined], settle: tracker)[0].settleNote == "stale failure")
        // A released session offers nothing to fetch with.
        #expect(Self.entries([undetermined], canFetch: false)[0].settleButton == nil)
        #expect(Self.entries([undetermined], canFetch: true)[0].settleButton != nil)
    }

    @Test func theIndexIsTheRowsPositionInTheComparison() {
        let entries = Self.entries(Self.mixedRows)
        #expect(entries.map(\.index) == Array(Self.mixedRows.indices))
    }

    // MARK: - Compare anyway: doing it

    @MainActor private struct SettleRig {
        let comparison: Comparison
        let left: MemoryFS
        let model: ComparisonSettleModel
        let root: URL

        func entries() -> [Presentation.RowEntry] {
            Presentation.rowEntries(
                comparison.rows, settle: model.tracker,
                canFetch: Presentation.canFetch(comparison))
        }
    }

    /// Two files per side, equal sizes and a connection that cannot hash, so
    /// the walk leaves two `undetermined(checksumUnavailable)` rows: `a`
    /// differs by one byte, `b` is identical.
    private func makeSettleRig() async throws -> SettleRig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonOverviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let left = MemoryFS(files: ["/L/a": Data("aaa".utf8), "/L/b": Data("bbb".utf8)])
        let right = MemoryFS(files: ["/R/a": Data("aax".utf8), "/R/b": Data("bbb".utf8)])
        let comparison = Comparison(
            left: left, leftRoot: "/L", right: right, rightRoot: "/R", algorithm: .sha256,
            transferQueue: TransferQueueViewModel(), temporaryRoot: root)
        comparison.start()
        await comparison.waitForWalk()
        return SettleRig(comparison: comparison, left: left, model: ComparisonSettleModel(), root: root)
    }

    @Test func settlingOneRowChangesThatRowAndNoOther() async throws {
        let rig = try await makeSettleRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let undetermined = ComparisonState.undetermined(.checksumUnavailable)
        // Positive: both rows start undetermined and both offer the action.
        #expect(rig.comparison.rows.map(\.state) == [undetermined, undetermined])
        #expect(rig.entries().allSatisfy { $0.settleButton != nil })
        let before = rig.comparison.rows
        let second = rig.entries()[1]
        #expect(second.path == "b")

        await rig.model.settle(second, on: rig.comparison)

        #expect(rig.comparison.rows[0] == before[0])
        #expect(rig.comparison.rows[1] == ComparisonRow(relativePath: "b", state: .same))
        // What the row now shows: its new state, no button, no note.
        let after = rig.entries()
        #expect(after[1].label == Presentation.label(for: .same))
        #expect(after[1].settleButton == nil)
        #expect(after[1].settleNote == nil)
        #expect(after[0].settleButton != nil)
        #expect(after[0].label == Presentation.label(for: undetermined))
        #expect(rig.model.tracker == Presentation.SettleTracker())
        // Positive: the second row's files were read, and not the first's.
        #expect(rig.left.reads == ["/L/b"])
    }

    @Test func aSettlingThatFindsADifferenceSaysDifferent() async throws {
        let rig = try await makeSettleRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }

        await rig.model.settle(rig.entries()[0], on: rig.comparison)

        #expect(rig.comparison.rows[0].state == .differs)
        #expect(rig.entries()[0].label == Presentation.label(for: .differs))
        #expect(rig.comparison.rows[1].state == .undetermined(.checksumUnavailable))
    }

    /// A throw leaves the row as it was and says why in the row's own words;
    /// here the session was released after the entry was made.
    @Test func aSettlingThatThrowsLeavesTheRowAndSaysWhy() async throws {
        let rig = try await makeSettleRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = rig.entries()[0]
        let before = rig.comparison.rows
        // Positive: before the release the action IS offered.
        #expect(entry.settleButton != nil)
        rig.comparison.releaseFileSystems()

        await rig.model.settle(entry, on: rig.comparison)

        #expect(rig.comparison.rows == before)
        let note = try #require(rig.model.tracker.failures[entry.path])
        #expect(note == Presentation.settleSessionClosed.text)
        #expect(!note.isEmpty)
        #expect(!rig.model.tracker.isPending(entry.path))
        // The list shows it: the row is unchanged, carries the note, and
        // offers no button because there is nothing to fetch with.
        let shown = rig.entries()[0]
        #expect(shown.label == entry.label)
        #expect(shown.settleNote == note)
        #expect(shown.settleButton == nil)
    }

    /// An entry that no longer stands for the row at its index settles
    /// nothing, and fetches nothing.
    @Test func aStaleEntryIsRefusedBeforeAnythingIsFetched() async throws {
        let rig = try await makeSettleRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entries = rig.entries()
        let stale = Presentation.RowEntry(
            path: entries[0].path, label: entries[0].label, reason: entries[0].reason,
            isMatch: false, index: 1, settleButton: entries[0].settleButton, settleNote: nil)
        let before = rig.comparison.rows

        await rig.model.settle(stale, on: rig.comparison)

        #expect(rig.comparison.rows == before)
        #expect(rig.model.tracker.failures["a"] == Presentation.settleRowMoved.text)
        #expect(rig.left.reads.isEmpty)
    }

    @Test func everyKindOfFailedSettlingHasItsOwnReadableText() throws {
        let failures: [any Error] = [
            ComparisonFetchError.sessionClosed, ComparisonFetchError.wrongKind,
            ComparisonFetchError.rowOutOfRange(3),
            ComparisonFetchError.noContentToCompare(.same), CancellationError(),
        ]
        let texts = failures.map { Presentation.settleFailureText(for: $0) }
        #expect(texts.allSatisfy { !$0.isEmpty && !$0.contains("%@") })
        #expect(texts[0] == Presentation.settleSessionClosed.text)
        #expect(texts[1] == Presentation.settleNotPossible.text)
        #expect(texts[2] == Presentation.settleRowMoved.text)
        #expect(texts[3] == Presentation.settleNotPossible.text)
        #expect(texts[4] == Presentation.settleStopped.text)
        #expect(Set([texts[0], texts[1], texts[2], texts[4]]).count == 4)

        // Any other error: the comparison's own frame around the cause, with
        // a credential filtered out.
        let foreign = Presentation.settleFailureText(
            for: RemoteFSError.connectionFailed(reason: "no route to https://K:HUNTER2@host.example/"))
        #expect(foreign.contains("host.example"))
        #expect(!foreign.contains("HUNTER2"))
        #expect(foreign.contains(Presentation.settleFailed.text.replacingOccurrences(of: "%@", with: "").trimmingCharacters(in: .whitespaces)))
    }

    @Test func theTrackerMovesThroughBeginSucceedAndFail() {
        var tracker = Presentation.SettleTracker()
        tracker.begin("x")
        #expect(tracker.isPending("x"))
        tracker.fail("x", text: "no")
        #expect(!tracker.isPending("x"))
        #expect(tracker.failures["x"] == "no")
        tracker.begin("x")
        #expect(tracker.failures["x"] == nil)
        tracker.succeed("x")
        #expect(tracker == Presentation.SettleTracker())
    }

    // MARK: - The view draws what the functions return

    private static let slicing = [
        "dropFirst", "dropLast", ".prefix(", ".suffix(", ".filter", "reversed", "sorted",
        "shuffled", "removeFirst", ".first", ".last",
    ]

    /// The residual scan: the views iterate each function's output, once, and
    /// hold nothing to rebind or slice. Every negative check has the positive
    /// one beside it.
    @Test func theViewsDrawOnlyWhatTheFunctionsReturn() throws {
        let (view, figure, row) = try Self.viewCode()

        // Positive: one call of each function, one iteration of each output.
        #expect(Self.occurrences(of: "ComparisonOverviewPresentation.summaryFigures(counts)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonOverviewPresentation.rowEntries(", in: view) == 1)
        #expect(Self.occurrences(of: "rows, settle: settler.tracker,", in: view) == 1)
        #expect(
            Self.occurrences(
                of: "canFetch: ComparisonOverviewPresentation.canFetch(comparison))", in: view) == 1)
        #expect(Self.occurrences(of: "Task { await settler.settle(entry, on: comparison) }", in: view) == 1)
        #expect(Self.occurrences(of: "ForEach(figures, id: \\.id)", in: view) == 1)
        #expect(Self.occurrences(of: "ForEach(entries, id: \\.path)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonOverviewFigure(figure: figure)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonOverviewRow(entry: entry) {", in: view) == 1)
        #expect(Self.occurrences(of: "summary(figures)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonOverviewPresentation.counts(of: rows)", in: view) == 1)
        // Negative: nothing is sliced, reordered or relabelled in the view.
        for token in Self.slicing {
            #expect(!view.contains(token), "the view uses \(token)")
        }
        #expect(!view.contains("label("))
        #expect(!view.contains("text(for"))
        #expect(!view.contains(".same"))

        // The figure and the row draw their one value, and hold no state, no
        // row and no presentation call to bind anything else to.
        #expect(figure.contains("Text(figure.label)"))
        #expect(Self.occurrences(of: "Text(String(figure.number))", in: figure) == 1)
        #expect(Self.occurrences(of: "Text(entry.path)", in: row) == 1)
        #expect(Self.occurrences(of: "Text(entry.label)", in: row) == 1)
        #expect(Self.occurrences(of: "if let reason = entry.reason", in: row) == 1)
        // The button: drawn from the entry's, and its action is the one closure
        // the view handed in. The row holds no comparison and starts no task.
        #expect(Self.occurrences(of: "if let button = entry.settleButton", in: row) == 1)
        #expect(Self.occurrences(of: "Button(button.title) { onSettle() }", in: row) == 1)
        #expect(Self.occurrences(of: ".disabled(!button.isEnabled)", in: row) == 1)
        #expect(Self.occurrences(of: "if let note = entry.settleNote", in: row) == 1)
        #expect(Self.occurrences(of: "Text(note)", in: row) == 1)
        for part in [figure, row] {
            #expect(!part.contains("Task"))
            #expect(!part.contains("settleUndetermined"))
            #expect(!part.contains("comparison"))
        }
        for part in [figure, row] {
            #expect(!part.contains("ComparisonRow"))
            #expect(!part.contains("ComparisonState"))
            #expect(!part.contains("RowEntry("))
            #expect(!part.contains("Figure("))
            // The type annotation names the presentation once; no call does.
            #expect(Self.occurrences(of: "Presentation", in: part) == 1)
            #expect(!part.contains(".same"))
            #expect(!part.contains("label("))
        }
    }

    /// The one call that settles a row is the model's, with the index the
    /// entry carries; the line of which reasons bytes can settle is read from
    /// `canBeSettledByBytes`, once, in `rowEntries`, and is not spelled twice.
    @Test func theSettleCallAndTheSettleableLineAreEachSpelledOnce() throws {
        let code = try Self.code("ComparisonOverview.swift")
        #expect(Self.occurrences(of: "settleUndetermined(rowAt: entry.index)", in: code) == 1)
        #expect(Self.occurrences(of: "settleUndetermined(", in: code) == 1)
        #expect(Self.occurrences(of: "canBeSettledByBytes", in: code) == 1)
        #expect(code.contains("why.canBeSettledByBytes && canFetch"))
    }

    /// The decisions about what to show are the presentation's, and the view
    /// asks: it does not spell the condition itself.
    @Test func theViewAsksThePresentationWhatToShowAndWhatToCount() throws {
        let (view, _, _) = try Self.viewCode()
        #expect(view.contains("ComparisonOverviewPresentation.showsEmptyNotice("))
        #expect(!view.contains(".completed"))
        // The progress line counts the rows held, like the figures do.
        #expect(view.contains("progressText(entriesFound: comparison.rows.count)"))
        #expect(!view.contains("comparison.progress"))
        #expect(!view.contains("rowsProduced"))
    }

    @Test func theWindowShowsTheOverviewAndTheFailureCause() throws {
        let window = try Self.code("ComparisonWindow.swift")
        #expect(window.contains("ComparisonOverviewView("))
        // Only a folder comparison has rows to overview.
        #expect(window.contains("ComparisonOverviewPresentation.showsOverview(for: comparison.kind)"))
        #expect(window.contains("ComparisonOverviewPresentation.failureCause(for:"))
        // The generic notice used to be the whole message; a raw rendering of
        // the error is not what replaces it.
        #expect(!window.contains("localizedDescription"))
        #expect(!window.contains("String(describing:"))
    }
}
