import Foundation
import Testing

@testable import macSCPCore

/// The management sheets' facet quick filter, as a value
/// (`docs/superpowers/specs/2026-08-29-sheet-facetten-filter-design.md`).
///
/// Everything decidable about it is decided here rather than in three
/// `filteredRows` bodies: what a facet selection means, where the offered
/// values come from, when the picker is worth drawing at all, what a search
/// and a facet do together, and — when they leave nothing — which of the two
/// is the one to name.
///
/// The rows are a local fixture rather than any of the three real row types.
/// A facet is a `String` the sheet derives from a row, so this value never
/// sees a `ManagedKey`, a `LoginSet` or a `KnownHostKey`, and a test that
/// built one would be testing the sheet's mapping function, not this.
@Suite("Sheet facet filter")
struct SheetFacetFilterTests {
    private struct Row: Equatable {
        let name: String
        let kind: String
    }

    private static let rows = [
        Row(name: "alpha", kind: "RSA"),
        Row(name: "beta", kind: "ED25519"),
        Row(name: "gamma", kind: "ED25519"),
    ]

    private static func predicate(_ query: String, isRegex: Bool = false)
        -> FileSearch.FileSearchPredicate
    {
        guard case .success(let compiled) = FileSearch.compile(query: query, isRegex: isRegex)
        else {
            Issue.record("the fixture query \(query) must compile")
            return matchesEverything
        }
        return compiled
    }

    /// The predicate an invalid regular expression falls back to — the same
    /// one `sheetSearchPredicate` hands the sheets so a half-typed pattern
    /// hides nothing. Built through `compile` rather than hand-rolled, so it
    /// stays the fallback the App layer actually uses.
    private static var matchesEverything: FileSearch.FileSearchPredicate {
        guard case .success(let all) = FileSearch.compile(query: "", isRegex: false) else {
            preconditionFailure("an empty query must always compile")
        }
        return all
    }

    private static func narrowing(
        _ filter: SheetFacetFilter, search: String = "", isRegex: Bool = false
    ) -> SheetNarrowing<Row> {
        filter.narrowing(
            rows,
            search: predicate(search, isRegex: isRegex),
            searchText: \.name,
            facetValue: \.kind)
    }

    // MARK: - One value or "All"

    @Test func noSelectionMatchesEveryValue() {
        #expect(SheetFacetFilter.all.isEmpty)
        #expect(SheetFacetFilter.all.matches("RSA"))
        #expect(SheetFacetFilter.all.matches("ED25519"))
    }

    @Test func aSelectionMatchesOnlyItsOwnValue() {
        let filter = SheetFacetFilter(selected: "RSA")
        #expect(!filter.isEmpty)
        #expect(filter.matches("RSA"))
        #expect(!filter.matches("ED25519"))
    }

    @Test func clearingReturnsToNoSelection() {
        #expect(SheetFacetFilter(selected: "RSA").cleared() == SheetFacetFilter.all)
    }

    // MARK: - The values come from the rows

    @Test func offeredValuesAreDerivedFromTheRowsAndDeduplicated() {
        #expect(SheetFacetFilter.values(of: Self.rows, facet: \.kind) == ["ED25519", "RSA"])
    }

    @Test func aValueNoRowCarriesIsNotOffered() {
        let onlyKeys = [Row(name: "beta", kind: "ED25519")]
        #expect(SheetFacetFilter.values(of: onlyKeys, facet: \.kind) == ["ED25519"])
    }

    @Test func noRowsOfferNoValues() {
        #expect(SheetFacetFilter.values(of: [Row](), facet: \.kind).isEmpty)
    }

    // MARK: - A picker that could change nothing is not drawn

    @Test(arguments: [0, 1])
    func thePickerIsNotOfferedBelowTwoValues(count: Int) {
        #expect(!SheetFacetFilter.offersPicker(valueCount: count))
    }

    @Test func thePickerIsOfferedFromTwoValues() {
        #expect(SheetFacetFilter.offersPicker(valueCount: 2))
        #expect(SheetFacetFilter.offersPicker(valueCount: 3))
    }

    // MARK: - Search and facet chain

    @Test func aRowSurvivesOnlyWhenBothNarrowingsMatch() {
        let narrowed = Self.narrowing(SheetFacetFilter(selected: "ED25519"), search: "a")
        #expect(narrowed.visible.map(\.name) == ["beta", "gamma"])
    }

    @Test func theSearchNarrowsWithinTheFacet() {
        let narrowed = Self.narrowing(SheetFacetFilter(selected: "ED25519"), search: "gam")
        #expect(narrowed.visible.map(\.name) == ["gamma"])
    }

    @Test func theFacetAloneNarrows() {
        #expect(Self.narrowing(SheetFacetFilter(selected: "RSA")).visible.map(\.name) == ["alpha"])
    }

    @Test func theSearchAloneNarrows() {
        #expect(Self.narrowing(.all, search: "alph").visible.map(\.name) == ["alpha"])
    }

    @Test func neitherNarrowingLeavesEveryRowStanding() {
        #expect(Self.narrowing(.all).visible == Self.rows)
    }

    @Test func rowOrderIsPreserved() {
        #expect(Self.narrowing(.all, search: "a").visible.map(\.name) == ["alpha", "beta", "gamma"])
    }

    // MARK: - "Unfiltered" is about both narrowings

    @Test func nothingIsUnfilteredWhileAFacetIsSelected() {
        #expect(!Self.narrowing(SheetFacetFilter(selected: "RSA")).isUnfiltered)
    }

    @Test func nothingIsUnfilteredWhileASearchIsTyped() {
        #expect(!Self.narrowing(.all, search: "a").isUnfiltered)
    }

    @Test func withoutSearchAndFacetTheListIsUnfiltered() {
        #expect(Self.narrowing(.all).isUnfiltered)
    }

    /// A blank query compiles to the matches-everything predicate, so it
    /// narrows nothing — and a footer reading "3 of 3" over a space bar
    /// would be the sheet claiming a narrowing that is not there.
    @Test func aWhitespaceOnlySearchDoesNotCountAsANarrowing() {
        #expect(Self.narrowing(.all, search: "   ").isUnfiltered)
    }

    // MARK: - The empty state names the narrowing that emptied it

    @Test func anEmptyStoreSaysSoRatherThanBlamingAFilter() {
        let narrowed = SheetFacetFilter.all.narrowing(
            [Row](), search: Self.predicate(""), searchText: \.name, facetValue: \.kind)
        #expect(narrowed.emptiness == .noRows)
    }

    @Test func anEmptyStoreSaysSoEvenWithBothNarrowingsOn() {
        let narrowed = SheetFacetFilter(selected: "RSA").narrowing(
            [Row](), search: Self.predicate("zzz"), searchText: \.name, facetValue: \.kind)
        #expect(narrowed.emptiness == .noRows)
    }

    @Test func aSearchThatMatchesNothingIsNamedAsTheSearch() {
        #expect(Self.narrowing(.all, search: "zzz").emptiness == .searchMatchesNothing)
    }

    @Test func aFacetWithNoRowsIsNamedAsTheFacet() {
        #expect(Self.narrowing(SheetFacetFilter(selected: "ECDSA")).emptiness == .facetMatchesNothing)
    }

    @Test func bothNarrowingsTogetherAreNamedTogether() {
        let narrowed = Self.narrowing(SheetFacetFilter(selected: "RSA"), search: "beta")
        #expect(narrowed.emptiness == .neitherMatches)
    }

    @Test func aListWithRowsLeftIsNotEmptyAtAll() {
        #expect(Self.narrowing(.all).emptiness == .notEmpty)
        #expect(Self.narrowing(SheetFacetFilter(selected: "RSA")).emptiness == .notEmpty)
    }

    /// An invalid expression compiles, in every sheet, to the
    /// matches-everything predicate plus an error text
    /// (`sheetSearchPredicate`), so it filters nothing. The facet must go on
    /// narrowing underneath it, and the empty state must not blame a search
    /// that is not filtering.
    @Test func anUnfilteringSearchLeavesTheFacetAsTheOnlyNarrowing() {
        let narrowed = SheetFacetFilter(selected: "ECDSA").narrowing(
            Self.rows,
            search: Self.matchesEverything,
            searchText: \.name,
            facetValue: \.kind)
        #expect(narrowed.visible.isEmpty)
        #expect(narrowed.emptiness == .facetMatchesNothing)
    }
}
