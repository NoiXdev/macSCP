import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The two passphrase actions on a managed key's context menu: WHEN each one
/// applies, and that each is actually wired to a target the sheet presents.
///
/// The first half is an ordinary unit test — `SSHKeysSheet.canCorrectPassphrase`
/// and `canChangePassphrase` are static and take the key and the store, so the
/// rule can be asked directly instead of inferred from source text.
///
/// The second half has to be a source scan: `SSHKeysSheet` cannot be
/// instantiated here (no view-render harness in this project, the boundary the
/// other wiring guards in this target already state). Every check in it is a
/// POSITIVE one — something that must be PRESENT — so none of them can go
/// quiet when what it names moves (CLAUDE.md, "Guards that name what they
/// watch"): a rename breaks them loudly. The five pre-existing actions are
/// asserted in the same span, so a span that has drifted onto the wrong
/// function fails instead of reporting success over nothing.
/// `@MainActor` because `canCorrectPassphrase`/`canChangePassphrase` are
/// members of a `View` and inherit its isolation; calling them from a
/// nonisolated suite compiles with an `#ActorIsolatedCall` warning, and the
/// warning budget here is zero.
@Suite("Managed key passphrase actions", .timeLimit(.minutes(1)))
@MainActor
struct KeyPassphraseActionsTests {
    private static let sourceFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/SSHKeysSheet.swift")

    private func tempStore() -> (ManagedKeyStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-passactions-\(UUID().uuidString)")
        return (ManagedKeyStore(directory: dir), dir)
    }

    private func key(encrypted: Bool, fileName: String? = nil) -> ManagedKey {
        let id = UUID()
        return ManagedKey(
            id: id, name: "work", comment: "", type: .ed25519,
            fingerprint: "SHA256:placeholder",
            publicKeyOpenSSH: "ssh-ed25519 AAAAplaceholder work",
            createdAt: Date(), hasPassphrase: encrypted, fileName: fileName ?? id.uuidString)
    }

    @Test func anEncryptedManagedKeyOffersBothActions() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = key(encrypted: true)
        #expect(SSHKeysSheet.canCorrectPassphrase(key, in: store))
        #expect(SSHKeysSheet.canChangePassphrase(key, in: store))
    }

    @Test func aKeyWhoseFileIsNotEncryptedCanOnlyBeGivenAPassphrase() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = key(encrypted: false)
        // Nothing is stored for an unencrypted key, so there is nothing to
        // correct — but the file can still be encrypted for the first time.
        #expect(SSHKeysSheet.canCorrectPassphrase(key, in: store) == false)
        #expect(SSHKeysSheet.canChangePassphrase(key, in: store))
    }

    @Test func anEntryWhoseFileNameLeavesTheKeyDirectoryOffersNeither() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let escaping = key(encrypted: true, fileName: "../elsewhere")
        #expect(SSHKeysSheet.canCorrectPassphrase(escaping, in: store) == false)
        #expect(SSHKeysSheet.canChangePassphrase(escaping, in: store) == false)
        // The same key with an ordinary file name IS offered both, so the two
        // refusals above are the file name and not the fixture.
        let ordinary = key(encrypted: true)
        #expect(SSHKeysSheet.canCorrectPassphrase(ordinary, in: store))
        #expect(SSHKeysSheet.canChangePassphrase(ordinary, in: store))
    }

    @Test func bothActionsSitOnTheContextMenuBesideTheExistingFive() throws {
        let menu = try Self.actionMenuItemsBody()
        // The five that were there before, asserted in the same span: without
        // them a span that has drifted elsewhere would look satisfied.
        for existing in [
            "keys.copyPublic", "keys.exportPublic", "keys.exportPrivate", "keys.rename",
            "keys.delete",
        ] {
            #expect(menu.contains(existing), "existing action \(existing)")
        }
        #expect(menu.contains("keys.passphrase.correct"))
        #expect(menu.contains("keys.passphrase.change"))
        #expect(menu.contains("correctPassphraseTarget = key"))
        #expect(menu.contains("changePassphraseTarget = key"))
    }

    @Test func bothActionsCarryTheirOwnDisabledRule() throws {
        let menu = try Self.actionMenuItemsBody()
        #expect(menu.contains(".disabled(!Self.canCorrectPassphrase(key, in: store))"))
        #expect(menu.contains(".disabled(!Self.canChangePassphrase(key, in: store))"))
    }

    @Test func eachTargetIsPresentedBySomething() throws {
        let source = try SourceCorpus.commentFree(of: Self.sourceFile)
        #expect(source.contains(".sheet(item: $correctPassphraseTarget)"))
        #expect(source.contains(".sheet(item: $changePassphraseTarget)"))
        #expect(source.contains("CorrectKeyPassphraseSheet("))
        #expect(source.contains("ChangeKeyPassphraseSheet("))
    }

    /// The body of `actionMenuItems(for:)`, comments stripped
    /// (`SourceCorpus.commentFree`) — an explanatory comment quoting the code it
    /// describes is indistinguishable from that code to a scanner, which this
    /// project has been bitten by (CLAUDE.md, 2026-08-29). NOT
    /// `SourceCorpus.code`, which blanks string literals as well: the
    /// catalogue keys this scan reads ARE string literals, and every check
    /// below passed vacuously over the blanked version.
    ///
    /// Throws rather than returning the whole file when the declaration or its
    /// closing brace cannot be found, so a renamed function is a loud failure
    /// and not a scan that quietly searches everything.
    private static func actionMenuItemsBody() throws -> String {
        let source = try SourceCorpus.commentFree(of: sourceFile)
        let declaration = "private func actionMenuItems(for key: ManagedKey) -> some View {"
        guard let start = source.range(of: declaration) else {
            throw MenuScanError.declarationNotFound(declaration)
        }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        guard depth == 0 else { throw MenuScanError.unbalancedBraces }
        return String(source[start.upperBound..<index])
    }

    private enum MenuScanError: Error, CustomStringConvertible {
        case declarationNotFound(String)
        case unbalancedBraces

        var description: String {
            switch self {
            case .declarationNotFound(let declaration):
                return """
                    No declaration `\(declaration)` in SSHKeysSheet.swift. The context-menu \
                    builder was renamed or its signature changed; point this scan at the new \
                    one rather than widening it to the whole file.
                    """
            case .unbalancedBraces:
                return "Braces did not balance while reading the context-menu builder's body."
            }
        }
    }
}
