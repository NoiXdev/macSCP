import SwiftUI
import macSCPCore

/// Sessions-menu / background-menu title (M11f/T2): plain title when
/// nothing is hidden, count-suffixed otherwise — needed so the way back
/// stays discoverable once the IMPORTED sidebar section itself is empty
/// (every imported entry hidden). Shared by `MacSCPApp`'s "Sessions" menu
/// and `SessionSidebar`'s background context menu so both entries read
/// identically.
func hiddenImportsMenuTitle(count: Int) -> String {
    guard count > 0 else {
        return L10n.string("menu.hiddenImports", "Hidden Imports…")
    }
    return String(
        format: L10n.string("menu.hiddenImports %@", "Hidden Imports (%@)…"),
        "\(count)")
}

/// One row of `HiddenImportsSheet`: either a still-in-config hidden host, or
/// an orphaned alias whose host entry disappeared from `~/.ssh/config`
/// (renamed or removed) after it was hidden. `alias` alone is a stable id —
/// `ImportedHostPartition.split` guarantees no alias appears in both
/// `hidden` and `orphaned` at once, but `split` alone would happily return
/// duplicate `hidden` entries for a `Host` block repeated in the config
/// file; no-duplicates-within-`hidden` is actually guaranteed upstream by
/// `SSHConfigImporter.load`'s dedupe (`SSHConfigParser.swift`'s "first block
/// wins" filter), which the `hosts` passed in here always went through.
private struct HiddenImportRow: Identifiable {
    let alias: String
    let isOrphaned: Bool
    var id: String { alias }
}

/// Hidden-imports management sheet (M11f/T2, brief section "Sheet"): lists
/// every alias the user hid from the IMPORTED sidebar section, split into
/// still-in-config hosts ("Show Again") and orphaned aliases whose host
/// entry is gone ("Remove from List") — both routes call
/// `HiddenImportStore.unhide`, the only difference is the label and the
/// secondary "no longer in ~/.ssh/config" caption. Shape mirrors
/// `KnownHostsSheet`/`LoginSetsSheet` (title + list + caption footer +
/// `.polishedProminent` Close) for consistency across the app's management
/// sheets.
struct HiddenImportsSheet: View {
    let store: HiddenImportStore
    /// The full, unfiltered `~/.ssh/config` parse — the SAME inventory
    /// `ContentView.refreshImportedHosts()` re-splits, so this sheet's
    /// hidden/orphaned split always matches what the sidebar would show.
    let hosts: [SSHConfigHost]
    /// Called after every successful `unhide` (M11f/T2) — tells
    /// `ContentView` to recompute `importedHosts`/`hiddenImportAliases`, so
    /// the sidebar's IMPORTED section and the Sessions-menu count stay live
    /// while this sheet is still open.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [HiddenImportRow] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("hiddenImports.title", "Hidden Imports")).font(.headline)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            // Only claim "nothing hidden" when the list is GENUINELY empty
            // (same rule as `KnownHostsSheet.load()`'s review finding): after
            // a load error the empty list must not suggest there is nothing
            // hidden — the red message above is the truth.
            if rows.isEmpty && errorMessage == nil {
                Spacer(minLength: 0)
                Text(L10n.string(
                    "hiddenImports.empty",
                    "Right-click an imported connection in the sidebar and choose “Hide” to have it show up here."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                List(rows) { row in
                    rowView(row)
                }
            }

            HStack {
                // Same rule as the empty-state check above: after a load
                // error, `rows` is `[]` but that is NOT "0 hidden" — it's
                // "we don't know" — so the count is suppressed right next to
                // the red error text instead of contradicting it.
                if errorMessage == nil {
                    Text(String(
                        format: L10n.string("hiddenImports.count %lld", "%lld hidden"),
                        rows.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { load() }
    }

    @ViewBuilder
    private func rowView(_ row: HiddenImportRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.alias)
                if row.isOrphaned {
                    Text(L10n.string("hiddenImports.orphaned", "no longer in ~/.ssh/config"))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.inkSecondary)
                }
            }
            Spacer()
            Button(row.isOrphaned
                ? L10n.string("hiddenImports.removeFromList", "Remove from List")
                : L10n.string("hiddenImports.unhide", "Show Again")) {
                unhide(row.alias)
            }
            .buttonStyle(.polished)
        }
        .padding(.vertical, 2)
    }

    /// Hidden rows first (input order, matching `importedHosts`/`visible`),
    /// then orphaned aliases (already alphabetically sorted by `split`).
    private func load() {
        do {
            let aliases = try store.allHidden()
            let result = ImportedHostPartition.split(hosts: hosts, hiddenAliases: aliases)
            rows = result.hidden.map { HiddenImportRow(alias: $0.alias, isOrphaned: false) }
                + result.orphaned.map { HiddenImportRow(alias: $0, isOrphaned: true) }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = String(
                format: L10n.string("hiddenImports.loadError %@", "Could not load hidden imports: %@"),
                String(describing: error))
        }
    }

    /// Both "Show Again" (still-in-config) and "Remove from List" (orphaned)
    /// call this — `unhide` is the same store operation either way, the
    /// button's label is the only thing that differs (brief). The error is
    /// captured SEPARATELY and re-applied AFTER the reload (pattern:
    /// `KnownHostsSheet.removeSelected`): `load()` clears `errorMessage` on
    /// its own success path, and reading usually still works even when the
    /// write just failed — without this, a failed "show again" would
    /// silently leave the row in place with zero feedback. `load()`/
    /// `onChange()` always run so the sheet and the sidebar stay consistent
    /// with whatever is ACTUALLY on disk, whether or not the write above
    /// succeeded.
    private func unhide(_ alias: String) {
        var unhideError: String?
        do {
            try store.unhide(alias)
        } catch {
            unhideError = String(
                format: L10n.string("hiddenImports.unhideError %@", "Could not restore the import: %@"),
                String(describing: error))
        }
        load()
        onChange()
        if let unhideError {
            errorMessage = unhideError
        }
    }
}
