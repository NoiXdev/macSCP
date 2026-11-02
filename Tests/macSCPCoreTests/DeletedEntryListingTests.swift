import Foundation
import Testing
@testable import macSCPCore

/// A directory listing that also shows the keys a delete marker hides
/// (S3 version history, Task 10): the row a `DeletedEntry` becomes, and what
/// `RemoteBrowserViewModel` does with the switch that asks for them.
///
/// The App's half (which connections the switch can apply to, and the request
/// counts that prove it) is `ShowDeletedFilesTests`.
@Suite("Deleted entries in the listing", .timeLimit(.minutes(5)))
@MainActor
struct DeletedEntryListingTests {
    // MARK: Fixtures

    /// A source that answers what it is told and writes down what it was
    /// asked, so a test can say that it was NOT asked.
    @MainActor
    final class FakeDeletedFileSource: DeletedFileSource {
        var availability: DeletedFilesAvailability = .available
        var answer: DeletedFilesAnswer = .rows([])
        var error: (any Error)?
        private(set) var listed: [String] = []
        private(set) var asked: [String] = []

        func availability(inDirectory path: String) async -> DeletedFilesAvailability {
            asked.append(path)
            return availability
        }

        func deletedFiles(inDirectory path: String) async throws -> DeletedFilesAnswer {
            listed.append(path)
            if let error { throw error }
            return answer
        }
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func deletedRow(_ name: String, marker: String = "m1", in directory: String = "/") -> RemoteFileItem {
        RemoteFileItem(
            name: name, path: RemotePath.join(directory, name), kind: .file, modifiedAt: day,
            deleteMarkerVersionID: marker)
    }

    private func makeFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "kept.txt", path: "/kept.txt", kind: .file, size: 1),
                RemoteFileItem(name: "Folder", path: "/Folder", kind: .directory),
            ]
        ])
    }

    // MARK: The row

    @Test func aDeletedKeyBecomesARowCarryingItsMarkerVersionId() {
        let entries = [
            DeletedEntry(key: "docs/a.txt", markerVersionId: "marker-7", modifiedAt: day)
        ]
        let rows = RemoteFileItem.deletedRows(
            from: entries, inDirectory: "/bucket/docs", keyPrefix: "docs/")
        #expect(rows.count == 1)
        let row = rows.first
        #expect(row?.name == "a.txt")
        #expect(row?.path == "/bucket/docs/a.txt")
        #expect(row?.kind == .file)
        #expect(row?.size == nil)
        #expect(row?.modifiedAt == day)
        #expect(row?.deleteMarkerVersionID == "marker-7")
        #expect(row?.isDeleted == true)
    }

    /// The row's name is the part of the key after the prefix; an entry that
    /// has no such part, or one that reaches into a sub-folder, is not a row
    /// of THIS directory. Core's listing already drops both, so this is the
    /// second line of defence and the positive beside it.
    @Test func onlyAKeyDirectlyUnderThePrefixBecomesARow() {
        let entries = [
            DeletedEntry(key: "docs/a.txt", markerVersionId: "m1", modifiedAt: nil),
            DeletedEntry(key: "docs/sub/b.txt", markerVersionId: "m2", modifiedAt: nil),
            DeletedEntry(key: "docs/", markerVersionId: "m3", modifiedAt: nil),
            DeletedEntry(key: "other/c.txt", markerVersionId: "m4", modifiedAt: nil),
        ]
        let rows = RemoteFileItem.deletedRows(from: entries, inDirectory: "/b/docs", keyPrefix: "docs/")
        #expect(rows.map(\.name) == ["a.txt"])
    }

    @Test func everyExistingCallSiteOfRemoteFileItemStillCompiles() {
        // The positive beside the default: an item built with the old argument
        // list has `isDeleted == false`.
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file)
        #expect(item.isDeleted == false)
        #expect(item.deleteMarkerVersionID == nil)
    }

    // MARK: The listing

    @Test func aDeletedRowJoinsTheListingAndANormalOneDoesNot() async {
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow("gone.txt")])
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["Folder", "gone.txt", "kept.txt"])
        #expect(vm.items.filter(\.isDeleted).map(\.name) == ["gone.txt"])
        #expect(vm.deletedFilesNotice == nil)
    }

    @Test func aSwitchedOffPaneNeverAsksTheSource() async {
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow("gone.txt")])
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        await vm.load()
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(source.listed.isEmpty)
        // The positive beside the negative: the same source is asked once the
        // switch is on, so the empty list above is the switch and not a source
        // that was never wired.
        vm.showDeletedFiles = true
        await vm.load()
        #expect(source.listed == ["/"])
    }

    @Test func theHiddenFilesFilterAppliesToDeletedRowsToo() async {
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow(".secret"), deletedRow("seen.txt")])
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.items.filter(\.isDeleted).map(\.name) == ["seen.txt"])
        vm.showHiddenFiles = true
        await vm.load()
        #expect(vm.items.filter(\.isDeleted).map(\.name) == [".secret", "seen.txt"])
    }

    /// A key and a folder can share a name (`a` deleted, `a/x` present). The
    /// table identifies rows by path, so the listing keeps the one the plain
    /// listing reported and drops the deleted row rather than show two rows
    /// with one identity.
    @Test func aDeletedRowWhosePathIsAlreadyListedIsDropped() async {
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow("Folder"), deletedRow("gone.txt")])
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.items.map(\.path) == ["/Folder", "/gone.txt", "/kept.txt"])
        #expect(vm.items.first { $0.path == "/Folder" }?.isDeleted == false)
    }

    // MARK: Cannot apply, cannot confirm, cannot list

    @Test func aSourceThatDoesNotApplyLeavesThePlainListing() async {
        let source = FakeDeletedFileSource()
        source.answer = .notApplicable
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(vm.state == .loaded)
        #expect(vm.deletedFilesNotice == nil)
    }

    @Test func anUnreadVersioningStateIsSaidToBeUnconfirmedAndNotToBeOff() async {
        let source = FakeDeletedFileSource()
        source.answer = .notConfirmed
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(vm.state == .loaded)
        #expect(vm.deletedFilesNotice == .versioningNotConfirmed)
    }

    /// The plain listing worked, so the pane shows it; the deleted listing did
    /// not, so the pane says so rather than let the absence read as "nothing
    /// was deleted". The error itself goes nowhere: a `reason` can carry an
    /// endpoint of the form `scheme://KEY:SECRET@host`.
    @Test func aFailedDeletedListingKeepsThePlainRowsAndSaysSo() async {
        let source = FakeDeletedFileSource()
        let canary = "https://AKIACANARYKEY:SECRETCANARY@store.invalid"
        source.error = RemoteFSError.protocolError(reason: canary)
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(vm.state == .loaded)
        #expect(vm.lastLoadError == nil)
        #expect(vm.deletedFilesNotice == .listingFailed)
        let noticeText = String(describing: vm.deletedFilesNotice)
        let leaked = noticeText.contains("SECRETCANARY") || noticeText.contains("AKIACANARYKEY")
        #expect(leaked == false)
    }

    @Test func aNoticeEndsWithTheNextLoad() async {
        let source = FakeDeletedFileSource()
        source.answer = .notConfirmed
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        #expect(vm.deletedFilesNotice == .versioningNotConfirmed)
        source.answer = .rows([])
        await vm.load()
        #expect(vm.deletedFilesNotice == nil)
    }

    // MARK: The silent refresh

    @Test func theSilentRefreshKeepsTheDeletedRowsItCannotReread() async {
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow("gone.txt")])
        let vm = RemoteBrowserViewModel(fs: makeFS())
        vm.deletedFileSource = source
        vm.showDeletedFiles = true
        await vm.load()
        source.error = RemoteFSError.protocolError(reason: "x")
        await vm.refreshQuietly()
        #expect(vm.items.filter(\.isDeleted).map(\.name) == ["gone.txt"])
        // And it replaces them when it can read: the row that is gone is gone.
        source.error = nil
        source.answer = .rows([])
        await vm.refreshQuietly()
        #expect(vm.items.filter(\.isDeleted).isEmpty)
    }

    // MARK: Turning the switch

    @Test func turningTheSwitchOnWhereItAppliesListsAgainAndOffDropsTheRowsWithoutARequest() async {
        let fs = makeFS()
        let source = FakeDeletedFileSource()
        source.answer = .rows([deletedRow("gone.txt")])
        let vm = RemoteBrowserViewModel(fs: fs)
        vm.deletedFileSource = source
        await vm.load()
        let before = await fs.listCallCounts["/"] ?? 0

        await vm.setShowDeletedFiles(true)
        #expect(vm.items.filter(\.isDeleted).map(\.name) == ["gone.txt"])
        #expect(await fs.listCallCounts["/"] == before + 1)

        await vm.setShowDeletedFiles(false)
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(vm.showDeletedFiles == false)
        // Dropping rows already held needs no request at all.
        #expect(await fs.listCallCounts["/"] == before + 1)
    }

    @Test func turningTheSwitchOnWhereItCannotApplyChangesNothing() async {
        let fs = makeFS()
        let source = FakeDeletedFileSource()
        source.availability = .notApplicable
        let vm = RemoteBrowserViewModel(fs: fs)
        vm.deletedFileSource = source
        await vm.load()
        vm.selectedItems = [vm.items[0]]
        let itemsBefore = vm.items
        let before = await fs.listCallCounts["/"] ?? 0

        await vm.setShowDeletedFiles(true)
        #expect(vm.items == itemsBefore)
        #expect(vm.state == .loaded)
        #expect(vm.selectedItems.count == 1)
        #expect(vm.deletedFilesNotice == nil)
        #expect(source.listed.isEmpty)
        #expect(await fs.listCallCounts["/"] == before)
        // The preference is kept for the next directory it does apply to.
        #expect(vm.showDeletedFiles == true)
    }

    @Test func aPaneWithNoSourceTakesTheSwitchAndDoesNothingElse() async {
        let fs = makeFS()
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let before = await fs.listCallCounts["/"] ?? 0
        await vm.setShowDeletedFiles(true)
        #expect(vm.items.map(\.name) == ["Folder", "kept.txt"])
        #expect(vm.deletedFilesNotice == nil)
        #expect(await fs.listCallCounts["/"] == before)
        // The positive beside it: this stub does count a listing.
        await vm.load()
        #expect(await fs.listCallCounts["/"] == before + 1)
    }

    @Test func anUnconfirmedAvailabilityIsSaidAndDoesNotReList() async {
        let fs = makeFS()
        let source = FakeDeletedFileSource()
        source.availability = .notConfirmed
        let vm = RemoteBrowserViewModel(fs: fs)
        vm.deletedFileSource = source
        await vm.load()
        let before = await fs.listCallCounts["/"] ?? 0
        await vm.setShowDeletedFiles(true)
        #expect(vm.deletedFilesNotice == .versioningNotConfirmed)
        #expect(await fs.listCallCounts["/"] == before)
        #expect(vm.state == .loaded)
    }

    // MARK: Menu and keys

    @Test func aDeletedRowOffersRestoreAndCopyPathAndNothingThatNeedsTheObject() {
        let selection = [deletedRow("gone.txt")]
        let entries = BrowserContextMenu.entries(
            for: selection, side: .remote, fileActions: [], supportsChecksum: true,
            supportsArchiving: true)
        #expect(entries == [.restoreDeleted, .copyPath])
        // The positive beside it: an ordinary file gets the long menu and no restore.
        let ordinary = BrowserContextMenu.entries(
            for: [RemoteFileItem(name: "a", path: "/a", kind: .file)], side: .remote)
        #expect(ordinary.contains(.rename))
        #expect(!ordinary.contains(.restoreDeleted))
    }

    @Test func aSelectionMixingDeletedAndPresentRowsOffersOnlyCopyPath() {
        let selection = [
            deletedRow("gone.txt"), RemoteFileItem(name: "a", path: "/a", kind: .file),
        ]
        let entries = BrowserContextMenu.entries(for: selection, side: .remote)
        #expect(entries == [.copyPath])
    }

    @Test func theKeyboardDoesNotOpenOrRenameADeletedRow() {
        let selection = [deletedRow("gone.txt")]
        #expect(BrowserKeyCommand.resolve(key: .commandO, selection: selection, side: .remote) == nil)
        #expect(BrowserKeyCommand.resolve(key: .commandDown, selection: selection, side: .remote) == nil)
        #expect(BrowserKeyCommand.resolve(key: .returnKey, selection: selection, side: .remote) == nil)
        #expect(BrowserKeyCommand.resolve(key: .commandDelete, selection: selection, side: .remote) == nil)
        // The positive beside the negatives: the same keys resolve on a present file.
        let present = [RemoteFileItem(name: "a", path: "/a", kind: .file)]
        #expect(BrowserKeyCommand.resolve(key: .commandO, selection: present, side: .remote) != nil)
        #expect(BrowserKeyCommand.resolve(key: .returnKey, selection: present, side: .remote) != nil)
    }
}

@Suite("Deleted files setting")
@MainActor
struct ShowDeletedFilesSettingTests {
    @Test func showDeletedFilesDefaultsFalseAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.showDeletedFiles == false)
        store.showDeletedFiles = true
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.showDeletedFiles == true)
        // The sibling stays its own switch.
        #expect(reloaded.showHiddenFiles == false)
    }
}
