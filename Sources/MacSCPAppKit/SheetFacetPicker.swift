import SwiftUI
import macSCPCore

/// The management sheets' facet quick filter, drawn once for all of them
/// (design: `docs/superpowers/specs/2026-08-29-sheet-facets-filter-design.md`).
///
/// The facets are DATA: the host sheet hands over the values it derived from
/// its own rows (`SheetFacetFilter.values(of:facet:)`) and keeps the mapping
/// from a row to its facet value to itself. This view knows nothing about
/// key types, backends or host-key algorithms — which is why the same view
/// stands in the keys sheet, the logins sheet and the known-hosts sheet
/// rather than each growing its own.
///
/// It sits under `SheetSearchField`, and the two chain rather than compete:
/// `SheetFacetFilter.narrowing(_:search:searchText:facetValue:)` requires
/// both to match. `SheetSearchField` itself is untouched by this — a facet
/// is not a search, and folding one into the other would have made the
/// search field carry a parameter every other surface that uses it passes
/// as empty.
///
/// Draws NOTHING below two derived values: with a single value, "All" and
/// that value select exactly the same rows, so the control could be operated
/// without anything changing. The threshold is
/// `SheetFacetFilter.offersPicker(valueCount:)`'s answer, not this view's,
/// for the same reason `SidebarTagFilterBar` asks Core which of its two
/// drawings applies.
struct SheetFacetPicker: View {
    /// The values this sheet offers, already derived, deduplicated and
    /// sorted by `SheetFacetFilter.values(of:facet:)` — this view does none
    /// of that itself.
    let values: [String]
    /// What the picker means, in the sheet's own words ("Key type",
    /// "Backend", "Algorithm") — the one thing about the facet that is
    /// sheet-specific and cannot be derived here.
    let label: String
    @Binding var filter: SheetFacetFilter

    var body: some View {
        if SheetFacetFilter.offersPicker(valueCount: values.count) {
            Picker(
                selection: Binding(
                    get: { filter.selected },
                    set: { filter = SheetFacetFilter(selected: $0) }
                )
            ) {
                Text(L10n.string("sheet.facet.all", "All")).tag(String?.none)
                ForEach(values, id: \.self) { value in
                    Text(value).tag(String?.some(value))
                }
            } label: {
                Text(label)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(label)
        }
    }
}

/// What a management sheet draws in place of its list, and the invitation
/// that goes with it.
///
/// The point of it is the middle two cases: an empty list must say WHICH
/// narrowing emptied it. "No matches." over a list a facet emptied sends the
/// user to erase a search that was never the problem — and the sheets said
/// exactly that until this view existed, because each of them decided
/// emptiness from `searchText.isEmpty` alone.
///
/// One button clears BOTH narrowings, and its label names neither: search
/// and facet can be on at once, and an invitation that cleared only one of
/// them would leave the list just as empty. That is the rule the sidebar's
/// own empty state (`SessionSidebar.emptyStateRow`) already follows, in the
/// same words.
///
/// The two messages the host supplies are the two only it can phrase: what
/// "nothing at all" means for its own contents ("No keys yet."), and what
/// its search failing to match is called. The facet cases are phrased here,
/// because "no entries of this kind" says the same thing over every sheet.
struct SheetListEmptyState: View {
    let emptiness: SheetListEmptiness
    /// What this sheet says when it holds nothing at all.
    let noRowsMessage: String
    /// What this sheet says when its search alone matched nothing.
    let noSearchMatchesMessage: String
    /// Clears the search AND the facet. Not optional: every case that draws
    /// the button reaches both narrowings, and a host that could only clear
    /// one of them is the bug this view exists to prevent.
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsShowAll {
                Button(L10n.string("sheet.empty.showAll", "Show all")) { onShowAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.remoteBlue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var message: String {
        switch emptiness {
        case .notEmpty, .noRows:
            return noRowsMessage
        case .searchMatchesNothing:
            return noSearchMatchesMessage
        case .facetMatchesNothing:
            return L10n.string("sheet.empty.noFacetMatches", "No entries of this kind.")
        case .neitherMatches:
            return L10n.string(
                "sheet.empty.noMatchesInFacet", "No entry of this kind matches the search.")
        }
    }

    /// Offered exactly when a narrowing is what emptied the list. An empty
    /// store has nothing to clear, and `.notEmpty` never reaches this view
    /// from a host that checks first — it falls in with the store-is-empty
    /// text above rather than needing a case that draws nothing.
    private var showsShowAll: Bool {
        switch emptiness {
        case .notEmpty, .noRows: return false
        case .searchMatchesNothing, .facetMatchesNothing, .neitherMatches: return true
        }
    }
}
