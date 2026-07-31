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
/// every catalog directly off disk (via a `#filePath`-relative path, so it
/// runs regardless of `swift test`'s working directory) and asserts each one
/// parses, AND that every non-English language's key set is identical to
/// English's, per layer.
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
    private static let coreEnPath = "Sources/macSCPCore/Resources/en.lproj/Localizable.strings"

    /// Loads a `.strings` file (old-style property list) as `[String:
    /// String]`, or `nil` if it fails to parse as a property list AT ALL --
    /// this is the exact failure mode `plutil -lint` reports and the one a
    /// grep-based key scan is blind to.
    private static func parse(_ relativePath: String) -> [String: String]? {
        let path = repoRoot.appendingPathComponent(relativePath).path(percentEncoded: false)
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// Non-English languages per layer. Task 3 appends "pl".
    private static let appLangs = ["de", "fr"]
    private static let coreLangs = ["de", "fr"]

    private static func appPath(_ lang: String) -> String {
        "Sources/MacSCPApp/Resources/\(lang).lproj/Localizable.strings"
    }
    private static func corePath(_ lang: String) -> String {
        "Sources/macSCPCore/Resources/\(lang).lproj/Localizable.strings"
    }

    private static var allPaths: [String] {
        [appEnPath, coreEnPath]
            + appLangs.map(appPath) + coreLangs.map(corePath)
    }

    @Test(arguments: LocalizableStringsTests.allPaths)
    func catalogParsesAsAPropertyList(relativePath: String) {
        #expect(
            Self.parse(relativePath) != nil,
            "\(relativePath) failed to parse as a property list — check for an unescaped quote or other syntax error"
        )
    }

    @Test func appLayerLanguagesMatchEnglishKeys() {
        for lang in Self.appLangs {
            assertIdenticalKeys(enPath: Self.appEnPath, otherPath: Self.appPath(lang))
        }
    }

    @Test func coreLayerLanguagesMatchEnglishKeys() {
        for lang in Self.coreLangs {
            assertIdenticalKeys(enPath: Self.coreEnPath, otherPath: Self.corePath(lang))
        }
    }

    private func assertIdenticalKeys(enPath: String, otherPath: String) {
        guard let en = LocalizableStringsTests.parse(enPath) else {
            Issue.record("\(enPath) failed to parse as a property list"); return
        }
        guard let other = LocalizableStringsTests.parse(otherPath) else {
            Issue.record("\(otherPath) failed to parse as a property list"); return
        }
        let missing = Set(en.keys).subtracting(other.keys)
        let extra = Set(other.keys).subtracting(en.keys)
        #expect(missing.isEmpty, "Keys present in \(enPath) but missing from \(otherPath): \(missing.sorted())")
        #expect(extra.isEmpty, "Keys present in \(otherPath) but missing from \(enPath): \(extra.sorted())")
    }
}
