import Foundation
import Testing

/// The mismatch warnings end by sending the user to a menu item. Those two
/// sentences live in Core's catalogue; the menu labels they name live in the
/// App's. A claim about code elsewhere, held here: renaming either menu item
/// in a language would otherwise leave the warning pointing at something that
/// no longer exists, and nothing would go red.
///
/// Both sides are READ from the catalogue files, per locale. No menu label is
/// spelled in this file; a rename is followed, not tracked by hand.
///
/// The negative direction (the message contains the label) is paired with
/// positive checks that the label is non-empty and that the message is longer
/// than the label, so the test cannot pass by matching an empty string.
@Suite("Host-key mismatch hint names real menu items", .timeLimit(.minutes(1)))
struct HostKeyMismatchHintGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let locales = ["en", "de", "fr", "pl"]

    private static func catalogue(_ target: String, _ locale: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent(
            "Sources/\(target)/Resources/\(locale).lproj/Localizable.strings")
        return try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(target)/\(locale).lproj/Localizable.strings did not parse as a property list")
    }

    /// `menu.*` labels carry a trailing ellipsis (they open a sheet); the
    /// sentence names the item without it.
    private static func withoutEllipsis(_ label: String) -> String {
        var s = label.trimmingCharacters(in: .whitespaces)
        for suffix in ["…", "..."] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// (Core message key, App menu label key) pairs. The menu bar title the
    /// sentences also name (`menu.sessions`) is held the same way.
    private static let pairs: [(message: String, menu: String)] = [
        ("core.hostkey.mismatch %@ %@ %@", "menu.knownHosts"),
        ("core.certificate.mismatch %@ %@ %@", "menu.serverCertificates"),
        ("core.hostkey.mismatch %@ %@ %@", "menu.sessions"),
        ("core.certificate.mismatch %@ %@ %@", "menu.sessions"),
    ]

    @Test(arguments: ["en", "de", "fr", "pl"])
    func theMismatchMessageNamesTheMenuItemThatForgetsTheHost(locale: String) throws {
        let core = try Self.catalogue("macSCPCore", locale)
        let app = try Self.catalogue("MacSCPAppKit", locale)
        for pair in Self.pairs {
            let rawLabel = try #require(app[pair.menu], "\(locale): App catalogue lacks \(pair.menu)")
            let label = Self.withoutEllipsis(rawLabel)
            let message = try #require(core[pair.message], "\(locale): Core catalogue lacks \(pair.message)")

            let labelIsEmpty = label.isEmpty
            #expect(labelIsEmpty == false, "\(locale): \(pair.menu) is empty after stripping its ellipsis")
            let messageIsLonger = message.count > label.count
            #expect(messageIsLonger, "\(locale): \(pair.message) is not longer than \(pair.menu)")

            let namesTheItem = message.contains(label)
            #expect(namesTheItem, """
                \(locale): \(pair.message) does not contain the menu label \
                "\(label)" (\(pair.menu) in the App catalogue). A renamed menu \
                item leaves the warning pointing at something that is gone.
                """)
        }
    }

    @Test func theLocaleListCoversEveryCatalogueTheTargetsShip() throws {
        for target in ["macSCPCore", "MacSCPAppKit"] {
            let dir = Self.repoRoot.appendingPathComponent("Sources/\(target)/Resources")
            let found = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
                .filter { $0.hasSuffix(".lproj") }
                .map { String($0.dropLast(".lproj".count)) }
                .sorted()
            #expect(found == Self.locales.sorted(), "\(target) ships \(found); this guard checks \(Self.locales)")
        }
    }
}
