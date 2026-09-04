import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The "Type" column and the bucket icon (Browser Type Column, Task 2,
/// 2026-09-04) as source-scanning guards — no rendering harness exists for
/// this AppKit table (`IconTooltipLintTests` names the same limitation), so
/// these read source text the same way `ChecksumColumnWiringGuardTests`
/// does for the ledger's one writer.
///
/// Two properties, each a positive check beside a negative one over the
/// same text (per this project's rule that a negative check needs a
/// positive check beside it, or it can go stale in silence):
///
/// 1. The Type cell reads `FileTypeLabel.label(for:` (positive) and the OLD
///    kind-only `typeText(` no longer exists in the file at all (negative)
///    — Task 1's finding was that `typeText(for:)` rendered coarser text
///    than the column's own sort order, so its disappearance is the whole
///    point of Task 2.
/// 2. The bucket icon branch reads `item.isBucket` (positive) beside a
///    count that the symbol scanned is exactly the one this task chose
///    (positive, not negative — there is nothing to forbid here, only
///    something to pin).
@Suite("Remote file table Type column")
struct RemoteFileTableTypeColumnGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/RemoteFileTableTypeColumnGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let tableFile: URL = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/RemoteFileTableView.swift")

    /// The table file's code with every `//` comment cut away — a comment
    /// that quotes the code it describes is indistinguishable from that
    /// code to a plain scan (measured elsewhere in this project's history;
    /// this file writes long explanatory comments right beside the code it
    /// scans, so the same trap applies here).
    private static func code() throws -> String {
        try String(contentsOf: tableFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    // MARK: - The Type cell

    /// Positive: the cell mapping actually calls `FileTypeLabel.label(for:`
    /// — not a hand-rolled second copy of the precedence Task 1 already
    /// built and tested.
    @Test func theTypeCellReadsFileTypeLabel() throws {
        #expect(try Self.code().contains("FileTypeLabel.label(for:"))
    }

    /// Negative, beside the positive above: the OLD App-layer lookup this
    /// task replaces is gone, not merely unused. `typeText(` is specific
    /// enough not to match `FileTypeLabel`, `cellText`, or anything else in
    /// this file — the styling switch's own `.type` case is spelled
    /// `case .owner, .group, .type:`, no parenthesis, so it cannot satisfy
    /// this string either.
    @Test func theOldKindOnlyLookupIsGone() throws {
        let code = try Self.code()
        #expect(code.contains("FileTypeLabel.label(for:"), "sanity: scanning the right file")
        #expect(code.contains("typeText(") == false)
    }

    // MARK: - The bucket icon

    /// Positive: a row's bucket-ness, not its `kind` alone, decides the
    /// icon — `kind` for a bucket is `.directory`, same as a plain folder,
    /// so nothing here can be satisfied by a kind check alone.
    @Test func theIconBranchReadsIsBucket() throws {
        #expect(try Self.code().contains("item.isBucket"))
    }

    /// Positive: `archivebox` is the SF Symbol this task picked (the brief's
    /// fallback — no existing bucket symbol was found under
    /// `Sources/MacSCPAppKit` by grep before this change), and it appears
    /// exactly once, in the icon branch, not duplicated by a copy-paste.
    @Test func theBucketSymbolIsArchiveboxUsedExactlyOnce() throws {
        let code = try Self.code()
        #expect(code.contains("systemSymbolName: \"archivebox\""))
        #expect(code.components(separatedBy: "\"archivebox\"").count - 1 == 1)
    }

    // MARK: - Every column has a header catalogue key

    /// Derived from `FileColumn.allCases` — not a hand-typed list, so a
    /// column added later is covered by this test without an edit to it.
    @Test func everyColumnHasAHeaderCatalogueKeyInTheEnglishCatalog() throws {
        let catalog = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8)
        for column in FileColumn.allCases {
            #expect(
                catalog.contains("\"filetable.column.\(column.rawValue)\" ="),
                "\(column) has no filetable.column.\(column.rawValue) key")
        }
    }

    /// The bucket marker's own tooltip key is declared in English — the
    /// four-catalog EQUALITY check (that this key also exists, correctly,
    /// in de/fr/pl) is `LocalizationParityTests`' job over every catalog in
    /// the tree, not re-implemented here.
    @Test func theBucketTooltipKeyIsDeclaredInTheEnglishCatalog() throws {
        let catalog = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8)
        #expect(catalog.contains("\"filetable.bucketTooltip\" ="))
    }
}
