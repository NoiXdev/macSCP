import SwiftUI
import macSCPCore

/// A compact, reusable search bar (M18). Wraps a text field, a regex toggle,
/// and an inline error label. The host view compiles a `FileSearchPredicate`
/// from `text`/`isRegex` (via `FileSearch.compile`) and filters its own list —
/// this view is presentation only.
///
/// Written for the management sheets and reused unchanged by the session
/// sidebar (D3), which is what "reusable" was supposed to mean: the regex
/// switch and the error label are more useful over a list of connections
/// than over a sheet, and a sidebar-only search field would have been a
/// second build of this one. The count of hosts that used to stand in this
/// sentence is gone on purpose — it was written at M18 and was wrong by the
/// time anyone read it.
struct SheetSearchField: View {
    @Binding var text: String
    @Binding var isRegex: Bool
    /// Non-nil when the current regex is invalid (host passes it in).
    var errorText: String?
    /// Opt-out from the regex checkbox being held at its ideal width.
    ///
    /// **Rigid is the default, on purpose.** A compressible control reports a
    /// small minimum, so the layout guard stays green while its label is cut;
    /// a call site that forgot an opt-IN would produce exactly that, silently.
    /// Forgetting this argument is therefore safe: the checkbox is held and a
    /// bound that cannot take it goes red. The one caller that passes `true` is
    /// the session sidebar, a container the user resizes down to
    /// `SettingsStore.sidebarWidthRange`'s lower bound, where a rigid checkbox
    /// would overflow instead; migrating it is the resizable containers' own
    /// task.
    ///
    /// Counted 2026-10-18 with `grep -rn 'SheetSearchField[(]' Sources/MacSCPAppKit`
    /// (bracketed so that this comment does not match its own pattern; the
    /// declaration has no call parenthesis): nine lines, eight inside a
    /// `BoundedView` (AuditLogSheet, HiddenImportsSheet, KnownHostsSheet,
    /// LoginSetsSheet, ServerCertificatesSheet, SnippetsSheet, SSHKeysSheet,
    /// TerminalSnippetPopover) and the one in SessionSidebar.
    var isInAResizableContainer = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignTokens.inkTertiary)
            TextField(
                L10n.string("search.placeholder", "Search"), text: $text)
                .textFieldStyle(.roundedBorder)
            regexToggle
                .help(L10n.string("search.regex.help", "Match with a regular expression"))
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

extension SheetSearchField {
    @ViewBuilder
    fileprivate var regexToggle: some View {
        let label = L10n.string("search.regex", "Regex")
        if isInAResizableContainer {
            Toggle(label, isOn: $isRegex)
                .toggleStyle(.checkbox)
        } else {
            CheckboxRow(label, isOn: $isRegex)
        }
    }
}

/// Compiles a predicate for a sheet's search state. Returns the predicate to
/// filter with (matches-all on empty/whitespace) and a localized error string
/// when the regex is invalid (so nothing is silently filtered to zero rows).
func sheetSearchPredicate(text: String, isRegex: Bool) -> (FileSearch.FileSearchPredicate, String?) {
    switch FileSearch.compile(query: text, isRegex: isRegex) {
    case .success(let predicate):
        return (predicate, nil)
    case .failure:
        // Invalid regex: match everything and show an error, rather than
        // hiding all rows behind a typo. An empty query is documented to
        // always compile successfully (FileSearch.compile's contract), so
        // this fallback never actually fails.
        guard case .success(let all) = FileSearch.compile(query: "", isRegex: false) else {
            preconditionFailure("FileSearch.compile with an empty query must always succeed")
        }
        return (all, L10n.string("search.regex.invalid", "Invalid regular expression"))
    }
}
