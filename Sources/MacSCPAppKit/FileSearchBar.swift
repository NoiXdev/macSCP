import SwiftUI
import macSCPCore

/// The file-list search bar (M11k/T2): a text field bound directly to
/// `RemoteBrowserViewModel`'s M11k/T1 search state — no second search path
/// lives here, this view only reads/writes the view model's own
/// `searchQuery`/`searchIsRegex`/`searchMode` and calls its
/// `focusNextMatch()`/`focusPreviousMatch()`/`clearSearch()`.
///
/// Shown by `BrowserPane` above the file list, gated by that pane's own
/// `@State` bool — see the design doc's "pro Pane" requirement. Visually
/// restrained on purpose: a single slim row, matching the panehead's own
/// font sizes/paddings rather than introducing new ones (M5g metrics are
/// untouched — this view is a new sibling row, not a change to the header).
struct FileSearchBar: View {
    let viewModel: RemoteBrowserViewModel
    /// Bumped by `BrowserPane` every time ⌘F fires, even while the bar is
    /// ALREADY open (M11k/T2): the bar doesn't disappear/reappear in that
    /// case, so a plain `.onAppear` alone wouldn't reclaim focus for a
    /// second ⌘F press after the user clicked away from the field. Changing
    /// this value re-runs the `.onChange` below regardless of what it
    /// changes to or from.
    let focusToken: Int
    /// Esc in the field, or the close button: closes the bar. `BrowserPane`
    /// is the one that actually calls `clearSearch()`/hides the bar/returns
    /// focus to the table — this view only signals "the user wants out".
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.inkTertiary)

            TextField(
                L10n.string("search.placeholder", "Search"),
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .focused($isFieldFocused)
            // Return/Shift-Return only matter in jump mode (design §3): in
            // filter mode the visible list already IS the match set, so
            // there is no separate "jump to the next one" concept — `.ignored`
            // lets the key event fall through to AppKit's default handling
            // (a no-op for a plain `TextField` with no `onSubmit`).
            .onKeyPress(.return, phases: .down) { press in
                guard viewModel.searchMode == .jump else { return .ignored }
                if press.modifiers.contains(.shift) {
                    viewModel.focusPreviousMatch()
                } else {
                    viewModel.focusNextMatch()
                }
                return .handled
            }
            // Escape (M11k/T2 step 5): handled via `onExitCommand` rather
            // than `.onKeyPress(.escape)` — the AppKit field editor backing
            // this `TextField` already reacts to Escape itself (cancelling
            // any in-progress edit), and `onExitCommand` is the modifier
            // documented to reach the view regardless of that internal
            // handling, unlike a plain key-press hook.
            .onExitCommand(perform: onClose)

            modePicker
                .frame(width: 118)

            Toggle(isOn: Binding(
                get: { viewModel.searchIsRegex },
                set: { viewModel.searchIsRegex = $0 }
            )) {
                Text(".*")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .toggleStyle(.button)
            .help(L10n.string("search.regexHelp", "Regular expression"))

            countOrError
                .frame(minWidth: 64, alignment: .trailing)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.string("search.close", "Close search"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { isFieldFocused = true }
        .onChange(of: focusToken) { _, _ in isFieldFocused = true }
    }

    /// Filter/Jump toggle (design §3). Bound through a plain `Int` rather
    /// than `viewModel.searchMode` directly: `FileSearchMode` (Core, M11k/T1)
    /// is `Equatable` but deliberately not `Hashable` — it has no UI-facing
    /// reason to be, and `Picker`'s selection requires `Hashable` — so this
    /// is a local App-layer mapping, not a change to Core's type.
    private var modePicker: some View {
        Picker("", selection: Binding<Int>(
            get: { viewModel.searchMode == .jump ? 1 : 0 },
            set: { viewModel.searchMode = $0 == 1 ? .jump : .filter }
        )) {
            Text(L10n.string("search.mode.filter", "Filter")).tag(0)
            Text(L10n.string("search.mode.jump", "Jump")).tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The trailing readout: the match count, UNLESS the current
    /// query/regex describes an invalid regular expression, in which case a
    /// concrete red message replaces it outright (maintainer's explicit
    /// "don't fake 0 matches" rule — see `FileSearchError`'s doc comment in
    /// Core). Filter mode shows "N of M" (matches of total entries); jump
    /// mode shows just the match count — the "Treffer k/N" position-within-
    /// matches indicator named as a nice-to-have in the design doc is left
    /// out here: computing the current position would mean re-deriving the
    /// match order in this view (Core keeps `searchMatchPaths` private,
    /// on purpose, precisely so nothing outside the view model re-implements
    /// the derivation), whereas a second, independent computation is the
    /// "second search path" this task was explicitly told not to add.
    @ViewBuilder
    private var countOrError: some View {
        if viewModel.searchError == .invalidRegex {
            Text(L10n.string("search.error.invalidRegex", "Invalid regular expression"))
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if viewModel.searchMode == .jump {
            Text(
                String(
                    format: L10n.string("search.count.jump %lld", "%lld matches"),
                    viewModel.searchMatchCount)
            )
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(DesignTokens.inkSecondary)
        } else {
            Text(
                String(
                    format: L10n.string("search.count.filter %1$lld %2$lld", "%1$lld of %2$lld"),
                    viewModel.searchMatchCount, viewModel.searchTotalCount)
            )
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(DesignTokens.inkSecondary)
        }
    }
}
