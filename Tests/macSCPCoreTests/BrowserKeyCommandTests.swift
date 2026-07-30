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
}
