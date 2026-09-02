import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The one property the value tests cannot reach: that the ledger behind
/// the checksum column has exactly ONE writer — the request path.
///
/// (There were two. The other — that the table's cell mapping knows every
/// column — is now a compile-time check instead of a scan: `cellText`
/// switches over `FileColumn` exhaustively. The scan it replaced was
/// satisfied by the STYLING switch in the same file and stayed green after
/// the real branch was deleted, measured while writing this.)
///
/// This one is the whole point of the feature. A column that fills itself
/// is a column that computes, and computing is the thing the maintainer
/// decided must stay an action. There is no rendering harness here (the
/// boundary the other wiring guards in this target document), so the check
/// reads source — built to `CLAUDE.md`'s two rules for that:
///
/// - **Nothing spells a symbol it could read.** File locations come off the
///   type names themselves. Rename a type and this guard follows it to its
///   new file rather than going silent.
/// - **Every negative check stands beside a positive one over the same
///   text.** The one negative below (the browse view model never touches
///   the ledger) is anchored by a positive check that the file it scans is
///   the browse view model at all.
@Suite("Checksum column wiring")
@MainActor
struct ChecksumColumnWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ChecksumColumnWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources")

    /// A file's CODE, with every `//` comment cut away — the difference
    /// between a guard and a comment that runs (see
    /// `ChecksumSurfaceGuardTests`, which was caught by exactly that).
    /// This project writes long explanatory comments AND scans source, so a
    /// prose sentence naming a call is indistinguishable from the call
    /// unless the prose is removed first.
    private static func code(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Every `.swift` file under `Sources/`, found rather than listed.
    private static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil)
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The single file whose code DECLARES `name` as a type. Fails if it is
    /// not exactly one, so a split or a duplicate cannot leave this guard
    /// scanning a file that no longer holds the thing it is about.
    private static func fileDeclaring(_ name: String) throws -> URL {
        var matches: [URL] = []
        for url in try swiftFiles() {
            let text = try code(at: url)
            let declarations = ["struct \(name)", "final class \(name)", "class \(name)", "enum \(name)"]
            if declarations.contains(where: { text.contains($0) }) { matches.append(url) }
        }
        #expect(matches.count == 1, "expected exactly one file declaring \(name)")
        return try #require(matches.first)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    // MARK: - The ledger has one writer, and it is the request path

    private static var ledgerName: String { String(describing: ChecksumLedger.self) }
    private static var batchName: String { String(describing: ChecksumBatch.self) }

    /// The writer exists at all — the positive anchor under everything
    /// below, which is otherwise a set of claims about how RARE a call is.
    @Test func theLedgerDeclaresExactlyOneWriter() throws {
        let ledger = try Self.code(at: Self.fileDeclaring(Self.ledgerName))
        #expect(Self.occurrences(of: "mutating func record(", in: ledger) == 1)
    }

    /// Counted in the pass that writes this sentence, over comment-stripped
    /// sources: TWO `.record(` calls exist in the whole package — the
    /// ledger write below, and one unrelated transfer-rate window. Both are
    /// asserted, so this is not a claim about a number nobody looked at: a
    /// third one anywhere turns this red, which is precisely the edit this
    /// guard exists to stop (a listing, a refresh or a column toggle
    /// quietly filling the ledger, i.e. computing without being asked).
    @Test func theLedgerIsWrittenFromOnePlaceAndItIsTheRequestPath() throws {
        var callSites: [URL] = []
        var total = 0
        for url in try Self.swiftFiles() {
            let count = Self.occurrences(of: ".record(", in: try Self.code(at: url))
            if count > 0 {
                total += count
                callSites.append(url)
            }
        }

        #expect(total == 2, "expected 2 `.record(` calls in Sources, found \(total)")
        #expect(callSites.count == 2)

        // The ledger's own call site is the file that also builds the batch
        // — the request path. The other call site is the unrelated one, and
        // it must NOT be that file.
        let withBatch = try callSites.filter { url in
            try Self.code(at: url).contains("\(Self.batchName)(")
        }
        #expect(withBatch.count == 1)
        let requestPath = try #require(withBatch.first)
        let requestPathCode = try Self.code(at: requestPath)
        #expect(Self.occurrences(of: ".record(", in: requestPathCode) == 1)
        #expect(requestPathCode.contains(Self.ledgerName))
    }

    /// The negative: nothing on the browse/listing path writes the ledger.
    /// A listing is where a value would have to be filled in automatically,
    /// and "empty until asked" is exactly the property that would be lost.
    ///
    /// Anchored by two positive checks over the same text — the file really
    /// is the browse view model (it declares the sort key the browser sorts
    /// by) and it really does list directories — so this cannot become a
    /// check that scans nothing and passes.
    @Test func theBrowseViewModelNeverTouchesTheLedger() throws {
        let viewModel = try Self.code(
            at: Self.fileDeclaring(String(describing: RemoteBrowserViewModel.self)))

        #expect(viewModel.contains("enum \(String(describing: FileSortKey.self))"))
        #expect(viewModel.contains("func refresh"))

        #expect(viewModel.contains(Self.ledgerName) == false)
        #expect(viewModel.contains(".record(") == false)
    }
}
