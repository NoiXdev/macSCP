import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The checksum column as the table renders it (2026-09-02): the cell text,
/// the header that names the algorithm, and the two structural facts that
/// keep the column from pretending to be like the others — it is not
/// sortable, and its cell mapping is actually wired.
@Suite("Checksum column")
@MainActor
struct ChecksumColumnTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func file(
        path: String = "/report.csv", kind: RemoteFileKind = .file, size: UInt64? = 42
    ) -> RemoteFileItem {
        RemoteFileItem(
            name: "report.csv", path: path, kind: kind, size: size, modifiedAt: referenceDate)
    }

    private static func digest(_ algorithm: ChecksumAlgorithm) -> FileChecksum {
        FileChecksum.computedOnRemote(
            algorithm, hex: String(repeating: "a", count: algorithm.hexDigitCount))!
    }

    private static func ledger(
        holding algorithm: ChecksumAlgorithm, for item: RemoteFileItem
    ) -> ChecksumLedger {
        var ledger = ChecksumLedger()
        ledger.record(.checksum(digest(algorithm)), for: item)
        return ledger
    }

    // MARK: - The cell

    @Test func aRowThatWasAskedAboutShowsItsHex() {
        let item = Self.file()
        let text = RemoteFileTableView.checksumCellText(
            for: item, in: Self.ledger(holding: .sha256, for: item), algorithm: .sha256)

        #expect(text == Self.digest(.sha256).hex)
    }

    /// Empty, not "—": the placeholder the other optional columns use says
    /// "this listing does not carry the value". Here the value is not
    /// missing from a listing, it was never asked for, and an empty cell is
    /// the only thing that says so.
    @Test func aRowThatWasNeverAskedAboutShowsNothing() {
        #expect(
            RemoteFileTableView.checksumCellText(
                for: Self.file(), in: ChecksumLedger(), algorithm: .sha256) == "")
    }

    @Test func aDirectoryRowShowsNothingEvenWithAValueUnderItsIdentity() {
        let directory = Self.file(kind: .directory)
        #expect(
            RemoteFileTableView.checksumCellText(
                for: directory, in: Self.ledger(holding: .sha256, for: directory),
                algorithm: .sha256) == "")
    }

    @Test func switchingTheAlgorithmEmptiesACellComputedUnderTheOtherOne() {
        let item = Self.file()
        let ledger = Self.ledger(holding: .sha256, for: item)

        #expect(RemoteFileTableView.checksumCellText(for: item, in: ledger, algorithm: .md5) == "")
    }

    /// The cell the table actually renders goes through the mapping over
    /// `FileColumn`, so the checksum branch has to be the one above and not
    /// a second, drifting copy.
    @Test func theCellMappingRendersTheChecksumColumnThroughThatSameText() {
        let item = Self.file()
        let ledger = Self.ledger(holding: .sha256, for: item)

        #expect(
            RemoteFileTableView.cellText(
                for: .checksum, item: item, ledger: ledger, algorithm: .sha256)
                == RemoteFileTableView.checksumCellText(
                    for: item, in: ledger, algorithm: .sha256))
    }

    /// Every column says something different about the same file — the
    /// cheapest thing a branch of that mapping can be is a copy of the one
    /// above it, and a copy is invisible in a screenshot.
    ///
    /// The fixture gives each column a distinguishable answer on purpose;
    /// what this pins is that no two branches produce the same one.
    @Test func everyColumnRendersItsOwnValueForTheSameFile() {
        let item = RemoteFileItem(
            name: "report.csv", path: "/report.csv", kind: .file, size: 4096,
            modifiedAt: Self.referenceDate, permissions: 0o644, owner: "www-data",
            group: "staff")
        let ledger = Self.ledger(holding: .sha256, for: item)

        let texts = FileColumn.allCases.map {
            RemoteFileTableView.cellText(
                for: $0, item: item, ledger: ledger, algorithm: .sha256)
        }

        #expect(texts.allSatisfy { $0.isEmpty == false })
        #expect(Set(texts).count == FileColumn.allCases.count)
    }

    // MARK: - The header

    /// A bare "Checksum" over a column of hex would not say WHICH digest —
    /// the one thing a person comparing against a published figure needs.
    @Test(arguments: ChecksumAlgorithm.allCases)
    func theHeaderNamesTheAlgorithm(algorithm: ChecksumAlgorithm) {
        let header = FileColumn.checksum.localizedHeaderTitle(checksumAlgorithm: algorithm)

        #expect(header.contains(algorithm.displayName))
        #expect(header != FileColumn.checksum.localizedTitle)
    }

    /// The header of every other column is its plain title — the algorithm
    /// belongs to this one column and must not leak into the rest.
    @Test(arguments: FileColumn.allCases.filter { $0 != .checksum })
    func everyOtherHeaderIsTheColumnsPlainTitle(column: FileColumn) {
        #expect(
            column.localizedHeaderTitle(checksumAlgorithm: .sha256) == column.localizedTitle)
    }

    /// The checkbox in Settings names the column without the algorithm: the
    /// setting is about showing the column, and the algorithm it shows is
    /// its own setting elsewhere on the same pane.
    @Test func theColumnsOwnTitleResolvesFromTheCatalog() {
        #expect(FileColumn.checksum.localizedTitle != "filetable.column.checksum")
        #expect(FileColumn.checksum.localizedTitle.isEmpty == false)
    }

    // MARK: - Structure

    /// Every column but this one carries a click-to-sort default direction;
    /// this one carries none, which is what leaves its header unclickable.
    /// Sorting a column that is empty for all but a handful of rows would
    /// order the listing by "what the user happened to ask about".
    @Test func theChecksumColumnHasNoSortDirectionWhileEveryOtherColumnDoes() {
        let spec = RemoteFileTableView.columnSpecs[.checksum]
        #expect(spec != nil)
        #expect(spec?.defaultAscending == nil)

        for column in FileColumn.allCases where column != .checksum {
            #expect(RemoteFileTableView.columnSpecs[column]?.defaultAscending != nil)
        }
    }

    /// Every column has a spec, so a case added to the enum cannot silently
    /// become a column the table refuses to build.
    @Test func everyColumnHasASpec() {
        for column in FileColumn.allCases {
            #expect(RemoteFileTableView.columnSpecs[column] != nil)
        }
    }
}
