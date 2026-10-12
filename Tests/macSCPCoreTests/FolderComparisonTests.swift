import Foundation
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
        #expect(rows == [ComparisonRow(relativePath: "a", state: .same)])
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
        var listings: [String: [RemoteFileItem]] = ["/l": names.map { dir($0) }]
        var rightListings: [String: [RemoteFileItem]] = ["/r": names.map { dir($0) }]
        for name in names {
            listings["/l/" + name] = []
            rightListings["/r/" + name] = []
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
        var leftSums: [String: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [String: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums["/l/" + item.name] = [.sha256: hex]
            rightSums["/r/" + item.name] = [.sha256: hex]
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
        let denied: [String: any Error] = [
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
            == [ComparisonRow(relativePath: "bad", state: .undetermined(.unreadable))])
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
            ComparisonRow(relativePath: "a", state: .same),
            ComparisonRow(relativePath: "b", state: .undetermined(.unreadable)),
            ComparisonRow(relativePath: "c", state: .same),
        ])
    }

    /// The root is the exception: the user chose those two folders, and with
    /// one unreadable there is nothing to compare.
    @Test(arguments: [true, false])
    func aFailureListingTheRootStillThrows(onTheLeft: Bool) async throws {
        let denied: [String: any Error] = [
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
        var leftSums: [String: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [String: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums["/l/" + item.name] = [.sha256: hex]
            rightSums["/r/" + item.name] = [.sha256: hex]
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
        var leftSums: [String: [ChecksumAlgorithm: String]] = [:]
        var rightSums: [String: [ChecksumAlgorithm: String]] = [:]
        for item in items {
            leftSums["/l/" + item.name] = [.sha256: hex]
            rightSums["/r/" + item.name] = [.sha256: hex]
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
        #expect(rows == [ComparisonRow(relativePath: "x", state: .typeMismatch)])
        #expect(left.listedPaths == ["/l"])
        #expect(right.listedPaths == ["/r"])
    }

    /// A symlink is `.undetermined(.unsupportedKind)` and is not followed,
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
            ComparisonRow(relativePath: "both", state: .undetermined(.unsupportedKind)),
            ComparisonRow(relativePath: "mixed", state: .undetermined(.unsupportedKind)),
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

private func dir(_ name: String) -> RemoteFileItem {
    RemoteFileItem(name: name, path: name, kind: .directory)
}

private func file(_ name: String, _ size: UInt64) -> RemoteFileItem {
    RemoteFileItem(name: name, path: name, kind: .file, size: size)
}

/// `prefix` lists one directory "d", which lists one directory "d", and so on
/// `depth` levels down; the last one is empty.
private func deepTree(prefix: String, depth: Int) -> [String: [RemoteFileItem]] {
    var listings: [String: [RemoteFileItem]] = [:]
    var path = prefix
    for _ in 0..<depth {
        listings[path] = [dir("d")]
        path = RemotePath.join(path, "d")
    }
    listings[path] = []
    return listings
}

/// A file system that answers `list` from a dictionary and checksums from
/// another, and COUNTS both, so a test can assert that a walk stopped rather
/// than merely stopped reporting.
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

    private let listings: [String: [RemoteFileItem]]
    private let checksums: [String: [ChecksumAlgorithm: String]]
    private let listFailures: [String: any Error]
    private let checksumFailures: [String: any Error]
    private let state = Mutex(State())

    /// `listFailures` and `checksumFailures` throw the given error for that
    /// path AFTER the call has been counted and its hook fired, so a test can
    /// cancel the task and fail the call in the same breath, as a cancelled
    /// network call does.
    init(
        listings: [String: [RemoteFileItem]],
        checksums: [String: [ChecksumAlgorithm: String]] = [:],
        listFailures: [String: any Error] = [:],
        checksumFailures: [String: any Error] = [:]
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
        if let failure = listFailures[path] { throw failure }
        guard let items = listings[path] else { throw RemoteFSError.notFound(path: path) }
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
        if let failure = checksumFailures[path] { throw failure }
        guard let table = checksums[path] else { return .unavailableOnThisConnection }
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
