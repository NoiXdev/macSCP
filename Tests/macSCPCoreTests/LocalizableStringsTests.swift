import Foundation
import Testing
@testable import macSCPCore

/// Permanent guard against the M11d final-review C-2 defect class: a single
/// unescaped smart quote on ONE line of a `.strings` file breaks the
/// PARSING of the ENTIRE file (verified: a mismatched `„...\"` pair made
/// `plutil -lint` fail and `NSDictionary(contentsOf:)` return `nil` for the
/// whole German `MacSCPApp` catalog, silently falling the whole German UI
/// back to English at runtime). A grep-based key-name scan cannot see this
/// class of defect at all — it only ever inspects key names, never whether
/// the file is valid property-list syntax to begin with. This suite loads
/// all four catalogs directly off disk (via a `#filePath`-relative path, so
/// it runs regardless of `swift test`'s working directory) and asserts each
/// one parses, AND that the en/de key sets are identical per layer.
@Suite("Localizable.strings catalogs")
struct LocalizableStringsTests {
    /// `#filePath` for this file is
    /// `<repoRoot>/Tests/macSCPCoreTests/LocalizableStringsTests.swift`;
    /// three `deletingLastPathComponent()` calls (file -> macSCPCoreTests/
    /// -> Tests/ -> repoRoot) recover the repo root regardless of `swift
    /// test`'s current working directory.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static let appEnPath = "Sources/MacSCPApp/Resources/en.lproj/Localizable.strings"
    private static let appDePath = "Sources/MacSCPApp/Resources/de.lproj/Localizable.strings"
    private static let coreEnPath = "Sources/macSCPCore/Resources/en.lproj/Localizable.strings"
    private static let coreDePath = "Sources/macSCPCore/Resources/de.lproj/Localizable.strings"

    /// Loads a `.strings` file (old-style property list) as `[String:
    /// String]`, or `nil` if it fails to parse as a property list AT ALL --
    /// this is the exact failure mode `plutil -lint` reports and the one a
    /// grep-based key scan is blind to.
    private static func parse(_ relativePath: String) -> [String: String]? {
        let path = repoRoot.appendingPathComponent(relativePath).path(percentEncoded: false)
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    @Test(arguments: [appEnPath, appDePath, coreEnPath, coreDePath])
    func catalogParsesAsAPropertyList(relativePath: String) {
        #expect(
            Self.parse(relativePath) != nil,
            "\(relativePath) failed to parse as a property list — check for an unescaped quote or other syntax error"
        )
    }

    @Test func appLayerHasIdenticalEnglishAndGermanKeys() {
        assertIdenticalKeys(enPath: Self.appEnPath, dePath: Self.appDePath)
    }

    @Test func coreLayerHasIdenticalEnglishAndGermanKeys() {
        assertIdenticalKeys(enPath: Self.coreEnPath, dePath: Self.coreDePath)
    }

    private func assertIdenticalKeys(enPath: String, dePath: String) {
        guard let en = LocalizableStringsTests.parse(enPath) else {
            Issue.record("\(enPath) failed to parse as a property list")
            return
        }
        guard let de = LocalizableStringsTests.parse(dePath) else {
            Issue.record("\(dePath) failed to parse as a property list")
            return
        }
        let missingInDe = Set(en.keys).subtracting(de.keys)
        let missingInEn = Set(de.keys).subtracting(en.keys)
        #expect(missingInDe.isEmpty, "Keys present in \(enPath) but missing from \(dePath): \(missingInDe.sorted())")
        #expect(missingInEn.isEmpty, "Keys present in \(dePath) but missing from \(enPath): \(missingInEn.sorted())")
    }
}
