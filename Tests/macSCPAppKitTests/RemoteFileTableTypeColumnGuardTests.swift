import AppKit
import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The "Type" column and the bucket icon (Browser Type Column, Task 2,
/// 2026-09-04). Most of this suite reads source text the same way
/// `ChecksumColumnWiringGuardTests` does for the ledger's one writer — this
/// table is not driven inside a hosted window in this project's tests, the
/// same limitation `IconTooltipLintTests` names for icon/tooltip pairing
/// (that suite's own header calls it "no test target of its own" for the
/// App layer, which is stale: `Package.swift` declares `macSCPAppKitTests`
/// — this very file lives in it — it just cannot render an `NSView` and
/// read pixels back). One test below is the exception: it drives
/// `Coordinator.tableView(_:viewFor:row:)` directly, which needs no window,
/// and checks the marker `NSImageView` it returns rather than scanning for
/// the code that builds one.
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

    // MARK: - The bucket icon, behaviourally (final-review fix)

    /// `theIconBranchReadsIsBucket` above is a source scan for the string
    /// `item.isBucket`, and `cellToolTip`'s `.name` case reads that same
    /// property (for the hover hint) a few lines below the icon branch — so
    /// deleting the icon branch ENTIRELY still leaves `item.isBucket`
    /// somewhere in the file, and that scan stays green over a real
    /// regression (final review of this plan, 2026-09-04). This drives the
    /// actual cell mapping instead of scanning for it: a bucket row, a
    /// symlink row, and a plain file row, each through
    /// `Coordinator.tableView(_:viewFor:row:)`, and reads the marker
    /// `NSImageView` each one comes back with.
    ///
    /// Three FRESH cells, not one reused one: `NSTableView
    /// .makeView(withIdentifier:owner:)` only ever returns a previously
    /// built view once the table has actually recycled it during a real
    /// scroll or reload pass inside a HOSTED window — nothing a headless
    /// unit test can drive without one (the same limitation this file's
    /// header names for rendering generally). The recycling-hygiene rule
    /// the production code documents at the icon branch — that a reused
    /// cell must be told its `isHidden` state on every pass, not just the
    /// two truthy branches — is exercised here across three independent
    /// cells instead, one per row, rather than across one cell scrolled
    /// through three rows.
    @Test @MainActor
    func theMarkerVariesPerRowBucketThenSymlinkThenPlainFile() throws {
        let bucket = RemoteFileItem(
            name: "my-bucket", path: "/my-bucket", kind: .directory, isBucket: true)
        let symlink = RemoteFileItem(name: "current", path: "/current", kind: .symlink)
        let plain = RemoteFileItem(name: "report.pdf", path: "/report.pdf", kind: .file)

        let coordinator = RemoteFileTableView.Coordinator(
            onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        coordinator.items = [bucket, symlink, plain]

        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let nameColumn = NSTableColumn(identifier: .init(FileColumn.name.rawValue))
        tableView.addTableColumn(nameColumn)

        func markerImageView(row: Int) throws -> NSImageView {
            let view = try #require(
                coordinator.tableView(tableView, viewFor: nameColumn, row: row)
                    as? NSTableCellView,
                "row \(row) did not produce an NSTableCellView")
            return try #require(view.imageView, "row \(row)'s cell has no marker imageView")
        }

        let bucketMarker = try markerImageView(row: 0)
        let symlinkMarker = try markerImageView(row: 1)
        let plainMarker = try markerImageView(row: 2)

        #expect(bucketMarker.isHidden == false)
        #expect(bucketMarker.image != nil)
        #expect(symlinkMarker.isHidden == false)
        #expect(symlinkMarker.image != nil)
        #expect(plainMarker.isHidden == true)
    }
}
