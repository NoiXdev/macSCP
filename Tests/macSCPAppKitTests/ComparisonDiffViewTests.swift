import Foundation
import MacSCPTestSupport
import SwiftUI
import Synchronization
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The content diff's words and shapes (diff view, Task 11): what a refusal
/// reads as, what a failed fetch reads as, what each line of a hunk looks
/// like, and what a hunk's header says.
///
/// Everything here is a pure function of a value, tested without a view, the
/// way `ComparisonOverviewTests` does it: the view draws what the functions
/// return and gains no judgement of its own, and the source scan at the end
/// pins only that.
///
/// The one rule the file exists for, the subsystem's: **nothing here tells
/// the user something nothing measured.** Concretely, a refusal never reads
/// as "nothing differs", a failure never reads as a refusal, a line that
/// changed never reads as one that did not, and a changed line whose two
/// sides would LOOK identical says what differs.
///
/// **Language.** `swift test` runs in whatever language the machine is set
/// to, so no assertion about a sentence compares it with an English one.
/// What a sentence must NOT say is held against the English source text and
/// the catalogue files; what it must say is the numbers it was given.
///
/// No test asserts how long anything took.
@Suite("Comparison diff view", .timeLimit(.minutes(2)))
@MainActor
struct ComparisonDiffViewTests {
    private typealias Presentation = ComparisonDiffPresentation

    // MARK: - Fixtures

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let appKit = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
    private static let locales = ["en", "de", "fr", "pl"]
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    private static func catalogue(_ locale: String) throws -> [String: String] {
        let url = appKit.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private static let missing = "ZZ-NOT-IN-THE-CATALOGUE-ZZ"

    private static func resolved(_ key: String) -> String? {
        let answer = L10n.bundle.localizedString(forKey: key, value: missing, table: nil)
        return answer == missing ? nil : answer
    }

    private static let refusals: [DiffRefusal] = [
        .binary, .notUTF8,
        .tooLarge(bytes: 4_194_305, ceiling: 4_194_304),
        .tooManyLines(leftLines: 20, rightLines: 2_097_152, ceilingProduct: 33_554_432),
        .notAnOrdinaryFile(side: .right, path: "/srv/notes.txt"),
    ]

    private static let fetchErrors: [ComparisonFetchError] = [
        .sessionClosed, .wrongKind, .rowOutOfRange(3), .noContentToCompare(.onlyLeft),
    ]

    /// Every state a row can carry and a fetch can be refused for, written
    /// out. `Presentation.wording(forNoContentIn:)` is an exhaustive switch,
    /// so a state added in Core stops the app compiling before it reaches
    /// this list.
    private static let allStates: [ComparisonState] = [
        .onlyLeft, .onlyRight, .same, .differs, .bothDirectories, .typeMismatch,
        .undetermined(.checksumUnavailable), .undetermined(.algorithmUnavailable(.md5)),
        .undetermined(.algorithmsDiffer), .undetermined(.etagIsNotAFileHash),
        .undetermined(.linkOnASide), .undetermined(.kindNotReported), .undetermined(.unreadable),
    ]

    /// A listing read back as what it holds, for the tests that ask about a
    /// hunk's own lines: the rows regrouped at each header, in order. Reading
    /// only; the structure itself is pinned by `theListingIsTheLegendThenEach…`.
    private struct Section: Equatable {
        let header: String
        let lines: [Presentation.LineEntry]
    }

    private static func sections(_ listing: Presentation.Listing) -> [Section] {
        var found: [Section] = []
        for row in listing.rows {
            switch row.kind {
            case .legend: break
            case .header(let text): found.append(Section(header: text, lines: []))
            case .line(let entry):
                if !found.isEmpty { found[found.count - 1] = Section(
                    header: found[found.count - 1].header,
                    lines: found[found.count - 1].lines + [entry]) }
            }
        }
        return found
    }

    /// Every line of a listing, in the order it is drawn.
    private static func lines(_ listing: Presentation.Listing) -> [Presentation.LineEntry] {
        listing.rows.compactMap { row in
            if case .line(let entry) = row.kind { entry } else { nil }
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// What a line looks like, as one string: the runs joined.
    private static func visible(_ runs: [Presentation.Run]) -> String {
        runs.map(\.text).joined()
    }

    // MARK: - Five refusals, five texts

    /// The list above is hand-maintained, and that is the one thing about it
    /// nothing checked (fix round 3, item 5). A SIXTH `DiffRefusal` case not
    /// added to `refusals` leaves every count in this file at 5 and passes,
    /// so its wording, its key, its distinctness and its "never reads as
    /// nothing differs" all go untested in silence. The structural floor is
    /// real — `wording(for:)` and `refusalText` switch exhaustively with no
    /// `default:`, so a sixth case does not compile until somebody names it —
    /// which makes the exposure "untested", not "unwritten".
    ///
    /// `DiffRefusal` has associated values, so it cannot be `CaseIterable`.
    /// The list is therefore tied to the number of cases the enum DECLARES,
    /// read from source: the technique this suite already uses for the view
    /// code below.
    ///
    /// **It counts case NAMES, not `case` keywords** (fix round 4, item 2).
    /// Fix round 3 counted lines beginning `case `, and one `case` keyword
    /// can declare any number of names: `case binary, probePlantedCase`
    /// declares two, the reader read one, the tie passed, and the sixth case
    /// went untested — which is the whole thing this test exists to prevent.
    /// It is CLAUDE.md's "`grep -c` counts matching LINES" one level up, and
    /// it arrived inside the fix written for the same mistake.
    @Test func theRefusalListHoldsEveryCaseTheEnumDeclares() throws {
        let core = Self.repoRoot.appendingPathComponent("Sources/macSCPCore")
        let source = try SourceCorpus.code(
            of: core.appendingPathComponent("Compare/DiffEligibility.swift"))
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "public enum DiffRefusal: Error, Equatable, Sendable", in: source)
        // Top-level case declarations of the enum's own body — not the
        // nested `Side`'s, whose cases sit one brace deeper.
        var depth = 0
        var declared = 0
        var caseLines: [String] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `declarationBody` hands back the body WITHOUT its outer
            // braces, so the enum's own cases sit at depth 0 and the nested
            // `Side`'s at depth 1.
            if depth == 0, trimmed.hasPrefix("case ") {
                declared += Self.namesDeclared(onCaseLine: trimmed)
                caseLines.append(trimmed)
            }
            for character in line {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
            }
        }
        #expect(declared == Self.refusals.count, "\(declared) cases, \(Self.refusals.count) listed")
        // Positives for the reader itself: it found cases at all, it did NOT
        // count the nested enum's two, and — since the counter above is the
        // part that can be wrong — this enum really is written one case per
        // line, so `declared` and `caseLines.count` agree here and would
        // diverge the moment somebody wrote two on one.
        #expect(declared == 5)
        #expect(caseLines.count == 5)
        #expect(body.contains("case left"))
        #expect(body.contains("case right"))
    }

    /// How many case names one `case` line declares: one, plus one per comma
    /// that is NOT inside an associated-value list. The parenthesis depth is
    /// what makes it right — `case tooLarge(bytes: Int, ceiling: Int)` holds
    /// a comma and declares ONE name, and a flat "does this line contain a
    /// comma" check would call three of this enum's five cases a violation.
    private static func namesDeclared(onCaseLine line: String) -> Int {
        var depth = 0
        var names = 1
        for character in line {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            case "," where depth == 0: names += 1
            default: break
            }
        }
        return names
    }

    /// The counter against a FIXTURE rather than against the real source,
    /// which is the lesson of this round's near miss: a self-test planted
    /// against real source is satisfied by the same loosening that satisfies
    /// the live scan, so it has to carry its own inputs.
    @Test func theCaseNameCounterCountsNamesAndNotCommas() {
        #expect(Self.namesDeclared(onCaseLine: "case binary") == 1)
        #expect(Self.namesDeclared(onCaseLine: "case binary, probePlantedCase") == 2)
        #expect(Self.namesDeclared(onCaseLine: "case a, b, c") == 3)
        // Commas inside an associated-value list declare nothing.
        #expect(Self.namesDeclared(onCaseLine: "case tooLarge(bytes: Int, ceiling: Int)") == 1)
        #expect(Self.namesDeclared(
            onCaseLine: "case tooManyLines(leftLines: Int, rightLines: Int, ceilingProduct: Int)")
            == 1)
        #expect(Self.namesDeclared(onCaseLine: "case notAnOrdinaryFile(side: Side, path: String)") == 1)
        // A second name beside an associated-value case is still a second
        // name, which is the shape the probe plants.
        #expect(Self.namesDeclared(onCaseLine: "case tooLarge(bytes: Int, ceiling: Int), planted") == 2)
        // Generic and collection brackets do not open a case list either.
        #expect(Self.namesDeclared(onCaseLine: "case rows([String: Int], Array<Int, Int>)") == 1)
    }

    @Test func eachRefusalHasItsOwnKeyAndItsOwnText() {
        let wordings = Self.refusals.map { Presentation.wording(for: $0) }
        #expect(wordings.count == 5)
        #expect(Set(wordings.map(\.key)).count == 5)
        #expect(Set(wordings.map(\.english)).count == 5)
        let texts = Self.refusals.map { Presentation.refusalText($0, locale: Self.english) }
        for (refusal, text) in zip(Self.refusals, texts) {
            #expect(!text.isEmpty, "\(refusal)")
            #expect(!text.contains("%"), "\(refusal): \(text)")
        }
        #expect(Set(texts).count == 5)
    }

    /// `.binary` is a statement about the FILE (a NUL byte: it is not text);
    /// `.notUTF8` is a statement about its ENCODING. A Latin-1 or Windows-1252
    /// configuration file is text, and calling it binary is false.
    @Test func notUTF8NamesTheEncodingAndNeverCallsTheFileBinary() throws {
        let binary = Presentation.wording(for: .binary)
        let notUTF8 = Presentation.wording(for: .notUTF8)
        #expect(binary.english.localizedCaseInsensitiveContains("binary"))
        #expect(!notUTF8.english.localizedCaseInsensitiveContains("binary"))
        #expect(notUTF8.english.contains("UTF-8"))
        #expect(notUTF8.english.contains("Latin-1"))
        #expect(notUTF8.english.contains("Windows-1252"))
        // It does not claim to know the encoding.
        #expect(notUTF8.english.contains("may be"))
        // The same in every language the app speaks.
        let stems = ["de": "bin", "fr": "binaire", "pl": "binarn"]
        for (locale, stem) in stems {
            let catalogue = try Self.catalogue(locale)
            let binaryText = try #require(catalogue[binary.key])
            let notUTF8Text = try #require(catalogue[notUTF8.key])
            #expect(binaryText.localizedCaseInsensitiveContains(stem), "\(locale) binary")
            #expect(!notUTF8Text.localizedCaseInsensitiveContains(stem), "\(locale) notUTF8")
            #expect(notUTF8Text.contains("UTF-8"), "\(locale)")
        }
    }

    @Test func tooLargeNamesTheSizeAndTheCeilingExactly() {
        let text = Presentation.refusalText(
            .tooLarge(bytes: 4_194_305, ceiling: 4_194_304), locale: Self.english)
        #expect(text.contains("4,194,305"))
        #expect(text.contains("4,194,304"))
        // A size one byte over the ceiling is still told apart from it.
        #expect(text.contains("4,194,305") && text.contains("4,194,304"))
        // The figures follow the locale they are shown in.
        let german = Presentation.refusalText(
            .tooLarge(bytes: 4_194_305, ceiling: 4_194_304), locale: Self.german)
        #expect(german.contains("4.194.305"))
        #expect(german.contains("4.194.304"))
        // The size comes before the ceiling, in the sentence's own order.
        let size = text.range(of: "4,194,305")
        let ceiling = text.range(of: "4,194,304")
        #expect(size != nil && ceiling != nil)
        if let size, let ceiling { #expect(size.lowerBound < ceiling.lowerBound) }
    }

    /// Both line counts, and never the product: the product is what this
    /// implementation's table costs, and nothing a user can act on.
    @Test func tooManyLinesNamesBothCountsAndNeverTheProduct() {
        let refusal = DiffRefusal.tooManyLines(
            leftLines: 20, rightLines: 2_097_152, ceilingProduct: 33_554_432)
        let text = Presentation.refusalText(refusal, locale: Self.english)
        #expect(text.contains("20"))
        #expect(text.contains("2,097,152"))
        // Neither the ceiling nor the product of the two counts, grouped or
        // not.
        for forbidden in ["33,554,432", "33554432", "41,943,040", "41943040"] {
            #expect(!text.contains(forbidden), Comment(rawValue: forbidden))
        }
        // The left count comes first: which side is which is not swapped.
        let swapped = Presentation.refusalText(
            .tooManyLines(leftLines: 2_097_152, rightLines: 20, ceilingProduct: 33_554_432),
            locale: Self.english)
        #expect(swapped != text)
        let leftFirst = text.range(of: "20")?.lowerBound
        let rightFirst = text.range(of: "2,097,152")?.lowerBound
        #expect(leftFirst != nil && rightFirst != nil)
        if let leftFirst, let rightFirst { #expect(leftFirst < rightFirst) }
    }

    // MARK: - A refusal is not "nothing differs"

    @Test func aRefusalNeverReadsAsAnAbsenceOfDifferences() {
        let identical = Presentation.identical.english
        for refusal in Self.refusals {
            let wording = Presentation.wording(for: refusal)
            #expect(wording.english != identical)
            // None of the five says the files are the same, equal or
            // identical, or that nothing was found.
            for claim in ["same", "equal", "identical", "no difference", "nothing differs", "match"] {
                #expect(
                    !wording.english.localizedCaseInsensitiveContains(claim),
                    "\(wording.key) says “\(claim)”")
            }
            // And each says that no line comparison was made.
            #expect(wording.english.hasPrefix("No line comparison was made"), "\(wording.key)")
        }
    }

    @Test func aRefusalIsShownInTheListingsPlaceAndAnEmptyDiffIsAnotherThing() {
        let target = Presentation.Target.filePair
        let refused = Self.refusals.map {
            Presentation.screen(target: target, loaded: .init(target: target, outcome: .refused($0)))
        }
        let identical = Presentation.screen(
            target: target, loaded: .init(target: target, outcome: .hunks([])))
        // Positive: an empty diff of a pair IS reported, in its own words.
        guard case .notice(let identicalNotice) = identical else {
            Issue.record("an empty diff is a notice")
            return
        }
        #expect(identicalNotice.text == Presentation.identical.text)
        #expect(identicalNotice.style == .identical)
        for screen in refused {
            #expect(screen != identical)
            guard case .notice(let notice) = screen else {
                Issue.record("a refusal is a notice, not a listing")
                continue
            }
            #expect(notice.style == .refusal)
            #expect(notice.text != identicalNotice.text)
        }
        #expect(Set(refused).count == 5)
    }

    // MARK: - A failure is not a refusal

    @Test func eachFailureHasItsOwnNonEmptyTextAndNoneIsARefusalsText() {
        var texts: [String] = []
        for error in Self.fetchErrors {
            let text = Presentation.failureText(for: error)
            #expect(!text.isEmpty, "\(error)")
            #expect(!text.contains("%"), "\(error): \(text)")
            texts.append(text)
        }
        texts.append(Presentation.failureText(for: CancellationError()))
        // `.wrongKind` and the states that cannot reach a diff share one
        // sentence on purpose; every OTHER pair of causes reads differently.
        let distinct = Set(texts)
        #expect(distinct.count == texts.count, "two failures read alike: \(texts)")

        let refusalTexts = Set(Self.refusals.map { Presentation.refusalText($0) })
        #expect(refusalTexts.count == 5)
        #expect(distinct.isDisjoint(with: refusalTexts))
        #expect(!distinct.contains(Presentation.identical.text))
    }

    @Test func aFailureIsStyledAsAFailureAndARefusalAsARefusal() {
        let target = Presentation.Target.row(index: 0)
        let failed = Presentation.screen(
            target: target,
            loaded: .init(target: target, outcome: .threw(ComparisonFetchError.sessionClosed)))
        let refused = Presentation.screen(
            target: target, loaded: .init(target: target, outcome: .refused(.binary)))
        guard case .notice(let failure) = failed, case .notice(let refusal) = refused else {
            Issue.record("both are notices")
            return
        }
        #expect(failure.style == .failure)
        #expect(refusal.style == .refusal)
        #expect(failure.style != refusal.style)
        #expect(failure.text != refusal.text)
    }

    @Test func everyStateARowCanHaveReadsItsOwnReasonForHavingNothingToCompare() {
        let texts = Self.allStates.map {
            Presentation.failureText(for: ComparisonFetchError.noContentToCompare($0))
        }
        #expect(texts.allSatisfy { !$0.isEmpty })
        // One side missing, either side, and a pair of different types each
        // read as what they are.
        let onlyLeft = Presentation.failureText(for: ComparisonFetchError.noContentToCompare(.onlyLeft))
        let onlyRight = Presentation.failureText(for: ComparisonFetchError.noContentToCompare(.onlyRight))
        let mismatch = Presentation.failureText(
            for: ComparisonFetchError.noContentToCompare(.typeMismatch))
        #expect(Set([onlyLeft, onlyRight, mismatch]).count == 3)
        // The reasons read as two sentences (which of the two is held to
        // `canBeSettledByBytes` below), and neither is one of the three.
        let undetermined = Set(
            Self.allStates.filter {
                if case .undetermined = $0 { return true } else { return false }
            }.map { Presentation.failureText(for: ComparisonFetchError.noContentToCompare($0)) })
        #expect(undetermined.count == 2)
        #expect(undetermined.isDisjoint(with: [onlyLeft, onlyRight, mismatch]))
    }

    /// "macSCP could not tell that both sides are ordinary files" is true of
    /// the reasons bytes cannot settle, and is not the wording of the five they
    /// can: four of those describe two ordinary files whose checksums could
    /// not be had, and `.kindNotReported` is an entry a fetch will settle, so
    /// a row that is about to be diffed is not told that nobody could tell. The
    /// split is held to `canBeSettledByBytes`, which is also what lets a row
    /// be diffed at all, so a change there cannot make this wording lie.
    @Test func theNotKnownToBeFilesSentenceIsOnlyForTheReasonsThatCanReachIt() {
        let notKnown = Presentation.Wording(
            key: "compare.diff.failure.notKnownFiles", english: "x")
        var withheld = 0
        var general = 0
        for state in Self.allStates {
            guard case .undetermined(let reason) = state else { continue }
            let wording = Presentation.wording(forNoContentIn: state)
            if reason.canBeSettledByBytes {
                #expect(wording == Presentation.notPossible, Comment(rawValue: "\(reason)"))
                general += 1
            } else {
                #expect(wording.key == notKnown.key, Comment(rawValue: "\(reason)"))
                withheld += 1
            }
        }
        #expect(general == 5 && withheld == 2)
    }

    /// The other half, with a real comparison: a row the settleable
    /// reasons describe IS diffed, so it never reaches the no-contents text.
    @Test func aRowWhoseChecksumCouldNotBeHadIsDiffedAndNotRefused() async throws {
        let rig = try await folderRig(left: ["a": data("1")], right: ["a": data("2")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.checksumUnavailable)])
        let model = ComparisonDiffModel()
        await model.load(.row(index: 0), on: rig.comparison)
        #expect(shown(Presentation.screen(target: .row(index: 0), loaded: model.loaded)) == ["-1", "+2"])
    }

    @Test func aForeignErrorIsShownAsItsCauseUnderTheDiffsOwnFrame() {
        struct Foreign: LocalizedError {
            var errorDescription: String? { "the disk said no" }
        }
        let text = Presentation.failureText(for: Foreign())
        #expect(text.contains("the disk said no"))
        #expect(!text.contains("Foreign"))
        #expect(text != ComparisonOverviewPresentation.failureCause(for: Foreign()))
        // A credential in an endpoint does not reach the line.
        let leaked = Presentation.failureText(
            for: RemoteFSError.connectionFailed(reason: "could not reach https://KEYID:HUNTER2@host.example/x"))
        #expect(leaked.contains("host.example"))
        #expect(!leaked.contains("HUNTER2"))
    }

    @Test func aStoppedFetchSaysItWasStoppedAndNothingWasCompared() {
        let stopped = Presentation.failureText(for: CancellationError())
        #expect(stopped == Presentation.stopped.text)
        #expect(Presentation.stopped.english.contains("nothing was compared"))
    }

    // MARK: - Which screen

    @Test func theScreenFollowsTheTargetAndNeverShowsAnotherRowsResult() throws {
        let a = Presentation.Target.row(index: 0)
        let b = Presentation.Target.row(index: 1)
        let hunksOfA = FileDiff.hunks(left: ["one"], right: ["two"], context: 0)
        let loadedA = Presentation.Loaded(target: a, outcome: .hunks(hunksOfA))

        // Positive: for its own target the result is the listing.
        guard case .listing = Presentation.screen(target: a, loaded: loadedA) else {
            Issue.record("a's result is not shown for a")
            return
        }
        // Another row's result is never shown: the answer is "fetching".
        let forB = Presentation.screen(target: b, loaded: loadedA)
        guard case .notice(let notice) = forB else {
            Issue.record("a's listing was shown for b")
            return
        }
        #expect(notice.style == .pending)
        #expect(notice.text == Presentation.pending.text)
        // Nothing loaded yet is the same answer; nothing selected is not.
        #expect(Presentation.screen(target: a, loaded: nil) == forB)
        guard case .notice(let idle) = Presentation.screen(target: nil, loaded: loadedA) else {
            Issue.record("no target should show a notice")
            return
        }
        #expect(idle.style == .idle)
        #expect(idle.text == Presentation.pickRow.text)
        #expect(idle.text != notice.text)
        // A file pair's result is not a row's.
        guard case .notice(let pair) = Presentation.screen(target: .filePair, loaded: loadedA) else {
            Issue.record("a row's listing was shown for the pair")
            return
        }
        #expect(pair.style == .pending)
    }

    @Test func theTargetIsTheSelectedRowForFoldersAndTheFilePairForAPair() {
        #expect(Presentation.target(kind: .folders, selection: nil) == nil)
        #expect(Presentation.target(kind: .folders, selection: 4) == .row(index: 4))
        // A pair has no rows, so a stray selection does not matter.
        #expect(Presentation.target(kind: .filePair, selection: nil) == .filePair)
        #expect(Presentation.target(kind: .filePair, selection: 0) == .filePair)
    }

    /// A row's identity is its POSITION, so this is a bounds check: there is
    /// no second spelling of a row to search for, and no first-versus-last to
    /// get it wrong. It used to be `rows.firstIndex { $0.relativePath == path }`,
    /// and `String` equality is Unicode canonical equivalence — two rows whose
    /// paths differ only by normalization are two files, and the search
    /// answered the EARLIER one for both.
    @Test func aRowIsFoundByItsPositionAndAPositionTheListLacksIsNotFound() {
        let rows = [
            fixtureRow("a", .differs),
            fixtureRow("b", .same),
            fixtureRow("c", .differs),
        ]
        #expect(Presentation.index(of: 0, in: rows) == 0)
        #expect(Presentation.index(of: 1, in: rows) == 1)
        #expect(Presentation.index(of: 2, in: rows) == 2)
        #expect(Presentation.index(of: 3, in: rows) == nil)
        #expect(Presentation.index(of: -1, in: rows) == nil)
        #expect(Presentation.index(of: 0, in: []) == nil)
        // The case that matters, and the one no path lookup could answer: two
        // rows whose paths are `==` as `String`s and different as bytes keep
        // their own positions, and the diff of each is its own.
        let nfc = "\u{00E4}"
        let nfd = "a\u{0308}"
        #expect(nfc == nfd)
        #expect(Array(nfc.utf8) != Array(nfd.utf8))
        let folded = [fixtureRow(nfc, .same), fixtureRow(nfd, .differs)]
        #expect(Presentation.index(of: 0, in: folded) == 0)
        #expect(Presentation.index(of: 1, in: folded) == 1)
        #expect(folded[0].state == .same)
        #expect(folded[1].state == .differs)
        // And the two targets are two targets.
        #expect(Presentation.Target.row(index: 0) != Presentation.Target.row(index: 1))
    }

    @Test func onlyAFailureIsSetApartInColour() {
        func emphasis(_ style: Presentation.Notice.Style) -> Color {
            Presentation.Notice(style: style, text: "x").emphasis
        }
        #expect(emphasis(.failure) == Color.orange)
        for quiet in [Presentation.Notice.Style.idle, .pending, .identical, .refusal] {
            #expect(emphasis(quiet) == Color.secondary)
            #expect(emphasis(quiet) != emphasis(.failure))
        }
        // Only the pending notice shows progress.
        #expect(Presentation.Notice(style: .pending, text: "x").showsProgress)
        for other in [Presentation.Notice.Style.idle, .identical, .refusal, .failure] {
            #expect(!Presentation.Notice(style: other, text: "x").showsProgress)
        }
    }

    // MARK: - The header

    /// A header is `@@ -a,b +c,d @@` with BOTH counts spelled out. The
    /// start is `leftStart + 1` only when the count is positive: a zero-count
    /// hunk names the line BEFORE, so the start is `leftStart` itself. A naive
    /// `start + 1` is off by one for every pure insertion and every pure
    /// deletion at context 0.
    @Test func aHeaderFollowsTheZeroCountRule() {
        func header(_ left: [String], _ right: [String], context: Int = 0) -> [String] {
            FileDiff.hunks(left: left, right: right, context: context).map(Presentation.header(for:))
        }
        // The checked examples: an append, and an empty left side.
        #expect(header(["a"], ["a", "x"]) == ["@@ -1,0 +2,1 @@"])
        #expect(header([], ["x"]) == ["@@ -0,0 +1,1 @@"])
        // The mirror images: a pure deletion, and an empty right side.
        #expect(header(["a", "b", "c", "d"], ["a", "b", "d"]) == ["@@ -3,1 +2,0 @@"])
        #expect(header(["n"], []) == ["@@ -1,1 +0,0 @@"])
        // A pure insertion in the middle names the line before it.
        #expect(header(["a", "b"], ["a", "x", "b"]) == ["@@ -1,0 +2,1 @@"])
        // A replacement has a positive count on both sides.
        #expect(header(["a", "b", "c"], ["a", "X", "c"]) == ["@@ -2,1 +2,1 @@"])
        // With context the counts include it: one removal in the middle of
        // seven lines, three context lines either side.
        #expect(
            header(
                ["1", "2", "3", "4", "5", "6", "7"], ["1", "2", "3", "5", "6", "7"], context: 3)
                == ["@@ -1,7 +1,6 @@"])
        // Two hunks, each with its own start.
        let long = (1...30).map(String.init)
        var edited = long
        edited[1] = "two"
        edited[27] = "twenty-eight"
        #expect(header(long, edited) == ["@@ -2,1 +2,1 @@", "@@ -28,1 +28,1 @@"])
    }

    /// The header's four numbers are read from the hunk and nowhere else: a
    /// hand-built hunk with unusual starts gives exactly what the rule says.
    @Test func aHeaderReadsStartsAndCountsFromTheHunk() {
        let removedThenAdded = DiffHunk(
            leftStart: 9, rightStart: 4,
            lines: [
                DiffLine(kind: .context, text: "c"), DiffLine(kind: .removed, text: "r"),
                DiffLine(kind: .removed, text: "r2"), DiffLine(kind: .added, text: "a"),
            ])
        #expect(Presentation.header(for: removedThenAdded) == "@@ -10,3 +5,2 @@")
        let onlyAdded = DiffHunk(
            leftStart: 9, rightStart: 4, lines: [DiffLine(kind: .added, text: "a")])
        #expect(Presentation.header(for: onlyAdded) == "@@ -9,0 +5,1 @@")
        let onlyRemoved = DiffHunk(
            leftStart: 9, rightStart: 4, lines: [DiffLine(kind: .removed, text: "a")])
        #expect(Presentation.header(for: onlyRemoved) == "@@ -10,1 +4,0 @@")
    }

    // MARK: - The lines

    private struct Fixture {
        let name: String
        let left: [String]
        let right: [String]
    }

    /// `count` numbered lines, with the lines at `changed` (one-based) spelled
    /// differently.
    private static func numbered(_ count: Int, changing changed: Set<Int> = []) -> [String] {
        var lines: [String] = []
        for number in 1...count {
            lines.append(changed.contains(number) ? "changed \(number)" : "line \(number)")
        }
        return lines
    }

    private static let fixtures: [Fixture] = [
        Fixture(name: "replace in the middle", left: numbered(12), right: numbered(12, changing: [6])),
        Fixture(name: "insert at the start", left: ["a", "b"], right: ["new", "a", "b"]),
        Fixture(name: "append", left: ["a", "b"], right: ["a", "b", "c", "d"]),
        Fixture(name: "delete the first", left: ["a", "b", "c"], right: ["b", "c"]),
        Fixture(name: "empty left", left: [], right: ["x", "y"]),
        Fixture(name: "empty right", left: ["x", "y"], right: []),
        Fixture(name: "two hunks", left: numbered(40), right: numbered(40, changing: [3, 37])),
        Fixture(
            name: "a pure insertion and a pure deletion", left: ["a", "b", "c", "d", "e"],
            right: ["a", "NEW", "b", "c", "e"]),
        Fixture(name: "duplicate lines", left: ["x", "x", "x", "y"], right: ["x", "y", "x", "x"]),
    ]

    /// The gutter numbers are right: for every line a number is shown for,
    /// that line of its own side's text IS the line. Over every fixture and
    /// every context width, and with a positive count so that a loop over
    /// nothing could not pass.
    @Test func everyNumberedLineIsTheLineOfThatNumberOnItsOwnSide() throws {
        var contexts = 0
        var removals = 0
        var additions = 0
        for fixture in Self.fixtures {
            for context in [0, 1, 3] {
                let hunks = FileDiff.hunks(left: fixture.left, right: fixture.right, context: context)
                let listing = Presentation.listing(for: hunks)
                let sections = Self.sections(listing)
                #expect(sections.count == hunks.count, Comment(rawValue: fixture.name))
                for (hunk, entry) in zip(hunks, sections) {
                    #expect(entry.lines.count == hunk.lines.count, Comment(rawValue: fixture.name))
                    for (line, shown) in zip(hunk.lines, entry.lines) {
                        let label = "\(fixture.name) c\(context): \(line.text)"
                        // The text is the line's text, in every case.
                        #expect(Self.visible(shown.runs) == line.text, Comment(rawValue: label))
                        // A wrong number is a failed expectation, never an
                        // out-of-range read that takes the runner down.
                        func text(_ side: [String], _ number: String) -> String? {
                            guard let n = Int(number), side.indices.contains(n - 1) else { return nil }
                            return side[n - 1]
                        }
                        let leftText = text(fixture.left, shown.leftNumber)
                        let rightText = text(fixture.right, shown.rightNumber)
                        switch line.kind {
                        case .context:
                            #expect(leftText == line.text, Comment(rawValue: label))
                            #expect(rightText == line.text, Comment(rawValue: label))
                            contexts += 1
                        case .removed:
                            #expect(leftText == line.text, Comment(rawValue: label))
                            #expect(shown.rightNumber.isEmpty, Comment(rawValue: label))
                            removals += 1
                        case .added:
                            #expect(rightText == line.text, Comment(rawValue: label))
                            #expect(shown.leftNumber.isEmpty, Comment(rawValue: label))
                            additions += 1
                        }
                    }
                }
            }
        }
        // Positive: every kind of line was actually checked, many times.
        #expect(contexts > 20 && removals > 10 && additions > 10)
    }

    /// A line drawn as removed is a removed line, one drawn as added is an
    /// added line, and no kind is drawn as another: each kind has its own
    /// sign, tone, tint and spoken word.
    @Test func eachKindOfLineIsDrawnAsItselfAndAsNoOther() {
        let hunk = DiffHunk(
            leftStart: 0, rightStart: 0,
            lines: [
                DiffLine(kind: .context, text: "same"), DiffLine(kind: .removed, text: "gone"),
                DiffLine(kind: .added, text: "new"),
            ])
        let lines = Self.lines(Presentation.listing(for: [hunk]))
        guard lines.count == 3 else {
            Issue.record("expected three lines, found \(lines.count)")
            return
        }
        #expect(lines.map(\.sign) == [" ", "-", "+"])
        #expect(lines.map(\.tone) == [.context, .removed, .added])
        #expect(lines.map { Self.visible($0.runs) } == ["same", "gone", "new"])
        // Three different words and three different tints, the unchanged one
        // with none.
        #expect(Set(lines.map(\.kindLabel)).count == 3)
        #expect(lines[0].kindLabel == Presentation.lineUnchanged.text)
        #expect(lines[1].kindLabel == Presentation.lineRemoved.text)
        #expect(lines[2].kindLabel == Presentation.lineAdded.text)
        #expect(lines[0].tint == Color.clear)
        #expect(lines[1].tint != Color.clear && lines[2].tint != Color.clear)
        #expect(lines[1].tint != lines[2].tint)
        // The removed tint is a red one and the added one a green one.
        #expect(lines[1].tint == Presentation.Tone.removed.tint)
        #expect(lines[2].tint == Presentation.Tone.added.tint)
        #expect(Presentation.Tone.removed.tint == Color.red.opacity(0.16))
        #expect(Presentation.Tone.added.tint == Color.green.opacity(0.16))
    }

    /// What a row is, as one character: the legend, a header, a line.
    private static func shape(_ listing: Presentation.Listing) -> String {
        listing.rows.map { row -> String in
            switch row.kind {
            case .legend: "L"
            case .header: "H"
            case .line: "."
            }
        }.joined()
    }

    /// The listing is ONE sequence: the legend, then for each hunk its header
    /// and its lines, and nothing else; the ids run 0, 1, 2 … without a gap.
    /// Draw order is data order, which is why the view holds no header-and-
    /// lines pair to place the wrong way round.
    @Test func theListingIsTheLegendThenEachHeaderWithItsLinesAndNothingElse() throws {
        let fixture = Self.fixtures[6]
        let hunks = FileDiff.hunks(left: fixture.left, right: fixture.right, context: 3)
        #expect(hunks.count == 2)
        let listing = Presentation.listing(for: hunks)

        let expectedShape =
            "L" + hunks.map { "H" + String(repeating: ".", count: $0.lines.count) }.joined()
        #expect(Self.shape(listing) == expectedShape)
        #expect(listing.rows.map(\.id) == Array(0..<listing.rows.count))
        #expect(listing.rows.first?.kind == .legend(Presentation.legend.text))

        // Each header is its own hunk's, directly before that hunk's lines.
        var index = 1
        for hunk in hunks {
            guard listing.rows.indices.contains(index) else {
                Issue.record("the listing ends before hunk \(Presentation.header(for: hunk))")
                return
            }
            #expect(listing.rows[index].kind == .header(Presentation.header(for: hunk)))
            index += 1
            for line in hunk.lines {
                guard listing.rows.indices.contains(index),
                    case .line(let entry) = listing.rows[index].kind
                else {
                    Issue.record("row \(index) is not a line")
                    return
                }
                #expect(Self.visible(entry.runs) == line.text)
                index += 1
            }
        }
        #expect(index == listing.rows.count)
        // Positive: the headers are two different ones.
        #expect(Set(Self.sections(listing).map(\.header)).count == 2)
    }

    /// The seam the listing test above does not cross: what `screen` builds
    /// from the hunks it was given. Two hunks (and three) in, the same
    /// hunks out, in order; a screen that kept the first, or turned them
    /// round, would read as a complete diff of a file whose last change it
    /// never shows.
    @Test func theScreenListsEveryHunkTheDiffReturnedInOrder() throws {
        let target = Presentation.Target.row(index: 0)
        var checked = 0
        for fixture in [Self.fixtures[6], Self.fixtures[7]]
        + [Fixture(name: "three", left: Self.numbered(60), right: Self.numbered(60, changing: [2, 30, 58]))] {
            let hunks = FileDiff.hunks(left: fixture.left, right: fixture.right, context: 1)
            #expect(hunks.count >= 1, Comment(rawValue: fixture.name))
            let screen = Presentation.screen(
                target: target, loaded: .init(target: target, outcome: .hunks(hunks)))
            guard case .listing(let listing) = screen else {
                Issue.record("\(fixture.name): not a listing")
                continue
            }
            let sections = Self.sections(listing)
            #expect(sections.map(\.header) == hunks.map(Presentation.header(for:)))
            #expect(sections.map(\.lines.count) == hunks.map(\.lines.count))
            let shownTexts = Self.lines(listing).map { Self.visible($0.runs) }
            #expect(shownTexts == hunks.flatMap(\.lines).map(\.text))
            #expect(
                Self.shape(listing)
                    == "L" + hunks.map { "H" + String(repeating: ".", count: $0.lines.count) }.joined())
            checked += hunks.count
        }
        // Positive: more than one hunk was actually exercised, three at most.
        #expect(checked >= 2 + 1 + 3)
        let multi = FileDiff.hunks(left: Self.fixtures[6].left, right: Self.fixtures[6].right, context: 3)
        #expect(multi.count == 2)
        #expect(Set(multi.map(Presentation.header(for:))).count == 2)
    }

    @Test func theGutterIsAsWideAsTheLargestNumberItShows() {
        func digits(_ left: [String], _ right: [String]) -> Int {
            Presentation.listing(for: FileDiff.hunks(left: left, right: right, context: 3)).numberDigits
        }
        #expect(digits(["a"], ["b"]) == 1)
        let hundred = (1...120).map(String.init)
        var edited = hundred
        edited[99] = "x"
        #expect(digits(hundred, edited) == 3)
        var early = hundred
        early[1] = "x"
        // The change is at the top, but its context stops at line 5.
        #expect(digits(hundred, early) == 1)
    }

    // MARK: - What a line looks like: invisible scalars

    /// A UTF-8 byte order mark is kept by the fetch, on purpose: stripping it
    /// would show an EMPTY diff for two files that differ by exactly those
    /// three bytes. The cost is here — the first line of such a diff is one
    /// removal and one addition whose two sides must NOT look identical.
    @Test func aByteOrderMarkIsVisibleSoTheTwoSidesLookDifferent() throws {
        let hunks = FileDiff.hunks(left: ["\u{FEFF}#!/bin/sh", "echo"], right: ["#!/bin/sh", "echo"], context: 3)
        #expect(hunks.count == 1)
        let lines = Self.lines(Presentation.listing(for: hunks))
        let removed = try #require(lines.first { $0.tone == .removed })
        let added = try #require(lines.first { $0.tone == .added })
        #expect(Self.visible(removed.runs) != Self.visible(added.runs))
        #expect(Self.visible(removed.runs) == "<U+FEFF>#!/bin/sh")
        #expect(removed.runs.filter(\.isEscape).map(\.text) == ["<U+FEFF>"])
        #expect(added.runs.allSatisfy { !$0.isEscape })
        // The marker is what the file-actions sheet draws for the same scalar.
        #expect(FileActionPlanDisplay.visible("\u{FEFF}") == "<U+FEFF>")
    }

    /// Pairs of lines that differ and, drawn as they stand, would look alike.
    /// Every one is drawn so that the two sides read differently.
    private static let lookalikes: [(left: String, right: String, what: String)] = [
        ("\u{FEFF}text", "text", "byte order mark"),
        ("a\u{00A0}b", "a b", "no-break space"),
        ("a\u{3000}b", "a b", "ideographic space"),
        ("a\u{2009}b", "a b", "thin space"),
        ("text ", "text", "trailing space"),
        ("text\t", "text", "trailing tab"),
        ("text   ", "text ", "more trailing spaces"),
        ("\ttext", "    text", "tab against spaces"),
        ("text\r", "text", "carriage return of a CRLF file"),
        ("a\u{200B}b", "ab", "zero-width space"),
        ("a\u{200C}b", "ab", "zero-width non-joiner"),
        ("a\u{202E}b", "ab", "right-to-left override"),
        ("a\u{2066}b", "ab", "bidirectional isolate"),
        ("a\u{0}b", "ab", "NUL"),
        ("a\u{7}b", "ab", "bell"),
        ("a\u{1B}[0mb", "a[0mb", "escape"),
        ("a\u{7F}b", "ab", "delete"),
        ("a\u{0085}b", "ab", "next line"),
        ("a\u{2028}b", "ab", "line separator"),
        ("a\u{2029}b", "ab", "paragraph separator"),
    ]

    /// What a reader SEES of some runs, which is not what their characters
    /// are: a plain run loses every scalar a text layout does not draw,
    /// spaces of every width become one space, a tab becomes four, and
    /// trailing spaces vanish; a marker is text and stays as written. Two
    /// strings that differ as scalars but have the same appearance are
    /// exactly the pair this feature must not show as two identical lines.
    private static func appearance(_ runs: [Presentation.Run]) -> String {
        var seen = ""
        for run in runs {
            if run.isEscape {
                seen += run.text
                continue
            }
            for scalar in run.text.unicodeScalars {
                if scalar == "\t" {
                    seen += "    "
                    continue
                }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: break
                case .spaceSeparator: seen += " "
                default: seen.unicodeScalars.append(scalar)
                }
            }
        }
        while seen.hasSuffix(" ") { seen.removeLast() }
        return seen
    }

    private static func raw(_ text: String) -> [Presentation.Run] {
        [Presentation.Run(text: text, isEscape: false)]
    }

    /// Compared by APPEARANCE, not by characters: "a no-break space and a
    /// space are drawn differently" is true of the scalars and says nothing
    /// about what the reader sees. The first expectation is the positive
    /// control: each fixture IS a pair that looks alike when drawn as it
    /// stands, so the second cannot pass on a pair that never needed a mark.
    @Test func aChangedLineWhoseSidesWouldLookAlikeIsDrawnSoTheyDoNot() {
        for pair in Self.lookalikes {
            #expect(pair.left != pair.right, Comment(rawValue: "\(pair.what): fixture is not a difference"))
            #expect(
                Self.appearance(Self.raw(pair.left)) == Self.appearance(Self.raw(pair.right)),
                Comment(rawValue: "\(pair.what): the fixture does not look alike as it stands"))
            let left = Self.appearance(Presentation.runs(of: pair.left, kind: .removed))
            let right = Self.appearance(Presentation.runs(of: pair.right, kind: .added))
            #expect(left != right, Comment(rawValue: "\(pair.what): both sides look like “\(left)”"))
            // Either way round.
            let leftAdded = Self.appearance(Presentation.runs(of: pair.left, kind: .added))
            let rightRemoved = Self.appearance(Presentation.runs(of: pair.right, kind: .removed))
            #expect(leftAdded != rightRemoved, Comment(rawValue: "\(pair.what), swapped"))
        }
        #expect(Self.lookalikes.count == 20)
    }

    @Test func theAppearanceReaderSeesWhatItShould() {
        #expect(Self.appearance(Self.raw("a\u{00A0}b")) == "a b")
        #expect(Self.appearance(Self.raw("\tx")) == "    x")
        #expect(Self.appearance(Self.raw("x  ")) == "x")
        #expect(Self.appearance(Self.raw("a\u{0}\u{FEFF}b")) == "ab")
        #expect(Self.appearance([Presentation.Run(text: "<U+0020>", isEscape: true)]) == "<U+0020>")
        #expect(Self.appearance(Self.raw("a b")) != Self.appearance(Self.raw("ab")))
    }

    /// The same scalars, asked of the real diff: a pair of files that differ
    /// ONLY in one such scalar produce a removal and an addition that read
    /// differently, through the whole path from `FileDiff` to the entry.
    @Test func aPairOfFilesDifferingInOneInvisibleScalarShowsItInTheListing() throws {
        for pair in Self.lookalikes {
            let hunks = FileDiff.hunks(left: ["head", pair.left, "tail"], right: ["head", pair.right, "tail"], context: 1)
            let lines = Self.lines(Presentation.listing(for: hunks))
            let removed = try #require(lines.first { $0.tone == .removed }, Comment(rawValue: pair.what))
            let added = try #require(lines.first { $0.tone == .added }, Comment(rawValue: pair.what))
            #expect(
                Self.appearance(removed.runs) != Self.appearance(added.runs),
                Comment(rawValue: pair.what))
            // Positive: the unchanged neighbours are drawn as they are.
            #expect(lines.first?.tone == .context)
            #expect(Self.visible(lines[0].runs) == "head")
        }
    }

    /// No scalar a text layout would act on instead of draw is ever handed
    /// to a `Text`: a NUL may end the string where it stands. In an unchanged
    /// line too.
    @Test func noPlainRunHoldsAScalarTheLayoutWouldActOn() {
        let hostile = Self.lookalikes.flatMap { [$0.left, $0.right] } + ["\u{0}\u{0}", "x\u{0}", "\u{0}x"]
        for text in hostile {
            for kind in [DiffLine.Kind.context, .added, .removed] {
                for run in Presentation.runs(of: text, kind: kind) where !run.isEscape {
                    for scalar in run.text.unicodeScalars {
                        let category = scalar.properties.generalCategory
                        let hidden = category == .control || category == .format
                            || category == .lineSeparator || category == .paragraphSeparator
                        // A tab and a space are the two scalars an unchanged
                        // line is allowed to carry plainly.
                        let allowed = (scalar == "\t" && kind == .context)
                        #expect(!hidden || allowed, "\(kind): U+\(String(scalar.value, radix: 16)) in a plain run")
                    }
                }
                // The runs lose nothing: the plain text and the scalars the
                // markers stand for are the text, in order.
                #expect(Presentation.runs(of: text, kind: kind).isEmpty == text.isEmpty)
            }
        }
    }

    /// Unchanged lines are not decorated: a tab-indented or space-trailed
    /// context line is the same on both sides, and marking every one would
    /// teach the reader to ignore markers. A control scalar still is marked.
    @Test func anUnchangedLineKeepsItsPlainWhitespaceAndStillMarksWhatCannotBeDrawn() {
        let plain = Presentation.runs(of: "\tindented  ", kind: .context)
        #expect(plain == [Presentation.Run(text: "\tindented  ", isEscape: false)])
        // The same text as a changed line is marked, in positions.
        let changed = Presentation.runs(of: "\tindented  ", kind: .removed)
        #expect(changed.filter(\.isEscape).map(\.text) == ["<U+0009>", "<U+0020>", "<U+0020>"])
        #expect(Self.visible(changed) == "<U+0009>indented<U+0020><U+0020>")
        // Inner spaces of a changed line are plain.
        #expect(Self.visible(Presentation.runs(of: "a b  c", kind: .added)) == "a b  c")
        // A NUL is marked in an unchanged line.
        let nul = Presentation.runs(of: "a\u{0}b", kind: .context)
        #expect(nul.map(\.text) == ["a", "<U+0000>", "b"])
        #expect(nul.map(\.isEscape) == [false, true, false])
    }

    @Test func aMarkerIsSpelledTheWayTheFileActionsSheetSpellsIt() {
        for scalar in ["\u{0}", "\u{FEFF}", "\u{202E}", "\u{2028}", "\u{0085}"] {
            let ours = Presentation.runs(of: scalar, kind: .added).map(\.text).joined()
            #expect(ours == FileActionPlanDisplay.visible(scalar), "U+\(scalar.unicodeScalars.first!.value)")
            #expect(ours.hasPrefix("<U+"))
        }
        // An astral scalar keeps all its digits.
        #expect(Self.visible(Presentation.runs(of: "\u{E0001}", kind: .added)) == "<U+E0001>")
    }

    /// What the invisible-scalar policy leaves alone, pinned so that nobody
    /// reads its absence as an oversight in either direction: the zero-width
    /// joiner and the variation selectors compose emoji and are let through
    /// by the file-actions sheet for the same reason. The other half, two
    /// lines that differ only in Unicode normalisation form, is
    /// `twoLinesDifferingOnlyInNormalisationFormAreAChangeWhoseSidesLookAlike`.
    @Test func theScalarsAnEmojiIsBuiltFromPassThroughAsTheFileActionsSheetDoes() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(Self.visible(Presentation.runs(of: family, kind: .added)) == family)
        #expect(FileActionPlanDisplay.visible(family) == family)
        let heart = "\u{2764}\u{FE0F}"
        #expect(Self.visible(Presentation.runs(of: heart, kind: .removed)) == heart)
        #expect(FileActionPlanDisplay.visible(heart) == heart)
    }

    /// The known residual, pinned: a precomposed and a decomposed spelling of
    /// the same text. The diff compares BYTES, so the pair is reported as a
    /// change (the folder overview called the row different for the same
    /// reason), and it is drawn as one removal and one addition. Neither side
    /// carries a marker, because every scalar in them is an ordinary letter
    /// or a combining mark, and the two read the same. That is the trade;
    /// this test is where it is written down rather than only said.
    @Test func twoLinesDifferingOnlyInNormalisationFormAreAChangeWhoseSidesLookAlike() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        // Swift's own equality calls them equal, which is why the diff does
        // not use it; the bytes differ.
        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))

        let hunks = FileDiff.hunks(left: [composed], right: [decomposed], context: 0)
        #expect(hunks.count == 1)
        let lines = Self.lines(Presentation.listing(for: hunks))
        // Positive: the change IS shown, as two lines.
        #expect(lines.map(\.tone) == [.removed, .added])
        let removed = try #require(lines.first { $0.tone == .removed })
        let added = try #require(lines.first { $0.tone == .added })
        #expect(Array(Self.visible(removed.runs).utf8) == Array(composed.utf8))
        #expect(Array(Self.visible(added.runs).utf8) == Array(decomposed.utf8))
        // The residual: no marker on either side, and they look alike.
        #expect(removed.runs.allSatisfy { !$0.isEscape })
        #expect(added.runs.allSatisfy { !$0.isEscape })
        #expect(Self.appearance(removed.runs) == Self.appearance(added.runs))
    }

    // MARK: - Catalogues

    /// Every wording this file adds, derived from the presentation: nothing
    /// here is a list of keys written down a second time.
    private static var usedWordings: [Presentation.Wording] {
        let refusals = Self.refusals.map { Presentation.wording(for: $0) }
        let failures = Self.allStates.map { Presentation.wording(forNoContentIn: $0) }
        return refusals + failures + Presentation.otherWordings
    }

    @Test func everyKeyIsInAllFourCataloguesAndTranslated() throws {
        let wordings = Self.usedWordings
        let keys = Array(Set(wordings.map(\.key))).sorted()
        // 4 refusals, 4 reasons for having no contents, and the rest.
        #expect(keys.count >= 4 + 4 + 12)
        let english = try Self.catalogue("en")
        for locale in Self.locales {
            let catalogue = try Self.catalogue(locale)
            for key in keys {
                let value = try #require(catalogue[key], "\(locale) lacks \(key)")
                #expect(!value.isEmpty, "\(locale) \(key) is empty")
                if locale != "en" {
                    #expect(value != english[key], "\(locale) \(key) is the English text")
                }
                #expect(
                    Self.placeholders(in: value) == Self.placeholders(in: try #require(english[key])),
                    "\(locale) \(key) changes its placeholders")
            }
        }
    }

    @Test func theEnglishDefaultsTheCodeCarriesAreTheEnglishCatalogue() throws {
        let english = try Self.catalogue("en")
        let wordings = Self.usedWordings
        #expect(wordings.count >= 4 + 4 + 12)
        for wording in wordings {
            #expect(english[wording.key] == wording.english, "\(wording.key)")
        }
    }

    /// What the refusal says an ordinary-file-less side IS. `diffUnmapped`
    /// refuses a directory and a link and nothing else: `.other` is what a
    /// listing answers when a type was not reported, and goes on to the fetch.
    /// So a sentence that also names "a special entry" describes a case that
    /// cannot produce it, in a string the user has no way to check. The old
    /// ending, in each catalogue's words, was "a folder, a link or a special
    /// entry". The positive halves are beside the negative: each text names a
    /// folder AND a link, so a lookup that found nothing cannot pass.
    private static let refusalKinds:
        [String: (folder: String, link: String, special: String)] = [
            "en": ("folder", "link", "special entry"),
            "de": ("Ordner", "Link", "Sondereintrag"),
            "fr": ("dossier", "lien", "entrée spéciale"),
            "pl": ("folder", "dowiązanie", "wpis specjalny"),
        ]

    @Test func theNotAnOrdinaryFileSentenceNamesAFolderAndALinkAndNoSpecialEntry() throws {
        #expect(Set(Self.refusalKinds.keys) == Set(Self.locales))
        let key = Presentation.wording(for: .notAnOrdinaryFile(side: .left, path: "/p")).key
        for locale in Self.locales {
            let words = try #require(Self.refusalKinds[locale])
            let text = try #require(try Self.catalogue(locale)[key], "\(locale) lacks \(key)")
            #expect(text.contains(words.folder), "\(locale): \(text)")
            #expect(text.contains(words.link), "\(locale): \(text)")
            #expect(!text.contains(words.special), "\(locale): \(text)")
        }
        // The English the code carries is the English catalogue, so it cannot
        // keep the clause the catalogue lost.
        let carried = Presentation.wording(for: .notAnOrdinaryFile(side: .left, path: "/p")).english
        #expect(carried.contains("folder") && carried.contains("link"))
        #expect(!carried.contains("special entry"))
    }

    @Test func noTwoWordingsShareAKeyOrAnEnglishText() {
        let wordings = Self.usedWordings
        let unique = Dictionary(grouping: wordings, by: \.key).mapValues { Set($0.map(\.english)) }
        // A key repeated in the list (a state group) carries one text.
        #expect(unique.values.allSatisfy { $0.count == 1 })
        let byText = Dictionary(grouping: Set(wordings.map(\.key)), by: { key in
            wordings.first { $0.key == key }!.english
        })
        #expect(byText.values.allSatisfy { $0.count == 1 }, "two keys carry one text")
    }

    @Test func aKeyTheCatalogueDoesNotHoldFallsBackToEnglishNotToItsOwnName() {
        let wording = Presentation.Wording(key: "compare.diff.noSuchKey", english: "An English sentence.")
        #expect(wording.text == "An English sentence.")
        // Positive: a real key is answered by the catalogue.
        #expect(Self.resolved(Presentation.pending.key) != nil)
        #expect(Presentation.pending.text == Self.resolved(Presentation.pending.key))
    }

    private static func placeholders(in value: String) -> [String] {
        value.components(separatedBy: "%").dropFirst().compactMap { piece in
            if piece.hasPrefix("@") { return "%@" }
            if piece.hasPrefix("lld") { return "%lld" }
            return piece.isEmpty ? nil : "%?"
        }
    }

    // MARK: - Fetching: the model

    private struct Rig {
        let comparison: Comparison
        let root: URL
    }

    private func folderRig(
        left: [BytePath: Data], right: [BytePath: Data],
        onLeftRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonDiffViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let comparison = Comparison(
            left: MemoryFS(files: under("/L", left), onRead: onLeftRead),
            leftRoot: "/L",
            right: MemoryFS(files: under("/R", right)),
            rightRoot: "/R", algorithm: .sha256, transferQueue: TransferQueueViewModel(),
            temporaryRoot: root)
        comparison.start()
        await comparison.waitForWalk()
        return Rig(comparison: comparison, root: root)
    }

    private func pairRig(left: Data, right: Data) -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonDiffViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let comparison = Comparison(
            left: MemoryFS(files: ["/L/f": left]), leftRoot: "/L/f",
            right: MemoryFS(files: ["/R/f": right]), rightRoot: "/R/f", algorithm: .sha256,
            transferQueue: TransferQueueViewModel(), kind: .filePair, temporaryRoot: root)
        return Rig(comparison: comparison, root: root)
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// The text of every line of a listing screen, with its sign.
    private func shown(_ screen: Presentation.Screen) -> [String]? {
        guard case .listing(let listing) = screen else { return nil }
        return Self.lines(listing).map { $0.sign + Self.visible($0.runs) }
    }

    @Test func aRowShowsItsOwnContentsAndSelectingAnotherReplacesThem() async throws {
        let rig = try await folderRig(
            left: ["a": data("alpha\nsame"), "b": data("beta\nsame")],
            right: ["a": data("ALPHA\nsame"), "b": data("BETA!\nsame")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let a = Presentation.Target.row(index: 0)
        let b = Presentation.Target.row(index: 1)

        await model.load(a, on: rig.comparison)
        #expect(model.loaded?.target == a)
        #expect(shown(Presentation.screen(target: a, loaded: model.loaded)) == ["-alpha", "+ALPHA", " same"])

        await model.load(b, on: rig.comparison)
        #expect(model.loaded?.target == b)
        #expect(shown(Presentation.screen(target: b, loaded: model.loaded)) == ["-beta", "+BETA!", " same"])
        // The first row's result is not what a screen for the first row shows
        // any more: it is fetching again, not stale.
        guard case .notice(let notice) = Presentation.screen(target: a, loaded: model.loaded) else {
            Issue.record("b's result was shown for a")
            return
        }
        #expect(notice.style == .pending)
    }

    @Test func aFilePairShowsItsDiffWithoutAnyRow() async throws {
        let rig = pairRig(left: data("one\ntwo"), right: data("one\n2"))
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        await model.load(.filePair, on: rig.comparison)
        #expect(shown(Presentation.screen(target: .filePair, loaded: model.loaded)) == [" one", "-two", "+2"])
    }

    /// The last change of a file is on screen, not only the first: lines 3
    /// and 37 of forty both reach the listing through the model.
    @Test func aFileWithTwoSeparatedChangesShowsBothThroughTheModel() async throws {
        let rig = pairRig(
            left: data(Self.numbered(40).joined(separator: "\n")),
            right: data(Self.numbered(40, changing: [3, 37]).joined(separator: "\n")))
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        await model.load(.filePair, on: rig.comparison)
        guard case .listing(let listing) = Presentation.screen(target: .filePair, loaded: model.loaded)
        else {
            Issue.record("expected a listing")
            return
        }
        #expect(Self.sections(listing).map(\.header) == ["@@ -1,6 +1,6 @@", "@@ -34,7 +34,7 @@"])
        let texts = shown(.listing(listing)) ?? []
        #expect(texts.contains("-line 3") && texts.contains("+changed 3"))
        #expect(texts.contains("-line 37") && texts.contains("+changed 37"))
    }

    @Test func twoIdenticalFilesSayNoLineDiffersAndNothingElse() async throws {
        let rig = pairRig(left: data("x\ny"), right: data("x\ny"))
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        await model.load(.filePair, on: rig.comparison)
        guard case .notice(let notice) = Presentation.screen(target: .filePair, loaded: model.loaded) else {
            Issue.record("expected a notice")
            return
        }
        #expect(notice.style == .identical)
        #expect(notice.text == Presentation.identical.text)
    }

    @Test func eachRefusalIsReachedFromRealBytesAndShownInPlaceOfTheListing() async throws {
        let cases: [(name: String, left: Data, right: Data, refusal: DiffRefusal)] = [
            ("binary", Data([0x61, 0x00, 0x62]), data("text"), .binary),
            ("latin1", Data([0x63, 0x61, 0x66, 0xE9]), data("cafe"), .notUTF8),
        ]
        var seen: Set<String> = []
        for item in cases {
            let rig = pairRig(left: item.left, right: item.right)
            defer { try? FileManager.default.removeItem(at: rig.root) }
            let model = ComparisonDiffModel()
            await model.load(.filePair, on: rig.comparison)
            guard case .notice(let notice) = Presentation.screen(target: .filePair, loaded: model.loaded)
            else {
                Issue.record("\(item.name): expected a notice")
                continue
            }
            #expect(notice.style == .refusal, Comment(rawValue: item.name))
            #expect(notice.text == Presentation.refusalText(item.refusal), Comment(rawValue: item.name))
            seen.insert(notice.text)
        }
        #expect(seen.count == 2)
    }

    @Test func aRowWithNothingToCompareFailsWithItsOwnTextAndAReleasedSessionWithAnother() async throws {
        let rig = try await folderRig(
            left: ["only": data("x"), "both": data("1")], right: ["both": data("22")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        // Rows come back in the pairing's order: "both" then "only".
        #expect(rig.comparison.rows.map(\.relativePath) == ["both", "only"])
        let row = Presentation.Target.row(index: 1)
        let both = Presentation.Target.row(index: 0)
        let model = ComparisonDiffModel()

        await model.load(row, on: rig.comparison)
        guard case .notice(let noContent) = Presentation.screen(target: row, loaded: model.loaded) else {
            Issue.record("expected a notice")
            return
        }
        #expect(noContent.style == .failure)
        #expect(noContent.text == Presentation.failureText(for: ComparisonFetchError.noContentToCompare(.onlyLeft)))

        // Positive: a row with contents is diffed while the session is open.
        await model.load(both, on: rig.comparison)
        #expect(shown(Presentation.screen(target: both, loaded: model.loaded)) == ["-1", "+22"])

        rig.comparison.releaseFileSystems()
        await model.load(both, on: rig.comparison)
        guard case .notice(let closed) = Presentation.screen(target: both, loaded: model.loaded) else {
            Issue.record("expected a notice")
            return
        }
        #expect(closed.style == .failure)
        #expect(closed.text == Presentation.failureText(for: ComparisonFetchError.sessionClosed))
        #expect(closed.text != noContent.text)
    }

    @Test func aRowThatIsNoLongerInTheListIsNotDiffedAsAnotherRow() async throws {
        let rig = try await folderRig(left: ["a": data("1")], right: ["a": data("2")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let gone = Presentation.Target.row(index: 7)
        await model.load(gone, on: rig.comparison)
        guard case .notice(let notice) = Presentation.screen(target: gone, loaded: model.loaded) else {
            Issue.record("expected a notice")
            return
        }
        #expect(notice.style == .failure)
        #expect(notice.text == Presentation.failureText(for: ComparisonFetchError.rowOutOfRange(0)))
    }

    /// A load that was cancelled (the selection moved on) writes nothing: a
    /// late result must not land on a screen that has gone on to another row.
    @Test func aCancelledLoadWritesNothing() async throws {
        let rig = try await folderRig(left: ["a": data("1")], right: ["a": data("2")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let task = Task { await model.load(.row(index: 0), on: rig.comparison) }
        task.cancel()
        await task.value
        #expect(model.loaded == nil)
        // Positive: the same load, not cancelled, does write.
        await model.load(.row(index: 0), on: rig.comparison)
        #expect(model.loaded?.target == .row(index: 0))
    }

    /// A fetch held open at the moment its bytes are read: the test is told
    /// when the read of `path` has begun, and the read ends when it says.
    private final class Gate: Sendable {
        let path: String
        private let entered: AsyncStream<Void>
        private let release: AsyncStream<Void>
        private let enteredIn: AsyncStream<Void>.Continuation
        private let releaseIn: AsyncStream<Void>.Continuation
        private let opened = Mutex(false)

        init(path: String) {
            self.path = path
            let (entered, enteredIn) = AsyncStream<Void>.makeStream()
            let (release, releaseIn) = AsyncStream<Void>.makeStream()
            self.entered = entered
            self.release = release
            self.enteredIn = enteredIn
            self.releaseIn = releaseIn
        }

        /// The hook the file system calls on every read. Once the gate has
        /// been opened it lets every read through at once.
        var hook: @Sendable (String) async -> Void {
            { [self] read in
                guard read == path, !opened.withLock({ $0 }) else { return }
                enteredIn.yield()
                for await _ in release { break }
            }
        }

        func waitUntilEntered() async { for await _ in entered { return } }

        func open() {
            opened.withLock { $0 = true }
            releaseIn.yield()
        }
    }

    /// While a load is on its way, the result of the one before it is not
    /// there to be shown: not for the new row, and not for the old one.
    @Test func aLoadInFlightHoldsNoResultAtAll() async throws {
        let gate = Gate(path: "/L/b")
        let rig = try await folderRig(
            left: ["a": data("1"), "b": data("2")], right: ["a": data("11"), "b": data("22")],
            onLeftRead: gate.hook)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let a = Presentation.Target.row(index: 0)
        let b = Presentation.Target.row(index: 1)

        await model.load(a, on: rig.comparison)
        // Positive: a's result is there, so its absence below is the load's.
        #expect(model.loaded?.target == a)

        let task = Task { await model.load(b, on: rig.comparison) }
        await gate.waitUntilEntered()
        #expect(model.loaded == nil)
        for target in [a, b] {
            guard case .notice(let notice) = Presentation.screen(target: target, loaded: model.loaded)
            else {
                Issue.record("a listing was shown while the fetch was on its way")
                continue
            }
            #expect(notice.style == .pending)
        }

        gate.open()
        await task.value
        #expect(shown(Presentation.screen(target: b, loaded: model.loaded)) == ["-2", "+22"])
    }

    /// Two loads that are NOT cancelled and overlap: the first one's answer
    /// arrives while the second is still on its way. Each stamps what it
    /// writes with its own target, so the second's result is the second's.
    /// (In the window the first would have been cancelled by
    /// `.task(id:)`; the model must not depend on that for its stamp.)
    @Test func twoLoadsThatOverlapEachWriteTheirOwnTarget() async throws {
        let gateA = Gate(path: "/L/a")
        let gateB = Gate(path: "/L/b")
        let rig = try await folderRig(
            left: ["a": data("1"), "b": data("2")], right: ["a": data("11"), "b": data("22")],
            onLeftRead: { path in
                await gateA.hook(path)
                await gateB.hook(path)
            })
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let a = Presentation.Target.row(index: 0)
        let b = Presentation.Target.row(index: 1)

        let first = Task { await model.load(a, on: rig.comparison) }
        await gateA.waitUntilEntered()
        let second = Task { await model.load(b, on: rig.comparison) }
        gateA.open()
        await first.value
        // Positive: the first answer did land, while the second is unfinished.
        #expect(model.loaded?.target == a)
        #expect(shown(Presentation.screen(target: a, loaded: model.loaded)) == ["-1", "+11"])

        await gateB.waitUntilEntered()
        gateB.open()
        await second.value
        #expect(model.loaded?.target == b)
        #expect(shown(Presentation.screen(target: b, loaded: model.loaded)) == ["-2", "+22"])
    }

    /// A cancel that lands while the bytes are being fetched: the answer
    /// that comes back afterwards is dropped.
    @Test func aLoadCancelledMidFlightWritesNothingWhenItsAnswerArrives() async throws {
        let gate = Gate(path: "/L/b")
        let rig = try await folderRig(
            left: ["a": data("1"), "b": data("2")], right: ["a": data("11"), "b": data("22")],
            onLeftRead: gate.hook)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()

        let task = Task { await model.load(.row(index: 1), on: rig.comparison) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.open()
        await task.value
        #expect(model.loaded == nil)
        // Positive: the same load, left alone, does write.
        let again = Task { await model.load(.row(index: 1), on: rig.comparison) }
        // (The gate is open for good now, so this read is not held.)
        await again.value
        #expect(model.loaded?.target == .row(index: 1))
    }

    /// **Two genuinely distinct files whose names are `==` as `String`s.**
    /// One is spelled U+00E4 and one `a` + U+0308; `ComparisonPairing.pairs`
    /// keeps them apart (pass 1 keys on the UTF-8 bytes, pass 2 refuses a key
    /// two items share), so the walk produces two correctly classified rows.
    /// Selecting the second has to show the SECOND file's diff.
    ///
    /// Measured 2026-10-15, before the row's identity became its position:
    /// `index(of: path, in: rows)` answered 0 for both rows, so the lower half
    /// showed the first row's diff under the second row's selection — and the
    /// two rows shared one SwiftUI id.
    @Test func twoRowsWhoseNamesAreEqualAsStringsEachShowTheirOwnDiff() async throws {
        let nfc = "\u{00E4}"
        let nfd = "a\u{0308}"
        // The premise, in one line: one string to Swift, two files on disk.
        #expect(nfc == nfd)
        #expect(Array(nfc.utf8) != Array(nfd.utf8))
        let rig = try await folderRig(
            left: [BytePath(nfd): data("one"), BytePath(nfc): data("alpha")],
            right: [BytePath(nfd): data("twelve"), BytePath(nfc): data("alpha")])
        defer { try? FileManager.default.removeItem(at: rig.root) }

        // The order is the pairing's: same NFC form, so the UTF-8 bytes
        // decide, and `a` (0x61) precedes `ä` (0xC3 0xA4).
        #expect(
            rig.comparison.rows.map { Array($0.relativePath.utf8) }
                == [Array(nfd.utf8), Array(nfc.utf8)])
        // Positive: the two rows are classified differently, so a diff shown
        // for the wrong one is visible rather than coincidentally right.
        #expect(
            rig.comparison.rows.map(\.state)
                == [.differs, .undetermined(.checksumUnavailable)])

        let model = ComparisonDiffModel()
        await model.load(.row(index: 1), on: rig.comparison)
        #expect(model.loaded?.target == .row(index: 1))
        // The SECOND row's two files hold the same text, so its diff is empty
        // — and an empty diff is its own screen, never a listing.
        guard case .notice(let identical) = Presentation.screen(
            target: .row(index: 1), loaded: model.loaded)
        else {
            Issue.record("the second row's empty diff is a notice")
            return
        }
        #expect(identical.text == Presentation.identical.text)

        await model.load(.row(index: 0), on: rig.comparison)
        #expect(model.loaded?.target == .row(index: 0))
        #expect(
            shown(Presentation.screen(target: .row(index: 0), loaded: model.loaded))
                == ["-one", "+twelve"])
    }

    @Test func selectingNothingForgetsTheLastResult() async throws {
        let rig = pairRig(left: data("a"), right: data("b"))
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        await model.load(.filePair, on: rig.comparison)
        #expect(model.loaded != nil)
        await model.load(nil, on: rig.comparison)
        #expect(model.loaded == nil)
    }

    // MARK: - The view draws what the functions return

    private static func code(_ file: String) throws -> String {
        try SourceCorpus.code(of: appKit.appendingPathComponent(file))
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The core diff types, spelled the ways a stored property, a call or an
    /// annotation would name them. Not the bare names: `ComparisonDiffLineView`
    /// contains `DiffLine`.
    private static let coreSpellings = [
        "DiffHunk(", "[DiffHunk]", ": DiffHunk", "DiffLine(", "[DiffLine]", ": DiffLine",
        "DiffLine.Kind", "DiffRefusal",
    ]

    private static let slicing = [
        "dropFirst", "dropLast", ".prefix(", ".suffix(", ".filter", "reversed", "sorted",
        "shuffled", "removeFirst", ".first(", ".last(", "firstIndex", ".map", ".contains", ".enumerated",
    ]

    /// The diff file split at its views. Everything above `ComparisonDiffView`
    /// is the presentation and the model.
    private static func viewCode() throws -> (
        container: String, view: String, header: String, line: String, notice: String
    ) {
        let source = try Self.code("ComparisonDiffView.swift")
        func start(_ name: String) throws -> Range<String.Index> {
            try #require(source.range(of: "struct \(name): View"), "\(name)")
        }
        let container = try start("ComparisonResultView")
        let view = try start("ComparisonDiffView")
        let header = try start("ComparisonDiffHeaderView")
        let line = try start("ComparisonDiffLineView")
        let notice = try start("ComparisonDiffNoticeView")
        #expect(container.lowerBound < view.lowerBound)
        #expect(view.lowerBound < header.lowerBound)
        #expect(header.lowerBound < line.lowerBound)
        #expect(line.lowerBound < notice.lowerBound)
        return (
            String(source[container.lowerBound..<view.lowerBound]),
            String(source[view.lowerBound..<header.lowerBound]),
            String(source[header.lowerBound..<line.lowerBound]),
            String(source[line.lowerBound..<notice.lowerBound]),
            String(source[notice.lowerBound...])
        )
    }

    /// Every member read in `code`, off whatever value it is read: a root
    /// spelled with a lowercase letter or an underscore, followed by one or
    /// more member components — the whole chain is one read, so a slice
    /// applied to a sequence is a read of its own name and not of the
    /// sequence's. A root spelled with a capital is a type rather than a
    /// value, so neither it nor the components hanging off it are read here:
    /// a colour constant is not something the view knows.
    ///
    /// It asks for no list of roots, and that is the point of it. A scan that
    /// is told which names to look at bounds how those names are spelled and
    /// says nothing about any other value in scope — and the scanned region
    /// has values in scope that the views are handed for one purpose and
    /// could read for another.
    ///
    /// Whitespace may stand on either side of a dot, because Swift lets a
    /// chain break across lines and a scan that needed the dot against its
    /// root bought one spelling of a read while leaving the next line's
    /// spelling of the same read unseen. Each match is reported with its
    /// whitespace removed, so a read is one name however it is wrapped. The
    /// cost of that tolerance is a keyword standing in front of a leading
    /// dot: the roots named below are language keywords, which cannot be an
    /// identifier here, and skipping them leaves a set that is reads and
    /// nothing else. The list being short is safe rather than lucky — the
    /// caller asserts set EQUALITY, so a keyword nobody skipped arrives as a
    /// loud extra entry and not as a hole.
    private static func allMemberReads(in code: String) -> Set<String> {
        let keywords = "(?!(?:case|return|try|await|throw|is|as|in)\\b)"
        let pattern = "(?<![A-Za-z0-9_.$])\(keywords)[a-z_][A-Za-z0-9_]*"
            + "(?:\\s*\\.\\s*[A-Za-z_][A-Za-z0-9_]*)+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..., in: code)
        return Set(
            regex.matches(in: code, range: range).compactMap { match in
                Range(match.range, in: code).map {
                    String(code[$0]).components(separatedBy: .whitespacesAndNewlines).joined()
                }
            })
    }

    /// Every dotted name in `code` that is handed something: a method call or
    /// a modifier written with a leading dot, taking an argument list or a
    /// trailing closure. The closure form is here because a modifier needs no
    /// parentheses at all — one written with a brace alone was invisible to a
    /// scan that required an open paren, and so could not be rejected by any
    /// list of names. Whitespace may stand between the name and either
    /// delimiter, and the delimiter itself is not part of the name reported.
    private static func dottedCalls(in code: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "\\.[a-z][A-Za-z0-9]*\\s*[({]") else {
            return []
        }
        let range = NSRange(code.startIndex..., in: code)
        return Set(
            regex.matches(in: code, range: range).compactMap { match in
                Range(match.range, in: code).map {
                    String(code[$0].dropFirst().dropLast())
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            })
    }

    /// The dotted names the views hand something to: the presentation and
    /// model functions they give work to, the enum cases they match, and the
    /// modifiers that style a row without placing it anywhere but where it
    /// stands. Two of them are neither a call nor a modifier — a condition
    /// and a subject written over a member read open a brace, and the scan
    /// cannot tell that brace from a modifier's trailing closure. Both are
    /// member reads that the read list below names as well, so they are
    /// listed here rather than carved out of the scan: a carve-out for a
    /// name read off an identifier would have let a paren-free modifier
    /// written the same way straight through, which is the hole this list
    /// was just widened to close.
    ///
    /// What this list cannot bound is what any listed modifier is GIVEN. A
    /// name appearing here says a decision was made about the modifier, not
    /// about its arguments, and the arguments are where a value that hides
    /// content lives: a width or a padding set small enough collapses what
    /// it measures, and the name on it is still the same listed name. The
    /// sign column was measured collapsing that way with every token in this
    /// file untouched — which leaves the tint as the only thing telling a
    /// changed line apart, the distinction the sign exists to carry without
    /// colour. Extending a list of names is no defence against it; a test
    /// that reads the value is.
    private static let allowedCalls: Set<String> = [
        "accessibilityElement", "accessibilityLabel", "attributed", "background", "controlSize",
        "fixedSize", "font", "foregroundStyle", "frame", "header", "kind", "legend", "line",
        "listing", "load", "notice", "padding", "screen", "showsOverview", "showsProgress",
        "system", "target", "task", "textSelection",
    ]

    /// Every member read the views make, off any value in scope. Built by
    /// running the scan over the views and reading what is there: what each
    /// one is handed and nothing beside it. The one entry that is not a read
    /// of a handed value is the modifier chained under the local that holds
    /// the diff in the container, which the scan sees because the chain
    /// breaks across lines — it is a name of ours, so it is listed here
    /// rather than skipped in the scan.
    private static let allowedMemberReads: Set<String> = [
        "comparison.kind", "diff.frame", "entry.kindLabel", "entry.leftNumber",
        "entry.rightNumber", "entry.runs", "entry.sign", "entry.tint", "listing.numberDigits",
        "listing.rows", "model.load", "model.loaded", "notice.emphasis", "notice.showsProgress",
        "notice.text", "row.kind",
    ]

    @Test func theCallScanReadsLeadingDotsAndNothingElse() {
        let code = "a.b(c) d.e f(g).h(i) .j( x.k (y) Color.red.opacity(0.1) p.q { r } .s {"
        #expect(Self.dottedCalls(in: code) == ["b", "h", "j", "k", "opacity", "q", "s"])
        #expect(Self.dottedCalls(in: "no calls here").isEmpty)
    }

    @Test func theMemberReadScanSeesEveryChainAndNoTypeName() {
        let code = "a.b a.b.c xa.b a.d(x) b.e a . f Color.white Color.red.opacity"
        #expect(Self.allMemberReads(in: code) == ["a.b", "a.b.c", "xa.b", "a.d", "b.e", "a.f"])
        #expect(Self.allMemberReads(in: "no reads here").isEmpty)
    }

    /// The same scan on the spellings whitespace tolerance buys and costs: a
    /// chain broken across lines is the read it would be on one line, a
    /// keyword in front of a leading dot is not a read at all, and an
    /// identifier that merely begins with a keyword's letters is.
    @Test func theMemberReadScanFollowsAChainAcrossLinesAndSkipsAKeywordRoot() {
        let wrapped = "comparison\n    .rows.isEmpty"
        #expect(Self.allMemberReads(in: wrapped) == ["comparison.rows.isEmpty"])
        #expect(Self.allMemberReads(in: "case .legend(x) return .foo(y) try .z(w)").isEmpty)
        #expect(Self.allMemberReads(in: "caseLabel.kind") == ["caseLabel.kind"])
    }

    /// What is wrong with `tokens` in `code`: each must occur exactly once,
    /// and in the order given. Empty means nothing is. The presence is
    /// checked first and is the point: an ordering over a token that was
    /// renamed away compares two missing positions and reads like a check that
    /// is satisfied.
    private static func orderProblems(_ tokens: [String], in code: String) -> [String] {
        var problems: [String] = []
        var positions: [String.Index] = []
        for token in tokens {
            let count = occurrences(of: token, in: code)
            if count != 1 { problems.append("\(token) occurs \(count) times, not once") }
            if let range = code.range(of: token) { positions.append(range.lowerBound) }
        }
        if problems.isEmpty, positions != positions.sorted() {
            problems.append("out of order: \(tokens)")
        }
        return problems
    }

    private static func expectOrder(
        _ tokens: [String], in code: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let problems = orderProblems(tokens, in: code)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")),
                sourceLocation: sourceLocation)
    }

    /// The instrument itself: it reports a token that is missing, one that
    /// occurs twice, and a wrong order, and reports nothing for the right one.
    @Test func theOrderCheckReportsAMissingTokenARepeatedOneAndAWrongOrder() {
        #expect(Self.orderProblems(["a(", "b("], in: "a( b(").isEmpty)
        #expect(Self.orderProblems(["a(", "b("], in: "b( a(") == ["out of order: [\"a(\", \"b(\"]"])
        #expect(Self.orderProblems(["a(", "renamed("], in: "a( b(").count == 1)
        #expect(Self.orderProblems(["a(", "b("], in: "a( b( b(").count == 1)
        // A missing token is reported even when the rest is in order.
        #expect(Self.orderProblems(["renamed(", "other("], in: "a( b(").count == 2)
    }

    /// The residual scan: the views iterate each function's output, once, and
    /// hold nothing to rebind or slice. Every negative check has the positive
    /// one beside it.
    @Test func theViewsDrawOnlyWhatTheFunctionsReturn() throws {
        let (container, view, header, line, notice) = try Self.viewCode()

        // Positive: one call of each function, one iteration of each output.
        #expect(
            Self.occurrences(
                of: "ComparisonDiffPresentation.screen(target: target, loaded: model.loaded)", in: view)
                == 1)
        #expect(Self.occurrences(of: "await model.load(target, on: comparison)", in: view) == 1)
        #expect(Self.occurrences(of: ".task(id: target)", in: view) == 1)
        // ONE iteration over ONE sequence of rows, and no other: with no
        // second collection and no pair of subviews, the order drawn is the
        // order the rows are in. A reordering is a reordering of that array,
        // which the presentation's own tests see.
        #expect(Self.occurrences(of: "ForEach(listing.rows)", in: view) == 1)
        #expect(Self.occurrences(of: "ForEach(", in: view) == 1)
        #expect(Self.occurrences(of: "switch row.kind {", in: view) == 1)
        // What the view hands on is exactly what the presentation returned:
        // the screen goes from `screen(...)` to `content(...)` to the switch,
        // and nothing is applied to it on the way.
        #expect(
            Self.occurrences(
                of: "content(ComparisonDiffPresentation.screen(target: target, loaded: model.loaded))",
                in: view) == 1)
        #expect(Self.occurrences(of: "switch screen {", in: view) == 1)
        #expect(Self.occurrences(of: "case .legend(let text)", in: view) == 1)
        #expect(Self.occurrences(of: "case .header(let text)", in: view) == 1)
        #expect(Self.occurrences(of: "case .line(let entry)", in: view) == 1)
        #expect(Self.occurrences(of: "Text(text)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonDiffHeaderView(text: text)", in: view) == 1)
        #expect(
            Self.occurrences(
                of: "ComparisonDiffLineView(entry: entry, digits: listing.numberDigits)", in: view)
                == 1)
        #expect(!view.contains("hunks"))
        // And the only calls and modifiers anywhere in the views. Reading the
        // rows in the right order says nothing about how they are laid out:
        // `.scaleEffect(y: -1)` on the list and on each row draws them upright
        // in the opposite order with every token above untouched (measured).
        // So a layout modifier nobody listed is not silently fine, and adding
        // one is a decision made here.
        let everything = [container, view, header, line, notice].joined(separator: "\n")
        let calls = Self.dottedCalls(in: everything)
        #expect(
            calls.subtracting(Self.allowedCalls).isEmpty,
            Comment(rawValue: "\(calls.subtracting(Self.allowedCalls).sorted())"))
        // Positive: the scan reads the views at all, and every listed call is
        // used, so the list is not a set of names nothing uses.
        #expect(calls == Self.allowedCalls)
        // Every member read anywhere in the views, off any value in scope and
        // not only off the three the rows arrive in. A read nobody listed is
        // a function standing between what the presentation returned and what
        // is drawn, and no test of the presentation sees it — a leaf gated on
        // some other collection in scope draws a listing with every header
        // and not one line, and every token above it stays true.
        let read = Self.allMemberReads(in: everything)
        #expect(
            read.subtracting(Self.allowedMemberReads).isEmpty,
            Comment(rawValue: "\(read.subtracting(Self.allowedMemberReads).sorted())"))
        // Positive: each listed read is actually there, so the set above is
        // not empty because the scan found nothing.
        #expect(read == Self.allowedMemberReads)
        #expect(Self.occurrences(of: "ComparisonDiffNoticeView(notice: notice)", in: view) == 1)
        #expect(Self.occurrences(of: "case .notice(let notice)", in: view) == 1)
        #expect(Self.occurrences(of: "case .listing(let listing)", in: view) == 1)
        // Negative: nothing is sliced, reordered or relabelled in the view.
        for token in Self.slicing {
            #expect(!view.contains(token), "the view uses \(token)")
        }
        for core in Self.coreSpellings { #expect(!view.contains(core), Comment(rawValue: core)) }
        #expect(!view.contains(".refusal"))
        #expect(!view.contains(".failure"))
        #expect(!view.contains("default:"))

        // The header draws its text, and holds no collection and no line.
        #expect(Self.occurrences(of: "Text(text)", in: header) == 1)
        #expect(Self.occurrences(of: "ForEach", in: header) == 0)
        #expect(Self.occurrences(of: "ForEach", in: line) == 0)
        #expect(Self.occurrences(of: "ForEach", in: notice) == 0)
        #expect(!header.contains("LineView"))
        // The line draws the values of its entry: both numbers, the sign, the
        // runs (through the one attribution function), the tint.
        #expect(Self.occurrences(of: "Text(entry.leftNumber)", in: line) == 1)
        #expect(Self.occurrences(of: "Text(entry.rightNumber)", in: line) == 1)
        // In that order: the left gutter shows the left file's numbers. These
        // four ARE siblings of one row, so their order is a source order.
        Self.expectOrder(
            ["Text(entry.leftNumber)", "Text(entry.rightNumber)", "Text(entry.sign)",
             "FileActionPlanDisplay.attributed(entry.runs)"], in: line)
        #expect(Self.occurrences(of: "Text(entry.sign)", in: line) == 1)
        #expect(Self.occurrences(of: "FileActionPlanDisplay.attributed(entry.runs)", in: line) == 1)
        #expect(Self.occurrences(of: ".background(entry.tint)", in: line) == 1)
        #expect(Self.occurrences(of: ".accessibilityLabel(entry.kindLabel)", in: line) == 1)
        // The notice draws its text, and shows progress for the pending kind
        // by asking the entry.
        #expect(Self.occurrences(of: "Text(notice.text)", in: notice) == 1)
        #expect(Self.occurrences(of: "notice.showsProgress", in: notice) == 1)
        #expect(Self.occurrences(of: "notice.emphasis", in: notice) == 1)

        for part in [header, line, notice] {
            #expect(!part.contains("comparison"))
            for core in Self.coreSpellings { #expect(!part.contains(core), Comment(rawValue: core)) }
            #expect(!part.contains("ComparisonRow"))
            #expect(!part.contains("ComparisonState"))
            #expect(!part.contains("Task"))
            #expect(!part.contains("switch"))
            #expect(!part.contains("default:"))
            #expect(!part.contains(".added"))
            #expect(!part.contains(".removed"))
            #expect(!part.contains(".context"))
            #expect(!part.contains(".failure"))
            #expect(!part.contains(".refusal"))
            // The type annotation names the presentation once (the header
            // holds a plain string and names it not at all); no call does.
            #expect(
                Self.occurrences(of: "Presentation", in: part) == (part == header ? 0 : 1))
            for token in Self.slicing {
                #expect(!part.contains(token), "a part uses \(token)")
            }
        }

        // The container asks which target and whether to draw the overview.
        #expect(Self.occurrences(of: "ComparisonDiffPresentation.target(", in: container) == 1)
        #expect(container.contains("kind: comparison.kind, selection: selection"))
        #expect(container.contains("ComparisonOverviewPresentation.showsOverview(for: comparison.kind)"))
        #expect(container.contains("ComparisonOverviewView(comparison: comparison, selection: $selection)"))
        #expect(Self.occurrences(of: "ComparisonDiffView(", in: container) == 1)
        #expect(!container.contains(".folders"))
        #expect(!container.contains(".filePair"))
    }

    /// The diff is fetched in one place, by the entry points the model
    /// offers for its kind, and the row is resolved from its POSITION in one
    /// function. It used to be found by path, which is not an identity.
    @Test func theModelCallsTheTwoEntryPointsOnceEachAndFindsTheRowByPosition() throws {
        let code = try Self.code("ComparisonDiffView.swift")
        #expect(Self.occurrences(of: "diffFilePair()", in: code) == 1)
        #expect(Self.occurrences(of: "diff(forRowAt: index)", in: code) == 1)
        #expect(Self.occurrences(of: "diff(forRowAt:", in: code) == 1)
        let lookup = "ComparisonDiffPresentation.index(of: position, in: comparison.rows)"
        #expect(Self.occurrences(of: lookup, in: code) == 1)
        // Negative beside it: nothing here matches a row on its path.
        #expect(!code.contains("relativePath"))
        #expect(Self.occurrences(of: "guard !Task.isCancelled", in: code) == 1)
        // The presentation spells no `default:` arm over the Core types it
        // switches on. Positive: it does switch over all of them.
        #expect(!code.contains("default:"))
        #expect(code.contains("switch refusal"))
        #expect(code.contains("switch state"))
        #expect(code.contains("switch fetch"))
        #expect(code.contains("case .tooManyLines"))
        #expect(code.contains(".bothDirectories"))
    }

    @Test func theWindowHandsTheBodyToTheResultViewWhichShowsTheOverviewAndTheDiff() throws {
        let window = try Self.code("ComparisonWindow.swift")
        #expect(window.contains("ComparisonResultView(comparison: comparison)"))
        #expect(Self.occurrences(of: "ComparisonResultView(", in: window) == 1)
        // The overview moved into the result view; the window keeps neither
        // the overview nor a selection.
        #expect(!window.contains("ComparisonOverviewView("))
        #expect(!window.contains("selection"))
        let diff = try Self.code("ComparisonDiffView.swift")
        #expect(diff.contains("ComparisonOverviewView("))
        // The failure cause stays the window's.
        #expect(window.contains("ComparisonOverviewPresentation.failureCause(for:"))
    }
}
