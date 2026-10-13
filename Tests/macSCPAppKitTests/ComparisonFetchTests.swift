import Foundation
import Synchronization
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Diff view, Task 8: the comparison fetches both sides through the tab's
/// transfer queue, diffs a file pair, and settles one undetermined row by
/// bytes. What is pinned here, and by what:
///
/// 1. every byte a comparison moves goes through the queue — asserted on the
///    queue's own items, not on the call site;
/// 2. an explicitly chosen file pair is diffed without a checksum being asked
///    for — asserted on what the file system was ASKED, with a positive
///    control that it was asked to read;
/// 3. "compare anyway" rewrites one row and no other;
/// 4. the size ceiling is applied before a byte is fetched, and the byte,
///    encoding and line-count refusals after;
/// 5. how a file is cut into lines (CRLF, the final newline, a byte order
///    mark) is a decision of this task and is pinned either way;
/// 6. a released comparison answers `sessionClosed` from every entry point,
///    and one released mid-fetch does not carry on;
/// 7. the temporary directory exists after the first fetch and not after
///    `cancel()` or `releaseFileSystems()`.
///
/// No test here asserts how long anything took; the suite's hang bound is
/// `.timeLimit`.
@Suite("Comparison fetch", .timeLimit(.minutes(2)))
@MainActor
struct ComparisonFetchTests {

    // MARK: - Fixtures

    private struct Rig {
        let comparison: Comparison
        let left: MemoryFS
        let right: MemoryFS
        let queue: TransferQueueViewModel
        let temporaryRoot: URL
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonFetchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A folder comparison over `/L` and `/R`, walked to completion. Sizes
    /// that match and a connection that cannot hash give
    /// `.undetermined(.checksumUnavailable)` rows, which is the shape
    /// "compare anyway" exists for.
    private func makeFolderRig(
        left: [String: Data], right: [String: Data],
        reportsSizes: Bool = true, temporaryRoot: URL
    ) async -> Rig {
        let leftFS = MemoryFS(
            files: Dictionary(uniqueKeysWithValues: left.map { ("/L/" + $0.key, $0.value) }),
            reportsSizes: reportsSizes)
        let rightFS = MemoryFS(
            files: Dictionary(uniqueKeysWithValues: right.map { ("/R/" + $0.key, $0.value) }),
            reportsSizes: reportsSizes)
        let queue = TransferQueueViewModel()
        let comparison = Comparison(
            left: leftFS, leftRoot: "/L", right: rightFS, rightRoot: "/R",
            algorithm: .sha256, transferQueue: queue, temporaryRoot: temporaryRoot)
        comparison.start()
        await comparison.waitForWalk()
        return Rig(
            comparison: comparison, left: leftFS, right: rightFS, queue: queue,
            temporaryRoot: temporaryRoot)
    }

    /// A file-pair comparison over `/L/f` and `/R/f`. Not started: it has no
    /// walk, and `start()` is covered separately.
    private func makeFilePairRig(
        left: Data, right: Data, reportsSizes: Bool = true, temporaryRoot: URL,
        onLeftRead: @escaping @Sendable (String) async -> Void = { _ in },
        onRightRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> Rig {
        let leftFS = MemoryFS(
            files: ["/L/f": left], reportsSizes: reportsSizes, onRead: onLeftRead)
        let rightFS = MemoryFS(
            files: ["/R/f": right], reportsSizes: reportsSizes, onRead: onRightRead)
        let queue = TransferQueueViewModel()
        let comparison = Comparison(
            left: leftFS, leftRoot: "/L/f", right: rightFS, rightRoot: "/R/f",
            algorithm: .sha256, transferQueue: queue, kind: .filePair,
            temporaryRoot: temporaryRoot)
        return Rig(
            comparison: comparison, left: leftFS, right: rightFS, queue: queue,
            temporaryRoot: temporaryRoot)
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// Every entry below `root`, as paths relative to it.
    private static func leftovers(under root: URL) -> [String] {
        let base = root.path(percentEncoded: false)
        let found = FileManager.default.enumerator(atPath: base)?.allObjects as? [String]
        return found ?? []
    }

    /// A hunk's lines as the prefixed text a unified diff shows.
    private func render(_ hunk: DiffHunk) -> [String] {
        hunk.lines.map { line in
            switch line.kind {
            case .context: " " + line.text
            case .added: "+" + line.text
            case .removed: "-" + line.text
            }
        }
    }

    private func hunks(_ result: Result<[DiffHunk], DiffRefusal>) -> [DiffHunk]? {
        if case .success(let hunks) = result { return hunks }
        return nil
    }

    // MARK: - 1. Through the queue

    @Test func aFetchGoesThroughTheTransferQueue() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        let row = try #require(rig.comparison.rows.first)
        // Positive: the walk did not touch the queue, so what is counted
        // below is the fetch and nothing else.
        #expect(rig.queue.items.isEmpty)

        let urls = try await rig.comparison.fetchPair(row)

        #expect(rig.queue.items.count == 2)
        #expect(rig.queue.items.allSatisfy { $0.direction == .download })
        #expect(rig.queue.items.allSatisfy { $0.status == .finished })
        // Both sides were read from the file systems the comparison was
        // given, and what arrived is what they held.
        #expect(rig.left.reads == ["/L/a"])
        #expect(rig.right.reads == ["/R/a"])
        #expect(try Data(contentsOf: urls.left) == data("one"))
        #expect(try Data(contentsOf: urls.right) == data("two"))
        // Two different files under one name: separate directories.
        #expect(urls.left != urls.right)
    }

    @Test func aSecondFetchOfTheSameRowPutsNoConflictInFrontOfTheUser() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        let row = try #require(rig.comparison.rows.first)
        // No conflict decider is installed on this queue, so a destination
        // that already existed would fail the transfer.
        let first = try await rig.comparison.fetchPair(row)
        let second = try await rig.comparison.fetchPair(row)
        #expect(first.left != second.left)
        #expect(rig.queue.items.count == 4)
        #expect(rig.queue.items.allSatisfy { $0.status == .finished })
    }

    // MARK: - 2. An explicit file pair skips the classification

    /// Spec behaviour 1, asserted by what the file systems were ASKED for.
    @Test func anExplicitFilePairIsDiffedWithoutAskingForAChecksum() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The sizes are EQUAL, so the walk's classification would have asked
        // for a checksum. The file pair never reaches it.
        let rig = makeFilePairRig(left: data("a\nb\n"), right: data("a\nc\n"), temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(rig.left.checksumCalls == 0)
        #expect(rig.right.checksumCalls == 0)
        // Positive control: it did fetch, and the answer is a real diff.
        #expect(rig.left.reads == ["/L/f"])
        #expect(rig.right.reads == ["/R/f"])
        let shown = try #require(hunks(result))
        #expect(shown.count == 1)
        #expect(render(shown[0]) == [" a", "-b", "+c", " "])
    }

    /// The same behaviour for a folder row: the walk asked once, and the
    /// diff asks no more.
    @Test func aFolderRowIsDiffedWithoutAskingForAnotherChecksum() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        // Positive control: the walk DID ask, so a count that stays put is a
        // statement about the diff.
        let asked = rig.left.checksumCalls + rig.right.checksumCalls
        #expect(asked >= 1)

        let result = try await rig.comparison.diff(forRowAt: 0)

        #expect(rig.left.checksumCalls + rig.right.checksumCalls == asked)
        #expect(hunks(result)?.count == 1)
    }

    @Test func aFilePairComparisonIsOverBeforeItBeganAndHasNoRows() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeFilePairRig(left: data("x"), right: data("y"), temporaryRoot: root)
        rig.comparison.start()
        guard case .completed? = rig.comparison.outcome else {
            Issue.record("expected .completed, got \(String(describing: rig.comparison.outcome))")
            return
        }
        #expect(rig.comparison.rows.isEmpty)
        // Nothing was listed: there was no walk.
        #expect(rig.left.listCalls == 0)
    }

    @Test func eachEntryPointRefusesTheOtherKindOfComparison() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = makeFilePairRig(left: data("x"), right: data("y"), temporaryRoot: root)
        let folders = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        let row = try #require(folders.comparison.rows.first)

        await #expect(throws: ComparisonFetchError.wrongKind) { try await pair.comparison.diff(forRowAt: 0) }
        await #expect(throws: ComparisonFetchError.wrongKind) { try await pair.comparison.settleUndetermined(rowAt: 0) }
        await #expect(throws: ComparisonFetchError.wrongKind) { try await pair.comparison.fetchPair(row) }
        await #expect(throws: ComparisonFetchError.wrongKind) { try await folders.comparison.diffFilePair() }
        // Positive: the refusals are about the kind, not about a broken rig.
        #expect(hunks(try await folders.comparison.diff(forRowAt: 0)) != nil)
        #expect(hunks(try await pair.comparison.diffFilePair()) != nil)
    }

    // MARK: - 3. Compare anyway

    /// Spec behaviour 2.
    @Test func compareAnywaySettlesOneRowAndLeavesTheOthersAlone() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("aaa"), "b": data("bbb")],
            right: ["a": data("aax"), "b": data("bbb")],
            temporaryRoot: root)
        let undetermined = ComparisonState.undetermined(.checksumUnavailable)
        // Positive: both rows start undetermined, so "the other is
        // untouched" is about a row that COULD have been rewritten.
        #expect(rig.comparison.rows.map(\.state) == [undetermined, undetermined])
        let before = rig.comparison.rows

        let settled = try await rig.comparison.settleUndetermined(rowAt: 0)

        #expect(settled == .differs)
        #expect(rig.comparison.rows.count == before.count)
        #expect(rig.comparison.rows[0] == ComparisonRow(relativePath: "a", state: .differs))
        #expect(rig.comparison.rows[1] == before[1])
        #expect(rig.comparison.rows[1].state == undetermined)
    }

    @Test func compareAnywayCallsTwoUndeterminedFilesWithEqualBytesTheSame() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("aaa"), "b": data("bbb")],
            right: ["a": data("aaa"), "b": data("bbx")],
            temporaryRoot: root)
        let checksumsAfterWalk = rig.left.checksumCalls + rig.right.checksumCalls

        let settled = try await rig.comparison.settleUndetermined(rowAt: 0)

        #expect(settled == .same)
        #expect(rig.comparison.rows[0].state == .same)
        #expect(rig.comparison.rows[1].state == .undetermined(.checksumUnavailable))
        // The connection said it cannot hash; settling does not ask again.
        #expect(rig.left.checksumCalls + rig.right.checksumCalls == checksumsAfterWalk)
        // Positive: it did fetch.
        #expect(rig.left.reads == ["/L/a"])
    }

    /// The row it is GIVEN, not the first one: settling the second row writes
    /// the second row and leaves the first undetermined.
    @Test func compareAnywaySettlesTheRowItWasGivenAndNotTheFirst() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("aaa"), "b": data("bbb")],
            right: ["a": data("aax"), "b": data("bbb")],
            temporaryRoot: root)
        let undetermined = ComparisonState.undetermined(.checksumUnavailable)
        #expect(rig.comparison.rows.map(\.state) == [undetermined, undetermined])

        let settled = try await rig.comparison.settleUndetermined(rowAt: 1)

        #expect(settled == .same)
        #expect(rig.comparison.rows[0] == ComparisonRow(relativePath: "a", state: undetermined))
        #expect(rig.comparison.rows[1] == ComparisonRow(relativePath: "b", state: .same))
        // Positive: it read the second row's files and not the first's.
        #expect(rig.left.reads == ["/L/b"])
        #expect(rig.right.reads == ["/R/b"])
    }

    @Test func aRowIsDiffedByItsOwnIndex() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("aaa"), "b": data("one")],
            right: ["a": data("aax"), "b": data("two")],
            temporaryRoot: root)

        let shown = try #require(hunks(try await rig.comparison.diff(forRowAt: 1)))

        #expect(shown.count == 1)
        #expect(render(shown[0]) == ["-one", "+two"])
        #expect(rig.left.reads == ["/L/b"])
    }

    /// Bytes, not a prefix: a difference after the first chunk is found.
    @Test func compareAnywayFindsADifferenceFarIntoTheFile() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = Data(repeating: 0x61, count: 3 * (1 << 20) + 17)
        var right = left
        right[right.count - 1] = 0x62
        let rig = await makeFolderRig(left: ["big": left], right: ["big": right], temporaryRoot: root)
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.checksumUnavailable)])

        #expect(try await rig.comparison.settleUndetermined(rowAt: 0) == .differs)
    }

    @Test func compareAnywayRefusesARowThatIsNotUndeterminedByAChecksum() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("1"), "only": data("x")],
            right: ["a": data("22")],
            temporaryRoot: root)
        // `a` differs by size, `only` is on one side: neither is a row bytes
        // can settle, and neither is rewritten.
        let states = rig.comparison.rows.map(\.state)
        #expect(states.contains(.differs))
        #expect(states.contains(.onlyLeft))
        let before = rig.comparison.rows
        for index in before.indices {
            await #expect(throws: ComparisonFetchError.noContentToCompare(before[index].state)) {
                try await rig.comparison.settleUndetermined(rowAt: index)
            }
        }
        await #expect(throws: ComparisonFetchError.rowOutOfRange(7)) {
            try await rig.comparison.settleUndetermined(rowAt: 7)
        }
        #expect(rig.comparison.rows == before)
        #expect(rig.queue.items.isEmpty)
    }

    /// Every reason is decided, in both directions: a negative check beside
    /// its positive.
    @Test func onlyAChecksumShortfallCanBeSettledByBytes() {
        let settleable: [UndeterminedReason] = [
            .checksumUnavailable, .algorithmUnavailable(.sha256), .algorithmsDiffer,
            .etagIsNotAFileHash,
        ]
        let notSettleable: [UndeterminedReason] = [.unsupportedKind, .unreadable]
        #expect(settleable.allSatisfy { $0.canBeSettledByBytes })
        #expect(notSettleable.allSatisfy { !$0.canBeSettledByBytes })
    }

    // MARK: - 4. Refusals

    @Test func anOversizedPairRefusesRatherThanDiffing() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 0x61, count: DiffEligibility.ceilingBytes + 1)
        let rig = makeFilePairRig(left: big, right: data("small"), temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(result == .failure(
            .tooLarge(bytes: DiffEligibility.ceilingBytes + 1, ceiling: DiffEligibility.ceilingBytes)))
        // Refused from `stat`: not one byte was moved to learn it.
        #expect(rig.left.reads.isEmpty)
        #expect(rig.right.reads.isEmpty)
        #expect(rig.queue.items.isEmpty)
    }

    @Test func aPairExactlyAtTheCeilingIsFetchedAndDiffed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = Data(repeating: 0x61, count: DiffEligibility.ceilingBytes)
        let right = Data(repeating: 0x62, count: DiffEligibility.ceilingBytes)
        let rig = makeFilePairRig(left: left, right: right, temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(rig.left.reads == ["/L/f"])
        #expect(hunks(result)?.count == 1)
    }

    /// A server that reports no size is not trusted to mean "small": the
    /// bytes that arrive are measured too.
    @Test func aSideThatReportsNoSizeIsStillRefusedOnceItsBytesArrive() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 0x61, count: DiffEligibility.ceilingBytes + 1)
        let rig = makeFilePairRig(
            left: big, right: data("small"), reportsSizes: false, temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(result == .failure(
            .tooLarge(bytes: DiffEligibility.ceilingBytes + 1, ceiling: DiffEligibility.ceilingBytes)))
        // Positive: this time it WAS fetched, which is what the case is about.
        #expect(rig.left.reads == ["/L/f"])
    }

    @Test func binaryAndNonUTF8SidesEachRefuseWithTheirOwnReason() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = data("plain\n")
        let binary = Data([0x61, 0x00, 0x62])
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])   // "café" in Latin-1: not UTF-8

        let leftBinary = makeFilePairRig(left: binary, right: text, temporaryRoot: root)
        #expect(try await leftBinary.comparison.diffFilePair() == .failure(.binary))

        let rightLatin1 = makeFilePairRig(left: text, right: latin1, temporaryRoot: root)
        #expect(try await rightLatin1.comparison.diffFilePair() == .failure(.notUTF8))

        // Positive control: the same fixtures, with text on both sides, diff.
        let ok = makeFilePairRig(left: text, right: data("other\n"), temporaryRoot: root)
        #expect(hunks(try await ok.comparison.diffFilePair()) != nil)
    }

    /// Two 2 MB files of nothing but newlines: each under the byte ceiling,
    /// each with two million lines, and a line diff of the pair would need a
    /// table of four trillion entries. The refusal must come first.
    @Test func aPairWithTooManyLinesIsRefusedBeforeTheDiffRuns() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let newlines = Data(repeating: 0x0A, count: 2_000_000)
        let rig = makeFilePairRig(left: newlines, right: newlines, temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(result == .failure(.tooManyLines(
            leftLines: 2_000_001, rightLines: 2_000_001,
            ceilingProduct: DiffEligibility.maxLineProduct)))
        // Positive: the byte checks passed, so this was the line check.
        #expect(DiffEligibility.refusal(forBytes: [UInt8](newlines)) == nil)
    }

    // MARK: - 5. How a file is cut into lines

    @Test func aCRLFFileSplitsIntoAsManyLinesAsItsLFTwin() {
        let lf = Comparison.lines(of: Array("one\ntwo\nthree\n".utf8))
        let crlf = Comparison.lines(of: Array("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(lf.count == 4)
        #expect(crlf.count == lf.count)
        // The CR stays on its line, and the lines are therefore different.
        #expect(crlf == ["one\r", "two\r", "three\r", ""])
        #expect(lf == ["one", "two", "three", ""])
        // What `split(separator: "\n")` on a String would have produced, so
        // the case above is not satisfied by accident: one line, unsplit.
        #expect("one\r\ntwo\r\n".split(separator: "\n").count == 1)
    }

    @Test func theFinalNewlineIsAnEmptyLastLineAndTheSplitIsLossless() {
        #expect(Comparison.lines(of: Array("a\nb\n".utf8)) == ["a", "b", ""])
        #expect(Comparison.lines(of: Array("a\nb".utf8)) == ["a", "b"])
        // The choice is exactly one element, no more.
        #expect(
            Comparison.lines(of: Array("a\nb\n".utf8)).count
                == Comparison.lines(of: Array("a\nb".utf8)).count + 1)
        #expect(Comparison.lines(of: []) == [""])
        for text in ["", "\n", "a", "a\n", "\n\nb", "x\r\ny\n", "\u{FEFF}a\nb"] {
            #expect(Comparison.lines(of: Array(text.utf8)).joined(separator: "\n") == text)
        }
    }

    @Test func aCRLFFileDiffersFromItsLFTwinOnEveryLine() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeFilePairRig(
            left: data("a\r\nb\r\n"), right: data("a\nb\n"), temporaryRoot: root)

        let shown = try #require(hunks(try await rig.comparison.diffFilePair()))

        #expect(shown.count == 1)
        #expect(render(shown[0]) == ["-a\r", "-b\r", "+a", "+b", " "])
        // And a CRLF file against itself is one file: no hunks at all.
        let same = makeFilePairRig(
            left: data("a\r\nb\r\n"), right: data("a\r\nb\r\n"), temporaryRoot: root)
        #expect(try await same.comparison.diffFilePair() == .success([]))
    }

    @Test func aMissingFinalNewlineShowsInTheDiff() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeFilePairRig(left: data("a\nb\n"), right: data("a\nb"), temporaryRoot: root)

        let shown = try #require(hunks(try await rig.comparison.diffFilePair()))

        #expect(shown.count == 1)
        #expect(render(shown[0]) == [" a", " b", "-"])
    }

    /// The decision: a byte order mark is NOT stripped. It is U+FEFF at the
    /// start of line 1, so two files that differ by exactly those three bytes
    /// show a changed first line and not an empty diff.
    @Test func aByteOrderMarkIsKeptAndShowsAsAChangedFirstLine() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let withBOM = bom + data("#!/bin/sh\necho\n")
        let without = data("#!/bin/sh\necho\n")
        // Positive: the BOM is eligible and survives the split.
        #expect(DiffEligibility.refusal(forBytes: [UInt8](withBOM)) == nil)
        #expect(Comparison.lines(of: [UInt8](withBOM)).first == "\u{FEFF}#!/bin/sh")
        #expect(Comparison.lines(of: [UInt8](withBOM)).count == Comparison.lines(of: [UInt8](without)).count)

        let rig = makeFilePairRig(left: withBOM, right: without, temporaryRoot: root)
        let shown = try #require(hunks(try await rig.comparison.diffFilePair()))

        #expect(shown.count == 1)
        #expect(render(shown[0]).first == "-\u{FEFF}#!/bin/sh")
        #expect(render(shown[0]).contains("+#!/bin/sh"))
        // And two files that BOTH carry it agree.
        let both = makeFilePairRig(left: withBOM, right: withBOM, temporaryRoot: root)
        #expect(try await both.comparison.diffFilePair() == .success([]))
    }

    // MARK: - 6. The session is gone

    @Test func everyEntryPointAnswersSessionClosedOnceTheSessionIsReleased() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = await makeFolderRig(
            left: ["a": data("aaa")], right: ["a": data("aax")], temporaryRoot: root)
        let pair = makeFilePairRig(left: data("x"), right: data("y"), temporaryRoot: root)
        let row = try #require(folders.comparison.rows.first)
        // Positive: before the release every one of them works.
        #expect(hunks(try await folders.comparison.diff(forRowAt: 0)) != nil)
        #expect(hunks(try await pair.comparison.diffFilePair()) != nil)
        _ = try await folders.comparison.fetchPair(row)
        let fetchesBefore = folders.queue.items.count + pair.queue.items.count
        let readsBefore = folders.left.reads.count + pair.left.reads.count
        let statsBefore = folders.left.statCalls + pair.left.statCalls

        for comparison in [folders.comparison, pair.comparison] {
            comparison.cancel()
            comparison.releaseFileSystems()
        }

        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await folders.comparison.fetchPair(row)
        }
        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await folders.comparison.diff(forRowAt: 0)
        }
        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await folders.comparison.settleUndetermined(rowAt: 0)
        }
        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await pair.comparison.diffFilePair()
        }
        // Nothing was asked of the connection that was let go, and nothing
        // was queued.
        #expect(folders.queue.items.count + pair.queue.items.count == fetchesBefore)
        #expect(folders.left.reads.count + pair.left.reads.count == readsBefore)
        #expect(folders.left.statCalls + pair.left.statCalls == statsBefore)
        // And what was measured is still there, row unchanged.
        #expect(folders.comparison.rows == [row])
    }

    /// The release lands while the left file is being read. The first
    /// transfer finishes — the queue ignores the release — and the comparison
    /// must neither start the second nor report a result.
    @Test func aReleaseDuringTheFirstTransferStopsBeforeTheSecondAndLeavesNothing() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = ComparisonHolder()
        let rig = makeFilePairRig(
            left: data("x"), right: data("y"), temporaryRoot: root,
            onLeftRead: { _ in
                await MainActor.run { holder.releaseLeavingAStrayFile(under: root) }
            })
        holder.comparison = rig.comparison

        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await rig.comparison.diffFilePair()
        }

        // Positive: the left read DID happen (that is where the release
        // landed), so "the right was not read" is not an unreached branch.
        #expect(rig.left.reads == ["/L/f"])
        #expect(rig.right.reads.isEmpty)
        #expect(rig.comparison.temporaryDirectory == nil)
        let leftovers = Self.leftovers(under: root)
        #expect(leftovers.isEmpty, "temporary files outlived the release: \(leftovers)")
    }

    /// The same, landing during the SECOND transfer: both transfers complete,
    /// and only the check after them stands between this and a result read off
    /// files of a session that was let go.
    @Test func aReleaseDuringTheSecondTransferReportsSessionClosedAndLeavesNothing() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = ComparisonHolder()
        let rig = makeFilePairRig(
            left: data("x"), right: data("y"), temporaryRoot: root,
            onRightRead: { _ in
                await MainActor.run { holder.releaseLeavingAStrayFile(under: root) }
            })
        holder.comparison = rig.comparison

        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await rig.comparison.diffFilePair()
        }

        // Positive: both sides WERE read, so the release landed after the
        // last transfer and the refusal is the check at the end.
        #expect(rig.left.reads == ["/L/f"])
        #expect(rig.right.reads == ["/R/f"])
        #expect(rig.comparison.temporaryDirectory == nil)
        let leftovers = Self.leftovers(under: root)
        #expect(leftovers.isEmpty, "temporary files outlived the release: \(leftovers)")
    }

    // MARK: - 7. The temporary directory

    @Test func theTemporaryDirectoryExistsAfterTheFirstFetchAndNotAfterACancel() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        let row = try #require(rig.comparison.rows.first)
        #expect(rig.comparison.temporaryDirectory == nil)

        let urls = try await rig.comparison.fetchPair(row)
        let directory = try #require(rig.comparison.temporaryDirectory)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(urls.left.path(percentEncoded: false).hasPrefix(directory.path(percentEncoded: false)))
        #expect(urls.right.path(percentEncoded: false).hasPrefix(directory.path(percentEncoded: false)))

        rig.comparison.cancel()

        #expect(rig.comparison.temporaryDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: urls.left.path(percentEncoded: false)))
    }

    @Test func theTemporaryDirectoryIsRemovedOnReleaseToo() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        let row = try #require(rig.comparison.rows.first)
        _ = try await rig.comparison.fetchPair(row)
        let directory = try #require(rig.comparison.temporaryDirectory)
        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

        rig.comparison.releaseFileSystems()

        #expect(rig.comparison.temporaryDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    /// A diff and a settling read the bytes at once and keep nothing: ten
    /// "compare anyway" clicks must not leave ten copies of a large file.
    @Test func aDiffAndASettlingLeaveNoFetchedFilesBehind() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root)
        _ = try await rig.comparison.diff(forRowAt: 0)
        _ = try await rig.comparison.settleUndetermined(rowAt: 0)

        let directory = try #require(rig.comparison.temporaryDirectory)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(left.isEmpty, "fetched files were kept: \(left)")
        // Positive: both did fetch (two reads per side).
        #expect(rig.left.reads.count == 2)
    }
}

// MARK: - Doubles

@MainActor
private final class ComparisonHolder {
    var comparison: Comparison?

    /// Tears the comparison down the way `TabTeardown` does, then puts a file
    /// back where the comparison's directory was: what a transfer that was
    /// still writing does when it creates its file after the removal, or
    /// while the removal is running. The removal cannot be made to lose that
    /// race on demand, so the test makes the loser's result happen: a
    /// directory the release has already swept, holding something. The fetch
    /// that notices the release has to sweep it again.
    func releaseLeavingAStrayFile(under root: URL) {
        guard let comparison else { return }
        comparison.cancel()
        comparison.releaseFileSystems()
        let stray = root
            .appendingPathComponent(comparison.id.uuidString, isDirectory: true)
            .appendingPathComponent("stray", isDirectory: true)
        try? FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: stray.appendingPathComponent("file").path(percentEncoded: false), contents: Data("x".utf8))
    }
}

/// An in-memory file system that records what it was asked. `list` answers
/// the direct children of a directory from the keys of `files`.
private final class MemoryFS: RemoteFileSystem, RemoteChecksumProvider, Sendable {
    private struct State {
        var files: [String: Data]
        var reads: [String] = []
        var statCalls = 0
        var listCalls = 0
        var checksumCalls = 0
    }
    private let state: Mutex<State>
    private let reportsSizes: Bool
    private let onRead: @Sendable (String) async -> Void

    init(
        files: [String: Data], reportsSizes: Bool = true,
        onRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.state = Mutex(State(files: files))
        self.reportsSizes = reportsSizes
        self.onRead = onRead
    }

    var reads: [String] { state.withLock { $0.reads } }
    var statCalls: Int { state.withLock { $0.statCalls } }
    var listCalls: Int { state.withLock { $0.listCalls } }
    var checksumCalls: Int { state.withLock { $0.checksumCalls } }

    private func item(_ path: String, _ data: Data) -> RemoteFileItem {
        RemoteFileItem(
            name: path.split(separator: "/").last.map(String.init) ?? path, path: path, kind: .file,
            size: reportsSizes ? UInt64(data.count) : nil)
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        let files = state.withLock { state -> [String: Data] in
            state.listCalls += 1
            return state.files
        }
        return files.filter { RemotePath.parent(of: $0.key) == path }
            .map { item($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }

    func stat(path: String) async throws -> RemoteFileItem {
        let data = state.withLock { state -> Data? in
            state.statCalls += 1
            return state.files[path]
        }
        guard let data else { throw RemoteFSError.notFound(path: path) }
        return item(path, data)
    }

    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let data = state.withLock { state -> Data? in
            state.reads.append(path)
            return state.files[path]
        }
        guard let data else { throw RemoteFSError.notFound(path: path) }
        let rest = data.dropFirst(Int(offset))
        let hook = onRead
        return AsyncThrowingStream { continuation in
            if !rest.isEmpty { continuation.yield(Data(rest)) }
            // The hook runs after the bytes were handed over and before the
            // stream ends, so a test can land a teardown at the point where
            // the transfer has all it will get and has not yet finished.
            Task {
                await hook(path)
                continuation.finish()
            }
        }
    }

    func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        state.withLock { $0.checksumCalls += 1 }
        return .unavailableOnThisConnection
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
    func delete(path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func deleteTree(at path: String) async throws {}
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}
