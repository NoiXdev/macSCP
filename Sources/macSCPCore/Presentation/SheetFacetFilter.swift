import Foundation

/// The management sheets' facet quick filter: one value, or none at all
/// (design: `docs/superpowers/specs/2026-08-29-sheet-facets-filter-design.md`).
///
/// A facet is a small, closed dimension whose values exclude one another —
/// a key has ONE type, a login has ONE backend, a host key ONE algorithm —
/// so there is no set and no join here, deliberately unlike
/// `SidebarTagFilter`, whose tags are open-ended and stack. "All" is the
/// ABSENCE of a selection rather than a value of its own: a facet value
/// meaning "any" would have to be produced by every sheet's mapping
/// function, which would then be returning something no row carries.
///
/// The facet value is a `String` the sheet derives from a row — the very
/// text its badge draws — so this type never learns what a key type or a
/// backend is. That also means two rows whose badges read the same land in
/// the same facet, which is what makes a 2048-bit and a 4096-bit RSA key
/// one "RSA" without anyone writing that rule down.
public struct SheetFacetFilter: Equatable, Sendable {
    /// The chosen facet value, or `nil` for "All".
    public let selected: String?

    public init(selected: String? = nil) {
        self.selected = selected
    }

    /// No facet selected — every row passes.
    public static let all = SheetFacetFilter()

    /// Nothing is being narrowed by the facet.
    public var isEmpty: Bool { selected == nil }

    /// Back to "All".
    public func cleared() -> SheetFacetFilter { .all }

    /// Whether a row carrying `value` passes the facet. Comparison is exact:
    /// the value comes from the same function on both sides, so a case or
    /// spelling difference here would mean the sheet contradicting itself.
    public func matches(_ value: String) -> Bool {
        guard let selected else { return true }
        return selected == value
    }

    /// The facet values a sheet can offer, read off its own rows rather than
    /// enumerated: a value nobody has never appears, and a new one appears
    /// the moment a row carries it, with no list to maintain.
    ///
    /// Deduplicated and sorted, so the picker's order does not depend on the
    /// order rows happened to load in.
    public static func values<Row>(of rows: [Row], facet: (Row) -> String) -> [String] {
        var seen = Set<String>()
        for row in rows {
            seen.insert(facet(row))
        }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// From how many distinct values a facet picker is worth drawing.
    ///
    /// Two, because with one value every position of the control selects the
    /// same rows: "All" and that one value are the same answer. This
    /// project shows only what is possible, and a control that can be
    /// operated and changes nothing is worse than no control.
    public static let pickerMinimumValues = 2

    /// Whether the picker is offered at all for `valueCount` derived values.
    public static func offersPicker(valueCount: Int) -> Bool {
        valueCount >= pickerMinimumValues
    }

    /// Applies the search and this facet TOGETHER to `rows`: a row survives
    /// when the search matches it and the facet matches it. Typing after
    /// choosing a facet therefore searches inside what the facet left, the
    /// same rule the session sidebar follows.
    ///
    /// Written once and called by every management sheet that has a facet,
    /// rather than as a line inside each sheet's own row filter — which is
    /// the only reason the answers below (what survived, whether anything is
    /// being narrowed, and which narrowing emptied the list) cannot come to
    /// disagree with one another.
    public func narrowing<Row>(
        _ rows: [Row],
        search: FileSearch.FileSearchPredicate,
        searchText: (Row) -> String,
        facetValue: (Row) -> String
    ) -> SheetNarrowing<Row> {
        let visible = rows.filter { search.matches(searchText($0)) && matches(facetValue($0)) }
        return SheetNarrowing(
            visible: visible,
            searchNarrows: !search.isEmpty,
            facetNarrows: !isEmpty,
            hasRows: !rows.isEmpty)
    }
}

/// What one sheet's search and facet, applied together, leave standing — and
/// what the sheet may say about it.
///
/// A value rather than three computed properties in a view, because the
/// three questions are answers to the same filtering pass: a sheet that
/// derived "is anything filtered?" separately from "what survived?" is
/// exactly how `KnownHostsSheet` came to call itself unfiltered while a
/// facet was hiding rows.
public struct SheetNarrowing<Row> {
    /// The rows to draw, in the order they arrived.
    public let visible: [Row]
    /// Whether the search is filtering anything out. False for an empty,
    /// whitespace-only, or invalid query — all three compile to the
    /// matches-everything predicate, and a footer or an empty state that
    /// called those a narrowing would be blaming a filter that is not there.
    public let searchNarrows: Bool
    /// Whether a facet value is selected.
    public let facetNarrows: Bool
    /// Whether the sheet holds any rows at all, before either narrowing.
    public let hasRows: Bool

    public init(visible: [Row], searchNarrows: Bool, facetNarrows: Bool, hasRows: Bool) {
        self.visible = visible
        self.searchNarrows = searchNarrows
        self.facetNarrows = facetNarrows
        self.hasRows = hasRows
    }

    /// Neither narrowing is doing anything — what a footer must ask before
    /// it prints a plain total instead of an "N of M".
    public var isUnfiltered: Bool { !searchNarrows && !facetNarrows }

    /// Why the list is empty, or that it is not.
    public var emptiness: SheetListEmptiness {
        guard visible.isEmpty else { return .notEmpty }
        guard hasRows else { return .noRows }
        switch (searchNarrows, facetNarrows) {
        case (true, true): return .neitherMatches
        case (true, false): return .searchMatchesNothing
        case (false, true): return .facetMatchesNothing
        // Rows exist, nothing is narrowing, and yet none survived: the
        // filter above cannot produce this. Reported as "no rows" rather
        // than blaming a narrowing that is switched off — the one reading
        // that stays true if this ever becomes reachable.
        case (false, false): return .noRows
        }
    }
}

/// The reason a management sheet's list is empty, or that it is not. The
/// empty state names it, because "No matches." over a list emptied by a
/// facet sends the user to erase a search that was never the problem.
///
/// Deliberately NOT nested inside `SheetNarrowing`: nested, the case a
/// known-host narrowing produces and the case a key narrowing produces
/// would be two types, and the one view that draws the empty state would
/// have to be generic over a row type it never reads.
public enum SheetListEmptiness: Equatable, Sendable {
    /// Rows survived; there is a list to draw.
    case notEmpty
    /// The sheet holds nothing — no narrowing is to blame.
    case noRows
    /// The search matched nothing, with no facet selected.
    case searchMatchesNothing
    /// No row carries the selected facet value, with no search typed.
    case facetMatchesNothing
    /// Both narrowings are on and nothing survives both.
    case neitherMatches
}
