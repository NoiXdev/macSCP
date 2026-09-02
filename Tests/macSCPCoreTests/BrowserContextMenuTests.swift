import Foundation
import Testing
@testable import macSCPCore

@Suite("BrowserContextMenu")
struct BrowserContextMenuTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .file, size: 1)
    }
    private func symlink(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .symlink, size: nil)
    }

    @Test func backgroundShowsOnlyNewFolderAndNewFile() {
        #expect(BrowserContextMenu.entries(for: [], side: .remote) == [.newFolder, .newFile])
    }

    @Test func singleRemoteFileShowsEverything() {
        #expect(BrowserContextMenu.entries(for: [file("a")], side: .remote) == [
            .transferToOtherPane, .openInEditor, .rename, .infoAndPermissions,
            .newFolder, .newFile, .copyPath, .delete,
        ])
    }

    @Test func localPaneNeverOffersEditor() {
        #expect(!BrowserContextMenu.entries(for: [file("a")], side: .local)
            .contains(.openInEditor))
    }

    @Test func symlinkGetsNoTransferNoEditorNoPermissions() {
        let entries = BrowserContextMenu.entries(for: [symlink("l")], side: .remote)
        #expect(entries == [.rename, .newFolder, .newFile, .copyPath, .delete])
    }

    @Test func multiSelectionDropsSingleOnlyEntries() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote)
        #expect(entries == [.transferToOtherPane, .newFolder, .newFile, .copyPath, .delete])
    }

    @Test func symlinkOnlyMultiSelectionHasNoTransfer() {
        let entries = BrowserContextMenu.entries(
            for: [symlink("l1"), symlink("l2")], side: .remote)
        #expect(entries == [.newFolder, .newFile, .copyPath, .delete])
    }

    @Test func directoriesGetNoEditor() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        #expect(!BrowserContextMenu.entries(for: [dir], side: .remote)
            .contains(.openInEditor))
    }

    @Test func crossSessionTargetsFollowTransferEntry() {
        let t1 = CrossSessionTarget(id: UUID(), title: "db-prod", remotePath: "/srv", kind: .ssh)
        let t2 = CrossSessionTarget(id: UUID(), title: "backup", remotePath: "/volume1", kind: .ssh)
        let entries = BrowserContextMenu.entries(
            for: [file("a.txt")], side: .local, crossSessionTargets: [t1, t2])
        #expect(entries.starts(with: [
            .transferToOtherPane, .transferToSession(t1), .transferToSession(t2)]))
    }

    @Test func crossSessionTargetsAbsentWhenSelectionNotTransferable() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/", kind: .ssh)
        // Symlink-only selection: no transfer entry -> no session targets.
        let entries = BrowserContextMenu.entries(
            for: [symlink("l")], side: .remote, crossSessionTargets: [t])
        #expect(!entries.contains { if case .transferToSession = $0 { return true }; return false })
        #expect(!entries.contains(.transferToOtherPane))
    }

    @Test func emptyTargetsKeepTodayShape() {
        let with = BrowserContextMenu.entries(for: [file("a")], side: .local, crossSessionTargets: [])
        let without = BrowserContextMenu.entries(for: [file("a")], side: .local)
        #expect(with == without)
    }

    @Test func backgroundClickIgnoresTargets() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/", kind: .ssh)
        #expect(BrowserContextMenu.entries(for: [], side: .local, crossSessionTargets: [t]) == [.newFolder, .newFile])
    }

    @Test func singleFileSelectionIncludesBackendFileActions() {
        let action = FileActionContribution(id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")
        let entries = BrowserContextMenu.entries(for: [file("a")], side: .remote, fileActions: [action])
        #expect(entries.contains(.backendFileAction(action)))
    }

    @Test func folderAndMultiSelectOmitBackendFileActions() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        let action = FileActionContribution(id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")
        #expect(!BrowserContextMenu.entries(for: [dir], side: .remote, fileActions: [action])
            .contains(.backendFileAction(action)))
        #expect(!BrowserContextMenu.entries(for: [file("a"), file("b")], side: .remote, fileActions: [action])
            .contains(.backendFileAction(action)))
    }

    @Test func defaultFileActionsEmptyKeepsTodayShape() {
        let entries = BrowserContextMenu.entries(for: [file("a")], side: .remote)
        #expect(!entries.contains { if case .backendFileAction = $0 { return true }; return false })
    }

    // MARK: - Checksums (file checksums, Task 4)

    /// Absent, not present-and-dead. A backend that cannot answer the
    /// checksum question gets no entry at all; what it DOES get is the
    /// sentence in the info sheet, which is an answer where a greyed-out
    /// item is not.
    @Test func aBackendThatCannotAnswerOffersNoChecksumEntry() {
        #expect(!BrowserContextMenu.entries(
            for: [file("a")], side: .remote, supportsChecksum: false)
            .contains(.computeChecksum))
    }

    /// The default is the same absence, so every call site that predates
    /// checksums keeps the shape it had.
    @Test func theChecksumEntryIsAbsentUnlessAskedFor() {
        #expect(!BrowserContextMenu.entries(for: [file("a")], side: .remote)
            .contains(.computeChecksum))
    }

    @Test func aSingleFileOffersTheChecksumEntryWhereTheBackendCanAnswer() {
        #expect(BrowserContextMenu.entries(
            for: [file("a")], side: .remote, supportsChecksum: true) == [
            .transferToOtherPane, .openInEditor, .rename, .infoAndPermissions,
            .newFolder, .newFile, .copyPath, .computeChecksum, .delete,
        ])
    }

    /// A selection is computed one file after another, so several files
    /// are exactly as offerable as one.
    @Test func aMultipleSelectionOffersTheChecksumEntry() {
        #expect(BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote, supportsChecksum: true) == [
            .transferToOtherPane, .newFolder, .newFile, .copyPath,
            .computeChecksum, .delete,
        ])
    }

    /// A folder has no digest and neither has a symlink, so a selection
    /// holding no file at all offers nothing to compute — the same
    /// "only what is possible" rule, one level down from the backend.
    @Test func aSelectionWithNoFileInItOffersNoChecksum() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        #expect(!BrowserContextMenu.entries(
            for: [dir, symlink("l")], side: .remote, supportsChecksum: true)
            .contains(.computeChecksum))
        #expect(!BrowserContextMenu.entries(
            for: [], side: .remote, supportsChecksum: true)
            .contains(.computeChecksum))
    }

    /// A mixed selection keeps the entry: the run covers the files in it
    /// and there is nothing to explain away.
    @Test func aMixedSelectionKeepsTheChecksumEntryForItsFiles() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        #expect(BrowserContextMenu.entries(
            for: [dir, file("a")], side: .remote, supportsChecksum: true)
            .contains(.computeChecksum))
    }

    /// The local pane can compute too — the entry is not a remote-side
    /// one, unlike the editor.
    @Test func theLocalPaneOffersTheChecksumEntryAsWell() {
        #expect(BrowserContextMenu.entries(
            for: [file("a")], side: .local, supportsChecksum: true)
            .contains(.computeChecksum))
    }

    // MARK: - A bucket row opens, nothing else (2026-09-02, Task 4)

    private func bucket(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .directory)
    }
    private var listRoot: BrowserScope {
        BrowserScope(rootIsContainerList: true, currentPath: "/")
    }
    private var insideABucket: BrowserScope {
        BrowserScope(rootIsContainerList: true, currentPath: "/macscp-seed")
    }

    /// The whole rule, in the surface both menus and the keyboard read.
    ///
    /// The design offers ONE action on a bucket row — open it — and open is
    /// not a menu entry (it is the double-click and ⌘O, which take a row
    /// and never ask this model). Refresh is a pane button, not a row
    /// action. What is left for the menu is `copyPath`, which is a
    /// clipboard write and works on a bucket exactly as it does on a
    /// folder; everything else either mutates the bucket, moves bytes in or
    /// out of it, or asks a question a bucket has no answer to.
    @Test func aBucketRowOffersNothingButItsPath() {
        let entries = BrowserContextMenu.entries(
            for: [bucket("macscp-seed")], side: .remote,
            crossSessionTargets: [CrossSessionTarget(
                id: UUID(), title: "other", remotePath: "/", kind: .ssh)],
            fileActions: [FileActionContribution(
                id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")],
            supportsChecksum: true, scope: listRoot)

        #expect(entries == [.copyPath])
    }

    /// Named one by one as well as by the equality above, so a reader of a
    /// failure sees WHICH offer came back rather than a diff of two arrays
    /// — and so a later entry added to the model is covered by the
    /// equality even if nobody updates this list.
    @Test func noBucketRowOffersATransferARenameADeleteOrAChecksum() {
        let entries = BrowserContextMenu.entries(
            for: [bucket("macscp-seed")], side: .remote,
            fileActions: [FileActionContribution(
                id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")],
            supportsChecksum: true, scope: listRoot)

        #expect(!entries.contains(.transferToOtherPane))
        #expect(!entries.contains(.rename))
        #expect(!entries.contains(.delete))
        #expect(!entries.contains(.infoAndPermissions))
        #expect(!entries.contains(.newFolder))
        #expect(!entries.contains(.newFile))
        #expect(!entries.contains(.computeChecksum))
        #expect(!entries.contains(where: {
            if case .backendFileAction = $0 { return true }
            return false
        }))
    }

    /// The background click at the bucket list offers nothing either: "New
    /// Folder" there means a bucket, which macSCP does not create, and
    /// `S3FileSystem` refuses both calls at that level anyway. An entry
    /// that can only fail is not an offer.
    @Test func theBucketListBackgroundOffersNoNewFolderOrNewFile() {
        #expect(BrowserContextMenu.entries(for: [], side: .remote, scope: listRoot) == [])
    }

    /// The positive checks beside all of the above, and the reason the
    /// predicate takes a path rather than a "this is S3" flag: ONE level
    /// in, the same session's rows offer everything they always did.
    @Test func oneLevelInsideABucketTheFullMenuIsBack() {
        let object = RemoteFileItem(name: "a.txt", path: "/macscp-seed/a.txt", kind: .file, size: 1)

        let entries = BrowserContextMenu.entries(
            for: [object], side: .remote, supportsChecksum: true, scope: insideABucket)

        #expect(entries.contains(.transferToOtherPane))
        #expect(entries.contains(.rename))
        #expect(entries.contains(.delete))
        #expect(entries.contains(.computeChecksum))
        #expect(BrowserContextMenu.entries(for: [], side: .remote, scope: insideABucket)
            == [.newFolder, .newFile])
    }

    /// And with the toggle OFF — every SSH and WebDAV pane, and an S3
    /// session pointed at one bucket — the menu is byte-identical to the
    /// one the defaulted call produces, for a row whose path has exactly
    /// the shape a bucket row has.
    @Test func anOrdinarySessionsMenuIsUnchangedForTheSameShapedRow() {
        let folder = RemoteFileItem(name: "var", path: "/var", kind: .directory)

        #expect(
            BrowserContextMenu.entries(
                for: [folder], side: .remote, supportsChecksum: true, scope: .ordinary)
            == BrowserContextMenu.entries(for: [folder], side: .remote, supportsChecksum: true))
        #expect(BrowserContextMenu.entries(for: [], side: .remote, scope: .ordinary)
            == [.newFolder, .newFile])
    }

    /// A selection can only ever be rows of ONE listing, so "some rows are
    /// buckets" is not a shape the browser produces — but the gate reads
    /// the ROWS, not the pane, so a caller that mixes them is still held to
    /// the rule rather than quietly getting the full menu.
    @Test func oneBucketRowInASelectionGatesTheWholeSelection() {
        let object = RemoteFileItem(name: "a.txt", path: "/macscp-seed/a.txt", kind: .file, size: 1)

        let entries = BrowserContextMenu.entries(
            for: [object, bucket("macscp-second")], side: .remote,
            supportsChecksum: true, scope: insideABucket)

        #expect(entries == [.copyPath])
    }
}
