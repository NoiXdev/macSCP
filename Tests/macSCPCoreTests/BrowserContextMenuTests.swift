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
}
