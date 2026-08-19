import SwiftUI
import macSCPCore

/// Pure, testable projection from `SnippetMenuModel` to what `SnippetMenuItems`
/// draws (Terminal-Snippets milestone, Task 6): the same tag grouping, plus
/// two decisions no pixel harness can see — whether an entry is disabled,
/// and which entry (if any) carries the ⌃⌘n INSERT shortcut. Kept apart from
/// the `View` below precisely so those decisions live in a shape
/// `Tests/macSCPAppKitTests/` can assert against directly.
enum SnippetMenuPlan {
    struct Entry: Identifiable, Equatable {
        let snippet: Snippet
        let isDisabled: Bool
        /// 1-based ⌃⌘n digit for this entry's INSERT action, or `nil`. EXECUTE
        /// never gets one — see `MacSCPApp.swift`'s `snippetMenuItems` doc
        /// comment for why that is not negotiable (a keystroke that fires a
        /// command on a remote host the instant it is pressed has no good
        /// failure mode). Enforced structurally here — this struct has no
        /// field an execute shortcut could travel through — and guarded
        /// against a hand-written regression by
        /// `SnippetMenuItemsKeyboardShortcutGuardTests`.
        let insertShortcutDigit: Int?
        var id: Snippet.ID { snippet.id }
    }

    struct Group: Identifiable, Equatable {
        let tag: String?
        let entries: [Entry]
        var id: String { tag ?? "" }
    }

    /// How many snippets, in STORE order, get a shortcut. Mirrored by the
    /// "Snippets" group in `KeyboardShortcutsCatalog`, which spells the
    /// range out as ⌃⌘1–3.
    static let shortcutedCount = 3

    /// Projects `model.groups` into render-ready groups.
    ///
    /// `shortcutOrder` is deliberately the caller's STORE order, not
    /// `model.groups`' own tag-sorted order: the shortcut promise ("the
    /// first three snippets in store order") is about the store, and tag
    /// sorting would silently move which three snippets qualify whenever a
    /// tag happened to sort earlier. Pass `[]` (the default at the call
    /// site) to opt out of shortcuts entirely — every other trigger surface
    /// that renders this model does, since a keyboard shortcut only means
    /// anything wired into a `.commands` menu-bar item.
    ///
    /// A snippet carrying two tags appears in TWO groups (`SnippetMenuModel`
    /// duplicates it by design); it still receives the shortcut on only its
    /// FIRST occurrence here; the second copy gets `nil`, so the same key
    /// equivalent is never registered twice in one `NSMenu`.
    static func build(model: SnippetMenuModel, shortcutOrder: [Snippet]) -> [Group] {
        var digitByID: [Snippet.ID: Int] = [:]
        for (index, snippet) in shortcutOrder.prefix(shortcutedCount).enumerated() {
            digitByID[snippet.id] = index + 1
        }

        var assigned = Set<Snippet.ID>()
        return model.groups.map { group in
            Group(
                tag: group.tag,
                entries: group.snippets.map { snippet in
                    var digit: Int?
                    if let candidate = digitByID[snippet.id], !assigned.contains(snippet.id) {
                        digit = candidate
                        assigned.insert(snippet.id)
                    }
                    return Entry(
                        snippet: snippet, isDisabled: model.disabledReason != nil,
                        insertShortcutDigit: digit)
                })
        }
    }
}

/// The one shared rendering of a `SnippetMenuModel` (Terminal-Snippets
/// milestone, Task 6): a submenu per tag group (untagged entries render
/// directly, with no wrapping submenu), and — per snippet — TWO actions,
/// "Insert" and "Execute", both always offered. There is no per-snippet flag
/// deciding which one a snippet gets; the decision belongs at the trigger
/// (see `SnippetSendPlanner`'s doc comment), so both are
/// always present and `action`'s second parameter carries which one fired.
///
/// This is the SAME view the Terminal menu (Task 6), a session's context
/// menu (Task 7), the terminal panel's header popover (Task 8), and the
/// terminal's right-click menu (Task 9) all instantiate — the whole reason
/// `SnippetMenuModel` exists in Core is so those four surfaces read one
/// computed shape instead of four hand-guessed ones; this view is the other
/// half of that promise, the one place their entries are drawn.
///
/// Partly tested. The decision this view renders — which entry is disabled,
/// which carries the ⌃⌘n shortcut — lives in `SnippetMenuPlan` above and is
/// asserted directly. The BODY was untestable until Task 9: the pixel
/// harness only sees pure SwiftUI, never AppKit-backed menu content (the
/// same boundary `SnippetsSheet`'s doc comment documents). Task 9's
/// `NSHostingMenu` route turns this body into a real `NSMenu` in-process, so
/// `TerminalContextMenuTests` now asserts the rendered structure (a submenu
/// per tag, Insert/Execute per snippet, which flag each one passes) for the
/// no-shortcut configuration the right-click menu uses. Still unasserted:
/// how the ⌃⌘n key equivalent behaves once attached, and anything about
/// on-screen drawing.
struct SnippetMenuItems: View {
    let model: SnippetMenuModel
    /// Snippets in STORE order — see `SnippetMenuPlan.build`'s doc comment
    /// for why this must not be `model`'s own tag-sorted order. Defaults to
    /// `[]`: only the Terminal menu (Task 6) passes the real store order.
    var shortcutOrder: [Snippet] = []
    /// Whether to draw a separator ABOVE the entries. It separates them from
    /// whatever the host surface already put there — the Terminal menu's own
    /// items, a session row's other context-menu entries, the header
    /// popover's search field — so it defaults to `true`. Pass `false` where
    /// these entries are the ENTIRE menu (the terminal's right-click menu,
    /// Task 9): a separator with nothing above it is a stray line at the top
    /// of the popup, measured as a real leading `NSMenuItem.isSeparatorItem`
    /// in `TerminalContextMenuTests`, not a guess about how AppKit draws it.
    var leadingDivider: Bool = true
    let action: (Snippet, Bool) -> Void

    var body: some View {
        let groups = SnippetMenuPlan.build(model: model, shortcutOrder: shortcutOrder)
        if leadingDivider, !groups.isEmpty {
            Divider()
        }
        ForEach(groups) { group in
            if let tag = group.tag {
                Menu(tag) {
                    entryButtons(group.entries)
                }
            } else {
                entryButtons(group.entries)
            }
        }
    }

    @ViewBuilder
    private func entryButtons(_ entries: [SnippetMenuPlan.Entry]) -> some View {
        ForEach(entries) { entry in
            Menu(entry.snippet.name) {
                insertButton(entry)
                Button(L10n.string("menu.snippets.execute", "Execute")) {
                    action(entry.snippet, true)
                }
            }
            .disabled(entry.isDisabled)
        }
    }

    /// Split out so the ⌃⌘n shortcut — present on the INSERT action only —
    /// can be attached conditionally without an `if`/`else` duplicating the
    /// button's title and closure.
    @ViewBuilder
    private func insertButton(_ entry: SnippetMenuPlan.Entry) -> some View {
        let button = Button(L10n.string("menu.snippets.insert", "Insert")) {
            action(entry.snippet, false)
        }
        if let digit = entry.insertShortcutDigit {
            button.keyboardShortcut(
                KeyEquivalent(Character("\(digit)")), modifiers: [.control, .command])
        } else {
            button
        }
    }
}
