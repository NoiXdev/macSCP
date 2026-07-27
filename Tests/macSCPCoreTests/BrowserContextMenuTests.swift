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

    @Test func backgroundShowsOnlyNewFolder() {
        #expect(BrowserContextMenu.entries(for: [], side: .remote) == [.newFolder])
    }

    @Test func singleRemoteFileShowsEverything() {
        #expect(BrowserContextMenu.entries(for: [file("a")], side: .remote) == [
            .transferToOtherPane, .openInEditor, .rename, .infoAndPermissions,
            .newFolder, .copyPath, .delete,
        ])
    }

    @Test func localPaneNeverOffersEditor() {
        #expect(!BrowserContextMenu.entries(for: [file("a")], side: .local)
            .contains(.openInEditor))
    }

    @Test func symlinkGetsNoTransferNoEditorNoPermissions() {
        let entries = BrowserContextMenu.entries(for: [symlink("l")], side: .remote)
        #expect(entries == [.rename, .newFolder, .copyPath, .delete])
    }

    @Test func multiSelectionDropsSingleOnlyEntries() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote)
        #expect(entries == [.transferToOtherPane, .newFolder, .copyPath, .delete])
    }

    @Test func symlinkOnlyMultiSelectionHasNoTransfer() {
        let entries = BrowserContextMenu.entries(
            for: [symlink("l1"), symlink("l2")], side: .remote)
        #expect(entries == [.newFolder, .copyPath, .delete])
    }

    @Test func directoriesGetNoEditor() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        #expect(!BrowserContextMenu.entries(for: [dir], side: .remote)
            .contains(.openInEditor))
    }
}
