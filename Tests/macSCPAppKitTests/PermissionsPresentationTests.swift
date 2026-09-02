import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the info sheet's permissions block IS for each pair of answers it
/// can be given — decided as a value, so it is testable without rendering.
///
/// Two questions feed it, and they are different questions: whether the
/// BACKEND has a permission model the editor speaks (the capability), and
/// whether THIS ENTRY came with bits (the listing). Each has its own
/// sentence, because "this server has no file permissions" and "this entry
/// did not come with any" are not the same fact, and the first one used to
/// be said as the second only by the accident of every S3 and WebDAV
/// listing leaving the field `nil`.
@Suite("Permissions presentation")
struct PermissionsPresentationTests {
    private static let unresolved = "ZZ-UNRESOLVED-ZZ"

    /// A backend without a permission model shows no editor — and it does
    /// not matter what the listing carried, because the capability is the
    /// statement about what `setPermissions` can do, and the bits are not.
    @Test func aBackendWithoutAModelIsTheServerSentenceWhateverTheEntryCarries() {
        #expect(PermissionsPresentation.of(supportsPermissions: false, permissions: 0o644)
            == .unavailableOnThisServer)
        #expect(PermissionsPresentation.of(supportsPermissions: false, permissions: nil)
            == .unavailableOnThisServer)
    }

    /// A POSIX backend whose listing carried no bits for this entry says
    /// that, and says it about the entry.
    @Test func aPosixBackendWithoutBitsForThisEntryIsTheEntrySentence() {
        #expect(PermissionsPresentation.of(supportsPermissions: true, permissions: nil)
            == .unavailableForThisEntry)
    }

    /// Both answers present: the editor, and nothing said in its place.
    @Test func aPosixBackendWithBitsIsTheEditor() {
        let presentation = PermissionsPresentation.of(supportsPermissions: true, permissions: 0o644)
        #expect(presentation == .editor)
        #expect(presentation.sentence == nil)
    }

    /// Each sentence resolves from the catalog rather than falling back to
    /// its English default — the same check `ChecksumDisplayTests` makes
    /// for the checksum's own "this server does not" sentence.
    @Test func theServerSentenceIsLocalized() {
        let sentence = PermissionsPresentation.unavailableOnThisServer.sentence
        #expect(sentence == L10n.string("info.permissionsUnavailableOnThisServer", Self.unresolved))
        #expect(sentence != Self.unresolved)
    }

    @Test func theEntrySentenceIsLocalized() {
        let sentence = PermissionsPresentation.unavailableForThisEntry.sentence
        #expect(sentence == L10n.string("info.permissionsUnavailable", Self.unresolved))
        #expect(sentence != Self.unresolved)
    }

    // MARK: - The menu entry's title

    /// The entry that opens the sheet names what the sheet holds. On a
    /// backend with a permission model that is "Info & Permissions"; on
    /// one without, the same entry opens the same sheet, and its title
    /// says "Info" — a title promising an editor the sheet then explains
    /// away would be the disabled control in another place.
    @Test func theMenuTitlePromisesPermissionsOnlyWhereTheyAreOffered() {
        let withPermissions = PermissionsPresentation.infoMenuTitle(supportsPermissions: true)
        let without = PermissionsPresentation.infoMenuTitle(supportsPermissions: false)
        #expect(withPermissions == L10n.string("menu.info", Self.unresolved))
        #expect(without == L10n.string("menu.infoOnly", Self.unresolved))
        #expect(withPermissions != Self.unresolved)
        #expect(without != Self.unresolved)
        #expect(withPermissions != without)
    }

    /// The two sentences are different sentences. A catalog that mapped
    /// both keys to the same text would make the distinction above
    /// invisible to the user while every other test here stayed green.
    @Test func theTwoSentencesDiffer() {
        #expect(PermissionsPresentation.unavailableOnThisServer.sentence
            != PermissionsPresentation.unavailableForThisEntry.sentence)
    }
}
