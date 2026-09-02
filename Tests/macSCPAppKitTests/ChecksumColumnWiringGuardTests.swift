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
            if declares(name, in: try code(at: url)) { matches.append(url) }
        }
        #expect(matches.count == 1, "expected exactly one file declaring \(name)")
        return try #require(matches.first)
    }

    /// Whether `text` declares a type called exactly `name`.
    ///
    /// The name has to END where it is written: a plain `contains` of
    /// "struct BrowserPane" also matched the file declaring
    /// `BrowserPaneSide`, and `fileDeclaring` then reported two candidates.
    /// It failed loudly — the count is a positive check — which is the only
    /// reason this was a five-minute fix rather than a guard reading the
    /// wrong file.
    private static func declares(_ name: String, in text: String) -> Bool {
        let keywords = ["struct ", "final class ", "class ", "enum ", "actor "]
        for keyword in keywords {
            var searchStart = text.startIndex
            while let range = text.range(
                of: keyword + name, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                guard searchStart < text.endIndex else { return true }
                let next = text[searchStart]
                if !next.isLetter && !next.isNumber && next != "_" { return true }
            }
        }
        return false
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

    /// The files whose code mentions the ledger type at all — the whole
    /// world the count below is a claim about (review M1).
    ///
    /// The denominator used to be the package. `.record(` is a generic
    /// selector, and one unrelated transfer-rate window spells it, so
    /// renaming THAT method would have turned a checksum guard red and
    /// pointed the next reader here. Scoped to files that name the type, a
    /// write can still only appear where there is a ledger to write to.
    private static func filesMentioningTheLedger() throws -> [URL] {
        try swiftFiles().filter { try code(at: $0).contains(ledgerName) }
    }

    /// Exactly ONE write, in the file that also builds the run — counted
    /// over the files above in the pass that writes this sentence, where it
    /// is one. A second one anywhere is the edit this guard exists to stop:
    /// a listing, a refresh or a column toggle quietly filling the ledger,
    /// i.e. computing without being asked.
    @Test func theLedgerIsWrittenFromOnePlaceAndItIsTheRequestPath() throws {
        let files = try Self.filesMentioningTheLedger()
        #expect(files.count >= 2, "the ledger is declared in one file and used in others")

        var callSites: [URL] = []
        var total = 0
        for url in files {
            let count = Self.occurrences(of: ".record(", in: try Self.code(at: url))
            if count > 0 {
                total += count
                callSites.append(url)
            }
        }

        #expect(total == 1, "expected 1 ledger write in Sources, found \(total)")
        #expect(callSites.count == 1)

        let requestPath = try #require(callSites.first)
        #expect(try Self.code(at: requestPath).contains("\(Self.batchName)("))
    }

    /// Both surfaces that can ask for a digest ask through ONE place, and
    /// that place is the one that remembers (review C1).
    ///
    /// The info sheet and the batch sheet each called the view model
    /// themselves, and only the batch's answer was recorded — so a digest
    /// read in the info sheet left the column empty for the very file it
    /// had just been computed for, and asking again cost a second
    /// server-side hash of the whole file. What holds that shut is a count:
    /// ONE call to the view model's checksum operation in the whole request
    /// path, in the same file as the single write above. Anchored by
    /// positive checks that this file really does present both sheets.
    @Test func bothChecksumSurfacesAskThroughTheOnePlaceThatRemembers() throws {
        let requestPath = try Self.fileDeclaring(String(describing: BrowserPane.self))
        let code = try Self.code(at: requestPath)

        #expect(code.contains("\(String(describing: ChecksumBatchSheet.self))("))
        #expect(code.contains("\(String(describing: InfoPermissionsSheet.self))("))

        #expect(Self.occurrences(of: ".checksum(of:", in: code) == 1)
        #expect(Self.occurrences(of: ".record(", in: code) == 1)
    }

    /// The ledger is NOT the pane's own state (review I2): a value the user
    /// paid a server-side hash for must not die when the pane is rebuilt —
    /// a tab switch, hiding the Files pane, a reconnect. Its home is the
    /// session, which `SessionTabTests` reads from the value side.
    ///
    /// Reads DECLARATIONS rather than a spelled property name: every stored
    /// property of the ledger's type in that file has to be a binding, so a
    /// renamed property is still covered and a re-added pane-owned one is
    /// caught whatever it is called. The positive half — that there is such
    /// a declaration at all — is what keeps this from passing over a file
    /// that stopped mentioning the ledger entirely.
    @Test func thePanesLedgerIsBoundFromOutsideRatherThanOwnedByThePane() throws {
        let pane = try Self.code(at: Self.fileDeclaring(String(describing: BrowserPane.self)))

        let declarations = pane
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("var ") && $0.contains(": \(Self.ledgerName)") }

        #expect(declarations.count == 1, "the pane declares one ledger property")
        #expect(declarations.allSatisfy { $0.contains("@Binding") })
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
