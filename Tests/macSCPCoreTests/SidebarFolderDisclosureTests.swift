import Foundation
import Testing

@testable import macSCPCore

/// The two halves of "the search overlays the collapse state, it does not
/// overwrite it".
///
/// Both halves are decidable, so both are decided here rather than inside a
/// `Binding` in a view body no test can construct: what a folder DRAWS as,
/// and what the remembered state BECOMES when the user works the disclosure
/// triangle. The second is the one the design puts a condition on — a search
/// that permanently unfolded someone's folders would have rearranged their
/// sidebar unasked — and a rule that lives in a closure is a rule no test
/// reaches.
@Suite("Sidebar folder disclosure")
struct SidebarFolderDisclosureTests {
    @Test func aFolderTheUserClosedDrawsClosedWhileNothingIsSearched() {
        let folder = UUID()
        #expect(!SidebarFolderDisclosure.isOpen(
            folder, collapsed: [folder], expandsFolders: false))
        #expect(SidebarFolderDisclosure.isOpen(
            folder, collapsed: [], expandsFolders: false))
    }

    /// A match inside a closed folder is filtered and still invisible, so
    /// the remembered state is not consulted at all while a search narrows
    /// the tree.
    @Test func everyFolderDrawsOpenWhileASearchNarrowsTheTree() {
        let folder = UUID()
        #expect(SidebarFolderDisclosure.isOpen(
            folder, collapsed: [folder], expandsFolders: true))
    }

    /// The condition the maintainer's ruling rests on: nothing is written
    /// while searching. `nil` is not "collapse nothing" — it is "do not
    /// write", which is what keeps a folder the user closed closed again the
    /// moment the field is empty.
    @Test func workingTheTriangleWhileSearchingWritesNothing() {
        let folder = UUID()
        let remembered: Set<UUID> = [folder]
        #expect(SidebarFolderDisclosure.collapsed(
            remembered, setting: folder, open: false, expandsFolders: true) == nil)
        #expect(SidebarFolderDisclosure.collapsed(
            remembered, setting: folder, open: true, expandsFolders: true) == nil)
    }

    /// And the other half: with the field empty, the triangle writes exactly
    /// what it always did.
    @Test func closingAndOpeningAFolderIsRememberedWhileNothingIsSearched() {
        let folder = UUID()
        let other = UUID()
        let closed = SidebarFolderDisclosure.collapsed(
            [other], setting: folder, open: false, expandsFolders: false)
        #expect(closed == [other, folder])
        let opened = SidebarFolderDisclosure.collapsed(
            [other, folder], setting: folder, open: true, expandsFolders: false)
        #expect(opened == [other])
    }
}
