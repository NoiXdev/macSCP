import SwiftUI
import macSCPCore

/// One row of `SnippetTagField`'s suggestion list while a query is typed:
/// an already-existing tag (with how many snippets carry it) or the
/// "create new tag" row for whatever is currently typed.
enum SnippetTagFieldRow: Equatable {
    case existing(tag: String, count: Int)
    case createNew(tag: String)

    /// The tag text this row adds when chosen — the stored tag verbatim for
    /// `.existing` (see `SnippetTagSuggestions`'s doc comment on why it is
    /// never re-cased) or the already-trimmed typed text for `.createNew`.
    var tag: String {
        switch self {
        case .existing(let tag, _): return tag
        case .createNew(let tag): return tag
        }
    }
}

/// Builds the row list `SnippetTagField` shows under its text field: the
/// caller-supplied suggestions (already prefix-filtered and excluding
/// already-chosen tags — see `SnippetTagSuggestions.matching`), followed by
/// a "create new tag" row for the typed text run through `TagList.
/// normalized` (trimmed, dropped if that leaves it empty) whenever that
/// leaves something non-empty. Routed through the one-element array form of
/// the shared rule rather than trimming inline, so this row's tag can never
/// silently disagree with what `TagList` — and, downstream, `Snippet.
/// init?` — would keep or drop for the same string.
///
/// The create-new row is appended UNCONDITIONALLY whenever there is
/// non-empty typed text — even if that text happens to exactly match a
/// suggestion already in the list. Hiding it in that case would make the
/// row's presence depend on what already exists, which is exactly the kind
/// of second, silent decision this type exists to avoid; a resulting
/// duplicate add is instead a no-op at commit time (`SnippetTagCommit.
/// appending`), not something this function guards against.
enum SnippetTagFieldSuggestions {
    static func rows(
        typed: String,
        suggestions: [(tag: String, count: Int)]
    ) -> [SnippetTagFieldRow] {
        var rows = suggestions.map { SnippetTagFieldRow.existing(tag: $0.tag, count: $0.count) }
        if let trimmed = TagList.normalized([typed]).first {
            rows.append(.createNew(tag: trimmed))
        }
        return rows
    }
}

/// The three ways `tags` changes in `SnippetTagField`: committing one
/// candidate string (Return on the marked row, comma on the typed text, a
/// suggestion click), removing a specific chip (its own remove button), and
/// removing the last chip (Backspace in an empty field). Pure array
/// operations — no view, no I/O — so all three are unit-tested directly
/// rather than only exercised through a view nothing in this repo can render
/// (see `SnippetsSheet`'s doc comment on that boundary).
enum SnippetTagCommit {
    /// `tags` with `candidate` appended, UNLESS `candidate` is already
    /// present — compared exactly (case-sensitive), the same rule `Snippet`
    /// itself uses to drop duplicates (see its doc comment): re-adding an
    /// already-chosen tag is a no-op, not a second chip.
    static func appending(_ candidate: String, to tags: [String]) -> [String] {
        guard !tags.contains(candidate) else { return tags }
        return tags + [candidate]
    }

    /// `tags` with the first occurrence of `tag` removed — a no-op if `tag`
    /// isn't present. Used by a chip's own remove button, which names the
    /// exact tag to drop rather than always the last one.
    static func removing(_ tag: String, from tags: [String]) -> [String] {
        guard let index = tags.firstIndex(of: tag) else { return tags }
        var result = tags
        result.remove(at: index)
        return result
    }

    /// `tags` with its last element dropped — a no-op on an already-empty
    /// list, so a stray Backspace in an empty field with no chips left
    /// cannot underflow anything.
    static func removingLast(from tags: [String]) -> [String] {
        guard !tags.isEmpty else { return tags }
        return Array(tags.dropLast())
    }
}

/// The row-highlight clamp `SnippetTagField` needs on every keystroke: rows
/// are recomputed from the current query on every keystroke (see
/// `SnippetTagField.rows`), so a `highlightedIndex` left over from a longer,
/// earlier row list would otherwise point past the end of a list that typing
/// just narrowed — `rows[highlighted]` (Return's commit path) would be an
/// out-of-bounds crash, not a wrong string, which is why this is pulled out
/// and pinned rather than left as an inline `min()` nothing exercises.
enum SnippetTagFieldHighlight {
    /// `index` pulled back into `0..<rowCount`, or `nil` when `rowCount` is
    /// `0` (nothing to highlight — `SnippetTagField` never calls
    /// `rows[highlighted]` in that case, since Return's handler already
    /// guards on `highlighted != nil`). Clamped on BOTH ends: `min` pulls an
    /// index past the end back to the last row (the case every caller today
    /// actually hits — `highlightedIndex` only grows via `CandidateCycle`,
    /// which never returns a value outside `0..<rowCount` for a non-empty
    /// list), `max` guards a negative index no current caller passes but
    /// that a future one could, without which it would pass through
    /// unclamped and put `rows[highlighted]` out of bounds the same way an
    /// over-long index would.
    static func clamped(_ index: Int, rowCount: Int) -> Int? {
        guard rowCount > 0 else { return nil }
        return max(0, min(index, rowCount - 1))
    }
}

/// Splits typed text on commas: everything before each comma becomes a
/// committed tag, run through `TagList.normalized` (trimmed, empty segments
/// dropped — a bare "," or ",," commits nothing, and an in-batch duplicate
/// like "a,a," commits once), and the text after the LAST comma is what
/// stays in the field, still being typed. Pure text processing, split out
/// so pasting "a,b,c" and typing one comma at a time are provably the same
/// operation applied more than once, rather than two behaviors that only
/// happen to look alike.
enum SnippetTagFieldInput {
    static func commaSplit(_ text: String) -> (tagsToCommit: [String], remaining: String) {
        guard text.contains(",") else { return ([], text) }
        var parts = text.components(separatedBy: ",")
        let remaining = parts.removeLast()
        return (TagList.normalized(parts), remaining)
    }
}

/// Token field for a snippet's tags (Terminal-Snippets, Task 5): the chosen
/// tags as removable chips, and a text field that offers existing tags while
/// typing plus an always-present "create new" row for whatever's typed.
///
/// `suggestions` is handed in rather than built here — the same "closure in,
/// no store owned by the view" seam `SessionSecretPolicy` made testable
/// elsewhere in this app: the caller builds it from
/// `SnippetTagSuggestions.matching(_:in:excluding:)`, so this view never
/// reads a `SnippetStore` or a snippet list itself, and every actual
/// decision (which rows show, what Return/comma/Backspace do) lives in the
/// free functions above instead of inline in view code — this view is
/// wiring, not logic.
///
/// Return commits the highlighted row; comma commits the typed text outright
/// (splitting on every comma, so a paste like "a,b,c" commits all three);
/// Backspace in an empty field removes the last chip; a chip's own button
/// removes exactly that chip.
///
/// Reused verbatim by `ConnectionFormView`'s host-tag field (P3a/T5 fix
/// round 1) — `tags`/`suggestions` were already generic over any tag
/// vocabulary; only `placeholder` needed pulling out of the hardcoded
/// `"snippets.tags.placeholder"` lookup so a second caller with its own
/// wording (and its own catalog key) does not inherit the snippets copy.
/// Host tags and snippet tags stay independent VOCABULARIES either way
/// (`TagList`'s own doc comment) — this is one INPUT WIDGET serving two
/// unrelated `suggestions` closures, never one closure's data reaching the
/// other's field.
struct SnippetTagField: View {
    @Binding var tags: [String]
    let suggestions: (String) -> [(tag: String, count: Int)]
    var placeholder: String = L10n.string("snippets.tags.placeholder", "Add a tag…")

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool

    private var rows: [SnippetTagFieldRow] {
        SnippetTagFieldSuggestions.rows(typed: query, suggestions: suggestions(query))
    }

    /// `highlightedIndex` clamped to the current row list — see
    /// `SnippetTagFieldHighlight.clamped(_:rowCount:)` for why this can't
    /// just be `highlightedIndex` itself.
    private var highlighted: Int? {
        SnippetTagFieldHighlight.clamped(highlightedIndex, rowCount: rows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        SnippetTagChip(tag: tag, onRemove: { tags = SnippetTagCommit.removing(tag, from: tags) })
                    }
                }
            }
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onChange(of: query) { _, newValue in
                    let split = SnippetTagFieldInput.commaSplit(newValue)
                    for tag in split.tagsToCommit {
                        tags = SnippetTagCommit.appending(tag, to: tags)
                    }
                    query = split.remaining
                    highlightedIndex = 0
                }
                .onKeyPress(.return, phases: .down) { _ in
                    guard let highlighted else { return .ignored }
                    commit(rows[highlighted].tag)
                    return .handled
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    guard !rows.isEmpty else { return .ignored }
                    highlightedIndex = CandidateCycle.previous(from: highlighted, count: rows.count) ?? 0
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    guard !rows.isEmpty else { return .ignored }
                    highlightedIndex = CandidateCycle.next(from: highlighted, count: rows.count) ?? 0
                    return .handled
                }
                .onKeyPress(.delete, phases: .down) { _ in
                    guard query.isEmpty else { return .ignored }
                    tags = SnippetTagCommit.removingLast(from: tags)
                    return .handled
                }
            if isFieldFocused, !rows.isEmpty {
                suggestionsList
            }
        }
    }

    private func commit(_ tag: String) {
        tags = SnippetTagCommit.appending(tag, to: tags)
        query = ""
        highlightedIndex = 0
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                SnippetTagSuggestionRow(row: row, isHighlighted: index == highlighted) {
                    commit(row.tag)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.hairline, lineWidth: 1)
        )
    }
}

/// One chosen tag, as a removable capsule.
private struct SnippetTagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag).font(.system(size: 11.5))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help(String(format: L10n.string("snippets.tags.remove %@", "Remove “%@”"), tag))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(DesignTokens.remoteSoft, in: Capsule())
    }
}

/// One row of the suggestion list: an existing tag with its count, or the
/// "create new" row — click commits it the same way Return on the
/// highlighted row does.
private struct SnippetTagSuggestionRow: View {
    let row: SnippetTagFieldRow
    let isHighlighted: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            label
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isHighlighted ? DesignTokens.remoteSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var label: some View {
        switch row {
        case .existing(let tag, let count):
            Text(
                String(
                    format: L10n.string("snippets.filter.tagCount %1$@ %2$lld", "%1$@ (%2$lld)"),
                    tag, count)
            )
            .font(.system(size: 11.5))
        case .createNew(let tag):
            Text(String(format: L10n.string("snippets.tags.createNew %@", "Create “%@”"), tag))
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.inkSecondary)
        }
    }
}

/// Wraps its subviews left-to-right, moving to a new row when the current
/// one would overflow the proposed width — the tag chips' flow layout. Pure
/// geometry (no `@State`), used only here; `MacSCPAppKit` has no other
/// flow-wrap need yet, so this stays private next to its one caller rather
/// than becoming a shared utility.
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, origin.x - spacing)
        }
        return CGSize(width: maxX, height: origin.y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var origin = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: .unspecified)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
