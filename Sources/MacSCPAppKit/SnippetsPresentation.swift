import Foundation
import macSCPCore

/// The outcome of reading `snippets.json`, in the two shapes the UI has to
/// tell apart: a list (possibly empty) or a store that could not be read.
///
/// `SnippetStore.all()` throws for a file it cannot decode, and one
/// hand-edited multi-line `command` is enough to get there — `Snippet`'s
/// decoder refuses it, which `aHandEditedMultiLineCommandDoesNotDecode`
/// pins. Both readers of the store used to collapse that into `[]`, so an
/// unreadable store looked exactly like an empty one: the Terminal menu
/// showed no snippet entries, and the management sheet said "No snippets
/// yet." over a file that still holds every snippet the user wrote. Nothing
/// is lost in that state — `save`/`remove` read the file first and throw
/// too, so no write lands on top of it — but the user got no signal at all.
///
/// Both call sites now say which case they are in: `SnippetsSheet` shows the
/// read error in the error slot it already had and suppresses its "No
/// snippets yet." line, and the Terminal menu shows a disabled notice entry.
enum SnippetsLoad: Equatable {
    case loaded([Snippet])
    case unreadable

    /// Reads `store` once. Anything `all()` throws lands in `.unreadable` —
    /// the error itself is not carried, because neither call site shows it:
    /// a decoder's `debugDescription` is not a user-facing sentence, and a
    /// snippet's own text could appear in it.
    init(reading store: SnippetStore) {
        if let snippets = try? store.all() {
            self = .loaded(snippets)
        } else {
            self = .unreadable
        }
    }

    /// The snippets to list — empty for `.unreadable`, so a caller that only
    /// enumerates entries needs no special case. A caller that would
    /// otherwise CLAIM the store is empty must check `isUnreadable` instead.
    var snippets: [Snippet] {
        switch self {
        case .loaded(let snippets): return snippets
        case .unreadable: return []
        }
    }

    var isUnreadable: Bool { self == .unreadable }
}

/// Text for the Terminal menu's snippet entries.
enum SnippetMenuEntry {
    /// The menu title for one snippet. A snippet that runs immediately says
    /// so **in its own title**; an inserting one is titled with its bare
    /// name.
    ///
    /// This is the distinction the feature rests on — which entries fire a
    /// command on the far host the moment they are picked — and it is here,
    /// per item, rather than in the surrounding grouping, for a reason the
    /// grouping cannot cover:
    ///
    /// - `MacSCPApp.snippetMenuItems` emits sibling `Divider()`s for the
    ///   start of the snippet block and for "Manage Snippets…" as well, so a
    ///   divider marks no particular band. Reading the source is enough to
    ///   see that; the app was not launched.
    /// - The `Section` title above the executing entries would carry it, but
    ///   how `Section` draws a title inside a menu-bar menu has never been
    ///   observed in this project. An unverified rendering cannot be the
    ///   thing a safety distinction rests on.
    /// - A title is text the menu certainly renders — every other entry in
    ///   this menu proves it — and it survives the case where the grouping
    ///   collapses entirely: with only executing snippets saved there is no
    ///   second band to contrast with, and the band boundary says nothing.
    ///
    /// Text rather than a per-item symbol: the design rejected an icon (and
    /// M19a's rule would ask for a hover hint a menu item cannot carry). The
    /// sheet's row keeps its `bolt.fill` with its `.help`; that view can.
    static func title(for snippet: Snippet) -> String {
        guard snippet.runsImmediately else { return snippet.name }
        return String(
            format: L10n.string("menu.snippets.executingItem", "%@ (runs immediately)"),
            snippet.name)
    }
}
