import Foundation
import MacSCPTestSupport
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
/// 7. the temporary directory exists after the first fetch, survives
///    `cancel()` (which stops the walk and nothing else), and is gone after
///    `releaseFileSystems()`.
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
        left: [BytePath: Data], right: [BytePath: Data],
        reportsSizes: Bool = true, temporaryRoot: URL,
        leftKinds: [BytePath: RemoteFileKind] = [:],
        rightKinds: [BytePath: RemoteFileKind] = [:],
        leftChecksum: RemoteChecksumOutcome = .unavailableOnThisConnection,
        rightChecksum: RemoteChecksumOutcome = .unavailableOnThisConnection,
        unlistable: Set<BytePath> = [],
        onLeftRead: @escaping @Sendable (String) async -> Void = { _ in },
        onRightRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> Rig {
        // `leftKinds`, `rightKinds` and `unlistable` are named by the path
        // relative to the root, as `left` and `right` are.
        let leftFS = MemoryFS(
            files: under("/L", left), reportsSizes: reportsSizes,
            kinds: under("/L", leftKinds), checksum: leftChecksum,
            unlistable: Set(unlistable.map { BytePath("/L/" + $0.path) }), onRead: onLeftRead)
        let rightFS = MemoryFS(
            files: under("/R", right), reportsSizes: reportsSizes,
            kinds: under("/R", rightKinds), checksum: rightChecksum,
            unlistable: Set(unlistable.map { BytePath("/R/" + $0.path) }), onRead: onRightRead)
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
        leftKind: RemoteFileKind = .file, rightKind: RemoteFileKind = .file,
        onLeftRead: @escaping @Sendable (String) async -> Void = { _ in },
        onRightRead: @escaping @Sendable (String) async -> Void = { _ in },
        onLeftStat: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) -> Rig {
        let leftFS = MemoryFS(
            files: ["/L/f": left], reportsSizes: reportsSizes, kinds: ["/L/f": leftKind],
            onRead: onLeftRead, onStat: onLeftStat)
        let rightFS = MemoryFS(
            files: ["/R/f": right], reportsSizes: reportsSizes, kinds: ["/R/f": rightKind],
            onRead: onRightRead)
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
        #expect(rig.comparison.rows[0] == fixtureRow("a", .differs))
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
        #expect(rig.comparison.rows[0] == fixtureRow("a", undetermined))
        #expect(rig.comparison.rows[1] == fixtureRow("b", .same))
        // Positive: it read the second row's files and not the first's.
        #expect(rig.left.reads == ["/L/b"])
        #expect(rig.right.reads == ["/R/b"])
    }

    /// A row the SECOND pairing pass made: the left side spells the name NFD,
    /// the right side NFC, and they are one file to a person
    /// (`ComparisonPairing.pairs`' own reason for having a second pass). Both
    /// the settle and the diff have to fetch each side from that side's own
    /// path.
    ///
    /// Measured 2026-10-15, with `MemoryFS` keyed by UTF-8 bytes: the row's
    /// relative path joined to both roots asked the right side for the LEFT
    /// spelling, which that side does not have, so a row the overview had just
    /// offered "compare contents anyway" failed with a raw transfer error.
    @Test func aRowPairedOnlyByItsNormalizedNameIsFetchedFromEachSidesOwnPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nfd = "su\u{0308}b.txt"
        let nfc = "s\u{00FC}b.txt"
        let rig = await makeFolderRig(
            left: [BytePath(nfd): data("abc")], right: [BytePath(nfc): data("abd")],
            temporaryRoot: root)
        // Positive control: the pair WAS made — one row, not two one-sided
        // ones — and it is a row bytes can settle.
        #expect(rig.comparison.rows.count == 1)
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.checksumUnavailable)])

        let settled = try await rig.comparison.settleUndetermined(rowAt: 0)

        #expect(settled == .differs)
        #expect(rig.left.readBytePaths == [BytePath("/L/" + nfd)])
        #expect(rig.right.readBytePaths == [BytePath("/R/" + nfc)])

        // And the line diff of the same row, which fetches again.
        let diff = try await rig.comparison.diff(forRowAt: 0)
        #expect(try diff.get().isEmpty == false)
        #expect(rig.right.readBytePaths == [BytePath("/R/" + nfc), BytePath("/R/" + nfc)])
    }

    /// The two halves of the feature agree about a pair. These two files hold
    /// the same text spelled differently (precomposed and decomposed "a" with
    /// a diaeresis, in opposite order), with the same number of bytes: Swift
    /// calls the lines equal, a checksum over the bytes does not. The folder
    /// view cannot hash here, so the row is undetermined; settling it by
    /// bytes says `.differs`, and the diff of that row must then show a
    /// change and not nothing.
    @Test func aPairTheClassificationCallsDifferentHasANonEmptyDiff() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let composed = "\u{00E4}"
        let decomposed = "a\u{0308}"
        let left = composed + decomposed
        let right = decomposed + composed
        // Positive controls: equal as Strings, equal in size, different bytes.
        #expect(left == right)
        #expect(left.utf8.count == right.utf8.count)
        #expect(Array(left.utf8) != Array(right.utf8))
        let rig = await makeFolderRig(
            left: ["t": data(left)], right: ["t": data(right)], temporaryRoot: root)
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.checksumUnavailable)])

        #expect(try await rig.comparison.settleUndetermined(rowAt: 0) == .differs)
        let shown = try #require(hunks(try await rig.comparison.diff(forRowAt: 0)))

        #expect(shown.count == 1)
        #expect(render(shown[0]) == ["-" + left, "+" + right])
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

    /// A pair that REALLY produces `reason`, walked to completion, and what
    /// settling its one row is expected to do. This replaces a test that
    /// held two literal arrays of reasons against `canBeSettledByBytes`
    /// (`onlyAChecksumShortfallCanBeSettledByBytes`): it transcribed the split
    /// against itself, so it froze whichever one was in the tree and could not
    /// tell a right split from a wrong one — green for twelve days while an
    /// unreported type was refused. What is pinned here is what the FETCH DOES.
    ///
    /// Exhaustive with no `default:`, so a reason added in Core does not
    /// compile until somebody has built the pair that produces it and decided
    /// whether bytes answer it. `ComparisonOverviewTests.allReasons`, which the
    /// overview suite holds to the cases the enum declares, is the list this
    /// is walked over.
    private func settleScenario(
        for reason: UndeterminedReason, temporaryRoot root: URL
    ) async -> (rig: Rig, bytesSettleIt: Bool) {
        let same = data("same bytes")
        func sha256(_ digit: String) -> RemoteChecksumOutcome {
            let hex = String(repeating: digit, count: ChecksumAlgorithm.sha256.hexDigitCount)
            return .checksum(FileChecksum.computedOnRemote(.sha256, hex: hex)!)
        }
        func md5(_ digit: String) -> RemoteChecksumOutcome {
            let hex = String(repeating: digit, count: ChecksumAlgorithm.md5.hexDigitCount)
            return .checksum(FileChecksum.computedOnRemote(.md5, hex: hex)!)
        }
        switch reason {
        case .checksumUnavailable:
            return (
                await makeFolderRig(left: ["a": same], right: ["a": same], temporaryRoot: root), true
            )
        case .algorithmUnavailable:
            return (
                await makeFolderRig(
                    left: ["a": same], right: ["a": same], temporaryRoot: root,
                    leftChecksum: .algorithmUnavailable(.sha256), rightChecksum: sha256("b")),
                true
            )
        case .algorithmsDiffer:
            return (
                await makeFolderRig(
                    left: ["a": same], right: ["a": same], temporaryRoot: root,
                    leftChecksum: sha256("a"), rightChecksum: md5("b")),
                true
            )
        case .etagIsNotAFileHash:
            let multipart = FileChecksum.objectStorageETag(
                "\"" + String(repeating: "a", count: 32) + "-3\"")!
            return (
                await makeFolderRig(
                    left: ["a": same], right: ["a": same], temporaryRoot: root,
                    leftChecksum: .checksum(multipart), rightChecksum: md5("b")),
                true
            )
        case .kindNotReported:
            return (
                await makeFolderRig(
                    left: ["a": same], right: ["a": same], temporaryRoot: root,
                    leftKinds: ["a": .other]),
                true
            )
        case .linkOnASide:
            return (
                await makeFolderRig(
                    left: ["a": same], right: ["a": same], temporaryRoot: root,
                    leftKinds: ["a": .symlink]),
                false
            )
        case .unreadable:
            return (
                await makeFolderRig(
                    left: ["d": Data()], right: ["d": Data()], temporaryRoot: root,
                    leftKinds: ["d": .directory], rightKinds: ["d": .directory],
                    unlistable: ["d"]),
                false
            )
        }
    }

    /// Every reason is decided by what happens, in both directions: the row
    /// is first shown to carry the reason (so the pair was real), and then
    /// settled. A row bytes can answer ends `same` or `differs` and the files
    /// were read; one they cannot is refused, rewritten to nothing, and no
    /// byte was moved. The refusal carries its positive half in the same
    /// pass: the row was there, carrying that reason, before it was asked.
    @Test func settlingARowDoesWhatItsReasonSaysBytesCanAnswer() async throws {
        for reason in ComparisonOverviewTests.allReasons {
            let root = try makeTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (rig, bytesSettleIt) = await settleScenario(for: reason, temporaryRoot: root)
            let before = rig.comparison.rows
            // Positive: the pair produced exactly this reason, as one row.
            #expect(before.map(\.state) == [.undetermined(reason)], "\(reason)")

            if bytesSettleIt {
                let settled = try await rig.comparison.settleUndetermined(rowAt: 0)
                #expect(settled == .same || settled == .differs, "\(reason)")
                #expect(rig.comparison.rows[0].state == settled, "\(reason)")
                #expect(rig.left.reads.count == 1 && rig.right.reads.count == 1, "\(reason)")
            } else {
                await #expect(throws: ComparisonFetchError.noContentToCompare(before[0].state)) {
                    try await rig.comparison.settleUndetermined(rowAt: 0)
                }
                #expect(rig.comparison.rows == before, "\(reason)")
                #expect(rig.left.reads.isEmpty && rig.right.reads.isEmpty, "\(reason)")
                #expect(rig.queue.items.isEmpty, "\(reason)")
            }
        }
    }

    /// The decisive case, named. Two ORDINARY files whose kind the listing did
    /// not report: against a server whose listing attributes carry no
    /// permission bits every entry is `.other`, and before the split every
    /// such pair was refused "compare anyway". Both sides, and both answers.
    @Test func twoOrdinaryFilesWhoseKindWasNotReportedAreSettledByTheirBytes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("aaa"), "b": data("bbb")],
            right: ["a": data("aaa"), "b": data("bbx")],
            temporaryRoot: root,
            leftKinds: ["a": .other, "b": .other], rightKinds: ["a": .other, "b": .other])
        let unreported = ComparisonState.undetermined(.kindNotReported)
        #expect(rig.comparison.rows.map(\.state) == [unreported, unreported])

        #expect(try await rig.comparison.settleUndetermined(rowAt: 0) == .same)
        #expect(try await rig.comparison.settleUndetermined(rowAt: 1) == .differs)
        #expect(rig.comparison.rows.map(\.state) == [.same, .differs])
    }

    /// One side only, either one: a far side that reports nothing is as common
    /// as a near side that does.
    @Test func anUnreportedKindOnOnlyTheRightSideIsSettledByBytesToo() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            rightKinds: ["a": .other])
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.kindNotReported)])

        #expect(try await rig.comparison.settleUndetermined(rowAt: 0) == .differs)
    }

    // MARK: - 3b. An abandoned fetch is cancelled

    /// A read held open: the test is told when it began, and it ends when
    /// the test says. Not a clock.
    private final class ParkedRead: Sendable {
        private let entered: AsyncStream<Void>
        private let release: AsyncStream<Void>
        private let enteredIn: AsyncStream<Void>.Continuation
        private let releaseIn: AsyncStream<Void>.Continuation

        init() {
            let (entered, enteredIn) = AsyncStream<Void>.makeStream()
            let (release, releaseIn) = AsyncStream<Void>.makeStream()
            self.entered = entered
            self.release = release
            self.enteredIn = enteredIn
            self.releaseIn = releaseIn
        }

        var hook: @Sendable (String) async -> Void {
            { [self] _ in
                enteredIn.yield()
                for await _ in release { break }
            }
        }

        func waitUntilEntered() async { for await _ in entered { return } }
        func open() { releaseIn.yield() }

        /// The result of `task`, cancelled by the caller. The wait is itself
        /// cancellable, and when THIS test is cancelled (by its `.timeLimit`,
        /// which is the hang bound here) it lets the parked read go, so a
        /// build whose cancel never reaches the transfer ends as a failed
        /// test and not as a process that never exits.
        func result<T: Sendable>(of task: Task<T, any Error>) async -> Result<T, any Error> {
            await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
                open()
            }
        }
    }

    /// Selecting a row starts its diff (`.task(id: target)`), and moving the
    /// selection cancels the awaiting task. That cancel has to reach the
    /// transfer: `enqueueAndWait` used to wait on a bare continuation, so the
    /// download carried on behind a view that had gone to another row — and
    /// for a row whose type was not reported, that is a download started by
    /// an arrow key. Built from a real queue and a real cancel; every
    /// postcondition is read BEFORE the parked read is let go, because the
    /// read ending would make the queue look tidy whatever the cancel did.
    @Test(.timeLimit(.minutes(1)))
    func aDiffWhoseTaskIsCancelledMidFetchLeavesNoTransferRunning() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = ParkedRead()
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            leftKinds: ["a": .other], onLeftRead: parked.hook)
        #expect(rig.comparison.rows.map(\.state) == [.undetermined(.kindNotReported)])

        let task = Task { try await rig.comparison.diff(forRowAt: 0) }
        await parked.waitUntilEntered()
        // Positive: the transfer IS running, so what is read below is what
        // the cancel did to something that was alive.
        #expect(rig.queue.items.count == 1)
        guard case .running? = rig.queue.items.first?.status else {
            Issue.record("expected a running transfer, got \(String(describing: rig.queue.items.first?.status))")
            parked.open()
            return
        }

        task.cancel()
        let outcome = await parked.result(of: task)

        // Read before the thaw.
        let stillRunning = rig.queue.items.filter { !$0.status.isTerminal }
        let statuses = rig.queue.items.map(\.status)
        let rightReads = rig.right.reads
        parked.open()

        if case .success = outcome { Issue.record("the cancelled diff produced a result") }
        #expect(stillRunning.isEmpty, "\(statuses)")
        #expect(statuses == [.cancelled])
        // The right side was never started: nothing is left to download.
        #expect(rightReads.isEmpty)
    }

    /// The same cancel, landing before the task has begun: the transfer is
    /// enqueued by a task that is already cancelled, and must not be left
    /// to run. Deterministic: a `Task` made on the main actor does not start
    /// until this test yields.
    @Test func aDiffWhoseTaskWasCancelledBeforeItBeganRunsNoTransfer() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            leftKinds: ["a": .other])

        let task = Task { try await rig.comparison.diff(forRowAt: 0) }
        task.cancel()
        _ = await task.result

        #expect(rig.queue.items.allSatisfy { $0.status.isTerminal })
        #expect(rig.queue.items.allSatisfy { $0.status == .cancelled })
        #expect(rig.left.reads.isEmpty)
        #expect(rig.right.reads.isEmpty)
        // Positive: the same call, not cancelled, does fetch.
        let ok = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            leftKinds: ["a": .other])
        #expect(hunks(try await ok.comparison.diff(forRowAt: 0)) != nil)
        #expect(ok.left.reads == ["/L/a"])
    }

    /// The SECOND transfer, pinned on its own. The tests above cancel during
    /// the left download or before the first call, so a build in which only
    /// the right-hand download opts in to the cancel (or only the left) would
    /// pass them: each half of `fetch` has to be held by something that
    /// cannot be satisfied by the other. Here the left file arrives and
    /// finishes, the right read is parked, and the task is cancelled — which
    /// is what selecting a row, waiting a moment and arrowing on does.
    @Test(.timeLimit(.minutes(1)))
    func aDiffWhoseTaskIsCancelledDuringTheRightDownloadLeavesNoTransferRunning() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = ParkedRead()
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            leftKinds: ["a": .other], onRightRead: parked.hook)

        let task = Task { try await rig.comparison.diff(forRowAt: 0) }
        await parked.waitUntilEntered()
        // Positive: the left transfer is done and the right one is running,
        // so what is read below is what the cancel did to the SECOND item.
        let before = rig.queue.items.map(\.status)
        guard before.count == 2, before[0] == .finished, case .running = before[1] else {
            Issue.record("expected [finished, running], got \(before)")
            parked.open()
            return
        }
        #expect(rig.left.reads == ["/L/a"])

        task.cancel()
        let outcome = await parked.result(of: task)

        // Read before the thaw.
        let statuses = rig.queue.items.map(\.status)
        parked.open()

        if case .success = outcome { Issue.record("the cancelled diff produced a result") }
        #expect(statuses == [.finished, .cancelled], "\(statuses)")
        // Nothing was left in the comparison's directory by the abandoned fetch.
        #expect(rig.comparison.temporaryDirectory.map {
            Self.leftovers(under: $0).isEmpty
        } ?? true)
    }

    /// The click route to the same fetch.
    @Test(.timeLimit(.minutes(1)))
    func aSettleWhoseTaskIsCancelledMidFetchLeavesNoTransferRunning() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = ParkedRead()
        let rig = await makeFolderRig(
            left: ["a": data("one")], right: ["a": data("two")], temporaryRoot: root,
            leftKinds: ["a": .other], onLeftRead: parked.hook)

        let task = Task { try await rig.comparison.settleUndetermined(rowAt: 0) }
        await parked.waitUntilEntered()
        guard case .running? = rig.queue.items.first?.status else {
            Issue.record("expected a running transfer")
            parked.open()
            return
        }

        task.cancel()
        let outcome = await parked.result(of: task)
        let statuses = rig.queue.items.map(\.status)
        let row = rig.comparison.rows.first?.state
        parked.open()

        if case .success = outcome { Issue.record("the cancelled settle produced a result") }
        #expect(statuses == [.cancelled])
        // The row was not rewritten by an answer nobody got.
        #expect(row == .undetermined(.kindNotReported))
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

    /// The same refusal when only the RIGHT side is oversized. Every other
    /// oversized fixture here is left-only; a check that looked at one side
    /// would pass them all and download the other whole before refusing it.
    @Test func anOversizedRightSideIsRefusedBeforeAnyByteIsFetched() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 0x61, count: DiffEligibility.ceilingBytes + 1)
        let rig = makeFilePairRig(left: data("small"), right: big, temporaryRoot: root)

        let result = try await rig.comparison.diffFilePair()

        #expect(result == .failure(
            .tooLarge(bytes: DiffEligibility.ceilingBytes + 1, ceiling: DiffEligibility.ceilingBytes)))
        #expect(rig.left.reads.isEmpty)
        #expect(rig.right.reads.isEmpty)
        #expect(rig.queue.items.isEmpty)
        // Positive: the right side WAS asked about, which is how it was
        // refused; the left one was too, because it comes first.
        #expect(rig.right.statCalls == 1)
        #expect(rig.left.statCalls == 1)
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

    /// Fix round 1, F1. A file pair skips the classification — that is what
    /// it is for — so the diff is the only place either side's kind AS
    /// `stat` REPORTS IT is ever looked at. The qualifier is fix round 3's:
    /// this read "`diffFilePair()` is the ONLY place either side's kind is
    /// ever looked at, and the FAR side of a one-row comparison is a path the
    /// menu model never saw at all", and round 2 made both halves false —
    /// the menu model reads the far side's kind from the other pane's
    /// listing, and the check is in `diffUnmapped`, which `diffFilePair()`
    /// delegates to. A side that is not an ordinary file is refused with a
    /// reason, before a byte moves.
    @Test func asideThatIsNotAnOrdinaryFileIsRefusedBeforeAnyByteIsFetched() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = data("plain\n")

        for (leftKind, rightKind, offending) in [
            (RemoteFileKind.directory, RemoteFileKind.file, DiffRefusal.Side.left),
            (RemoteFileKind.file, RemoteFileKind.directory, DiffRefusal.Side.right),
            (RemoteFileKind.symlink, RemoteFileKind.file, DiffRefusal.Side.left),
            (RemoteFileKind.file, RemoteFileKind.symlink, DiffRefusal.Side.right),
        ] {
            let rig = makeFilePairRig(
                left: text, right: text, temporaryRoot: root,
                leftKind: leftKind, rightKind: rightKind)

            let result = try await rig.comparison.diffFilePair()

            #expect(result == .failure(.notAnOrdinaryFile(
                side: offending, path: offending == .left ? "/L/f" : "/R/f")))
            // Not one byte was moved to learn it, and nothing was enqueued.
            #expect(rig.left.reads.isEmpty)
            #expect(rig.right.reads.isEmpty)
            #expect(rig.queue.items.isEmpty)
            // Positive: the side was asked about, which is how it was refused.
            #expect(rig.left.statCalls == 1)
        }

        // The positive control the four negatives above rest on: the same
        // fixtures with an ordinary file on both sides are fetched and
        // diffed. Without it, a check that refused everything would satisfy
        // all four.
        let ok = makeFilePairRig(left: text, right: data("other\n"), temporaryRoot: root)
        #expect(hunks(try await ok.comparison.diffFilePair()) != nil)
        #expect(ok.left.reads == ["/L/f"])
    }

    /// `.other` is what a listing or a `stat` answers when the type was NOT
    /// REPORTED (no permission bits arrived), so it is not evidence that the
    /// entry is unsuitable. The diff refuses what it knows is a folder or a
    /// link and lets `.other` through to the fetch. Either side; the positive
    /// half is that the bytes were read and a real diff came back. (This
    /// comment continued "which is the one thing that can tell an ordinary
    /// file from a device node — and says so by name if it is not one." That
    /// was never measured and is withdrawn; nothing here asserts what the
    /// fetch does with a device node.)
    ///
    /// This replaces the fourth case of
    /// `asideThatIsNotAnOrdinaryFileIsRefusedBeforeAnyByteIsFetched`, which
    /// expected `(.file, .other)` to be refused as `.notAnOrdinaryFile` — the
    /// same treatment of "unknown" as "unsuitable" that `unsupportedKind` was.
    @Test func aSideWhoseKindWasNotReportedIsDiffedAndNotRefused() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (leftKind, rightKind) in [
            (RemoteFileKind.other, RemoteFileKind.file),
            (RemoteFileKind.file, RemoteFileKind.other),
            (RemoteFileKind.other, RemoteFileKind.other),
        ] {
            let rig = makeFilePairRig(
                left: data("a\nb\n"), right: data("a\nc\n"), temporaryRoot: root,
                leftKind: leftKind, rightKind: rightKind)

            let result = try await rig.comparison.diffFilePair()

            let shown = try #require(hunks(result), "\(leftKind) / \(rightKind): \(result)")
            #expect(shown.count == 1)
            #expect(rig.left.reads == ["/L/f"])
            #expect(rig.right.reads == ["/R/f"])
        }
    }

    /// The two places that decide "can bytes answer this?" — the settle,
    /// gated by the reason, and the diff, gated by the kind `stat` reports —
    /// agree for every reason the walk can produce. Built from real pairs and
    /// real outcomes: each reason's pair is walked twice on fresh rigs, once
    /// settled and once diffed, and neither `canBeSettledByBytes` nor the
    /// diff's kind check is asked what it thinks. A row bytes settle that the
    /// diff then refuses is the contradiction this exists for: the overview
    /// and the diff telling the user two things about the same two files.
    @Test func aRowBytesCanSettleIsNotThenRefusedByTheDiffAndAnUnsettleableOneIsBoth() async throws {
        var agreeingYes: [UndeterminedReason] = []
        var agreeingNo: [UndeterminedReason] = []
        for reason in ComparisonOverviewTests.allReasons {
            let settleRoot = try makeTemporaryRoot()
            let diffRoot = try makeTemporaryRoot()
            defer {
                try? FileManager.default.removeItem(at: settleRoot)
                try? FileManager.default.removeItem(at: diffRoot)
            }
            let (forSettle, _) = await settleScenario(for: reason, temporaryRoot: settleRoot)
            let (forDiff, _) = await settleScenario(for: reason, temporaryRoot: diffRoot)
            // Positive: both walks produced this reason, so the two outcomes
            // below are about the same pair.
            #expect(forSettle.comparison.rows.map(\.state) == [.undetermined(reason)], "\(reason)")
            #expect(forDiff.comparison.rows.map(\.state) == [.undetermined(reason)], "\(reason)")

            let settled = (try? await forSettle.comparison.settleUndetermined(rowAt: 0))
                .map { $0 == .same || $0 == .differs } ?? false
            var diffed = false
            if let result = try? await forDiff.comparison.diff(forRowAt: 0), case .success = result {
                diffed = true
            }
            #expect(settled == diffed, "\(reason): settled \(settled), diffed \(diffed)")
            if settled { agreeingYes.append(reason) } else { agreeingNo.append(reason) }
        }
        // Positive counts, so a loop that agreed about nothing cannot pass.
        #expect(agreeingYes.count == 5, "\(agreeingYes)")
        #expect(agreeingNo == [.linkOnASide, .unreadable])
    }

    /// The kind is read BEFORE the size, so a directory is refused as what it
    /// is rather than as an oversized file. Both orders of that question give
    /// a true answer; only one of them gives the useful one.
    @Test func aDirectoryIsRefusedAsOneRatherThanAsAnOversizedFile() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 0x61, count: DiffEligibility.ceilingBytes + 1)
        let rig = makeFilePairRig(
            left: big, right: data("small"), temporaryRoot: root, leftKind: .directory)

        let result = try await rig.comparison.diffFilePair()

        #expect(result == .failure(.notAnOrdinaryFile(side: .left, path: "/L/f")))
        // Positive beside it: the SAME oversized fixture, as an ordinary
        // file, still refuses for its size.
        let asAFile = makeFilePairRig(left: big, right: data("small"), temporaryRoot: root)
        #expect(try await asAFile.comparison.diffFilePair() == .failure(
            .tooLarge(bytes: DiffEligibility.ceilingBytes + 1, ceiling: DiffEligibility.ceilingBytes)))
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

    /// The real teardown path: release, then the queue's `cancelAll`, whose
    /// waiter throws `CancellationError`. The fetch has to translate that,
    /// because "cancelled" is not what happened to the user's pair; the
    /// session was closed. Asked through `fetchPair` and not through a diff,
    /// because the diff entry points wrap the whole operation in a second
    /// translation, which would answer `sessionClosed` here even with the
    /// fetch's own removed (found by planting exactly that). The two explicit
    /// checks in the fetch are not what this reaches: the left transfer is
    /// cancelled, so it never completes.
    @Test func aTransferCancelledByTheTeardownIsReportedAsSessionClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = ComparisonHolder()
        let rig = await makeFolderRig(
            left: ["a": data("x")], right: ["a": data("y")], temporaryRoot: root,
            onLeftRead: { _ in await holder.releaseAndCancelTheQueue() })
        holder.comparison = rig.comparison
        holder.queue = rig.queue
        let row = try #require(rig.comparison.rows.first)

        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await rig.comparison.fetchPair(row)
        }

        // Positive: the transfer was CANCELLED, not completed, so the error
        // the fetch saw was the queue's and the translation ran.
        #expect(rig.queue.items.count == 1)
        #expect(rig.queue.items.first?.status == .cancelled)
        #expect(rig.right.reads.isEmpty)
        #expect(rig.comparison.temporaryDirectory == nil)
    }

    /// A connection closed under the `stat` before any fetch: the backend
    /// throws its own error, and the comparison says the session is closed.
    @Test func aReleaseDuringTheStatReportsSessionClosedAndNotTheBackendsError() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = ComparisonHolder()
        let rig = makeFilePairRig(
            left: data("x"), right: data("y"), temporaryRoot: root,
            onLeftStat: { path in
                await MainActor.run {
                    holder.comparison?.cancel()
                    holder.comparison?.releaseFileSystems()
                }
                throw RemoteFSError.notFound(path: path)
            })
        holder.comparison = rig.comparison

        await #expect(throws: ComparisonFetchError.sessionClosed) {
            try await rig.comparison.diffFilePair()
        }

        // Positive: the stat was reached, and nothing was fetched after it.
        #expect(rig.left.reads.isEmpty)
        #expect(rig.queue.items.isEmpty)
    }

    // MARK: - 7. The temporary directory

    /// `cancel()` stops the walk and nothing else: the files of a diff the
    /// user is reading stay. `releaseFileSystems()` is what removes them.
    @Test func theTemporaryDirectoryExistsAfterTheFirstFetchAndSurvivesACancel() async throws {
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

        #expect(rig.comparison.temporaryDirectory == directory)
        #expect(FileManager.default.fileExists(atPath: urls.left.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: urls.right.path(percentEncoded: false)))

        rig.comparison.releaseFileSystems()

        #expect(rig.comparison.temporaryDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: urls.left.path(percentEncoded: false)))
    }

    /// The sequence that made the brief's `cancel()`-removes-the-directory
    /// wrong: a diff is being fetched, the user presses Cancel on the walk's
    /// progress line. The walk's cancel must not reach the diff.
    @Test func aCancelOfTheWalkDuringADiffDoesNotKillTheDiff() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = ComparisonHolder()
        let rig = makeFilePairRig(
            left: data("x\n"), right: data("y\n"), temporaryRoot: root,
            onLeftRead: { _ in await MainActor.run { holder.comparison?.cancel() } })
        holder.comparison = rig.comparison

        let result = try await rig.comparison.diffFilePair()

        // Positive: the cancel DID land during the fetch (the left side was
        // being read, and the comparison reports itself cancelled).
        #expect(rig.left.reads == ["/L/f"])
        guard case .cancelled? = rig.comparison.outcome else {
            Issue.record("expected .cancelled, got \(String(describing: rig.comparison.outcome))")
            return
        }
        #expect(hunks(result)?.count == 1)
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
    var queue: TransferQueueViewModel?

    /// What `TabTeardown` does to a comparison, in its order: end the
    /// comparison, let go of its connection, and cancel the queue's
    /// transfers. A transfer in flight then ends in the queue's
    /// `CancellationError`, which is what a fetch sees in a real teardown.
    func releaseAndCancelTheQueue() async {
        comparison?.cancel()
        comparison?.releaseFileSystems()
        await queue?.cancelAll(reason: .userRequested)
    }

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

/// A row whose two sides' paths are its relative path under each root, which
/// is what a walk over two roots whose entries are spelled ALIKE produces.
/// For a test whose subject is not the two paths. A pair the second pairing
/// pass made is spelled differently on each side and is not this shape;
/// `FolderComparisonTests` builds those rows itself.
///
/// `root + "/" + relativePath`, as `RemotePath.join` spells it for a root
/// that does not already end in a slash — which no root here does.
func fixtureRow(
    _ relativePath: String, _ state: ComparisonState,
    leftRoot: String = "/L", rightRoot: String = "/R"
) -> ComparisonRow {
    ComparisonRow(
        relativePath: relativePath, leftPath: leftRoot + "/" + relativePath,
        rightPath: rightRoot + "/" + relativePath, state: state)
}

/// A fixture keyed by its name relative to a root, re-keyed under that root.
/// The join is on the BYTES — `BytePath("/L/" + name)` — so a name in one
/// normalization form stays in it.
func under<Value>(_ root: String, _ fixture: [BytePath: Value]) -> [BytePath: Value] {
    Dictionary(uniqueKeysWithValues: fixture.map { (BytePath(root + "/" + $0.key.path), $0.value) })
}

/// An in-memory file system that records what it was asked. `list` answers
/// the direct children of a directory from the keys of `files`.
///
/// **Every table is keyed by `BytePath`, never by `String`.** A `String` key
/// folds canonically equivalent spellings together, so a fake keyed that way
/// answers an NFD lookup from its NFC entry and no test on it can see a fetch
/// aimed at a path built out of the wrong side's spelling. `BytePath`'s own
/// doc comment holds the measurement. A dictionary literal is unchanged — the
/// keys convert through `ExpressibleByStringLiteral` — and a lookup from a
/// path the code under test built says `BytePath(path)`. `list` compares the
/// parent directory the same way, because `RemotePath.parent(of:)` hands back
/// a `String` and `==` on two of those folds as well.
final class MemoryFS: RemoteFileSystem, RemoteChecksumProvider, Sendable {
    private struct State {
        var files: [BytePath: Data]
        var reads: [String] = []
        var statCalls = 0
        var listCalls = 0
        var checksumCalls = 0
    }
    private let state: Mutex<State>
    private let reportsSizes: Bool
    private let onRead: @Sendable (String) async -> Void
    private let onStat: @Sendable (String) async throws -> Void
    /// What `stat` and `list` report as the KIND of a path. Anything not
    /// named here is an ordinary file, which is what every fixture that
    /// predates the kind check wants.
    private let kinds: [BytePath: RemoteFileKind]
    /// What `remoteChecksum` answers. Unavailable by default, which is what
    /// every fixture that predates the reason split wants.
    private let checksum: RemoteChecksumOutcome
    /// Directories whose listing throws, which is how a walk ends up with an
    /// `.undetermined(.unreadable)` row.
    private let unlistable: Set<BytePath>

    init(
        files: [BytePath: Data], reportsSizes: Bool = true,
        kinds: [BytePath: RemoteFileKind] = [:],
        checksum: RemoteChecksumOutcome = .unavailableOnThisConnection,
        unlistable: Set<BytePath> = [],
        onRead: @escaping @Sendable (String) async -> Void = { _ in },
        onStat: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.state = Mutex(State(files: files))
        self.reportsSizes = reportsSizes
        self.kinds = kinds
        self.checksum = checksum
        self.unlistable = unlistable
        self.onRead = onRead
        self.onStat = onStat
    }

    /// The paths `readStream` was asked for, as they were spelled. Compare
    /// them through `BytePath` where a test is about a spelling: `==` on two
    /// `String`s folds the normalization forms this fake exists to tell apart.
    var reads: [String] { state.withLock { $0.reads } }
    /// `reads`, byte-keyed, for a test whose subject IS the spelling.
    var readBytePaths: [BytePath] { state.withLock { $0.reads.map { BytePath($0) } } }
    var statCalls: Int { state.withLock { $0.statCalls } }
    var listCalls: Int { state.withLock { $0.listCalls } }
    var checksumCalls: Int { state.withLock { $0.checksumCalls } }

    private func item(_ path: BytePath, _ data: Data) -> RemoteFileItem {
        let spelled = path.path
        return RemoteFileItem(
            name: spelled.split(separator: "/").last.map(String.init) ?? spelled, path: spelled,
            kind: kinds[path] ?? .file,
            size: reportsSizes ? UInt64(data.count) : nil)
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        if unlistable.contains(BytePath(path)) { throw RemoteFSError.notFound(path: path) }
        let files = state.withLock { state -> [BytePath: Data] in
            state.listCalls += 1
            return state.files
        }
        let parent = BytePath(path)
        return files.filter { BytePath(RemotePath.parent(of: $0.key.path)) == parent }
            .map { item($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }

    func stat(path: String) async throws -> RemoteFileItem {
        try await onStat(path)
        let data = state.withLock { state -> Data? in
            state.statCalls += 1
            return state.files[BytePath(path)]
        }
        guard let data else { throw RemoteFSError.notFound(path: path) }
        return item(BytePath(path), data)
    }

    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let data = state.withLock { state -> Data? in
            state.reads.append(path)
            return state.files[BytePath(path)]
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
        return checksum
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
