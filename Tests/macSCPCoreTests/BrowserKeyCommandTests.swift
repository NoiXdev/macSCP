import Foundation
import Testing
@testable import macSCPCore

@Suite("BrowserKeyCommand")
struct BrowserKeyCommandTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .file, size: 1)
    }
    private func symlink(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .symlink, size: nil)
    }

    // MARK: - .returnKey -> rename

    @Test func returnKeyWithSingleSelectionRenames() {
        let item = file("a")
        #expect(BrowserKeyCommand.resolve(key: .returnKey, selection: [item], side: .remote) == .rename(item))
    }

    @Test func returnKeyWithMultipleSelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .returnKey, selection: [file("a"), file("b")], side: .remote) == nil)
    }

    @Test func returnKeyWithEmptySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .returnKey, selection: [], side: .remote) == nil)
    }

    // MARK: - .commandDown / .commandO -> open

    @Test func commandDownWithSingleSelectionOpens() {
        let item = file("a")
        #expect(BrowserKeyCommand.resolve(key: .commandDown, selection: [item], side: .remote) == .open(item))
    }

    @Test func commandOWithSingleSelectionOpens() {
        let item = file("a")
        #expect(BrowserKeyCommand.resolve(key: .commandO, selection: [item], side: .remote) == .open(item))
    }

    @Test func commandDownWithMultipleSelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandDown, selection: [file("a"), file("b")], side: .remote) == nil)
    }

    @Test func commandOWithMultipleSelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandO, selection: [file("a"), file("b")], side: .remote) == nil)
    }

    @Test func commandDownWithEmptySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandDown, selection: [], side: .remote) == nil)
    }

    @Test func commandOWithEmptySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandO, selection: [], side: .remote) == nil)
    }

    // MARK: - .commandUp -> goUp (always)

    @Test func commandUpAlwaysGoesUp() {
        #expect(BrowserKeyCommand.resolve(key: .commandUp, selection: [], side: .remote) == .goUp)
        #expect(BrowserKeyCommand.resolve(key: .commandUp, selection: [file("a")], side: .remote) == .goUp)
        #expect(BrowserKeyCommand.resolve(key: .commandUp, selection: [file("a"), file("b")], side: .remote) == .goUp)
    }

    // MARK: - .commandDelete -> delete

    @Test func commandDeleteWithNonEmptySelectionDeletes() {
        let selection = [file("a"), file("b")]
        #expect(BrowserKeyCommand.resolve(key: .commandDelete, selection: selection, side: .remote) == .delete(selection))
    }

    @Test func commandDeleteWithEmptySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandDelete, selection: [], side: .remote) == nil)
    }

    // MARK: - .commandI -> info

    @Test func commandIWithSingleFileShowsInfo() {
        let item = file("a")
        #expect(BrowserKeyCommand.resolve(key: .commandI, selection: [item], side: .remote) == .info(item))
    }

    @Test func commandIWithSingleSymlinkIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandI, selection: [symlink("l")], side: .remote) == nil)
    }

    @Test func commandIWithMultipleSelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .commandI, selection: [file("a"), file("b")], side: .remote) == nil)
    }

    // MARK: - .space -> transfer

    @Test func spaceWithTransferableSelectionTransfers() {
        let selection = [file("a"), symlink("l")]
        #expect(BrowserKeyCommand.resolve(key: .space, selection: selection, side: .remote) == .transfer(selection))
    }

    @Test func spaceWithTransferableSelectionTransfersOnLocalSideToo() {
        let selection = [file("a")]
        #expect(BrowserKeyCommand.resolve(key: .space, selection: selection, side: .local) == .transfer(selection))
    }

    @Test func spaceWithSymlinkOnlySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .space, selection: [symlink("l")], side: .remote) == nil)
    }

    @Test func spaceWithEmptySelectionIsNil() {
        #expect(BrowserKeyCommand.resolve(key: .space, selection: [], side: .remote) == nil)
    }

    // MARK: - .escape -> clearSelection (always)

    @Test func escapeAlwaysClearsSelection() {
        #expect(BrowserKeyCommand.resolve(key: .escape, selection: [], side: .remote) == .clearSelection)
        #expect(BrowserKeyCommand.resolve(key: .escape, selection: [file("a")], side: .remote) == .clearSelection)
    }

    // MARK: - A bucket row opens, nothing else (2026-09-02, Task 4)

    private func bucket(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .directory)
    }
    private var listRoot: BrowserScope {
        BrowserScope(rootIsContainerList: true, currentPath: "/")
    }

    /// This resolver's whole reason for existing is that the keyboard must
    /// never be more permissive than the menu. The bucket gate lives in
    /// `entries`, so threading the scope through is the entire change — and
    /// this test is what proves it was threaded, in every direction the
    /// keyboard can go.
    @Test func theKeyboardIsNoMorePermissiveOnABucketRowThanTheMenu() {
        let selection = [bucket("macscp-seed")]

        #expect(BrowserKeyCommand.resolve(
            key: .returnKey, selection: selection, side: .remote, scope: listRoot) == nil)
        #expect(BrowserKeyCommand.resolve(
            key: .commandDelete, selection: selection, side: .remote, scope: listRoot) == nil)
        #expect(BrowserKeyCommand.resolve(
            key: .commandI, selection: selection, side: .remote, scope: listRoot) == nil)
        #expect(BrowserKeyCommand.resolve(
            key: .space, selection: selection, side: .remote, scope: listRoot) == nil)
    }

    /// …and the one action the design DOES offer still resolves, from both
    /// of its keys. Open takes a row and never asks the menu model, which
    /// is exactly why it survives the gate — stated here so a later reader
    /// does not "fix" the asymmetry.
    @Test func aBucketRowStillOpensFromTheKeyboard() {
        let only = bucket("macscp-seed")

        #expect(BrowserKeyCommand.resolve(
            key: .commandDown, selection: [only], side: .remote, scope: listRoot) == .open(only))
        #expect(BrowserKeyCommand.resolve(
            key: .commandO, selection: [only], side: .remote, scope: listRoot) == .open(only))
        #expect(BrowserKeyCommand.resolve(
            key: .commandUp, selection: [only], side: .remote, scope: listRoot) == .goUp)
    }

    /// The positive check beside them: the same keys on the same-shaped row
    /// in an ordinary session are unchanged, and the defaulted call and the
    /// explicit `.ordinary` one agree.
    @Test func anOrdinarySessionsKeysAreUnchangedForTheSameShapedRow() {
        let folder = RemoteFileItem(name: "var", path: "/var", kind: .directory)

        #expect(BrowserKeyCommand.resolve(
            key: .returnKey, selection: [folder], side: .remote, scope: .ordinary)
            == .rename(folder))
        #expect(BrowserKeyCommand.resolve(
            key: .returnKey, selection: [folder], side: .remote)
            == .rename(folder))
        #expect(BrowserKeyCommand.resolve(
            key: .commandDelete, selection: [folder], side: .remote, scope: .ordinary)
            == .delete([folder]))
    }
}
