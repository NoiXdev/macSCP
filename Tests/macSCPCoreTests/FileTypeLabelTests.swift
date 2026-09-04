import Foundation
import Testing
@testable import macSCPCore

/// `FileTypeLabel` (Browser Type Column, 2026-09-04): the "Type" column's
/// cell text and sort key. Precedence: `isBucket`, then `.directory`, then
/// `.symlink`, then the name's last extension uppercased, falling back to
/// "File" for a name with no extension.
@Suite("FileTypeLabel")
struct FileTypeLabelTests {
    private func item(
        name: String = "a", kind: RemoteFileKind = .file, isBucket: Bool = false
    ) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: kind, isBucket: isBucket)
    }

    @Test func lastExtensionIsUppercased() {
        #expect(FileTypeLabel.label(for: item(name: "report.PDF")) == "PDF")
    }

    @Test func onlyTheLastExtensionOfACompoundSuffixCounts() {
        #expect(FileTypeLabel.label(for: item(name: "archive.tar.gz")) == "GZ")
    }

    @Test func aLowercaseExtensionIsUppercasedToo() {
        #expect(FileTypeLabel.label(for: item(name: "photo.JPEG")) == "JPEG")
    }

    @Test func aDotfileWithNoFurtherExtensionIsAFile() {
        #expect(FileTypeLabel.label(for: item(name: ".bashrc")) == "File")
    }

    @Test func aNameWithNoExtensionAtAllIsAFile() {
        #expect(FileTypeLabel.label(for: item(name: "README")) == "File")
    }

    @Test func aDirectoryIsAFolder() {
        #expect(FileTypeLabel.label(for: item(name: "docs", kind: .directory)) == "Folder")
    }

    @Test func aSymlinkIsALink() {
        #expect(FileTypeLabel.label(for: item(name: "current", kind: .symlink)) == "Link")
    }

    /// A symlink's label ignores whatever extension its name happens to
    /// carry — `.symlink` outranks the extension check.
    @Test func aSymlinkIsALinkEvenWithAFileLikeName() {
        #expect(FileTypeLabel.label(for: item(name: "current.txt", kind: .symlink)) == "Link")
    }

    @Test func aBucketIsABucket() {
        #expect(FileTypeLabel.label(for: item(name: "my-bucket", kind: .directory, isBucket: true)) == "Bucket")
    }

    /// `isBucket` outranks `.directory` — a bucket never reads "Folder".
    @Test func isBucketOutranksDirectory() {
        let bucket = item(name: "my-bucket", kind: .directory, isBucket: true)
        #expect(FileTypeLabel.label(for: bucket) != "Folder")
        #expect(FileTypeLabel.label(for: bucket) == "Bucket")
    }

    @Test func sortKeyMatchesTheDisplayLabel() {
        let file = item(name: "report.PDF")
        #expect(FileTypeLabel.sortKey(for: file) == FileTypeLabel.label(for: file))
    }
}
