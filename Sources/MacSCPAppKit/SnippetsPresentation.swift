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
///
/// TEMPORARY (Terminal-Snippets, Task 1): this type's whole purpose was
/// marking a snippet that runs immediately in its own menu title — see the
/// history of this doc comment for the reasoning. `Snippet.runsImmediately`
/// no longer exists (the maintainer's call: the insert-or-execute decision
/// now belongs at the trigger, not the model — see `Snippet`'s doc comment),
/// so every title below is currently just the bare name. Task 5 removes this
/// type entirely once the menu offers both actions per snippet instead of
/// baking one choice into the entry's title.
enum SnippetMenuEntry {
    /// The menu title for one snippet — currently always its bare name; see
    /// this type's doc comment for why.
    static func title(for snippet: Snippet) -> String {
        snippet.name
    }
}
