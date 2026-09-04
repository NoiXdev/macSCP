import Foundation
import Testing
@testable import macSCPCore

/// `FileColumn` (M11m/T1): which optional columns the file list can show,
/// plus the pure per-column formatters T2's cells reuse. `name` is the one
/// column that's always visible and never toggleable; the other legacy
/// two (`size`/`modified`) default ON to preserve today's behavior, the
/// four new ones default OFF.
@Suite("FileColumn")
struct FileColumnTests {
    @Test func allCasesAreThePlannedEightColumns() {
        #expect(
            FileColumn.allCases == [
                .name, .size, .modified, .permissions, .owner, .group, .type, .checksum,
            ])
    }

    @Test func nameIsNotToggleable() {
        #expect(FileColumn.name.isToggleable == false)
    }

    @Test(arguments: [
        FileColumn.size, .modified, .permissions, .owner, .group, .type, .checksum,
    ])
    func everyOtherColumnIsToggleable(column: FileColumn) {
        #expect(column.isToggleable == true)
    }

    @Test func defaultVisibilityMatchesTodaysThreeFixedColumns() {
        #expect(FileColumn.name.defaultVisible == true)
        #expect(FileColumn.size.defaultVisible == true)
        #expect(FileColumn.modified.defaultVisible == true)
        #expect(FileColumn.permissions.defaultVisible == false)
        #expect(FileColumn.owner.defaultVisible == false)
        #expect(FileColumn.group.defaultVisible == false)
        #expect(FileColumn.checksum.defaultVisible == false)
    }

    /// `.type` is the one deliberate exception to the opt-in rule above
    /// (Browser Type Column plan, 2026-09-04, Global Constraint) — it ships
    /// visible by default, not off-until-chosen like every other M11m
    /// column.
    @Test func typeDefaultsToVisible() {
        #expect(FileColumn.type.defaultVisible == true)
    }

    /// The default SET a fresh install (or a `settings.json` predating this
    /// feature) sees — `.type` is in it, alongside the three legacy fixed
    /// columns.
    @Test func typeIsInTheDefaultVisibleColumnSet() {
        let defaults = Set(FileColumn.allCases.filter(\.defaultVisible))
        #expect(defaults.contains(.type))
        #expect(defaults == [.name, .size, .modified, .type])
    }

    // MARK: - Formatters

    @Test func permissionsTextRendersRwxString() {
        let item = RemoteFileItem(
            name: "a", path: "/a", kind: .file, permissions: 0o644)
        #expect(FileColumnFormatter.permissionsText(for: item) == "rw-r--r--")
    }

    @Test func permissionsTextIsNilWithoutPermissionBits() {
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file)
        #expect(FileColumnFormatter.permissionsText(for: item) == nil)
    }

    @Test func ownerAndGroupTextPassThroughTheRawItemValues() {
        let item = RemoteFileItem(
            name: "a", path: "/a", kind: .file, owner: "www-data", group: "staff")
        #expect(FileColumnFormatter.ownerText(for: item) == "www-data")
        #expect(FileColumnFormatter.groupText(for: item) == "staff")
    }

    @Test func ownerAndGroupTextAreNilWhenUnavailable() {
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file)
        #expect(FileColumnFormatter.ownerText(for: item) == nil)
        #expect(FileColumnFormatter.groupText(for: item) == nil)
    }

    // MARK: - Checksum column

    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func file(
        kind: RemoteFileKind = .file, size: UInt64? = 42
    ) -> RemoteFileItem {
        RemoteFileItem(
            name: "report.csv", path: "/report.csv", kind: kind, size: size,
            modifiedAt: referenceDate)
    }

    private static func digest(_ algorithm: ChecksumAlgorithm) -> FileChecksum {
        FileChecksum.computedOnRemote(
            algorithm, hex: String(repeating: "a", count: algorithm.hexDigitCount))!
    }

    /// The column shows what the ledger holds, and shows it as the hex the
    /// user asked for — never a re-derived or re-formatted spelling.
    @Test func checksumTextIsTheRecordedHex() {
        let item = Self.file()
        var ledger = ChecksumLedger()
        let value = Self.digest(.sha256)
        ledger.record(.checksum(value), for: item)

        #expect(
            FileColumnFormatter.checksumText(for: item, in: ledger, algorithm: .sha256)
                == value.hex)
    }

    /// The whole point of the column: a file nobody asked about has no
    /// text at all, not a placeholder and not a dash.
    @Test func checksumTextIsNilWhenNothingWasAsked() {
        #expect(
            FileColumnFormatter.checksumText(for: Self.file(), in: ChecksumLedger(), algorithm: .sha256)
                == nil)
    }

    @Test func checksumTextIsNilUnderAnotherAlgorithm() {
        let item = Self.file()
        var ledger = ChecksumLedger()
        ledger.record(.checksum(Self.digest(.sha256)), for: item)

        #expect(FileColumnFormatter.checksumText(for: item, in: ledger, algorithm: .md5) == nil)
    }

    /// A row whose bytes changed under the same path reads empty again —
    /// the ledger's own key rule, seen from the column.
    @Test func checksumTextIsNilOnceTheFileChanged() {
        var ledger = ChecksumLedger()
        ledger.record(.checksum(Self.digest(.sha256)), for: Self.file(size: 42))

        #expect(
            FileColumnFormatter.checksumText(
                for: Self.file(size: 43), in: ledger, algorithm: .sha256) == nil)
    }

    /// A directory has no digest, so its cell is empty even if a value was
    /// somehow recorded under the same identity: the column asks the kind
    /// itself rather than trusting the ledger to have refused.
    @Test(arguments: [RemoteFileKind.directory, .symlink, .other])
    func checksumTextIsNilForEverythingThatIsNotAFile(kind: RemoteFileKind) {
        let item = Self.file(kind: kind)
        var ledger = ChecksumLedger()
        ledger.record(.checksum(Self.digest(.sha256)), for: item)

        #expect(FileColumnFormatter.checksumText(for: item, in: ledger, algorithm: .sha256) == nil)
    }
}
