import SwiftUI
import macSCPCore

/// The sidebar's tag filter, in whichever of its two drawings applies (E2).
///
/// One value underneath both: `SidebarTagFilter` — a set of tags plus a join.
/// The chip row and the dialog select into that same value, which is why
/// crossing the threshold in either direction carries the whole selection
/// over untouched; there is nothing here that translates "the one tag from
/// the row" into "the several from the dialog", because the row never held a
/// single tag to begin with.
///
/// WHICH drawing applies is `SidebarTagFilter.presentation(availableTagCount:)`'s
/// answer, not this view's: the threshold is a number the design says no test
/// can place correctly, so it lives once in Core where moving it is a
/// one-line decision rather than a literal edited inside a SwiftUI body.
struct SidebarTagFilterBar: View {
    /// Every tag any saved session carries, already deduplicated and sorted
    /// by `SidebarVisibility.availableTags` — this view does neither itself.
    let tags: [String]
    @Binding var filter: SidebarTagFilter

    var body: some View {
        switch SidebarTagFilter.presentation(availableTagCount: tags.count) {
        case .bar:
            HostTagFilterRow(tags: tags, filter: $filter)
        case .dialog:
            HostTagFilterDialogButton(tags: tags, filter: $filter)
        }
    }
}

/// The sidebar's host-tag filter row (P3a/T6, extended for E2): "All" plus
/// one chip per available tag. Tapping a tag chip selects it, tapping it
/// again deselects it — several can stand selected at once, and "All" clears
/// them in one gesture.
///
/// Deliberately simpler than `SnippetTagFilterRow`: no per-tag counts (a host
/// tag's purpose is to narrow a short list by eye, not to report how many
/// sessions carry it) and no "No Tag" chip (`SidebarVisibility.compute` has
/// no untagged-only mode — a host tag filter is either a set of tags or no
/// filter, never "sessions with zero tags"). Both the pill
/// (`TagFilterChip`) and the horizontal-scroll shell around it
/// (`TagFilterScrollRow`) are shared with `SnippetTagFilterRow`; only the
/// chip SEQUENCE inside differs between the two rows.
private struct HostTagFilterRow: View {
    let tags: [String]
    @Binding var filter: SidebarTagFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TagFilterScrollRow {
                TagFilterChip(
                    title: L10n.string("sidebar.filter.all", "All"),
                    isSelected: filter.isEmpty,
                    onSelect: { filter = filter.cleared() })
                ForEach(tags, id: \.self) { tag in
                    TagFilterChip(
                        title: tag,
                        isSelected: filter.contains(tag),
                        onSelect: { filter = filter.toggling(tag) })
                }
            }
            if filter.showsJoinChoice {
                TagFilterJoinPicker(filter: $filter)
            }
        }
    }
}

/// What the row becomes once there are more tags than it can show (E2): one
/// button carrying how many of them are selected, opening the dialog.
///
/// The count is what makes the collapsed state honest — a button that only
/// said "Filter by tag" would look identical whether it was narrowing the
/// list or not, and a sidebar filtering invisibly is the exact thing E1's
/// clear-on-switch-off rule exists to prevent elsewhere.
private struct HostTagFilterDialogButton: View {
    let tags: [String]
    @Binding var filter: SidebarTagFilter
    @State private var isShowingDialog = false

    var body: some View {
        TagFilterChip(
            title: title,
            isSelected: !filter.isEmpty,
            onSelect: { isShowingDialog = true })
            .sheet(isPresented: $isShowingDialog) {
                TagFilterSheet(tags: tags, filter: $filter)
            }
    }

    private var title: String {
        guard !filter.isEmpty else {
            return L10n.string("sidebar.filter.button", "Filter by tag")
        }
        return String(
            format: L10n.string("sidebar.filter.button.selected %lld", "Tags (%lld)"),
            filter.tags.count)
    }
}

/// The filter dialog: every available tag as a checkbox, over the same value
/// the chip row writes.
///
/// Roomier, not different — the join sits here under the same rule it does in
/// the row (`showsJoinChoice`), and "Show all" clears the same way the
/// sidebar's own empty state does.
private struct TagFilterSheet: View {
    let tags: [String]
    @Binding var filter: SidebarTagFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("sidebar.filter.button", "Filter by tag"))
                .font(.headline)

            if filter.showsJoinChoice {
                TagFilterJoinPicker(filter: $filter)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(
                            get: { filter.contains(tag) },
                            set: { _ in filter = filter.toggling(tag) }
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(L10n.string("sidebar.empty.clearFilter", "Show all")) {
                    filter = filter.cleared()
                }
                .disabled(filter.isEmpty)
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300, height: 360)
    }
}

/// "All" vs "any" for the selected tags — drawn only while the choice means
/// something, which is `SidebarTagFilter.showsJoinChoice`'s answer and not
/// this view's: below two selected tags the two positions pick out exactly
/// the same sessions, and a switch that can be flipped without anything
/// changing is worse than no switch.
///
/// Both surfaces that offer the choice draw THIS view, so the row and the
/// dialog cannot come to disagree about when it appears or what its two
/// positions are called.
private struct TagFilterJoinPicker: View {
    @Binding var filter: SidebarTagFilter

    var body: some View {
        Picker(
            selection: Binding(
                get: { filter.join },
                set: { filter = filter.joined($0) }
            )
        ) {
            Text(L10n.string("sidebar.filter.join.all", "All tags"))
                .tag(SidebarTagFilter.Join.all)
            Text(L10n.string("sidebar.filter.join.any", "Any tag"))
                .tag(SidebarTagFilter.Join.any)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(L10n.string(
            "sidebar.filter.join.help",
            "Whether a connection must carry all selected tags or just one of them."))
    }
}
