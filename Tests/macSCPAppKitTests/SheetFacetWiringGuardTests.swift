import Foundation
import Testing

/// The facet quick filter is wired into the sheets that are supposed to have
/// one — and the sheets decide emptiness through it rather than beside it
/// (facet design, 2026-08-29).
///
/// `SheetFacetFilterTests` already pins every decidable thing about the
/// value itself, without ever opening a sheet. A `narrowing` that is correct
/// in isolation and simply not called, a picker built from a hand-written
/// list instead of the rows, or an empty state that went back to reading the
/// search alone would leave all of those green. This suite is the wiring
/// check they cannot be — the same shape as
/// `KnownHostsSortWiringGuardTests` and `SidebarFilterWiringTests`, and for
/// the same reason: this project renders no view in a test, so the check is
/// a scan over source text.
///
/// ## What the scan reads, and what it does not
///
/// Line comments are removed before anything is matched. That is not
/// tidiness: `SheetFacetPicker.swift`'s own doc comment quotes
/// `searchText.isEmpty` while explaining why no sheet may decide emptiness
/// from it, and a raw-text scan cannot tell that sentence from the code it
/// describes. `strippedSource` is held to that by `theStripperRemovesA
/// CommentThatQuotesTheForbiddenShape` below.
///
/// String literals are NOT removed, and the checks are written so that this
/// costs nothing: none of the matched shapes (`SheetFacetPicker(`,
/// `.narrowing(`, `SheetListEmptyState(`, `searchText.isEmpty`) is something
/// a user-facing string would contain. Block comments would defeat the
/// stripper entirely, so `theScannedSheetsUseNoBlockComments` asserts there
/// are none rather than assuming it.
///
/// Known blind spots, stated rather than discovered later:
/// - The scan proves the chaining is CALLED, not that its result is what the
///   list draws. `KnownHostsSortWiringGuardTests` follows a `Table`'s first
///   argument back to its declaration and could be extended here; the two
///   other sheets build their rows inside `body`, where there is no
///   declaration to follow.
/// - `theFacetValueAndThePickerValuesComeFromOneFunction` requires the
///   mapping to be a named `Self.` function. A sheet that inlined the same
///   expression twice would fail this guard even though it behaves
///   correctly — deliberately: the shared function is the property, because
///   it is what stops the picker from offering a value no row can match.
@Suite("Sheet facet wiring")
struct SheetFacetWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SheetFacetWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSourceDirectory = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    /// The sheets the design gives a facet, spelled out — and held to being
    /// the complete list by `everySheetDrawingAFacetPickerIsListedHere`, so
    /// this cannot quietly become a list of two while a third sheet grows a
    /// facet nobody guards.
    ///
    /// `AuditLogSheet` is deliberately absent: it has its own segment filter
    /// and keeps it. `ServerCertificatesSheet` is absent because it has no
    /// facet at all — its `isUnfiltered` reads the search alone, which is
    /// correct for a sheet whose search is its only narrowing.
    static let facetedSheets = [
        "KnownHostsSheet.swift",
        "SSHKeysSheet.swift",
        "LoginSetsSheet.swift",
    ]

    private static func strippedSource(_ fileName: String) throws -> String {
        let url = appSourceDirectory.appendingPathComponent(fileName)
        return strippingLineComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// Blanks everything from a `//` to the end of its line, keeping the line
    /// breaks so the result still reads line by line.
    ///
    /// Only line comments, and only because `theScannedSheetsUseNoBlockComments`
    /// establishes that these files have no other kind. A `//` inside a
    /// string literal would blank the rest of that line too; that is a false
    /// NEGATIVE (it can only hide a match, never invent one), and no string
    /// in the scanned files contains one.
    static func strippingLineComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .map { line in
                guard let commentStart = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<commentStart.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The first `Self.<name>` written within `window` characters after
    /// `marker`. Returns `nil` when the marker is absent or nothing matches
    /// inside the window — both of which the callers turn into a failure,
    /// so a window that is too small fails loudly instead of matching
    /// nothing and reading as satisfied.
    static func mappingFunction(after marker: String, in source: String, window: Int = 200)
        -> String?
    {
        guard let markerRange = source.range(of: marker) else { return nil }
        let end = source.index(
            markerRange.upperBound, offsetBy: window, limitedBy: source.endIndex)
            ?? source.endIndex
        let region = source[markerRange.upperBound..<end]
        guard let selfRange = region.range(of: "Self.") else { return nil }
        let name = region[selfRange.upperBound...].prefix {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
        return name.isEmpty ? nil : "Self.\(name)"
    }

    // MARK: - The list of faceted sheets is the real one

    @Test func everySheetDrawingAFacetPickerIsListedHere() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.appSourceDirectory, includingPropertiesForKeys: nil)
        var drawing: Set<String> = []
        for url in contents where url.pathExtension == "swift" {
            let source = Self.strippingLineComments(
                try String(contentsOf: url, encoding: .utf8))
            // The view's own definition is not a sheet drawing it.
            guard url.lastPathComponent != "SheetFacetPicker.swift" else { continue }
            if source.contains("SheetFacetPicker(") {
                drawing.insert(url.lastPathComponent)
            }
        }
        #expect(drawing == Set(Self.facetedSheets), """
            The sheets drawing `SheetFacetPicker` are \(drawing.sorted()), but this suite \
            guards \(Self.facetedSheets.sorted()). A sheet that grew a facet without being \
            listed here is guarded by nothing; a listed sheet that lost its picker is a \
            regression.
            """)
    }

    // MARK: - Search and facet chain, in one shared call

    @Test(arguments: SheetFacetWiringGuardTests.facetedSheets)
    func theSheetChainsItsSearchAndItsFacet(fileName: String) throws {
        let source = try Self.strippedSource(fileName)
        #expect(source.contains(".narrowing("), """
            \(fileName) never calls the shared chaining \
            (`SheetFacetFilter.narrowing(_:search:searchText:facetValue:)`) — its search and \
            its facet are either not applied together or applied by a second copy of the rule.
            """)
        #expect(source.contains("SheetFacetPicker("), """
            \(fileName) does not draw the shared facet picker.
            """)
        #expect(source.contains("SheetListEmptyState("), """
            \(fileName) does not draw the shared empty state, so its empty list cannot name \
            which narrowing emptied it.
            """)
    }

    /// The negative check of this suite, and the positive one it needs
    /// beside it: `emptiness` being read is what makes "no
    /// `searchText.isEmpty`" mean "the decision moved" rather than "the
    /// spelling moved". Without it, a sheet that dropped both would pass.
    @Test(arguments: SheetFacetWiringGuardTests.facetedSheets)
    func theSheetDoesNotDecideEmptinessFromTheSearchAlone(fileName: String) throws {
        let source = try Self.strippedSource(fileName)
        #expect(source.contains("emptiness:"), """
            \(fileName) never hands an `emptiness` to its empty state — so the check below, \
            that it no longer reads `searchText.isEmpty`, would pass over a sheet that had \
            simply stopped saying anything.
            """)
        #expect(!source.contains("searchText.isEmpty"), """
            \(fileName) still decides something from `searchText.isEmpty`. With a facet in \
            play that read is false: it calls the sheet unfiltered while a facet is hiding \
            rows. Ask the narrowing (`isUnfiltered` / `emptiness`) instead.
            """)
    }

    // MARK: - The offered values are the values rows are matched on

    @Test(arguments: SheetFacetWiringGuardTests.facetedSheets)
    func theFacetValueAndThePickerValuesComeFromOneFunction(fileName: String) throws {
        let source = try Self.strippedSource(fileName)
        let matching = Self.mappingFunction(after: "facetValue:", in: source)
        let offering = Self.mappingFunction(after: "values(of:", in: source)
        #expect(matching != nil, """
            \(fileName): no `Self.<function>` follows `facetValue:` — this guard cannot see \
            which function maps a row to its facet value, and the comparison below would \
            compare nothing.
            """)
        #expect(offering != nil, """
            \(fileName): no `Self.<function>` follows `values(of:` — the picker's values are \
            not derived through a named mapping function, or not derived from the rows at all.
            """)
        #expect(matching == offering, """
            \(fileName) offers facet values from \(offering ?? "nothing") but matches rows \
            with \(matching ?? "nothing"). Two spellings of the same label is how a picker \
            comes to offer a value no row can ever match.
            """)
    }

    // MARK: - What the scan rests on

    @Test(arguments: SheetFacetWiringGuardTests.facetedSheets)
    func theScannedSheetsUseNoBlockComments(fileName: String) throws {
        let url = Self.appSourceDirectory.appendingPathComponent(fileName)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("/*"), """
            \(fileName) contains a block comment. This suite's stripper only removes `//` \
            comments, so a block comment would be read as code — and a sentence quoting \
            `searchText.isEmpty` would trip the check written to forbid the code.
            """)
    }

    @Test func theStripperRemovesACommentThatQuotesTheForbiddenShape() {
        let stripped = SheetFacetWiringGuardTests.strippingLineComments("""
            /// emptiness from `searchText.isEmpty` alone.
            let kept = narrowing.emptiness
            """)
        #expect(!stripped.contains("searchText.isEmpty"))
        #expect(stripped.contains("narrowing.emptiness"))
    }

    @Test func theStripperKeepsCodeThatPrecedesATrailingComment() {
        let stripped = SheetFacetWiringGuardTests.strippingLineComments(
            "let x = searchText.isEmpty // still code")
        #expect(stripped.contains("searchText.isEmpty"))
        #expect(!stripped.contains("still code"))
    }

    @Test func theMappingExtractorFindsNothingOutsideItsWindow() {
        let source = "facetValue: " + String(repeating: " ", count: 300) + "Self.tooFar(x)"
        #expect(SheetFacetWiringGuardTests.mappingFunction(after: "facetValue:", in: source) == nil)
        #expect(
            SheetFacetWiringGuardTests.mappingFunction(
                after: "facetValue:", in: "facetValue: { Self.label($0) }") == "Self.label")
    }
}
