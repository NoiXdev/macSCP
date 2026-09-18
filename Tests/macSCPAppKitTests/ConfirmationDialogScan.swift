import Foundation
import MacSCPTestSupport

/// One `.confirmationDialog(` read out of a SwiftUI source file, for the
/// guards that pin how a question is wired: which state it is bound to,
/// what each of its buttons does, what its `isPresented:` setter runs and
/// where its text comes from.
///
/// The one dialog scanner of this target. `ConvertKeyWiringGuardTests`
/// (the login-set question) and `ToolbarTransferConfirmationGuardTests`
/// (the toolbar transfer question) each carried a private copy of the same
/// span walk until 2026-09-18; the copies differed only in which fields
/// they returned, so this type returns the union and each guard reads what
/// it checks.
///
/// Every span is found in the strict view
/// (`SwiftSource.blankingCommentsAndStrings`), where a brace or parenthesis
/// inside a comment or a literal cannot decide where a span ends, and key
/// literals are read from the comment-only view (`SwiftSource.blankingComments`)
/// at the same offsets — both views blank in place, so one offset
/// addresses the same character in each (`SwiftSource`'s own doc comment).
///
/// Fail-closed: `bound(to:in:)` throws when no dialog's argument list
/// names the state, and when the bound dialog's shape cannot be read, so a
/// moved dialog is a loud failure rather than an empty span that satisfies
/// every negative check.
struct ConfirmationDialogScan {
    enum ScanError: Error {
        /// A `.confirmationDialog(` whose argument list never closes.
        case unbalanced
        /// No dialog names the state, or the bound one lacks a buttons
        /// closure, a `message:` closure, an `isPresented:` setter, or a
        /// `Button(` whose action trails its argument list.
        case dialogNotFound
    }

    /// One `Button(` in the buttons closure: the catalog key its label
    /// names, its argument list in both views, and its trailing action —
    /// read at the same offsets, which is what pairs a key with its action.
    struct ButtonSpan {
        /// The first key an `L10n.string(` in the argument list names, or
        /// `nil` when the label is not a catalog lookup.
        let key: String?
        /// The argument list, strict view, parentheses included.
        let arguments: String
        /// The same argument list, comment-only view: literals survive.
        let literalArguments: String
        /// The trailing action closure, strict view, braces included.
        let action: String
    }

    /// The parenthesised argument list, strict view.
    let arguments: String
    /// The buttons closure, strict view.
    let buttons: String
    /// The `message:` closure, strict view.
    let message: String
    /// The `isPresented:` binding's `set:` closure, strict view.
    let setter: String
    /// Each `Button(` in the buttons closure, in order.
    let buttonSpans: [ButtonSpan]
    /// Every title, `Button(` or `Text(` in the dialog that does not open
    /// straight into `L10n.string(` (directly or through `String(format:`),
    /// as the strict text it opens into.
    let unlocalizedTexts: [String]
    /// How many texts were checked: the title plus every `Button(` and
    /// `Text(`.
    let textCount: Int
    /// Every key literal an `L10n.string(` in the dialog names, in order.
    let keys: [String]

    /// The first `.confirmationDialog(` whose ARGUMENT LIST names `state`.
    static func bound(to state: String, in source: String) throws -> ConfirmationDialogScan {
        let strict = Array(try SwiftSource.blankingCommentsAndStrings(source))
        let literal = Array(try SwiftSource.blankingComments(source))
        guard strict.count == literal.count else { throw ScanError.dialogNotFound }
        let opener = Array(".confirmationDialog(")
        var start = 0
        while let found = firstOffset(of: opener, in: strict, from: start) {
            start = found + opener.count
            let parenOpen = found + opener.count - 1
            guard let parenClose = closingOffset(from: parenOpen, in: strict, open: "(", close: ")")
            else { throw ScanError.unbalanced }
            let arguments = String(strict[parenOpen...parenClose])
            guard arguments.contains(state) else { continue }
            guard let buttonsOpen = firstOffset(of: ["{"], in: strict, from: parenClose),
                  let buttonsClose = closingOffset(from: buttonsOpen, in: strict, open: "{", close: "}"),
                  let label = firstOffset(of: Array("message:"), in: strict, from: buttonsClose),
                  let messageOpen = firstOffset(of: ["{"], in: strict, from: label),
                  let messageClose = closingOffset(from: messageOpen, in: strict, open: "{", close: "}"),
                  let setLabel = firstOffset(of: Array("set:"), in: strict, from: parenOpen),
                  setLabel < parenClose,
                  let setterOpen = firstOffset(of: ["{"], in: strict, from: setLabel),
                  let setterClose = closingOffset(from: setterOpen, in: strict, open: "{", close: "}"),
                  setterClose < parenClose
            else { throw ScanError.dialogNotFound }

            var textStarts = [parenOpen + 1]
            for token in [Array("Button("), Array("Text(")] {
                var from = parenOpen
                while let hit = firstOffset(of: token, in: strict, from: from), hit < messageClose {
                    textStarts.append(hit + token.count)
                    from = hit + token.count
                }
            }
            let unlocalized = textStarts.compactMap { offset -> String? in
                let window = String(strict[offset..<min(offset + 120, strict.count)])
                    .filter { !$0.isWhitespace }
                let localized = window.hasPrefix("L10n.string(")
                    || window.hasPrefix("String(format:L10n.string(")
                return localized ? nil : String(window.prefix(40))
            }

            var buttonSpans: [ButtonSpan] = []
            var buttonFrom = buttonsOpen
            let buttonToken = Array("Button(")
            while let hit = firstOffset(of: buttonToken, in: strict, from: buttonFrom), hit < buttonsClose {
                let argsOpen = hit + buttonToken.count - 1
                guard let argsClose = closingOffset(from: argsOpen, in: strict, open: "(", close: ")"),
                      let actionOpen = firstOffset(of: ["{"], in: strict, from: argsClose),
                      strict[(argsClose + 1)..<actionOpen].allSatisfy(\.isWhitespace),
                      let actionClose = closingOffset(from: actionOpen, in: strict, open: "{", close: "}")
                else { throw ScanError.dialogNotFound }
                let literalArguments = String(literal[argsOpen...argsClose])
                buttonSpans.append(ButtonSpan(
                    key: catalogKeys(in: literalArguments).first,
                    arguments: String(strict[argsOpen...argsClose]),
                    literalArguments: literalArguments,
                    action: String(strict[actionOpen...actionClose])))
                buttonFrom = actionClose
            }

            return ConfirmationDialogScan(
                arguments: arguments,
                buttons: String(strict[buttonsOpen...buttonsClose]),
                message: String(strict[messageOpen...messageClose]),
                setter: String(strict[setterOpen...setterClose]),
                buttonSpans: buttonSpans,
                unlocalizedTexts: unlocalized,
                textCount: textStarts.count,
                keys: catalogKeys(in: String(literal[parenOpen...messageClose])))
        }
        throw ScanError.dialogNotFound
    }

    /// Every key literal an `L10n.string(` in `text` names, in order.
    /// Walked by hand rather than matched with a regex literal: the project's
    /// source strippers read every test file, and a bare `/…/` literal
    /// carrying a quote is what they cannot parse.
    static func catalogKeys(in text: String) -> [String] {
        var keys: [String] = []
        for piece in text.components(separatedBy: "L10n.string(").dropFirst() {
            let rest = piece.drop(while: { $0.isWhitespace })
            guard rest.first == "\"" else { continue }
            keys.append(String(rest.dropFirst().prefix(while: { $0 != "\"" })))
        }
        return keys
    }

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
