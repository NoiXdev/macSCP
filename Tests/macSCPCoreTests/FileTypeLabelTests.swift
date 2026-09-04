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

    /// The catalogue words this file's non-extension cases compare against.
    /// `CoreL10n.string` resolves against the host's preferred language, so
    /// a fixed literal ("File"/"Folder"/"Link"/"Bucket") would pin the test
    /// environment — passing on an English Mac and failing on a German or
    /// Polish one (same trap `SessionListViewModelTests` documents for
    /// `core.login.mergeFailed`). Going through the keys instead means the
    /// expectation resolves under whatever locale the suite actually runs
    /// in, same as `FileTypeLabel.label(for:)` itself does. The uppercased
    /// EXTENSION cases above (`"PDF"`, `"GZ"`, `"JPEG"`) are not catalogue
    /// text — they never go through `CoreL10n` — so they stay literal.
    private static let fileWord = CoreL10n.string("core.fileType.file")
    private static let folderWord = CoreL10n.string("core.fileType.folder")
    private static let linkWord = CoreL10n.string("core.fileType.link")
    private static let bucketWord = CoreL10n.string("core.fileType.bucket")

    @Test func aDotfileWithNoFurtherExtensionIsAFile() {
        #expect(FileTypeLabel.label(for: item(name: ".bashrc")) == Self.fileWord)
    }

    @Test func aNameWithNoExtensionAtAllIsAFile() {
        #expect(FileTypeLabel.label(for: item(name: "README")) == Self.fileWord)
    }

    /// A trailing dot with nothing after it is an empty extension, not a
    /// one-character one — `NSString.pathExtension` returns `""` for
    /// "name.", the same as for "README" above (Task 1 review).
    @Test func aTrailingDotWithNothingAfterItIsAFile() {
        #expect(FileTypeLabel.label(for: item(name: "name.")) == Self.fileWord)
    }

    @Test func aDirectoryIsAFolder() {
        #expect(FileTypeLabel.label(for: item(name: "docs", kind: .directory)) == Self.folderWord)
    }

    /// A directory's `.directory` check runs before any extension is ever
    /// looked at, so a name that LOOKS like it carries one ("photos.d")
    /// still reads "Folder" — the same precedence `isBucketOutranksDirectory`
    /// pins for buckets, one level down (Task 1 review).
    @Test func aDirectoryNamedLikeItHasAnExtensionIsStillAFolder() {
        #expect(FileTypeLabel.label(for: item(name: "photos.d", kind: .directory)) == Self.folderWord)
    }

    @Test func aSymlinkIsALink() {
        #expect(FileTypeLabel.label(for: item(name: "current", kind: .symlink)) == Self.linkWord)
    }

    /// A symlink's label ignores whatever extension its name happens to
    /// carry — `.symlink` outranks the extension check.
    @Test func aSymlinkIsALinkEvenWithAFileLikeName() {
        #expect(FileTypeLabel.label(for: item(name: "current.txt", kind: .symlink)) == Self.linkWord)
    }

    @Test func aBucketIsABucket() {
        #expect(
            FileTypeLabel.label(for: item(name: "my-bucket", kind: .directory, isBucket: true))
                == Self.bucketWord)
    }

    /// `isBucket` outranks `.directory` — a bucket never reads "Folder".
    @Test func isBucketOutranksDirectory() {
        let bucket = item(name: "my-bucket", kind: .directory, isBucket: true)
        #expect(FileTypeLabel.label(for: bucket) != Self.folderWord)
        #expect(FileTypeLabel.label(for: bucket) == Self.bucketWord)
    }

    @Test func sortKeyMatchesTheDisplayLabel() {
        let file = item(name: "report.PDF")
        #expect(FileTypeLabel.sortKey(for: file) == FileTypeLabel.label(for: file))
    }
}
