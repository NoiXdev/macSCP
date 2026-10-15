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
            .newFolder, .newFile, .copyPath, .compareWithOtherPane, .delete,
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
        #expect(entries == [
            .transferToOtherPane, .newFolder, .newFile, .copyPath,
            .compareTwoSelected, .delete,
        ])
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
            .newFolder, .newFile, .copyPath, .computeChecksum,
            .compareWithOtherPane, .delete,
        ])
    }

    /// A selection is computed one file after another, so several files
    /// are exactly as offerable as one.
    @Test func aMultipleSelectionOffersTheChecksumEntry() {
        #expect(BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote, supportsChecksum: true) == [
            .transferToOtherPane, .newFolder, .newFile, .copyPath,
            .computeChecksum, .compareTwoSelected, .delete,
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

    // MARK: - The destination side (review C-1)

    /// The toolbar's **Download** button, decided here rather than by a
    /// second `.disabled(...)` rule of its own.
    ///
    /// Before C-1 the button's only gate was "at least one non-symlink is
    /// selected", which a bucket row satisfies — so selecting a bucket
    /// WITHOUT opening it enabled Download, and one click enqueued
    /// `enqueueTree(direction: .download, sourceDirectory: "/macscp-seed")`.
    /// Nothing refused it: `list` and `stat` are exactly the two calls a
    /// bucket legitimately answers, so the whole bucket came down.
    ///
    /// The button now asks for `.transferToOtherPane`, which is what the
    /// context menu and the Space key already ask for — so the symlink rule
    /// is no longer a second copy either.
    @Test func aSelectedBucketRowOffersNoTransferSoDownloadIsDisabled() {
        let entries = BrowserContextMenu.entries(
            for: [bucket("macscp-seed")], side: .remote, scope: listRoot)

        #expect(!entries.contains(.transferToOtherPane))
    }

    /// The positive check beside it: an object row one level in still
    /// offers the transfer, so Download is still enabled where it should be.
    @Test func anObjectRowInsideABucketStillOffersTheTransfer() {
        let object = RemoteFileItem(name: "a.txt", path: "/macscp-seed/a.txt", kind: .file, size: 1)

        #expect(BrowserContextMenu.entries(for: [object], side: .remote, scope: insideABucket)
            .contains(.transferToOtherPane))
    }

    /// The toolbar's **Upload** button and the LOCAL pane's "Transfer ▸ To
    /// the other pane", which are the same decision seen from the other end:
    /// the rows are ordinary local files, and it is the DESTINATION that
    /// cannot receive.
    ///
    /// Core refuses the resulting `write("/name")` after the fact
    /// (`bucketLevelRefused`), which is precisely the treatment this task
    /// closed for the drop target two files away. Same action, other door,
    /// so: same answer.
    @Test func nothingIsOfferedToAPaneSittingAtTheBucketList() {
        let localFile = RemoteFileItem(name: "a.txt", path: "/Users/me/a.txt", kind: .file, size: 1)

        let entries = BrowserContextMenu.entries(
            for: [localFile], side: .local, scope: .ordinary, destination: listRoot)

        #expect(!entries.contains(.transferToOtherPane))
        // Everything else the local row could do is untouched: the
        // destination's trouble is not this row's.
        #expect(entries.contains(.rename))
        #expect(entries.contains(.delete))
        #expect(entries.contains(.copyPath))
    }

    /// The positive check beside it, twice: the same local row offers the
    /// transfer when the destination is one level inside a bucket, and when
    /// the destination is an ordinary pane — which is every SSH, WebDAV and
    /// single-bucket S3 session, and the defaulted call.
    @Test func aPaneThatCanReceiveStillGetsOfferedTheTransfer() {
        let localFile = RemoteFileItem(name: "a.txt", path: "/Users/me/a.txt", kind: .file, size: 1)

        #expect(BrowserContextMenu.entries(
            for: [localFile], side: .local, scope: .ordinary, destination: insideABucket)
            .contains(.transferToOtherPane))
        #expect(BrowserContextMenu.entries(
            for: [localFile], side: .local, scope: .ordinary, destination: .ordinary)
            .contains(.transferToOtherPane))
        #expect(BrowserContextMenu.entries(for: [localFile], side: .local)
            .contains(.transferToOtherPane))
    }

    /// Cross-session targets survive a destination that cannot receive:
    /// another TAB's remote pane is a different destination, and
    /// `CrossSessionTargets.targets` is what excludes the ones that are
    /// themselves at a bucket list. The AppKit menu builder relies on the
    /// ORDER here — targets follow `.transferToOtherPane` when it is
    /// present, and stand alone when it is not — so the contract is pinned
    /// rather than left to be read.
    @Test func crossSessionTargetsSurviveARefusingOtherPaneAndKeepTheirOrder() {
        let localFile = RemoteFileItem(name: "a.txt", path: "/Users/me/a.txt", kind: .file, size: 1)
        let target = CrossSessionTarget(
            id: UUID(), title: "other", remotePath: "/var", kind: .ssh)

        let refused = BrowserContextMenu.entries(
            for: [localFile], side: .local, crossSessionTargets: [target],
            scope: .ordinary, destination: listRoot)
        #expect(refused.first == .transferToSession(target))

        let accepted = BrowserContextMenu.entries(
            for: [localFile], side: .local, crossSessionTargets: [target],
            scope: .ordinary, destination: .ordinary)
        #expect(Array(accepted.prefix(2)) == [.transferToOtherPane, .transferToSession(target)])
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

    // MARK: - User-defined actions (file-actions plan, 2026-10-12)

    @Test func aUserActionIsOfferedOnTheSideItDeclares() {
        let remoteOnly = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let onRemote = BrowserContextMenu.entries(
            for: [file("a")], side: .remote, userFileActions: [remoteOnly])
        let onLocal = BrowserContextMenu.entries(
            for: [file("a")], side: .local, userFileActions: [remoteOnly])
        #expect(onRemote.contains(.userFileAction(remoteOnly)))
        #expect(onLocal.contains(.userFileAction(remoteOnly)) == false)
    }

    /// A store file can hold an action the editor would have refused. It is
    /// not offered, rather than offered and failing when clicked.
    @Test func anInvalidActionIsNotOffered() {
        let invalid = FileAction(name: "Broken", command: "wc -l '{{PATH}}'", runsOn: [.remote])
        #expect(FileActionTemplate.firstProblem(in: invalid) != nil)
        let entries = BrowserContextMenu.entries(
            for: [file("a")], side: .remote, userFileActions: [invalid])
        #expect(entries.contains(.userFileAction(invalid)) == false)
    }

    /// Offered last, so adding one never moves an entry a user's hand has
    /// learned. The positive beside that: `delete` is still present.
    @Test func userActionsComeAfterEveryBuiltInEntry() {
        let action = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let entries = BrowserContextMenu.entries(
            for: [file("a")], side: .remote, userFileActions: [action])
        let deleteIndex = entries.firstIndex(of: .delete)
        let actionIndex = entries.firstIndex(of: .userFileAction(action))
        #expect(deleteIndex != nil)
        #expect(actionIndex != nil)
        if let deleteIndex, let actionIndex { #expect(actionIndex > deleteIndex) }
    }

    @Test func noUserActionsLeavesTheMenuExactlyAsItWas() {
        let without = BrowserContextMenu.entries(for: [file("a")], side: .remote)
        let withEmpty = BrowserContextMenu.entries(
            for: [file("a")], side: .remote, userFileActions: [])
        #expect(withEmpty == without)
    }

    // MARK: - The two comparison entries (diff view plan, Task 12)

    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .directory)
    }

    /// One row, measured against its counterpart in the other pane. The row
    /// may be a file or a folder: which of the two a comparison is of is the
    /// App's reading of `kind`, not a second gate here.
    @Test func oneRowIsOfferedTheComparisonWithTheOtherPane() {
        #expect(BrowserContextMenu.entries(for: [file("a")], side: .remote)
            .contains(.compareWithOtherPane))
        #expect(BrowserContextMenu.entries(for: [folder("d")], side: .local)
            .contains(.compareWithOtherPane))
    }

    /// Exactly two selected FILES of one side, compared with each other.
    @Test func exactlyTwoSelectedFilesAreOfferedTheirOwnComparison() {
        let entries = BrowserContextMenu.entries(for: [file("a"), file("b")], side: .remote)
        #expect(entries.contains(.compareTwoSelected))
        // And that offer is the two-row one, not the one-row one.
        #expect(entries.contains(.compareWithOtherPane) == false)
    }

    /// Each negative carries the positive beside it — the entry list is not
    /// empty — so a filter that matched nothing could not pass for a filter
    /// that excluded correctly.
    @Test func oneFileIsNotTwo() {
        let entries = BrowserContextMenu.entries(for: [file("a")], side: .remote)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareTwoSelected) == false)
    }

    @Test func threeFilesAreNotTwo() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), file("b"), file("c")], side: .remote)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareTwoSelected) == false)
        #expect(entries.contains(.compareWithOtherPane) == false)
    }

    /// Two rows, and neither is a file: there is no pair of files to compare.
    /// The folder pair's own comparison is the ONE-row entry, over the other
    /// pane.
    @Test func aFolderPairIsNotAFilePair() {
        let entries = BrowserContextMenu.entries(
            for: [folder("d1"), folder("d2")], side: .remote)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareTwoSelected) == false)
    }

    /// One file and one folder is not two files either — the mixed case the
    /// three above leave out.
    @Test func aFileAndAFolderAreNotTwoFiles() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), folder("d")], side: .remote)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareTwoSelected) == false)
    }

    /// The background click. Its list is the two "new" entries, which is the
    /// positive beside the negative: a non-empty menu that holds neither
    /// comparison.
    @Test func anEmptySelectionIsOfferedNoComparison() {
        let entries = BrowserContextMenu.entries(for: [], side: .remote)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareTwoSelected) == false)
        #expect(entries.contains(.compareWithOtherPane) == false)
    }

    /// A bucket row answers `copyPath` and nothing else, the rule at the top
    /// of `entries(for:…)`. Comparison does not reach around it.
    @Test func aBucketRowIsOfferedNoComparison() {
        let entries = BrowserContextMenu.entries(
            for: [bucket("macscp-seed")], side: .remote, scope: listRoot)
        #expect(entries == [.copyPath])
    }

    /// The OTHER pane has to be showing a directory for a counterpart to
    /// exist: at a bucket list the same name would be a BUCKET, which is a
    /// container and not an entry to compare. Withheld rather than offered
    /// and refused — the `computeChecksum` judgement.
    @Test func theOneRowComparisonIsWithheldWhileTheOtherPaneSitsAtABucketList() {
        let refused = BrowserContextMenu.entries(
            for: [file("a")], side: .local, destination: listRoot)
        #expect(refused.isEmpty == false)
        #expect(refused.contains(.compareWithOtherPane) == false)
        // The positive: one level in, the same call offers it.
        let accepted = BrowserContextMenu.entries(
            for: [file("a")], side: .local, destination: insideABucket)
        #expect(accepted.contains(.compareWithOtherPane))
    }

    /// The two-row comparison asks nothing of the other pane — both sides of
    /// it are this pane's — so the gate above does not touch it.
    @Test func theTwoRowComparisonSurvivesTheOtherPaneSittingAtABucketList() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .local, destination: listRoot)
        #expect(entries.contains(.compareTwoSelected))
    }

    /// A symlink row is offered NEITHER comparison, which is the exclusion
    /// `transferToOtherPane`, `infoAndPermissions` and `computeChecksum`
    /// already make. The reason here is its own: `stat` FOLLOWS a link on
    /// every backend this app speaks, so a comparison of a link is a
    /// comparison of whatever it points at, shown under the link's name.
    @Test func aSymlinkRowIsOfferedNeitherComparison() {
        let one = BrowserContextMenu.entries(for: [symlink("l")], side: .remote)
        #expect(one.isEmpty == false)
        #expect(one.contains(.compareWithOtherPane) == false)

        let two = BrowserContextMenu.entries(
            for: [symlink("l1"), symlink("l2")], side: .remote)
        #expect(two.isEmpty == false)
        #expect(two.contains(.compareTwoSelected) == false)

        // The positives beside both: the same two shapes of selection DO get
        // their entry when the rows are ordinary files, so neither negative
        // above can be a filter that matches nothing.
        #expect(BrowserContextMenu.entries(for: [file("a")], side: .remote)
            .contains(.compareWithOtherPane))
        #expect(BrowserContextMenu.entries(for: [file("a"), file("b")], side: .remote)
            .contains(.compareTwoSelected))
    }

    /// One file and one symlink is not two files — the mixed case the pair
    /// above leaves out, and the one a `kind != .symlink` test on the FIRST
    /// row only would let through.
    @Test func aFileAndASymlinkAreNotTwoFiles() {
        for selection in [[file("a"), symlink("l")], [symlink("l"), file("a")]] {
            let entries = BrowserContextMenu.entries(for: selection, side: .remote)
            #expect(entries.isEmpty == false)
            #expect(entries.contains(.compareTwoSelected) == false)
        }
    }

    /// A single DIRECTORY row keeps its one-row comparison: the symlink
    /// exclusion above is about links, not about everything that is not a
    /// file.
    @Test func aDirectoryRowKeepsItsOneRowComparison() {
        #expect(BrowserContextMenu.entries(for: [folder("d")], side: .local)
            .contains(.compareWithOtherPane))
    }

    /// Fix round 2. The FAR side's kind is read from the other pane's loaded
    /// rows, which came from a listing — and a listing reports a symlink as a
    /// symlink on every backend. `stat` cannot: over SFTP it is
    /// `SSH_FXP_STAT`, which follows the link and answers for its target, so
    /// a link to a regular file reached the diff and the target's bytes were
    /// shown under the link's path. This is the one layer that can see it.
    @Test func aFarSideListedAsASymlinkIsOfferedNoComparison() {
        let rows = [symlink("a"), file("b")]
        let withheld = BrowserContextMenu.entries(
            for: [file("a")], side: .local, destinationRows: rows)
        #expect(withheld.isEmpty == false)
        #expect(withheld.contains(.compareWithOtherPane) == false)

        // The positive beside it: the OTHER name in the very same listing is
        // an ordinary file, and that row is offered. So the negative above is
        // about the counterpart's kind and not about the listing existing.
        let offered = BrowserContextMenu.entries(
            for: [file("b")], side: .local, destinationRows: rows)
        #expect(offered.contains(.compareWithOtherPane))
    }

    /// Only a symlink is withheld this way. A far DIRECTORY, a far `.other`
    /// and a far name that is not there at all keep the entry: each of those
    /// `stat` CAN see, so the comparison opens and refuses with a reason the
    /// user can read, which is better than an entry that is simply absent.
    @Test func aFarSideOfAnyOtherKindKeepsTheEntryAndItsReadableRefusal() {
        let cases: [[RemoteFileItem]] = [
            [RemoteFileItem(name: "a", path: "/a", kind: .directory)],
            [RemoteFileItem(name: "a", path: "/a", kind: .other, size: nil)],
            [file("a")],
            [],                       // never listed, or loading, or errored
            [file("other")],          // listed, but not this name
        ]
        for rows in cases {
            let entries = BrowserContextMenu.entries(
                for: [file("a")], side: .local, destinationRows: rows)
            #expect(entries.contains(.compareWithOtherPane), "\(rows)")
        }
    }

    /// The far row is matched by Swift `String` equality, which is UNICODE
    /// CANONICAL EQUIVALENCE — not byte equality (fix round 3, N3).
    ///
    /// This test was called `theFarRowIsMatchedByItsNameExactly` and its doc
    /// comment read "Byte-exact on the name, deliberately: a name that only
    /// matches under normalisation falls through to the fallback, which is
    /// correct." Both halves were wrong. `$0.name == only.name` is `String
    /// ==`, which folds NFD and NFC — the property `ComparisonPairing.pairs`
    /// keys on UTF-8 bytes to ESCAPE, and says so in its own doc comment —
    /// so a name that matches only under normalisation is CAUGHT, not missed.
    /// And its three fixtures were a capital, a trailing space and a
    /// different name: no normalisation case at all, which is why making the
    /// match genuinely byte-exact left the suite green and put the stronger
    /// behaviour in the tree by accident of `==` rather than by decision.
    ///
    /// The NFD case below is what makes it a decision. It is also the
    /// assertion that protects the gate from being "tidied" to byte keys for
    /// consistency with `ComparisonPairing` — a change a careful reader would
    /// make for a good-sounding reason, which would silently let a far
    /// symlink whose name is spelled in the other normal form through to the
    /// diff, where `stat` follows it.
    @Test func theFarRowIsMatchedByCanonicalEquivalenceAndNotByBytes() {
        // "cafe\u{301}" (NFD) and "caf\u{e9}" (NFC) are canonically
        // equivalent and byte-different. The far row is listed in one form,
        // the selected row carries the other.
        let nfd = "cafe\u{301}"
        let nfc = "caf\u{e9}"
        #expect(nfd == nfc)
        #expect(Array(nfd.utf8) != Array(nfc.utf8))

        let farListing = [
            RemoteFileItem(name: nfd, path: "/\(nfd)", kind: .symlink, size: nil)
        ]
        let nearRow = RemoteFileItem(name: nfc, path: "/\(nfc)", kind: .file, size: 1)
        let entries = BrowserContextMenu.entries(
            for: [nearRow], side: .local, destinationRows: farListing)
        #expect(entries.isEmpty == false)
        #expect(entries.contains(.compareWithOtherPane) == false)

        // Positive beside it: the same near row against a far listing of the
        // same name as an ordinary FILE is offered, so the negative above is
        // about the kind and not about the name failing to match at all.
        let asAFile = [RemoteFileItem(name: nfd, path: "/\(nfd)", kind: .file, size: 1)]
        #expect(BrowserContextMenu.entries(
            for: [nearRow], side: .local, destinationRows: asAFile)
            .contains(.compareWithOtherPane))
    }

    /// What `String ==` does NOT fold, and the fallback those land in: case,
    /// a trailing space, and a different name are different names, so the
    /// entry is offered and the comparison answers for itself.
    @Test func aFarNameThatMerelyLooksSimilarIsADifferentName() {
        let almost = [
            RemoteFileItem(name: "A", path: "/A", kind: .symlink, size: nil),
            RemoteFileItem(name: "a ", path: "/a ", kind: .symlink, size: nil),
            RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .symlink, size: nil),
        ]
        let entries = BrowserContextMenu.entries(
            for: [file("a")], side: .local, destinationRows: almost)
        #expect(entries.contains(.compareWithOtherPane))
        // Positive: the exact name, in the same shape of listing, IS matched.
        let exact = almost + [symlink("a")]
        #expect(BrowserContextMenu.entries(
            for: [file("a")], side: .local, destinationRows: exact)
            .contains(.compareWithOtherPane) == false)
    }

    /// The TWO-row entry asks nothing of the other pane — both of its rows
    /// come from this selection and carry their own listed kinds, which the
    /// `allSatisfy` on `.file` already holds to account. So the far rows
    /// change nothing about it, in either direction.
    @Test func theTwoRowEntryIsUntouchedByTheFarSide() {
        let pair = [file("a"), file("b")]
        let withFar = BrowserContextMenu.entries(
            for: pair, side: .local, destinationRows: [symlink("a"), symlink("b")])
        #expect(withFar.contains(.compareTwoSelected))
        let withoutFar = BrowserContextMenu.entries(for: pair, side: .local)
        #expect(withFar == withoutFar)
    }

    /// No far rows at all leaves every menu byte-identical to the one the
    /// defaulted call produces — the floor this gate falls back to.
    @Test func noFarRowsLeavesTheMenuExactlyAsItWas() {
        for selection in [[file("a")], [file("a"), file("b")], [folder("d")], []] {
            #expect(
                BrowserContextMenu.entries(for: selection, side: .local, destinationRows: [])
                == BrowserContextMenu.entries(for: selection, side: .local))
        }
    }

    /// Before `delete`, so the separator the App draws above `delete` still
    /// divides the inspections from the destructive entry, and before the
    /// user's own actions, which stay the last run.
    @Test func theComparisonEntriesComeBeforeDeleteAndBeforeTheUsersOwnActions() throws {
        let action = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let one = BrowserContextMenu.entries(
            for: [file("a")], side: .remote, userFileActions: [action])
        let compare = try #require(one.firstIndex(of: .compareWithOtherPane))
        let delete = try #require(one.firstIndex(of: .delete))
        let user = try #require(one.firstIndex(of: .userFileAction(action)))
        #expect(compare < delete)
        #expect(delete < user)

        let two = BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote, userFileActions: [action])
        let pair = try #require(two.firstIndex(of: .compareTwoSelected))
        let pairDelete = try #require(two.firstIndex(of: .delete))
        #expect(pair < pairDelete)
    }
}
