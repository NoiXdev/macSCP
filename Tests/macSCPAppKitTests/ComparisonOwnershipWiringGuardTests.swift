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

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }
}
