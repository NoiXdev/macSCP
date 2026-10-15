import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// `@MainActor` because `FolderComparison.walk` is: its two callbacks are
/// plain closures that mutate the locals captured here.
@Suite @MainActor struct FolderComparisonTests {
    @Test func rowsCarryThePathRelativeToEachRoot() async throws {
        let left = FakeFS(listings: ["/l": [dir("sub")], "/l/sub": [file("a", 1)]])
        let right = FakeFS(listings: ["/r": [dir("sub")], "/r/sub": [file("a", 2)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.contains { $0.relativePath == "sub/a" && $0.state == .differs })
        // The directory pair is descended into and not reported itself: a
        // `.bothDirectories` row would say nothing the children do not.
        #expect(!rows.contains { $0.relativePath == "sub" })
        // Positive control for the check above: the walk did reach "sub".
        #expect(left.listedPaths == ["/l", "/l/sub"])
    }

    /// A root of "/" must not produce "//sub" for its children.
    @Test func aRootOfSlashJoinsWithoutDoubledSeparators() async throws {
        let left = FakeFS(listings: ["/": [dir("sub")], "/sub": [file("a", 1)]])
        let right = FakeFS(listings: ["/": [dir("sub")], "/sub": [file("a", 2)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/", right: right, rightRoot: "/",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.map(\.relativePath) == ["sub/a"])
        #expect(left.listedPaths == ["/", "/sub"])
    }

    @Test func aDirectoryOnOneSideOnlyIsOneRowAndIsNotDescendedInto() async throws {
        let left = FakeFS(listings: ["/l": [dir("gone")], "/l/gone": [file("x", 1)]])
        let right = FakeFS(listings: ["/r": []])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.map(\.relativePath) == ["gone"])
        #expect(rows.first?.state == .onlyLeft)
        #expect(left.listCalls == 1)  // the root only
    }

    /// Descent follows `.bothDirectories` and nothing else. A matching file
    /// pair is `.same`, is reported, and is never listed.
    @Test func aMatchingFilePairIsReportedAndNotDescendedInto() async throws {
        let hex = String(repeating: "a", count: 64)
        let left = FakeFS(
            listings: ["/l": [file("a", 7)], "/l/a": [file("trap", 1)]],
            checksums: ["/l/a": [.sha256: hex]])
        let right = FakeFS(
            listings: ["/r": [file("a", 7)], "/r/a": [file("trap", 1)]],
            checksums: ["/r/a": [.sha256: hex]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows == [expectedRow("a", .same)])
        #expect(left.listedPaths == ["/l"])
        // Positive control: the pair really was compared, so `.same` is a
        // measured answer and not a default.
        #expect(left.checksumCalls == 1)
    }

    /// Review Focus 5: the cancel must stop the WALK, not just the reporting.
    /// The task is created on the main actor and cancelled before this test
    /// next suspends, so it cannot have begun: the first check must stop it
    /// before a single listing.
    @Test func cancellingStopsTheWalkRatherThanOnlyTheReporting() async throws {
        let left = FakeFS(listings: deepTree(prefix: "/l", depth: 40))
        let right = FakeFS(listings: deepTree(prefix: "/r", depth: 40))
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { _ in }, onProgress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.listCalls == 0)
        #expect(right.listCalls == 0)
    }

    /// The per-directory check, alone: a level of empty directories has no
    /// pairs, so the per-pair check never runs and only the check before each
    /// listing can stop the walk. Cancelled from inside the second listing;
    /// without that check all ten children would still be listed.
    @Test func aCancelAcrossEmptyDirectoriesIsStoppedByTheCheckBeforeEachListing() async throws {
        let names = (0..<10).map { "e\($0)" }
        var listings: [BytePath: [RemoteFileItem]] = ["/l": names.map { dir($0) }]
        var rightListings: [BytePath: [RemoteFileItem]] = ["/r": names.map { dir($0) }]
        for name in names {
            listings[BytePath("/l/" + name)] = []
            rightListings[BytePath("/r/" + name)] = []
        }
        let left = FakeFS(listings: listings)
        let right = FakeFS(listings: rightListings)
        left.onList = { count in
            if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { _ in }, onProgress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.listCalls == 2)  // the root, then the one that was cancelled
    }

    /// The same property with the mechanism proven to have run: the walk is
    /// cancelled from INSIDE its third listing, after it has demonstrably
    /// descended twice, and must not list a fourth directory. The count is
    /// exact because nothing between a listing and the next check can list.
    @Test func aCancelDuringTheWalkStopsItBeforeTheNextListing() async throws {
        let left = FakeFS(listings: deepTree(prefix: "/l", depth: 40))
        let right = FakeFS(listings: deepTree(prefix: "/r", depth: 40))
        left.onList = { count in
            if count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var progressReports = 0
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { _ in }, onProgress: { _ in progressReports += 1 })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.listCalls == 3)
        #expect(right.listCalls == 3)
        // Positive control: levels 1 and 2 ran to completion first.
        #expect(progressReports == 2)
    }

    /// The per-pair check: a flat directory of equal-size files, cancelled
    /// while the second pair is being classified. The pair in flight finishes;
    /// the third is never asked about.
    @Test func aCancelDuringAPairStopsBeforeTheNextPair() async throws {
        let hex = String(repeating: "c", count: 64)
        let items = (0..<10).map { file("f\($0)", 5) }
        var leftSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums[BytePath("/l/" + item.name)] = [.sha256: hex]
            rightSums[BytePath("/r/" + item.name)] = [.sha256: hex]
        }
        let left = FakeFS(listings: ["/l": items], checksums: leftSums)
        let right = FakeFS(listings: ["/r": items], checksums: rightSums)
        left.onChecksum = { count in
            if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var rows: [ComparisonRow] = []
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.checksumCalls == 2)
        #expect(rows.count == 2)
    }

    /// The ordinary local-to-S3 pair: one side answers from an ETag, which is
    /// always MD5, the other computes the user's choice. Without the retry
    /// every equal-size pair comes back `.algorithmsDiffer`.
    @Test func anETagSideIsRetriedWithMD5RatherThanLeftUndetermined() async throws {
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let left = FakeFS(
            listings: ["/l": [file("a", 7)]],
            checksums: ["/l/a": [.sha256: String(repeating: "e", count: 64), .md5: md5]])
        let right = FakeFS(
            listings: ["/r": [file("a", 7)]],
            checksums: ["/r/a": [.md5: md5]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.first { $0.relativePath == "a" }?.state == .same)
        // Positive control: the first pass asked for sha256, the retry for md5.
        // Both sides are asserted: the ETag side answers md5 whatever it is
        // asked, so only its own record shows what the retry asked of it.
        #expect(left.askedAlgorithms == [.sha256, .md5])
        #expect(right.askedAlgorithms == [.sha256, .md5])
    }

    /// The mirror: the ETag is on the LEFT. The retry is symmetric, so it
    /// must not matter which side held it.
    @Test func anETagOnTheLeftIsRetriedWithMD5Too() async throws {
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let left = FakeFS(
            listings: ["/l": [file("a", 7)]],
            checksums: ["/l/a": [.md5: md5]])
        let right = FakeFS(
            listings: ["/r": [file("a", 7)]],
            checksums: ["/r/a": [.sha256: String(repeating: "e", count: 64), .md5: md5]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.first { $0.relativePath == "a" }?.state == .same)
        #expect(left.askedAlgorithms == [.sha256, .md5])
        #expect(right.askedAlgorithms == [.sha256, .md5])
    }

    /// The retry must not loop: two sides that still disagree under MD5 stay
    /// undetermined rather than retrying forever. Each side answers with an
    /// algorithm of its own whatever it is asked, so both passes disagree.
    @Test func theRetryHappensAtMostOnce() async throws {
        let left = FakeFS(
            listings: ["/l": [file("a", 7)]],
            checksums: ["/l/a": [.md5: String(repeating: "a", count: 32)]])
        let right = FakeFS(
            listings: ["/r": [file("a", 7)]],
            checksums: ["/r/a": [.sha1: String(repeating: "b", count: 40)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.first?.state == .undetermined(.algorithmsDiffer))
        #expect(left.askedAlgorithms == [.sha256, .md5])  // first pass, one retry, no third
    }

    /// With MD5 already chosen there is nothing different to retry with.
    @Test func chosenMD5IsNotRetried() async throws {
        let left = FakeFS(
            listings: ["/l": [file("a", 7)]],
            checksums: ["/l/a": [.md5: String(repeating: "a", count: 32)]])
        let right = FakeFS(
            listings: ["/r": [file("a", 7)]],
            checksums: ["/r/a": [.sha1: String(repeating: "b", count: 40)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .md5, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.first?.state == .undetermined(.algorithmsDiffer))
        #expect(left.askedAlgorithms == [.md5])
    }

    /// The laziness the design rests on: a size difference settles a pair
    /// without any checksum, retry or not.
    @Test func aSizeDifferenceAsksNoChecksumAtAll() async throws {
        let left = FakeFS(listings: ["/l": [file("a", 1)]])
        let right = FakeFS(listings: ["/r": [file("a", 2)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.first?.state == .differs)
        #expect(left.checksumCalls == 0)
        #expect(right.checksumCalls == 0)
    }

    @Test func progressReportsTheDirectoriesSeenSoFar() async throws {
        let left = FakeFS(listings: ["/l": [dir("a")], "/l/a": []])
        let right = FakeFS(listings: ["/r": [dir("a")], "/r/a": []])
        var seen: [Int] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { _ in },
            onProgress: { seen.append($0.directoriesVisited) })
        #expect(seen == [1, 2])
    }

    @Test func progressCountsTheRowsProducedSoFar() async throws {
        let left = FakeFS(listings: ["/l": [dir("a"), file("x", 1)], "/l/a": [file("y", 1)]])
        let right = FakeFS(listings: ["/r": [dir("a"), file("x", 2)], "/r/a": []])
        var last: ComparisonProgress?
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { _ in }, onProgress: { last = $0 })
        // x differs; a/y is only on the left.
        #expect(last == ComparisonProgress(directoriesVisited: 2, rowsProduced: 2))
    }

    // MARK: - A subtree that cannot be read is a row, not the end

    /// Either side failing to list a subdirectory gives that directory ONE
    /// `.unreadable` row and is not descended into. The sibling processed
    /// AFTER it still reports its rows: that is the positive control, without
    /// which this would pass on a walk that simply stopped early.
    @Test(arguments: [true, false])
    func anUnreadableSubdirectoryIsOneRowAndTheWalkContinues(onTheLeft: Bool) async throws {
        let denied: [BytePath: any Error] = [
            (onTheLeft ? "/l/bad" : "/r/bad"): RemoteFSError.permissionDenied(path: "bad")
        ]
        let left = FakeFS(
            listings: [
                "/l": [dir("bad"), dir("good")],
                "/l/bad": [dir("inner")], "/l/bad/inner": [file("deep", 1)],
                "/l/good": [file("x", 1)],
            ],
            listFailures: onTheLeft ? denied : [:])
        let right = FakeFS(
            listings: [
                "/r": [dir("bad"), dir("good")],
                "/r/bad": [dir("inner")], "/r/bad/inner": [file("deep", 2)],
                "/r/good": [file("x", 2)],
            ],
            listFailures: onTheLeft ? [:] : denied)
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.filter { $0.relativePath == "bad" }
            == [expectedRow("bad", .undetermined(.unreadable))])
        #expect(!rows.contains { $0.relativePath.hasPrefix("bad/") })
        #expect(!left.listedPaths.contains("/l/bad/inner"))
        // Positive control: "good" comes after "bad" in the queue.
        #expect(rows.contains { $0.relativePath == "good/x" && $0.state == .differs })
    }

    /// One pair whose classification throws is that pair's row; its siblings
    /// in the same directory are still classified.
    @Test func aPairWhoseClassificationThrowsIsOneRowAndItsSiblingsAreStillClassified() async throws {
        let hex = String(repeating: "d", count: 64)
        let items = ["a", "b", "c"].map { file($0, 5) }
        let left = FakeFS(
            listings: ["/l": items],
            checksums: ["/l/a": [.sha256: hex], "/l/b": [.sha256: hex], "/l/c": [.sha256: hex]],
            checksumFailures: ["/l/b": RemoteFSError.protocolError(reason: "unreadable")])
        let right = FakeFS(
            listings: ["/r": items],
            checksums: ["/r/a": [.sha256: hex], "/r/b": [.sha256: hex], "/r/c": [.sha256: hex]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows == [
            expectedRow("a", .same),
            expectedRow("b", .undetermined(.unreadable)),
            expectedRow("c", .same),
        ])
    }

    /// The root is the exception: the user chose those two folders, and with
    /// one unreadable there is nothing to compare.
    @Test(arguments: [true, false])
    func aFailureListingTheRootStillThrows(onTheLeft: Bool) async throws {
        let denied: [BytePath: any Error] = [
            (onTheLeft ? "/l" : "/r"): RemoteFSError.permissionDenied(path: "root")
        ]
        let left = FakeFS(listings: ["/l": [file("a", 1)]], listFailures: onTheLeft ? denied : [:])
        let right = FakeFS(listings: ["/r": [file("a", 1)]], listFailures: onTheLeft ? [:] : denied)
        var rows: [ComparisonRow] = []
        await #expect(throws: RemoteFSError.self) {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        #expect(rows.isEmpty)
        // Positive control: the failing listing was reached.
        #expect(left.listCalls == 1)
    }

    /// A cancel that arrives as a thrown `CancellationError` from a LISTING
    /// (what a cancelled network call does) must propagate, not become an
    /// `.unreadable` row. The task is not cancelled here: the error alone has
    /// to be enough.
    @Test func aCancellationErrorFromAListingPropagates() async throws {
        let left = FakeFS(
            listings: deepTree(prefix: "/l", depth: 40),
            listFailures: ["/l/d/d": CancellationError()])
        let right = FakeFS(listings: deepTree(prefix: "/r", depth: 40))
        var rows: [ComparisonRow] = []
        await #expect(throws: CancellationError.self) {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        #expect(left.listCalls == 3)  // positive control: it got that far, and no further
        #expect(rows.isEmpty)
    }

    /// The same through the task: a backend that fails with an error of its
    /// own because the task was cancelled (here `URLError.cancelled`, not a
    /// `CancellationError`) is still a cancel, and must not be an
    /// `.unreadable` row either.
    @Test func aCancelledTaskIsNotMistakenForAnUnreadableDirectory() async throws {
        let left = FakeFS(
            listings: deepTree(prefix: "/l", depth: 40),
            listFailures: ["/l/d/d": URLError(.cancelled)])
        let right = FakeFS(listings: deepTree(prefix: "/r", depth: 40))
        left.onList = { count in
            if count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var rows: [ComparisonRow] = []
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.listCalls == 3)
        #expect(rows.isEmpty)
    }

    /// The classification site, same two cases: a `CancellationError` thrown
    /// by a checksum stops the walk at that pair.
    @Test func aCancellationErrorFromAChecksumPropagates() async throws {
        let hex = String(repeating: "e", count: 64)
        let items = (0..<5).map { file("f\($0)", 5) }
        var leftSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums[BytePath("/l/" + item.name)] = [.sha256: hex]
            rightSums[BytePath("/r/" + item.name)] = [.sha256: hex]
        }
        let left = FakeFS(
            listings: ["/l": items], checksums: leftSums,
            checksumFailures: ["/l/f1": CancellationError()])
        let right = FakeFS(listings: ["/r": items], checksums: rightSums)
        var rows: [ComparisonRow] = []
        await #expect(throws: CancellationError.self) {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        #expect(left.checksumCalls == 2)  // f0, then the one that was cancelled
        #expect(rows.map(\.relativePath) == ["f0"])
    }

    @Test func aCancelledTaskWhoseChecksumFailsWithItsOwnErrorIsStillACancel() async throws {
        let hex = String(repeating: "f", count: 64)
        let items = (0..<5).map { file("f\($0)", 5) }
        var leftSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [BytePath: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums[BytePath("/l/" + item.name)] = [.sha256: hex]
            rightSums[BytePath("/r/" + item.name)] = [.sha256: hex]
        }
        let left = FakeFS(
            listings: ["/l": items], checksums: leftSums,
            checksumFailures: ["/l/f1": URLError(.cancelled)])
        let right = FakeFS(listings: ["/r": items], checksums: rightSums)
        left.onChecksum = { count in
            if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var rows: [ComparisonRow] = []
        let task = Task {
            try await FolderComparison.walk(
                left: left, leftRoot: "/l", right: right, rightRoot: "/r",
                algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(left.checksumCalls == 2)
        #expect(rows.map(\.relativePath) == ["f0"])
    }

    // MARK: - Which pairs are descended into, and in what order

    /// A directory against a FILE is a `.typeMismatch` row and nothing more.
    /// Descending would list the directory's side against the file's path and
    /// turn into an `.unreadable` row, a row that says something false about
    /// the tree. Neither side may be listed below the root.
    @Test(arguments: [true, false])
    func aDirectoryAgainstAFileIsOneRowAndIsNotDescendedInto(directoryOnTheLeft: Bool) async throws {
        let left = FakeFS(listings: directoryOnTheLeft
            ? ["/l": [dir("x")], "/l/x": [file("y", 1)]] : ["/l": [file("x", 1)]])
        let right = FakeFS(listings: directoryOnTheLeft
            ? ["/r": [file("x", 1)]] : ["/r": [dir("x")], "/r/x": [file("y", 1)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows == [expectedRow("x", .typeMismatch)])
        #expect(left.listedPaths == ["/l"])
        #expect(right.listedPaths == ["/r"])
    }

    /// A symlink is `.undetermined(.linkOnASide)` and is not followed,
    /// whether the other side holds a symlink or a directory.
    @Test func aSymlinkPairIsOneRowAndIsNotDescendedInto() async throws {
        let link = { (name: String) in RemoteFileItem(name: name, path: name, kind: .symlink) }
        let left = FakeFS(listings: [
            "/l": [link("both"), link("mixed")], "/l/both": [file("y", 1)], "/l/mixed": [file("y", 1)],
        ])
        let right = FakeFS(listings: [
            "/r": [link("both"), dir("mixed")], "/r/both": [file("y", 1)], "/r/mixed": [file("y", 1)],
        ])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows == [
            expectedRow("both", .undetermined(.linkOnASide)),
            expectedRow("mixed", .undetermined(.linkOnASide)),
        ])
        #expect(left.listedPaths == ["/l"])
        #expect(right.listedPaths == ["/r"])
    }

    /// Breadth-first: a level is finished before the next is started, and
    /// within a level the directories are taken in the order they were found.
    /// A stack would list "b" before "a"; the unreadable-subdirectory test
    /// above relies on "good" coming after "bad" for its positive control, so
    /// this is what that control stands on.
    @Test func directoriesAreVisitedBreadthFirstInTheOrderTheyWereFound() async throws {
        let left = FakeFS(listings: [
            "/l": [dir("a"), dir("b")], "/l/a": [dir("deep"), file("x", 1)],
            "/l/a/deep": [file("z", 1)], "/l/b": [file("y", 1)],
        ])
        let right = FakeFS(listings: [
            "/r": [dir("a"), dir("b")], "/r/a": [dir("deep"), file("x", 2)],
            "/r/a/deep": [file("z", 2)], "/r/b": [file("y", 2)],
        ])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(left.listedPaths == ["/l", "/l/a", "/l/b", "/l/a/deep"])
        #expect(rows.map(\.relativePath) == ["a/x", "b/y", "a/deep/z"])
    }

    // MARK: - A pair only the second pass could make

    /// `ComparisonPairing.pairs` has a second pass for exactly one case: the
    /// local side hands back NFD and the server stored NFC, so the same file
    /// must not appear as two rows. The pair it makes then has a DIFFERENT
    /// spelling on each side, and nothing may join one of them to both roots.
    ///
    /// A directory pair of that shape, descended. Measured 2026-10-15 with
    /// the fakes keyed by UTF-8 bytes (see `BytePath`): with one relative
    /// path joined to both roots, the right-hand listing of the left's
    /// spelling — a path the right side does not have — threw, and the whole
    /// subtree came back as one `.undetermined(.unreadable)` row saying
    /// nothing here could be read. The directory is readable; only the
    /// spelling was wrong.
    @Test func aDirectoryPairedOnlyByItsNormalizedNameIsDescendedOnBothSides() async throws {
        let nfd = "su\u{0308}b"  // s, u, combining diaeresis
        let nfc = "s\u{00FC}b"  // s, ü
        let left = FakeFS(listings: [
            "/l": [dir(nfd)], BytePath("/l/" + nfd): [file("a", 1)],
        ])
        let right = FakeFS(listings: [
            "/r": [dir(nfc)], BytePath("/r/" + nfc): [file("a", 2)],
        ])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        // The child of the pair, classified. Not one unreadable row standing
        // for the subtree.
        #expect(rows.count == 1)
        #expect(rows.first?.state == .differs)
        #expect(rows.first.map { Array($0.relativePath.utf8) } == Array((nfd + "/a").utf8))
        // Positive controls: the pair WAS made, and the walk DID descend —
        // each side listed its root and then its own spelling of the pair.
        #expect(left.listedPaths.map { BytePath($0) } == ["/l", BytePath("/l/" + nfd)])
        #expect(right.listedPaths.map { BytePath($0) } == ["/r", BytePath("/r/" + nfc)])
    }

    /// The same pair as a FILE pair: the row has to carry each side's own
    /// path, because that is what the App layer fetches both sides from
    /// (`Comparison.fetchPair`, `diff(forRowAt:)`, `settleUndetermined`).
    @Test func aFilePairedOnlyByItsNormalizedNameCarriesEachSidesOwnPath() async throws {
        let nfd = "su\u{0308}b.txt"
        let nfc = "s\u{00FC}b.txt"
        let left = FakeFS(listings: ["/l": [file(nfd, 7)]])
        let right = FakeFS(listings: ["/r": [file(nfc, 7)]])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(BytePath(row.leftPath) == BytePath("/l/" + nfd))
        #expect(BytePath(row.rightPath) == BytePath("/r/" + nfc))
        // Positive control: the pair WAS made by the second pass — one row,
        // not two one-sided ones — and the sizes tie, so it is undetermined
        // on this connection rather than `.differs`.
        #expect(row.state == .undetermined(.checksumUnavailable))
    }

    /// A ONE-SIDED row still carries two paths, and the absent side's is this
    /// row's name under that root. Nothing fetches it; what matters is that
    /// the row the user reads is complete.
    @Test func aRowWithOneSideCarriesThatSidesPathAndTheOtherRootsSpelling() async throws {
        let left = FakeFS(listings: ["/l": [file("gone", 1)]])
        let right = FakeFS(listings: ["/r": []])
        var rows: [ComparisonRow] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { rows.append($0) }, onProgress: { _ in })
        #expect(rows.map(\.relativePath) == ["gone"])
        #expect(rows.first?.state == .onlyLeft)
        #expect(rows.first?.leftPath == "/l/gone")
        #expect(rows.first?.rightPath == "/r/gone")
    }

    // MARK: - The accounting of an unreadable directory

    /// A directory that failed to list counts as visited, and its row counts
    /// in `rowsProduced`, and it is reported like any other level. Pinned
    /// here because Tasks 10 and 11 build their progress display on it.
    @Test func anUnreadableDirectoryCountsAsVisitedAndItsRowAsProduced() async throws {
        let left = FakeFS(
            listings: ["/l": [dir("bad"), file("x", 1)]],
            listFailures: ["/l/bad": RemoteFSError.permissionDenied(path: "bad")])
        let right = FakeFS(listings: ["/r": [dir("bad"), file("x", 2)], "/r/bad": []])
        var reports: [ComparisonProgress] = []
        try await FolderComparison.walk(
            left: left, leftRoot: "/l", right: right, rightRoot: "/r",
            algorithm: .sha256, onRow: { _ in }, onProgress: { reports.append($0) })
        #expect(reports == [
            ComparisonProgress(directoriesVisited: 1, rowsProduced: 1),  // the root: x differs
            ComparisonProgress(directoriesVisited: 2, rowsProduced: 2),  // bad: unreadable
        ])
    }
}

// MARK: - Helpers

/// An expected row of a walk over `/l` and `/r`, whose two sides' paths are
/// its relative path under each root. For a pair whose two sides are spelled
/// ALIKE; a pair the second pairing pass made is not this shape and is
/// asserted path by path.
private func expectedRow(_ relativePath: String, _ state: ComparisonState) -> ComparisonRow {
    ComparisonRow(
        relativePath: relativePath, leftPath: "/l/" + relativePath,
        rightPath: "/r/" + relativePath, state: state)
}

private func dir(_ name: String) -> RemoteFileItem {
    RemoteFileItem(name: name, path: name, kind: .directory)
}

private func file(_ name: String, _ size: UInt64) -> RemoteFileItem {
    RemoteFileItem(name: name, path: name, kind: .file, size: size)
}

/// `prefix` lists one directory "d", which lists one directory "d", and so on
/// `depth` levels down; the last one is empty.
private func deepTree(prefix: String, depth: Int) -> [BytePath: [RemoteFileItem]] {
    var listings: [BytePath: [RemoteFileItem]] = [:]
    var path = prefix
    for _ in 0..<depth {
        listings[BytePath(path)] = [dir("d")]
        path = RemotePath.join(path, "d")
    }
    listings[BytePath(path)] = []
    return listings
}

/// A file system that answers `list` from a dictionary and checksums from
/// another, and COUNTS both, so a test can assert that a walk stopped rather
/// than merely stopped reporting.
///
/// **Every table is keyed by `BytePath`, never by `String`.** A `String` key
/// folds canonically equivalent spellings together, so a fake keyed that way
/// answers an NFD lookup from its NFC entry and no test on it can see a path
/// built out of the wrong side's spelling. `BytePath`'s own doc comment holds
/// the measurement. A dictionary literal is unchanged — the keys convert
/// through `ExpressibleByStringLiteral` — and a lookup from a path the code
/// under test built says `BytePath(path)`.
///
/// `list` rewrites each item's `path` to `directory + name`, as a real
/// backend does, so the checksum table can be keyed by the path a file really
/// has. A directory that is not in `listings` throws `notFound`, so a walk
/// that asks for a path it should not have built is not read as an empty
/// folder: below the root that surfaces as an `.unreadable` row a test can
/// see, at the root as a thrown error.
///
/// A checksum request is answered with the requested algorithm when the table
/// has it, and otherwise with whatever the table does hold for that path,
/// which is what an object store does (its ETag is MD5 whatever was asked).
/// A path with no table entry answers `.unavailableOnThisConnection`.
private final class FakeFS: RemoteFileSystem, RemoteChecksumProvider, Sendable {
    private struct State {
        var listedPaths: [String] = []
        var asked: [ChecksumAlgorithm] = []
        var onList: (@Sendable (Int) -> Void)?
        var onChecksum: (@Sendable (Int) -> Void)?
    }

    private let listings: [BytePath: [RemoteFileItem]]
    private let checksums: [BytePath: [ChecksumAlgorithm: String]]
    private let listFailures: [BytePath: any Error]
    private let checksumFailures: [BytePath: any Error]
    private let state = Mutex(State())

    /// `listFailures` and `checksumFailures` throw the given error for that
    /// path AFTER the call has been counted and its hook fired, so a test can
    /// cancel the task and fail the call in the same breath, as a cancelled
    /// network call does.
    init(
        listings: [BytePath: [RemoteFileItem]],
        checksums: [BytePath: [ChecksumAlgorithm: String]] = [:],
        listFailures: [BytePath: any Error] = [:],
        checksumFailures: [BytePath: any Error] = [:]
    ) {
        self.listings = listings
        self.checksums = checksums
        self.listFailures = listFailures
        self.checksumFailures = checksumFailures
    }

    // Read after a walk ends, never during one.
    var listCalls: Int { state.withLock { $0.listedPaths.count } }
    var listedPaths: [String] { state.withLock { $0.listedPaths } }
    var checksumCalls: Int { state.withLock { $0.asked.count } }
    var askedAlgorithms: [ChecksumAlgorithm] { state.withLock { $0.asked } }

    /// Fired with the 1-based call number, after the call is counted.
    var onList: (@Sendable (Int) -> Void)? {
        get { state.withLock { $0.onList } }
        set { state.withLock { $0.onList = newValue } }
    }
    var onChecksum: (@Sendable (Int) -> Void)? {
        get { state.withLock { $0.onChecksum } }
        set { state.withLock { $0.onChecksum = newValue } }
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        let (count, hook) = state.withLock { s -> (Int, (@Sendable (Int) -> Void)?) in
            s.listedPaths.append(path)
            return (s.listedPaths.count, s.onList)
        }
        hook?(count)
        if let failure = listFailures[BytePath(path)] { throw failure }
        guard let items = listings[BytePath(path)] else {
            throw RemoteFSError.notFound(path: path)
        }
        return items.map {
            RemoteFileItem(
                name: $0.name, path: RemotePath.join(path, $0.name), kind: $0.kind, size: $0.size)
        }
    }

    func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        let (count, hook) = state.withLock { s -> (Int, (@Sendable (Int) -> Void)?) in
            s.asked.append(algorithm)
            return (s.asked.count, s.onChecksum)
        }
        hook?(count)
        if let failure = checksumFailures[BytePath(path)] { throw failure }
        guard let table = checksums[BytePath(path)] else { return .unavailableOnThisConnection }
        let answered = table[algorithm].map { (algorithm, $0) }
            ?? table.first.map { ($0.key, $0.value) }
        guard let (answeredAlgorithm, hex) = answered,
            let value = FileChecksum.computedOnRemote(answeredAlgorithm, hex: hex)
        else { return .unavailableOnThisConnection }
        return .checksum(value)
    }

    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.notFound(path: path)
    }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {}
    func delete(path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func deleteTree(at path: String) async throws {}
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}
