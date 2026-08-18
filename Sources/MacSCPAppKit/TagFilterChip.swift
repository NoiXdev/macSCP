import SwiftUI

/// A single selectable capsule chip for a tag-filter row. Shared between the
/// snippet-tag filter row (`SnippetsSheet`, Terminal-Snippets Task 5) and the
/// sidebar's host-tag filter row (P3a/T6): both rows show a small set of
/// selectable pills that differ only in what feeds them (per-tag snippet
/// counts vs. a plain sorted tag list) and how many special chips bracket the
/// per-tag ones ("All" + "No Tag" vs. just "All") — the PILL ITSELF has
/// nothing tag-specific in it, so it lives once here rather than as two
/// files with the same literal body.
struct TagFilterChip: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isSelected ? DesignTokens.remoteSoft : Color.clear, in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : DesignTokens.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// The horizontal-scrolling shell both tag-filter rows sit inside (P3a/T6
/// fix round 1): `SnippetTagFilterRow` and `HostTagFilterRow` lay out
/// DIFFERENT chip sequences — different content, different count — but the
/// scaffold around that content (`ScrollView(.horizontal) { HStack(spacing:
/// 6) { … } }`) was, until this fix, written out identically in both files.
/// Only the pill (`TagFilterChip`, above) was actually shared before; this
/// closes the remaining duplication rather than leaving a comment that
/// claimed more sharing than the code had.
struct TagFilterScrollRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                content()
            }
        }
    }
}
