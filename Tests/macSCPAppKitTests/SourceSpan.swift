/// Offset arithmetic over a blanked Swift source view: find a token, and
/// find the bracket that balances one.
///
/// Neither helper knows anything about dialogs. They lived on
/// `ConfirmationDialogScan` until this sweep, which was fine while that type
/// was their only reader; `ToolbarTransferConfirmationGuardTests` then
/// borrowed them for a scan that reads a toolbar body and no dialog at all,
/// and a guard reaching through a dialog-named type to walk something that
/// is not a dialog is the kind of misdirection this project's naming rules
/// exist to prevent. Both readers today — `ConfirmationDialogScan` and
/// `ToolbarTransferConfirmationGuardTests`, counted in the pass that wrote
/// this sentence — call them here instead.
///
/// Both take, and return, offsets into a `[Character]` taken from one of
/// `SwiftSource`'s blanked views. Over raw source they are meaningless: a
/// brace inside a comment or a string literal would decide where a span
/// ends (`SwiftSourceStripping`'s own doc comment).
enum SourceSpan {
    /// The first offset at or after `start` where `token` begins in `text`.
    static func firstOffset(of token: [Character], in text: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, text.count >= token.count, start <= text.count - token.count else { return nil }
        for offset in start...(text.count - token.count)
        where text[offset..<(offset + token.count)].elementsEqual(token) {
            return offset
        }
        return nil
    }

    /// The offset of the `closer` that balances the `opener` at `open`, or
    /// `nil` when it never closes. Meaningful only over a blanked view.
    static func closingOffset(
        from open: Int, in text: [Character], open opener: Character, close closer: Character
    ) -> Int? {
        var depth = 0
        for offset in open..<text.count {
            if text[offset] == opener { depth += 1 }
            if text[offset] == closer {
                depth -= 1
                if depth == 0 { return offset }
            }
        }
        return nil
    }
}
