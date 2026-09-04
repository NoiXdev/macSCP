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
    /// The catalog keys these lines name. Written once, read by the checks
    /// that scan the view and by the one that scans the catalog, so the two
    /// cannot disagree about which keys exist.
    private static let footnoteKeys = [
        "connection.s3.endpoint.understood %@",
        "connection.s3.endpoint.unreadable",
    ]

    private static let pathStyleHintKey = "connection.s3.pathStyle.forcedByIP"

    private static func footnoteBody(in source: String) -> String? {
        guard let start = source.range(of: "private func fieldFootnote(") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    /// The parenthesis-balanced text between `call`'s own opening `(` and
    /// its matching close, paren-balanced the same way
    /// `TransferQueueBarCancelGuardTests.declarationBodyRange` brace-balances
    /// a declaration's body (that scanner is the model; this one counts `(`
    /// and `)` instead of `{` and `}`). `call` is a match on text ending in
    /// `"("` (e.g. `"SchemaFormView("`), so its `upperBound` already sits
    /// just past that opening paren and balancing starts at depth 1.
    ///
    /// Without this, cutting the list at the first `)` (fix round 2,
    /// 2026-09-04) would truncate it the moment any argument's value is
    /// itself a call — a false red naming a missing argument that is
    /// actually just past a `)` the scan stopped at early, not a silent
    /// pass.
    ///
    /// Balanced over `source` blanked by `SwiftSource.blankingCommentsAndStrings`
    /// (fix round 3, 2026-09-04), not over `source` itself: `source` here is
    /// only `strippingLineComments`, so a `)` written inside a string
    /// literal argument's own value — `footnote: describe(")")`, say —
    /// would be counted as a real close and truncate the list early, the
    /// same failure mode round 2 already fixed for a nested call. Positions
    /// are found in the blanked text and sliced out of the ORIGINAL
    /// `source`, so the returned text still carries the literal content the
    /// checks above read (e.g. `.contains("footnote:")`); this is safe only
    /// because `SwiftSourceStrippingTests.bothModesPreserveLengthAndLineStructure`
    /// holds the blanked text to the same character count as `source`,
    /// which is verified below rather than assumed — a stripper that ever
    /// changed length would silently address the wrong text through a
    /// borrowed offset, so the fallback slices the blanked text itself
    /// instead, which is line-for-line the same as `source` even if their
    /// counts ever drifted apart.
    private static func argumentList(after call: Range<String.Index>, in source: String) throws -> String? {
        let blanked = try SwiftSource.blankingCommentsAndStrings(source)
        let blankedChars = Array(blanked)
        let originalChars = Array(source)
        let lengthsMatch = blankedChars.count == originalChars.count
        let sliceChars = lengthsMatch ? originalChars : blankedChars

        let start = source.distance(from: source.startIndex, to: call.upperBound)
        guard start >= 0, start <= blankedChars.count, start <= sliceChars.count else { return nil }
        var depth = 1
        var index = start
        while index < blankedChars.count {
            switch blankedChars[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    guard index <= sliceChars.count else { return nil }
                    return String(sliceChars[start..<index])
                }
            default:
                break
            }
            index += 1
        }
        return nil
    }

    @Test func theFormHandsTheSchemaViewItsFootnoteClosure() throws {
        let source = try Self.formView()
        let call = try #require(
            source.range(of: "SchemaFormView("),
            "ConnectionFormView no longer builds a SchemaFormView — this guard's anchor is gone")
        let argumentList = try #require(
            try Self.argumentList(after: call, in: source),
            "SchemaFormView( never closes — no matching ) found, so the scan cannot bound the argument list")
        #expect(argumentList.contains("footnote:"), """
            The SchemaFormView built by ConnectionFormView carries no \
            `footnote:` argument, so the S3 endpoint field no longer says \
            what it understood — a form that silently assumes https for a \
            schemeless endpoint and shows nothing about it.
            """)
        #expect(argumentList.contains("forcedValues:"), """
            The SchemaFormView built by ConnectionFormView carries no \
            `forcedValues:` argument, so a field whose value a rule decides \
            is rendered as a control the user can still change.
            """)
    }

    /// The case a first-`)` cut would have truncated (fix round 2,
    /// 2026-09-04): a nested call inside an argument's own value. Cutting at
    /// the first `)` here would stop at `f(1, 2)`'s own close and read the
    /// list as `"a: f(1, 2"` — missing `b:` entirely and reporting it absent
    /// even though the real call carries it.
    @Test func argumentListSurvivesANestedCallInAnArgument() throws {
        let source = "SchemaFormView(a: f(1, 2), b: 3)"
        let call = try #require(source.range(of: "SchemaFormView("))
        let list = try #require(try Self.argumentList(after: call, in: source))
        #expect(list == "a: f(1, 2), b: 3")
    }

    /// The case round 2's fix left open (leak-route review, 2026-09-04): a
    /// `)` written inside a STRING LITERAL argument value. Balancing over
    /// `source` itself — as `argumentList` did before this fix — would read
    /// that `)` as the call's own close and truncate the list at
    /// `a: "value`, silently dropping `, b: 3` (and, on the real call this
    /// guards, `footnote:`/`forcedValues:` whenever either argument's value
    /// happened to carry a literal `)`). Balancing over the blanked text
    /// instead makes the literal's content — quotes included — invisible to
    /// the paren counter, so only the real, code-level `)` ends the scan.
    @Test func argumentListSurvivesAParenInsideAStringLiteralArgument() throws {
        let source = "SchemaFormView(a: \"value)\", b: 3)"
        let call = try #require(source.range(of: "SchemaFormView("))
        let list = try #require(try Self.argumentList(after: call, in: source))
        #expect(list == "a: \"value)\", b: 3")
    }

    @Test func theSchemaViewDrawsWhateverTheFootnoteReturns() throws {
        let source = try Self.schemaView()
        #expect(source.contains("footnote?("), """
            SchemaFormView declares a `footnote` but never calls it, so \
            nothing it returns reaches the screen.
            """)
    }

    /// The footnote's text is composed in Core and localized in the App.
    /// Both halves are checked, because either one alone is a different
    /// feature: a hardcoded English sentence, or a localized sentence about
    /// nothing.
    ///
    /// The Core function is `requestOrigin`, not `canonicalEndpoint` (review
    /// 2026-09-04, I-3): under virtual-hosted addressing the request goes to
    /// `<bucket>.<host>`, so a line built from the endpoint's own origin
    /// announces a destination the app does not dial.
    @Test func theFootnoteAsksCoreWhereTheRequestGoesAndSaysItLocalized() throws {
        let body = try #require(Self.footnoteBody(in: try Self.formView()),
                                "fieldFootnote is gone from ConnectionFormView")
        #expect(body.contains("S3FieldSchema.requestOrigin("))
        #expect(!body.contains("S3FieldSchema.canonicalEndpoint("), """
            fieldFootnote prints the ENDPOINT's origin. Under virtual-hosted \
            addressing the request goes to <bucket>.<host>, which is a \
            different name — print `requestOrigin` instead.
            """)
        for key in Self.footnoteKeys {
            #expect(body.contains(key))
        }
    }

    /// Every catalog key the footnote and the path-style hint name is
    /// declared in `en.lproj` — the source catalog `LocalizationParityTests`
    /// measures the other three against. Without this anchor the checks above
    /// would be satisfied by a key that renders to the user as its own raw
    /// text, in every language at once.
    @Test func everyKeyTheseLinesNameIsInTheEnglishCatalog() throws {
        let catalog = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8)
        for key in Self.footnoteKeys + [Self.pathStyleHintKey] {
            #expect(catalog.contains("\"\(key)\" = "), """
                en.lproj/Localizable.strings declares no \(key).
                """)
        }
    }

    /// I-3's other half: the toggle a user can no longer change is DISABLED,
    /// and a line says why. Both ends are checked — the form deciding it
    /// (from Core's rule, not a predicate of its own) and the renderer
    /// applying it.
    @Test func theForcedPathStyleToggleIsDisabledAndTheFormSaysWhy() throws {
        let form = try Self.formView()
        #expect(form.contains("S3FieldSchema.pathStyleIsForced("), """
            ConnectionFormView no longer asks Core whether path style is \
            forced, so either the toggle is left changeable for an IP-literal \
            endpoint or the form has grown a second copy of that rule.
            """)
        #expect(form.contains(Self.pathStyleHintKey))
        #expect(form.contains("S3Field.usePathStyle.rawValue"))

        let schema = try Self.schemaView()
        #expect(schema.contains("forcedValues[field.id]"), """
            SchemaFormView takes the forced values but never reads them for a \
            row, so a field whose value a rule decides is still editable.
            """)
        let greyed = schema.components(separatedBy: "\n")
            .filter { $0.contains(".disabled(") && $0.contains("forcedValues") }
        #expect(!greyed.isEmpty, """
            No `.disabled(` in SchemaFormView reads `forcedValues`, so a \
            forced field is drawn as an ordinary, editable control.
            """)
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

    /// A message about a connection must never carry the LOGIN. The footnote
    /// composes an origin (host, port, bucket) and a fixed sentence, so no
    /// access key or secret can reach the screen through it — and reading a
    /// credential field here is the change that would break that.
    ///
    /// The forbidden ids are S3's own CREDENTIAL SCHEMA, read off the
    /// descriptor rather than listed: a field added to that schema is covered
    /// the day it is added. Until review 2026-09-04 this check forbade every
    /// field but the endpoint, which was too wide by exactly one — the
    /// path-style toggle's own hint is drawn by this function too.
    ///
    /// Paired with the presence checks above, which prove the body is still
    /// there to scan; the value-level proof that no credential reaches the
    /// composed text is Core's
    /// `noCredentialInTheEndpointReachesTheOriginOrTheCanonicalSpelling`.
    @Test func theFootnoteReadsNoCredentialField() throws {
        let body = try #require(Self.footnoteBody(in: try Self.formView()),
                                "fieldFootnote is gone from ConnectionFormView")
        let credentialFields = BackendDescriptor.descriptor(for: .s3)
            .credentialSchema.fields.map(\.id)
        #expect(!credentialFields.isEmpty, "S3 declares no credential fields — nothing to check")
        for id in credentialFields {
            #expect(!body.contains("S3Field.\(id)"), """
                fieldFootnote reads S3Field.\(id), a credential field. The \
                line it draws is a sentence about where the connection \
                points; a login never belongs in it.
                """)
        }
    }
}
