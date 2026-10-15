import Foundation
import MacSCPTestSupport
import Testing

/// The source-level half of the diff view's ownership rule (Task 7): the
/// comparison model is reached through the tab, and the tab's teardown ends
/// it. `ComparisonOwnershipTests` holds the behaviour; this holds what no
/// value test can reach — WHO may construct a `Comparison`, and WHERE
/// `TabTeardown` ends one.
///
/// Every negative check has a positive one beside it asserting the thing it
/// scans is there at all. Task 9 extends this with the window's half (it
/// holds no file system or connection and resolves the tab through
/// `TabRegistry`), because that file does not exist yet.
@Suite("Comparison ownership wiring guard")
struct ComparisonOwnershipWiringGuardTests {
    private static let sources = SourceCorpus.url(of: .sources)
    private static let appKit = sources.appendingPathComponent("MacSCPAppKit")

    private static func code(_ file: String) throws -> String {
        let view = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return view.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    /// A way to reach the `Comparison` initialiser: the type name not
    /// preceded by another identifier character (`FolderComparison(`,
    /// `ComparisonRow(` are other types), followed by `(`, by `.init` — with
    /// or without the call, since `let make = Comparison.init` is a
    /// construction waiting for its arguments — or by `.self`, the other way
    /// to get a value that constructs one.
    ///
    /// This is a pattern and not a structural boundary on purpose: a
    /// `fileprivate` initialiser would have to live in `SessionTab.swift`,
    /// which Swift allows for a class only as a convenience initialiser
    /// delegating to an accessible designated one — and it would also close
    /// the door on the tests, which build a `Comparison` over a scripted file
    /// system without a connected tab. So the pattern covers both spellings
    /// of the call.
    private static let construction = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])Comparison(\.init\b|\.self\b|\()"#)

    private static func constructions(in code: String) -> Int {
        construction.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// One declaration's brace-balanced body, over the comment- and
    /// string-blanked view, so a statement added to the function cannot push
    /// a call out of a fixed-length prefix.
    private static func declarationBody(_ declaration: String, in file: String) throws -> String {
        let source = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return try TransferQueueBarCancelGuardTests
            .declarationBody(of: declaration, in: source)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func swiftFiles() throws -> [URL] {
        try SourceCorpus.files(under: sources).filter { $0.pathExtension == "swift" }
    }

    // MARK: Construction

    @Test func onlyTheTabConstructsAComparison() throws {
        // Positive: the scan sees the tab's own construction, and there is
        // exactly one.
        let tab = try Self.code("SessionTab.swift")
        #expect(Self.constructions(in: tab) == 1)

        // Negative: no other file under Sources constructs one — not the
        // window, not the quit path, not a view.
        var elsewhere: [String] = []
        for url in try Self.swiftFiles() where url.lastPathComponent != "SessionTab.swift" {
            let code = try SourceCorpus.code(of: url)
            if Self.constructions(in: code) > 0 { elsewhere.append(url.lastPathComponent) }
        }
        #expect(elsewhere.isEmpty, "constructed outside the tab: \(elsewhere)")

        // Positive for the pattern itself: it matches the spelling it
        // forbids and none of the neighbouring type names.
        #expect(Self.constructions(in: "let c = Comparison(left: a)") == 1)
        #expect(Self.constructions(in: "ComparisonRow(relativePath: p)") == 0)
        #expect(Self.constructions(in: "FolderComparison(x)") == 0)
        #expect(Self.constructions(in: "let c = Comparison.init(left: a)") == 1)
        #expect(Self.constructions(in: "ComparisonRow.init(relativePath: p)") == 0)
        // The function-value spellings: no `(` follows.
        #expect(Self.constructions(in: "let make = Comparison.init") == 1)
        #expect(Self.constructions(in: "let type = Comparison.self") == 1)
        #expect(Self.constructions(in: "let make = ComparisonRow.init") == 0)
        #expect(Self.constructions(in: "let make = FolderComparison.init") == 0)
        // And an ordinary mention of the type is not a construction.
        #expect(Self.constructions(in: "var comparisons: [Comparison] = []") == 0)
    }

    @Test func theTabIsTheOnlyWriterOfItsComparisons() throws {
        let tab = try Self.code("SessionTab.swift")
        #expect(tab.contains("private(set) var comparisons: [Comparison]"))
        #expect(tab.contains("comparisons.append(comparison)"))
    }

    // MARK: Teardown

    @Test func aTabsTeardownEndsItsComparisonsBeforeTheQueueSweepAndTheDisconnect() throws {
        let code = try Self.code("TabTeardown.swift")
        #expect(Self.occurrences(of: "tab.endComparisons()", in: code) == 1)

        let end = try #require(code.range(of: "tab.endComparisons()"))
        let sweep = try #require(code.range(of: "await tab.transferQueue.cancelAll("))
        let disconnect = try #require(code.range(of: "await session.remote.disconnect()"))
        #expect(end.upperBound <= sweep.lowerBound)
        #expect(end.upperBound <= disconnect.lowerBound)
    }

    @Test func endingComparisonsCancelsEachAndForgetsThem() throws {
        let tab = try Self.code("SessionTab.swift")
        let start = try #require(tab.range(of: "func endComparisons() {"))
        let body = String(tab[start.upperBound...].prefix(220))
        #expect(body.contains("comparison.cancel()"))
        #expect(body.contains("comparison.releaseFileSystems()"))
        #expect(body.contains("comparisons.removeAll()"))
        // The cancel comes first: the release is in addition to it.
        let cancel = try #require(body.range(of: "comparison.cancel()"))
        let release = try #require(body.range(of: "comparison.releaseFileSystems()"))
        #expect(cancel.upperBound <= release.lowerBound)
    }

    /// The refusal during a teardown is stated once, where the comparison is
    /// created, and the counter it reads is written by the teardown alone.
    @Test func aComparisonIsRefusedWhileTheTabIsBeingTornDown() throws {
        let tab = try Self.code("SessionTab.swift")
        let start = try #require(tab.range(of: "func startComparison("))
        let body = String(tab[start.upperBound...].prefix(400))
        #expect(body.contains("guard let session, !isTearingDown else { return nil }"))

        let teardown = try Self.code("TabTeardown.swift")
        #expect(Self.occurrences(of: "tab.tearDownsInFlight += 1", in: teardown) == 1)
        #expect(Self.occurrences(of: "tab.tearDownsInFlight -= 1", in: teardown) == 1)
        // Raised before the first suspension point and lowered by `defer`.
        let raise = try #require(teardown.range(of: "tab.tearDownsInFlight += 1"))
        let sweep = try #require(teardown.range(of: "await tab.transferQueue.cancelAll("))
        #expect(raise.upperBound <= sweep.lowerBound)
        #expect(teardown.contains("defer { tab.tearDownsInFlight -= 1 }"))

        var writers: [String] = []
        for url in try Self.swiftFiles() {
            if try SourceCorpus.code(of: url).contains("tearDownsInFlight") {
                writers.append(url.lastPathComponent)
            }
        }
        #expect(writers.sorted() == ["SessionTab.swift", "TabTeardown.swift"])
    }

    /// Quit adds no sweep of its own: it runs each window's close sequence
    /// and each of those ends in `TabTeardown.run`. The positive half is that
    /// the quit chain does call `TabTeardown.run`; the negative half is that
    /// nothing on the quit path names a comparison.
    @Test func quitHasNoComparisonSweepOfItsOwn() throws {
        for file in ["QuitSequence.swift", "MacSCPApp.swift"] {
            let code = try Self.code(file)
            #expect(!code.contains("endComparisons"), "\(file) sweeps comparisons")
            #expect(!code.contains(".comparisons"), "\(file) reaches into a tab's comparisons")
        }
        let quit = try Self.code("QuitSequence.swift")
        #expect(quit.contains("TabTeardown.run("))
    }

    /// `endComparisons` is spelled in the tab that declares it and in the one
    /// teardown that calls it, and nowhere else.
    @Test func onlyTheTeardownEndsComparisons() throws {
        var files: [String] = []
        for url in try Self.swiftFiles() {
            if try SourceCorpus.code(of: url).contains("endComparisons") {
                files.append(url.lastPathComponent)
            }
        }
        #expect(files.sorted() == ["SessionTab.swift", "TabTeardown.swift"])
    }

    // MARK: One relative path is never joined to two roots

    /// **The invariant F1 and F4 were two symptoms of.** A pair the second
    /// pairing pass made is spelled differently on each side, so there is no
    /// such thing as "the path of a row": joining either spelling to the
    /// other side's root names a path that is not there. The structural half
    /// is that `ComparisonRow` has no single path to ask for — it carries
    /// `leftPath` and `rightPath` — and this is the residual half, because
    /// joining a root to `relativePath` is still something a caller could
    /// write.
    ///
    /// Every negative check has a positive one beside it: a file that fetched
    /// nothing at all would satisfy the negatives on its own.
    @Test func nothingJoinsOneRelativePathToTwoRoots() throws {
        let comparison = try Self.code("Comparison.swift")
        // Positive: the three per-row entry points each fetch from the row's
        // own two paths — `fetchPair`, `settleUndetermined` and the diff.
        #expect(
            Self.occurrences(
                of: "fetch(leftPath: row.leftPath, rightPath: row.rightPath)",
                in: comparison) == 2)
        #expect(
            Self.occurrences(
                of: "diff(leftPath: row.leftPath, rightPath: row.rightPath)",
                in: comparison) == 1)
        // Negative: neither root is joined to anything here, and the helper
        // that used to do it is gone.
        for spelling in ["join(leftRoot", "join(rightRoot", "Self.join("] {
            #expect(!comparison.contains(spelling), "Comparison.swift spells \(spelling)")
        }

        // Core's walk carries both paths per level instead of one relative
        // path it joins twice.
        // `commentFree`, not `code`: the blanked view deletes string
        // literals, and the root entry below is keyed by the EMPTY relative
        // path, which is one.
        let walk = try SourceCorpus.commentFree(
            of: Self.sources
                .appendingPathComponent("macSCPCore")
                .appendingPathComponent("Compare")
                .appendingPathComponent("FolderComparison.swift"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
        // Positive: the queue is a triple, seeded with the two roots, and
        // each child takes the path its OWN side's listing reported.
        #expect(walk.contains("var queue: [(relative: String, leftPath: String, rightPath: String)]"))
        #expect(walk.contains("(relative: \"\", leftPath: leftRoot, rightPath: rightRoot)"))
        #expect(walk.contains("let childLeft = pair.left?.path ?? RemotePath.join(leftPath, pair.name)"))
        #expect(walk.contains("let childRight = pair.right?.path ?? RemotePath.join(rightPath, pair.name)"))
        // Negative: neither ROOT is joined to a relative path anywhere in the
        // walk. `leftPath`/`rightPath` above are the level's own paths, not
        // the roots, which is the whole distinction.
        for spelling in ["join(leftRoot", "join(rightRoot"] {
            #expect(!walk.contains(spelling), "FolderComparison.swift spells \(spelling)")
        }
    }

    // MARK: A settle the cancel can reach

    /// The settle path's cancel SOURCE. `cancelsWithTask: true` on both of a
    /// settle's downloads is worth something only if somebody holds the task
    /// that delivers the cancel, and until 2026-10-15 nobody did: the
    /// overview view started a bare `Task` and kept no handle to it, so
    /// `Comparison.cancel()` reached the walk and nothing else.
    @Test func theOverviewStartsASettleThroughTheComparisonAndNotATaskOfItsOwn() throws {
        let overview = try Self.code("ComparisonOverview.swift")
        // Positive: the settle IS started, exactly once, through the
        // comparison. Without these the negative checks below would be
        // satisfied by a file that starts no settle at all.
        #expect(Self.occurrences(of: "comparison.startTrackedWork {", in: overview) == 1)
        #expect(
            Self.occurrences(of: "await settler.settle(entry, on: comparison)", in: overview) == 1)
        // Negative: no task of this file's own, in any of the three spellings.
        #expect(!overview.contains("Task {"), "the overview starts a task of its own")
        #expect(!overview.contains("Task<"), "the overview holds a task of its own")
        #expect(!overview.contains("Task.detached"), "the overview detaches a task")
    }

    /// `cancel()` reaches the walk AND everything else the comparison
    /// started, and `startTrackedWork` is the one place a task is put where
    /// it can reach it.
    @Test func cancellingAComparisonCancelsTheWalkAndEverythingElseItStarted() throws {
        let body = try Self.declarationBody("func cancel()", in: "Comparison.swift")
        #expect(body.contains("walk?.cancel()"))
        #expect(body.contains("trackedWork.removeAll()"))
        #expect(body.contains("for task in tracked.values { task.cancel() }"))

        let code = try Self.code("Comparison.swift")
        // Positive: there is exactly one store, and it is the one
        // `startTrackedWork` writes.
        #expect(Self.occurrences(of: "trackedWork[key] = task", in: code) == 1)
        let start = try Self.declarationBody(
            "func startTrackedWork(_ operation: @escaping @MainActor () async -> Void)",
            in: "Comparison.swift")
        #expect(start.contains("trackedWork[key] = task"))
    }

    /// Nothing outside the comparison keeps a task of the comparison's.
    /// `trackedWork` is private, so this is about the SPELLING reaching no
    /// other file — the counterpart of `onlyTheTeardownEndsComparisons`
    /// above.
    @Test func onlyTheComparisonHoldsTheWorkItStarted() throws {
        var files: [String] = []
        for url in try Self.swiftFiles() {
            if try SourceCorpus.code(of: url).contains("trackedWork") {
                files.append(url.lastPathComponent)
            }
        }
        #expect(files == ["Comparison.swift"])
        // Positive: and the callers reach it by the function, not the store.
        var callers: [String] = []
        for url in try Self.swiftFiles() {
            if try SourceCorpus.code(of: url).contains("startTrackedWork") {
                callers.append(url.lastPathComponent)
            }
        }
        #expect(callers.sorted() == ["Comparison.swift", "ComparisonOverview.swift"])
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }
}
