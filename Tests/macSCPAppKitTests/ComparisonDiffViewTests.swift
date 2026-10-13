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
        .undetermined(.unsupportedKind), .undetermined(.unreadable),
    ]

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// What a line looks like, as one string: the runs joined.
    private static func visible(_ runs: [Presentation.Run]) -> String {
        runs.map(\.text).joined()
    }

    // MARK: - Four refusals, four texts

    @Test func eachRefusalHasItsOwnKeyAndItsOwnText() {
        let wordings = Self.refusals.map { Presentation.wording(for: $0) }
        #expect(wordings.count == 4)
        #expect(Set(wordings.map(\.key)).count == 4)
        #expect(Set(wordings.map(\.english)).count == 4)
        let texts = Self.refusals.map { Presentation.refusalText($0, locale: Self.english) }
        for (refusal, text) in zip(Self.refusals, texts) {
            #expect(!text.isEmpty, "\(refusal)")
            #expect(!text.contains("%"), "\(refusal): \(text)")
        }
        #expect(Set(texts).count == 4)
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
            // None of the four says the files are the same, equal or
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
        #expect(Set(refused).count == 4)
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
        #expect(refusalTexts.count == 4)
        #expect(distinct.isDisjoint(with: refusalTexts))
        #expect(!distinct.contains(Presentation.identical.text))
    }

    @Test func aFailureIsStyledAsAFailureAndARefusalAsARefusal() {
        let target = Presentation.Target.row(path: "a")
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
        // The six reasons share one sentence (the row above already says
        // which), and it is not one of the three.
        let undetermined = Set(
            Self.allStates.filter {
                if case .undetermined = $0 { return true } else { return false }
            }.map { Presentation.failureText(for: ComparisonFetchError.noContentToCompare($0)) })
        #expect(undetermined.count == 1)
        #expect(undetermined.isDisjoint(with: [onlyLeft, onlyRight, mismatch]))
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
        let a = Presentation.Target.row(path: "a")
        let b = Presentation.Target.row(path: "b")
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
        #expect(Presentation.target(kind: .folders, selection: "x/y") == .row(path: "x/y"))
        // A pair has no rows, so a stray selection does not matter.
        #expect(Presentation.target(kind: .filePair, selection: nil) == .filePair)
        #expect(Presentation.target(kind: .filePair, selection: "x") == .filePair)
    }

    @Test func aRowIsFoundByItsPathAndNotByAnotherRowsPosition() {
        let rows = [
            ComparisonRow(relativePath: "a", state: .differs),
            ComparisonRow(relativePath: "b", state: .same),
            ComparisonRow(relativePath: "c", state: .differs),
        ]
        #expect(Presentation.index(of: "a", in: rows) == 0)
        #expect(Presentation.index(of: "b", in: rows) == 1)
        #expect(Presentation.index(of: "c", in: rows) == 2)
        #expect(Presentation.index(of: "d", in: rows) == nil)
        #expect(Presentation.index(of: "a", in: []) == nil)
        // A path that is the beginning of an EARLIER row's path is not that
        // row, and a path that is the whole of a later one is found.
        let nested = [
            ComparisonRow(relativePath: "dir/file", state: .differs),
            ComparisonRow(relativePath: "dir", state: .differs),
            ComparisonRow(relativePath: "dir/file.bak", state: .differs),
        ]
        #expect(Presentation.index(of: "dir", in: nested) == 1)
        #expect(Presentation.index(of: "dir/file", in: nested) == 0)
        #expect(Presentation.index(of: "dir/fil", in: nested) == nil)
        #expect(Presentation.index(of: "DIR", in: nested) == nil)
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
                #expect(listing.hunks.count == hunks.count, Comment(rawValue: fixture.name))
                for (hunk, entry) in zip(hunks, listing.hunks) {
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
        let lines = Presentation.listing(for: [hunk]).hunks[0].lines
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

    @Test func theListingKeepsEveryHunkAndEveryLineInOrderAndSumsToTheInput() {
        let fixture = Self.fixtures[6]
        let hunks = FileDiff.hunks(left: fixture.left, right: fixture.right, context: 3)
        #expect(hunks.count == 2)
        let listing = Presentation.listing(for: hunks)
        #expect(listing.hunks.map(\.header) == hunks.map(Presentation.header(for:)))
        #expect(listing.hunks.map(\.lines.count) == hunks.map(\.lines.count))
        // Distinct ids across the hunks and inside each.
        #expect(Set(listing.hunks.map(\.id)).count == hunks.count)
        for hunk in listing.hunks { #expect(Set(hunk.lines.map(\.id)).count == hunk.lines.count) }
        #expect(listing.legend == Presentation.legend.text)
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
        let lines = Presentation.listing(for: hunks).hunks[0].lines
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
            let lines = Presentation.listing(for: hunks).hunks[0].lines
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
    /// by the file-actions sheet for the same reason, and a line that differs
    /// from another only in Unicode normalisation form is drawn as the text
    /// it is. (The diff itself compares bytes, so such a pair IS shown as a
    /// change.)
    @Test func theScalarsAnEmojiIsBuiltFromPassThroughAsTheFileActionsSheetDoes() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(Self.visible(Presentation.runs(of: family, kind: .added)) == family)
        #expect(FileActionPlanDisplay.visible(family) == family)
        let heart = "\u{2764}\u{FE0F}"
        #expect(Self.visible(Presentation.runs(of: heart, kind: .removed)) == heart)
        #expect(FileActionPlanDisplay.visible(heart) == heart)
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
        left: [String: Data], right: [String: Data],
        onLeftRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonDiffViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let comparison = Comparison(
            left: MemoryFS(
                files: Dictionary(uniqueKeysWithValues: left.map { ("/L/" + $0.key, $0.value) }),
                onRead: onLeftRead),
            leftRoot: "/L",
            right: MemoryFS(files: Dictionary(uniqueKeysWithValues: right.map { ("/R/" + $0.key, $0.value) })),
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
        return listing.hunks.flatMap(\.lines).map { $0.sign + Self.visible($0.runs) }
    }

    @Test func aRowShowsItsOwnContentsAndSelectingAnotherReplacesThem() async throws {
        let rig = try await folderRig(
            left: ["a": data("alpha\nsame"), "b": data("beta\nsame")],
            right: ["a": data("ALPHA\nsame"), "b": data("BETA!\nsame")])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()
        let a = Presentation.Target.row(path: "a")
        let b = Presentation.Target.row(path: "b")

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
        let row = Presentation.Target.row(path: "only")
        let both = Presentation.Target.row(path: "both")
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
        let gone = Presentation.Target.row(path: "not-there")
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
        let task = Task { await model.load(.row(path: "a"), on: rig.comparison) }
        task.cancel()
        await task.value
        #expect(model.loaded == nil)
        // Positive: the same load, not cancelled, does write.
        await model.load(.row(path: "a"), on: rig.comparison)
        #expect(model.loaded?.target == .row(path: "a"))
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
        let a = Presentation.Target.row(path: "a")
        let b = Presentation.Target.row(path: "b")

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

    /// A cancel that lands while the bytes are being fetched: the answer
    /// that comes back afterwards is dropped.
    @Test func aLoadCancelledMidFlightWritesNothingWhenItsAnswerArrives() async throws {
        let gate = Gate(path: "/L/b")
        let rig = try await folderRig(
            left: ["a": data("1"), "b": data("2")], right: ["a": data("11"), "b": data("22")],
            onLeftRead: gate.hook)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = ComparisonDiffModel()

        let task = Task { await model.load(.row(path: "b"), on: rig.comparison) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.open()
        await task.value
        #expect(model.loaded == nil)
        // Positive: the same load, left alone, does write.
        let again = Task { await model.load(.row(path: "b"), on: rig.comparison) }
        // (The gate is open for good now, so this read is not held.)
        await again.value
        #expect(model.loaded?.target == .row(path: "b"))
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
    /// annotation would name them. Not the bare names: `ComparisonDiffHunkView`
    /// contains `DiffHunk`.
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
        container: String, view: String, hunk: String, line: String, notice: String
    ) {
        let source = try Self.code("ComparisonDiffView.swift")
        func start(_ name: String) throws -> Range<String.Index> {
            try #require(source.range(of: "struct \(name): View"), "\(name)")
        }
        let container = try start("ComparisonResultView")
        let view = try start("ComparisonDiffView")
        let hunk = try start("ComparisonDiffHunkView")
        let line = try start("ComparisonDiffLineView")
        let notice = try start("ComparisonDiffNoticeView")
        #expect(container.lowerBound < view.lowerBound)
        #expect(view.lowerBound < hunk.lowerBound)
        #expect(hunk.lowerBound < line.lowerBound)
        #expect(line.lowerBound < notice.lowerBound)
        return (
            String(source[container.lowerBound..<view.lowerBound]),
            String(source[view.lowerBound..<hunk.lowerBound]),
            String(source[hunk.lowerBound..<line.lowerBound]),
            String(source[line.lowerBound..<notice.lowerBound]),
            String(source[notice.lowerBound...])
        )
    }

    /// The residual scan: the views iterate each function's output, once, and
    /// hold nothing to rebind or slice. Every negative check has the positive
    /// one beside it.
    @Test func theViewsDrawOnlyWhatTheFunctionsReturn() throws {
        let (container, view, hunk, line, notice) = try Self.viewCode()

        // Positive: one call of each function, one iteration of each output.
        #expect(
            Self.occurrences(
                of: "ComparisonDiffPresentation.screen(target: target, loaded: model.loaded)", in: view)
                == 1)
        #expect(Self.occurrences(of: "await model.load(target, on: comparison)", in: view) == 1)
        #expect(Self.occurrences(of: ".task(id: target)", in: view) == 1)
        #expect(Self.occurrences(of: "ForEach(listing.hunks, id: \\.id)", in: view) == 1)
        #expect(Self.occurrences(of: "ComparisonDiffHunkView(hunk: hunk, digits: listing.numberDigits)", in: view) == 1)
        #expect(Self.occurrences(of: "Text(listing.legend)", in: view) == 1)
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

        // The hunk draws its header and its lines, nothing else.
        #expect(Self.occurrences(of: "Text(hunk.header)", in: hunk) == 1)
        #expect(Self.occurrences(of: "ForEach(hunk.lines, id: \\.id)", in: hunk) == 1)
        #expect(Self.occurrences(of: "ComparisonDiffLineView(entry: entry, digits: digits)", in: hunk) == 1)
        // The line draws the values of its entry: both numbers, the sign, the
        // runs (through the one attribution function), the tint.
        #expect(Self.occurrences(of: "Text(entry.leftNumber)", in: line) == 1)
        #expect(Self.occurrences(of: "Text(entry.rightNumber)", in: line) == 1)
        #expect(Self.occurrences(of: "Text(entry.sign)", in: line) == 1)
        #expect(Self.occurrences(of: "FileActionPlanDisplay.attributed(entry.runs)", in: line) == 1)
        #expect(Self.occurrences(of: ".background(entry.tint)", in: line) == 1)
        #expect(Self.occurrences(of: ".accessibilityLabel(entry.kindLabel)", in: line) == 1)
        // The notice draws its text, and shows progress for the pending kind
        // by asking the entry.
        #expect(Self.occurrences(of: "Text(notice.text)", in: notice) == 1)
        #expect(Self.occurrences(of: "notice.showsProgress", in: notice) == 1)
        #expect(Self.occurrences(of: "notice.emphasis", in: notice) == 1)

        for part in [hunk, line, notice] {
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
            // The type annotation names the presentation once; no call does.
            #expect(Self.occurrences(of: "Presentation", in: part) == 1)
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
    /// offers for its kind, and the row is found by path in one function.
    @Test func theModelCallsTheTwoEntryPointsOnceEachAndFindsTheRowByPath() throws {
        let code = try Self.code("ComparisonDiffView.swift")
        #expect(Self.occurrences(of: "diffFilePair()", in: code) == 1)
        #expect(Self.occurrences(of: "diff(forRowAt: index)", in: code) == 1)
        #expect(Self.occurrences(of: "diff(forRowAt:", in: code) == 1)
        #expect(Self.occurrences(of: "ComparisonDiffPresentation.index(of: path, in: comparison.rows)", in: code) == 1)
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
