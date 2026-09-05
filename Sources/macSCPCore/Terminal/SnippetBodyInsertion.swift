import Foundation

/// Where a placeholder like `{{NAME}}` lands when it is inserted into a
/// snippet's command body, decided without any view: at a live caret,
/// replacing a selection, or appended when there is no selection to speak
/// of.
///
/// The two cases answer different questions and are kept separate rather
/// than folded into one "insert somewhere" rule:
///
/// - **No selection** (`nil`) means there is no caret to speak of -- the
///   editor's `NSTextView` bridge has not mounted yet, or the caller has no
///   way to ask it. This is a WRITE to the end of a document, so it earns
///   the one-space separation snippet commands have always used (skipped
///   when `body` is empty or already ends in whitespace -- a line break
///   already separates on its own, and turning it into "line break plus
///   space" would indent the next line for no reason).
/// - **A selection**, empty (a caret) or not, is a plain text-editing
///   operation: `placeholder` replaces exactly that range, with no spacing
///   invented around it -- the same as typing or pasting into the middle of
///   a line in any text view.
public enum SnippetBodyInsertion {
    /// Inserts `placeholder` into `body` at `selection`, or appends it when
    /// `selection` is `nil`.
    ///
    /// `cursorAfter` is always the index right after the inserted
    /// `placeholder` in the RETURNED `body` -- never an index into the
    /// original `body`, which a caller must not reuse once this returns.
    public static func insert(
        _ placeholder: String, into body: String, at selection: Range<String.Index>?
    ) -> (body: String, cursorAfter: String.Index) {
        guard let selection else {
            guard let last = body.last else {
                return (placeholder, placeholder.endIndex)
            }
            let newBody = last.isWhitespace ? body + placeholder : body + " " + placeholder
            return (newBody, newBody.endIndex)
        }
        // `String.replaceSubrange` can invalidate indices from the string it
        // was called on, so the cursor position is recomputed as a
        // `Character` offset from `newBody`'s own `startIndex` rather than
        // reused from `body` -- offsets, unlike indices, survive the
        // mutation because they don't point INTO either string's storage.
        let prefixLength = body.distance(from: body.startIndex, to: selection.lowerBound)
        var newBody = body
        newBody.replaceSubrange(selection, with: placeholder)
        let cursorAfter = newBody.index(
            newBody.startIndex, offsetBy: prefixLength + placeholder.count)
        return (newBody, cursorAfter)
    }
}
