import Foundation
import Testing
import macSCPCore

/// Guards the line the S3 endpoint field draws under itself — "Connects to
/// https://minio.lan:9000" — against the two ways it can go missing without
/// anything turning red (2026-09-03, the task that made a schemeless
/// `host:9000` connectable): `ConnectionFormView` stops handing
/// `SchemaFormView` the closure, or `SchemaFormView` stops calling it.
///
/// A source scan, not a rendered check, for the reason every guard in this
/// target is one: this project renders no view in a test.
///
/// Every check here is POSITIVE — each names something that must be PRESENT —
/// except `theFootnoteNamesNoFieldButTheEndpoint`, which is paired with the
/// presence check above it (this project's rule: a negative check without a
/// positive one beside it stops matching in silence).
@Suite("Endpoint footnote wiring")
struct EndpointFootnoteWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/EndpointFootnoteWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ relativePath: String) throws -> String {
        SheetFacetWiringGuardTests.strippingLineComments(
            try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func formView() throws -> String {
        try source("Sources/MacSCPAppKit/ConnectionFormView.swift")
    }

    private static func schemaView() throws -> String {
        try source("Sources/MacSCPAppKit/SchemaFormView.swift")
    }

    /// The body of `fieldFootnote`, from its signature to the next
    /// declaration at the same indentation. Nil when the function is gone,
    /// which every caller turns into a failure rather than into an empty
    /// string that satisfies a scan.
    private static func footnoteBody(in source: String) -> String? {
        guard let start = source.range(of: "private func fieldFootnote(") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    @Test func theFormHandsTheSchemaViewItsFootnoteClosure() throws {
        let source = try Self.formView()
        let call = try #require(
            source.range(of: "SchemaFormView("),
            "ConnectionFormView no longer builds a SchemaFormView — this guard's anchor is gone")
        let rest = source[call.upperBound...]
        let argumentList = try #require(
            rest.range(of: ")").map { String(rest[rest.startIndex..<$0.lowerBound]) })
        #expect(argumentList.contains("footnote:"), """
            The SchemaFormView built by ConnectionFormView carries no \
            `footnote:` argument, so the S3 endpoint field no longer says \
            what it understood — a form that silently assumes https for a \
            schemeless endpoint and shows nothing about it.
            """)
    }

    @Test func theSchemaViewDrawsWhateverTheFootnoteReturns() throws {
        let source = try Self.schemaView()
        #expect(source.contains("footnote?("), """
            SchemaFormView declares a `footnote` but never calls it, so \
            nothing it returns reaches the screen.
            """)
    }

    /// The footnote's text is composed in Core (`canonicalEndpoint` yields
    /// `scheme://host[:port]`) and localized in the App. Both halves are
    /// checked, because either one alone is a different feature: a hardcoded
    /// English sentence, or a localized sentence about nothing.
    @Test func theFootnoteAsksCoreWhatTheEndpointMeansAndSaysItLocalized() throws {
        let body = try #require(Self.footnoteBody(in: try Self.formView()),
                                "fieldFootnote is gone from ConnectionFormView")
        #expect(body.contains("S3FieldSchema.canonicalEndpoint("))
        #expect(body.contains("connection.s3.endpoint.understood %@"))
        #expect(body.contains("connection.s3.endpoint.unreadable"))
    }

    /// The footnote is about the ENDPOINT field, identified by the schema
    /// enum rather than by a spelled-out `"endpoint"` — a literal is a second
    /// copy of a name, and this one would keep compiling after a rename while
    /// matching no field at all.
    @Test func theFootnoteIdentifiesItsFieldThroughTheSchemaEnum() throws {
        let body = try #require(Self.footnoteBody(in: try Self.formView()),
                                "fieldFootnote is gone from ConnectionFormView")
        #expect(body.contains("S3Field.endpoint.rawValue"))
        #expect(!body.contains("\"\(S3Field.endpoint.rawValue)\""), """
            fieldFootnote compares against the literal field id instead of \
            S3Field.endpoint.rawValue.
            """)
    }

    /// A message about a connection must never carry the login. The footnote
    /// reads exactly one field's value and composes an ORIGIN from it, so no
    /// access key or secret can reach the screen through this line — and
    /// naming any other S3 field here would be the change that breaks that.
    /// Paired with the presence checks above, which prove the body is still
    /// there to scan.
    @Test func theFootnoteNamesNoFieldButTheEndpoint() throws {
        let body = try #require(Self.footnoteBody(in: try Self.formView()),
                                "fieldFootnote is gone from ConnectionFormView")
        for field in S3Field.allCases where field != .endpoint {
            #expect(!body.contains("S3Field.\(field.rawValue)"), """
                fieldFootnote reads S3Field.\(field.rawValue). The line it \
                draws is a sentence about where the connection points; only \
                the endpoint belongs in it.
                """)
        }
    }
}
