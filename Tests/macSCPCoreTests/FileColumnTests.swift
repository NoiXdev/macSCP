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
    @Test func allCasesAreThePlannedSevenColumns() {
        #expect(
            FileColumn.allCases == [
                .name, .size, .modified, .permissions, .owner, .group, .type,
            ])
    }

    @Test func nameIsNotToggleable() {
        #expect(FileColumn.name.isToggleable == false)
    }

    @Test(arguments: [
        FileColumn.size, .modified, .permissions, .owner, .group, .type,
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
        #expect(FileColumn.type.defaultVisible == false)
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
}
