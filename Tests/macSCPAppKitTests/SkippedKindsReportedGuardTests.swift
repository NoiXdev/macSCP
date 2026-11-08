import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// An import of a file a NEWER macSCP wrote reports the entries it could
/// not read — in both import paths.
///
/// Why this is a guard and not only a unit test: `skippedKinds` defaults to
/// `[]` on both result-text builders, so a call site that stops passing it
/// still compiles and the line simply stops appearing. That is the exact
/// failure this task exists to remove — three of four sessions imported and
/// "3 imported" reported — arriving through a dropped argument instead of
/// through a thrown-away document.
///
/// Read from the corpus's CODE view
/// (`SwiftSource.blankingCommentsAndStrings`), so a comment quoting the
/// wiring is not the wiring — the two call sites below both carry an
/// explanatory comment next to the argument.
///
/// Every check here is POSITIVE: each names something that must be present,
/// so it fails loudly the moment the thing it names moves, rather than
/// going quiet. `propertyName` is read off a key path for the same reason —
/// a renamed `skippedKinds` fails to compile here instead of leaving three
/// searches for a string nothing spells any more.
@Suite("Skipped kinds are reported to the user")
struct SkippedKindsReportedGuardTests {
    private static let sessionOwnerFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/ContentView+ExportImport.swift")
    private static let loginOwnerFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/LoginSetsSheet.swift")
    private static let textFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/ImportFeedbackText.swift")

    /// `skippedKinds`, derived from `SessionExportPayload`'s own property
    /// rather than spelled.
    private static let propertyName: String = {
        let described = String(describing: \SessionExportPayload.skippedKinds)
        return String(described.split(separator: ".").last ?? "")
    }()

    /// Never read for its value. Typechecks only while
    /// `LoginSetExportPayload` carries a `skippedKinds: [String]` too, so
    /// the twin losing the property fails the BUILD here rather than
    /// leaving the login-set check below to search for a name only the
    /// session payload still has.
    ///
    /// A function rather than a `static let`: a `KeyPath` is not
    /// `Sendable`, and a static one does not compile under
    /// `.swiftLanguageMode(.v6)` — measured here, `error: static property
    /// 'loginKeyPathTypechecks' is not concurrency-safe because
    /// non-'Sendable' type 'KeyPath<LoginSetExportPayload, [String]>' may
    /// have shared mutable state`. The sibling guard
    /// `LoginSetImportLatchWiringGuardTests` can hold one because its
    /// whole suite is `@MainActor`; this one reads files and does not need
    /// to be.
    private static func loginKeyPathTypechecks() -> KeyPath<LoginSetExportPayload, [String]> {
        \.skippedKinds
    }

    /// The derivation itself, so a key-path description that stopped naming
    /// the property cannot turn every check below into a search for "".
    @Test func theNameIsDerived() {
        #expect(Self.propertyName == "skippedKinds")
        _ = Self.loginKeyPathTypechecks()
    }

    /// The session import passes what the DECODE skipped into the result
    /// text, read off the payload — the planner never saw those entries, so
    /// a count taken from the plan would always be zero.
    @Test func theSessionImportPassesWhatTheDecodeSkipped() throws {
        let code = try SourceCorpus.code(of: Self.sessionOwnerFile)
        let body = try #require(
            Self.body(of: "func applyImport(", in: code),
            "no `applyImport` in ContentView+ExportImport.swift — re-anchor this guard")
        #expect(
            body.contains("\(Self.propertyName): pending.payload.\(Self.propertyName)"),
            "applyImport does not pass the decoded payload's \(Self.propertyName)")
    }

    /// The login-set import does the same, and composes the line through
    /// the shared builder rather than wording it a second time.
    @Test func theLoginSetImportPassesWhatTheDecodeSkippedAndUsesTheSharedLine() throws {
        let code = try SourceCorpus.code(of: Self.loginOwnerFile)
        let applyBody = try #require(
            Self.body(of: "func applyImport(", in: code),
            "no `applyImport` in LoginSetsSheet.swift — re-anchor this guard")
        #expect(
            applyBody.contains("\(Self.propertyName): pending.payload.\(Self.propertyName)"),
            "applyImport does not pass the decoded payload's \(Self.propertyName)")

        let textBody = try #require(
            Self.body(of: "func importResultText(", in: code),
            "no `importResultText` in LoginSetsSheet.swift — re-anchor this guard")
        #expect(
            textBody.contains("ImportFeedbackText.skippedKindsLine("),
            "the login-set summary does not compose the skipped-entries line in one place")
    }

    /// The shared builder is where the sentence lives, and it is looked up
    /// rather than hardcoded.
    @Test func theLineIsComposedOnceAndLookedUpFromTheCatalog() throws {
        let code = try SourceCorpus.code(of: Self.textFile)
        let body = try #require(
            Self.body(of: "func skippedKindsLine(", in: code),
            "no `skippedKindsLine` in ImportFeedbackText.swift — re-anchor this guard")
        #expect(body.contains("L10n.string("), "the line is not looked up through L10n")

        // The catalogue key is a string LITERAL, so the code view above has
        // it blanked; this one check reads the comment-free view instead,
        // where literals survive and a comment quoting the key cannot
        // stand in for it. The four catalogues are held to carrying the key
        // by `everyStringThisFeatureShowsIsInAllFourCatalogs` and
        // `everyPluralCatalogDeclaresExactlyTheEnglishKeys`.
        let literals = try SourceCorpus.commentFree(of: Self.textFile)
        let literalBody = try #require(
            Self.body(of: "func skippedKindsLine(", in: literals),
            "no `skippedKindsLine` in ImportFeedbackText.swift — re-anchor this guard")
        #expect(
            literalBody.contains("import.result.skippedKinds"),
            "the skipped-entries line no longer looks up its own catalog key")
    }

    /// The brace-balanced body after the first occurrence of `anchor`.
    private static func body(of anchor: String, in code: String) -> String? {
        guard let start = code.range(of: anchor),
            let open = code[start.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }
}
