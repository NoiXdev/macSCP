import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The audit sheet looks a kind's label up as `audit.kind.<rawValue>`; a
/// missing entry silently renders the raw case name to the user. This checks
/// every shipped language for every `AuditEvent.Kind` case, present or
/// future, so the guard names the kind and the language that lacks a label
/// itself rather than relying on the key-set parity tests to notice a
/// catalogue that is short of one. It also pins the Terminal filter's label,
/// which no `Kind` case covers.
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
        // Every shipped language, not English alone: a label present only in
        // `en` passes a check of `en` while the other three render the raw
        // case name. This is a positive `contains` check, so a catalogue that
        // loses the entry fails here instead of passing in silence.
        for language in Self.languages {
            let text = try catalog(language)
            #expect(
                text.contains("\"audit.kind.\(kind.rawValue)\""),
                "missing for \(kind.rawValue) in \(language)")
        }
    }

    /// The `audit.kind.<case>` entries of one catalogue's text, as
    /// `(case, label)` pairs in file order. Read as text, like the guard
    /// above, so it sees each language and not the test bundle's own locale.
    private static func kindLabels(in text: String) throws -> [(kind: String, label: String)] {
        let entry = try NSRegularExpression(
            pattern: "^\"audit\\.kind\\.([A-Za-z]+)\"\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\";",
            options: [.anchorsMatchLines])
        let whole = NSRange(text.startIndex..., in: text)
        return entry.matches(in: text, range: whole).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: text),
                let label = Range(match.range(at: 2), in: text)
            else { return nil }
            return (kind: String(text[kind]), label: String(text[label]))
        }
    }

    /// The labels that more than one kind carries.
    private static func repeatedLabels(_ pairs: [(kind: String, label: String)]) -> [String] {
        Dictionary(grouping: pairs, by: \.label).filter { $0.value.count > 1 }.keys.sorted()
    }

    /// The audit table's Event column draws a kind's label, so two kinds with
    /// one label are indistinguishable rows. `AuditLogSortingTests` asserts
    /// uniqueness through the test bundle's locale, which pins English only;
    /// this reads each catalogue, so a duplicate in `de`, `fr` or `pl` is seen.
    @Test(arguments: ["en", "de", "fr", "pl"])
    func noTwoKindsShareALabelInTheCatalogue(language: String) throws {
        let pairs = try Self.kindLabels(in: try catalog(language))
        // The positive half, so an empty read cannot pass as "no duplicates":
        // every kind was found, and each has a label.
        #expect(pairs.count == AuditEvent.Kind.allCases.count, "read \(pairs.count) labels in \(language)")
        #expect(Set(pairs.map(\.kind)) == Set(AuditEvent.Kind.allCases.map(\.rawValue)))
        #expect(pairs.allSatisfy { !$0.label.isEmpty })
        let repeated = Self.repeatedLabels(pairs)
        #expect(repeated.isEmpty, "labels shared by more than one kind in \(language): \(repeated)")
    }

    /// The positive control for the guard above: the same reading and the same
    /// comparison, on text that does carry a duplicate, finds it.
    @Test func theLabelGuardSeesADuplicateWhenThereIsOne() throws {
        let text = """
            "audit.kind.rename" = "Moved";
            "audit.kind.delete" = "Removed";
            "audit.kind.newFile" = "Moved";
            """
        let pairs = try Self.kindLabels(in: text)
        #expect(pairs.count == 3)
        #expect(Self.repeatedLabels(pairs) == ["Moved"])
    }

    @Test func everyCatalogLabelsTheTerminalFilter() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.filter.terminal\""), "missing in \(language)")
        }
    }
}
