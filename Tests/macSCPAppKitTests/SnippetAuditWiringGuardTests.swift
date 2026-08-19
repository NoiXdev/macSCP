import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The audit sheet looks a kind's label up as `audit.kind.<rawValue>`; a
/// missing entry silently renders the raw case name to the user. This pins
/// the new kind in every catalog, and pins the new filter's label with it.
@Suite("Snippet audit wiring")
struct SnippetAuditWiringGuardTests {
    private static let languages = ["en", "de", "fr", "pl"]

    private func catalog(_ language: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: "Localizable", withExtension: "strings",
                subdirectory: "\(language).lproj"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyCatalogLabelsTheSnippetKind() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.kind.snippetExecuted\""), "missing in \(language)")
        }
    }

    @Test func everyCatalogLabelsTheTerminalFilter() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.filter.terminal\""), "missing in \(language)")
        }
    }
}
