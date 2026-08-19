import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The audit sheet looks a kind's label up as `audit.kind.<rawValue>`; a
/// missing entry silently renders the raw case name to the user. Catalog
/// key-set parity across languages is already covered by
/// `LocalizableStringsTests`, so this only checks the English catalog, but
/// it checks it for every `AuditEvent.Kind` case, present or future. It
/// also pins the Terminal filter's label, which no `Kind` case covers.
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

    /// A missing `audit.kind.*` entry silently renders the raw case name to
    /// the user, and nothing else catches that for a FUTURE case -- this
    /// runs over every case in `AuditEvent.Kind`, not just the one this
    /// phase added, so the next kind that forgets its label fails here.
    @Test(arguments: AuditEvent.Kind.allCases)
    func everyKindHasACatalogLabel(kind: AuditEvent.Kind) throws {
        let text = try catalog("en")
        #expect(text.contains("\"audit.kind.\(kind.rawValue)\""), "missing for \(kind.rawValue)")
    }

    @Test func everyCatalogLabelsTheTerminalFilter() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.filter.terminal\""), "missing in \(language)")
        }
    }
}
