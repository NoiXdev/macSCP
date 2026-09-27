/// Span arithmetic over a blanked Swift source view: find a token, find the
/// bracket that balances one, and cut out the brace-balanced body an anchor
/// opens.
///
/// None of it knows anything about dialogs. The two offset helpers lived on
/// `ConfirmationDialogScan` until this sweep, which was fine while that type
/// was their only reader; `ToolbarTransferConfirmationGuardTests` then
/// borrowed them for a scan that reads a toolbar body and no dialog at all,
/// and a guard reaching through a dialog-named type to walk something that
/// is not a dialog is the kind of misdirection this project's naming rules
/// exist to prevent. Their readers today — `ConfirmationDialogScan` and
/// `ToolbarTransferConfirmationGuardTests`, counted in the pass that wrote
/// this sentence — call them here instead.
///
/// The `String.Index` half below arrived the same way, one round later:
/// `MainWindowSizePlanTests` was calling `TabsWindowLifecycleTests.body(after:in:)`
/// — one guard suite reaching into another suite's private scanner for a
/// walk that is about neither suite — while `TabContextMenuWiringGuardTests`
/// carried a second, byte-different implementation of the same brace count
/// and `JumpSessionSummaryResolutionGuardTests` a third. One walk stands
/// here now, with five readers counted in the pass that wrote this
/// sentence: those three suites, `TabsWindowLifecycleTests`, and — the
/// reason this file moved out of `macSCPAppKitTests` and into the support
/// target — `RemoteFileSystemReadStreamCycleGuardTests`'s `ReadStreamScan`
/// in the Core target. Both targets scan source; a brace walk is no more
/// the App suite's than a comment stripper is, and `SwiftSource` and
/// `SourceCorpus` already live here.
///
/// Every helper here takes, and returns, positions in one of `SwiftSource`'s
/// blanked views. Over raw source they are meaningless: a brace inside a
/// comment or a string literal would decide where a span ends
/// (`SwiftSourceStripping`'s own doc comment).
public enum SourceSpan {
    /// The first offset at or after `start` where `token` begins in `text`.
    public static func firstOffset(of token: [Character], in text: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, text.count >= token.count, start <= text.count - token.count else { return nil }
        for offset in start...(text.count - token.count)
        where text[offset..<(offset + token.count)].elementsEqual(token) {
            return offset
        }
        return nil
    }

    /// The offset of the `closer` that balances the `opener` at `open`, or
    /// `nil` when it never closes. Meaningful only over a blanked view.
    public static func closingOffset(
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

    /// The index of the `}` that balances the `{` at `open`, or `nil` when
    /// it never closes — the `String.Index` form of `closingOffset`, for the
    /// scanners that slice a `String` rather than a `[Character]`.
    public static func closingBrace(from open: String.Index, in source: String) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The anchor, the first `{` at or after where it starts, and the `}`
    /// that balances that brace. `nil` on a missing anchor or unbalanced
    /// braces rather than a guess, so every caller fails closed when the
    /// thing it names moves.
    ///
    /// The brace is looked for from the anchor's OWN start, so an anchor
    /// that spells its opening brace (`"func f() {"`) and one that stops at
    /// the parameter list (`"func f("`) reach the same body. The second
    /// form used to reach further: `TabsWindowLifecycleTests`'s version
    /// counted from the anchor's end with the depth already at 1, so
    /// `"func applicationShouldTerminate("` returned that function's body
    /// AND everything after it up to the enclosing type's closing brace.
    public static func bodySpan(
        after anchor: String, in source: String
    ) -> (anchor: Range<String.Index>, open: String.Index, close: String.Index)? {
        guard let found = source.range(of: anchor),
              let open = source[found.lowerBound...].firstIndex(of: "{"),
              let close = closingBrace(from: open, in: source)
        else { return nil }
        return (found, open, close)
    }

    /// Everything between the first `{` at or after `anchor` and the `}`
    /// that balances it, the braces themselves excluded. `nil` on a missing
    /// anchor or unbalanced braces (`bodySpan`).
    public static func body(after anchor: String, in source: String) -> String? {
        guard let span = bodySpan(after: anchor, in: source) else { return nil }
        return String(source[source.index(after: span.open)..<span.close])
    }
}
