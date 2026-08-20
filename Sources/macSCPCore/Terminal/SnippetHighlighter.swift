import Foundation

/// Which syntax a snippet's command is written in (snippet editor, part 1).
///
/// A parameter rather than a stored field on `Snippet`: today there is one
/// case, and a stored column with a single possible value buys nothing but
/// a migration. When a second protocol arrives, the field gets added then
/// and legacy JSON decodes as `.shell` -- the same optional-defaulting
/// pattern `groupID` and `loginSetID` already use.
public enum SnippetLanguage: Sendable {
    case shell
}

/// One coloured run of a command. Carries WHAT a range is, never which
/// colour it gets -- Core knows no colours; the App layer maps kinds to
/// design tokens.
public struct SnippetToken: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case command, option, string, variable, comment, `operator`, plain
    }
    public let kind: Kind
    public let range: Range<String.Index>

    public init(kind: Kind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

public enum SnippetHighlighter {
    /// Splits `text` into coloured runs. Single pass, left to right; every
    /// non-whitespace character lands in exactly one token, whitespace is not
    /// tokenised, and the App layer is expected to paint a base colour first
    /// rather than rely on full coverage.
    public static func tokens(in text: String, language: SnippetLanguage) -> [SnippetToken] {
        switch language {
        case .shell: return shellTokens(in: text)
        }
    }

    private static let operatorStarts: Set<Character> = ["|", "&", ";", ">", "<"]

    private static func shellTokens(in text: String) -> [SnippetToken] {
        var tokens: [SnippetToken] = []
        var i = text.startIndex
        var sawCommand = false

        while i < text.endIndex {
            let c = text[i]

            if c.isWhitespace {
                i = text.index(after: i)
                continue
            }

            // A comment runs to the end of the LINE -- not to the end of
            // the text. A command may span lines (snippet editor, part 2),
            // and an earlier version of this branch ended the token at
            // `text.endIndex` and stopped tokenising there, so one `#` on
            // the first line swallowed every later line: no strings, no
            // variables, nothing. That is a colouring bug on its own, and
            // it also blinded `SnippetVariableSubstitution
            // .firstDeclarationProblem`, which reads the `.string` tokens
            // from here to decide whether a placeholder sits inside quotes.
            // A `#` inside a string never reaches this branch, because
            // quotes are consumed whole below.
            if c == "#" {
                var j = i
                while j < text.endIndex, !text[j].isNewline { j = text.index(after: j) }
                tokens.append(SnippetToken(kind: .comment, range: i..<j))
                i = j
                continue
            }

            if c == "'" || c == "\"" {
                let span = quotedSpan(in: text, openingAt: i)
                tokens.append(SnippetToken(kind: .string, range: i..<span.end))
                i = span.end
                continue
            }

            if c == "$" {
                var j = text.index(after: i)
                if j < text.endIndex, text[j] == "{" {
                    while j < text.endIndex, text[j] != "}" { j = text.index(after: j) }
                    if j < text.endIndex { j = text.index(after: j) }
                    tokens.append(SnippetToken(kind: .variable, range: i..<j))
                    i = j
                    continue
                }
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" {
                    j = text.index(after: j)
                }
                // A bare `$` names nothing, so it is not a variable.
                if j > text.index(after: i) {
                    tokens.append(SnippetToken(kind: .variable, range: i..<j))
                    i = j
                } else {
                    tokens.append(SnippetToken(kind: .plain, range: i..<j))
                    i = j
                }
                continue
            }

            if operatorStarts.contains(c) {
                var j = text.index(after: i)
                // `&&` and `||` are one operator, `&` and `|` on their own
                // are too.
                if j < text.endIndex, text[j] == c, c == "&" || c == "|" {
                    j = text.index(after: j)
                }
                tokens.append(SnippetToken(kind: .operator, range: i..<j))
                i = j
                continue
            }

            // A plain word: everything up to whitespace or a character that
            // starts something else.
            var j = i
            while j < text.endIndex,
                  !text[j].isWhitespace,
                  text[j] != "'", text[j] != "\"", text[j] != "$", text[j] != "#",
                  !operatorStarts.contains(text[j]) {
                j = text.index(after: j)
            }
            let word = text[i..<j]
            let kind: SnippetToken.Kind
            if !sawCommand {
                kind = .command
                sawCommand = true
            } else if word.hasPrefix("-") {
                kind = .option
            } else {
                kind = .plain
            }
            tokens.append(SnippetToken(kind: kind, range: i..<j))
            i = j
        }
        return tokens
    }

    /// How far the quoted span that opens at `start` reaches, and whether it
    /// actually closed.
    ///
    /// The ONE place this project decides where a quoted run ends -- both
    /// `shellTokens` and `quotingBalancesPerLine` go through it, so the two
    /// answers cannot drift apart (the same single-implementation reasoning
    /// `PosixQuoting`'s doc comment gives for quoting).
    ///
    /// `text[start]` is the opening quote. Inside a DOUBLE-quoted span a
    /// backslash escapes the next character, so `"a\"b"` is one span and not
    /// a closed `"a\"` followed by loose text -- getting that wrong is what
    /// let a placeholder inside `"a\"{{X}}"` read as unquoted. A
    /// SINGLE-quoted span honours no escape at all in POSIX: every
    /// character up to the next `'` is literal, backslash included, so
    /// `'a\'` closes at that second quote. The asymmetry is the shell's, not
    /// a simplification.
    ///
    /// An unterminated span reports `closed: false` and reaches to the end
    /// of the text, so a caller that only wants tokens still gets a range
    /// covering the rest rather than dropping it on the floor.
    private static func quotedSpan(
        in text: String, openingAt start: String.Index
    ) -> (end: String.Index, closed: Bool) {
        let quote = text[start]
        let honoursEscapes = quote == "\""
        var j = text.index(after: start)
        while j < text.endIndex {
            if honoursEscapes, text[j] == "\\" {
                let afterBackslash = text.index(after: j)
                guard afterBackslash < text.endIndex else { break }
                j = text.index(after: afterBackslash)
                continue
            }
            if text[j] == quote { return (text.index(after: j), true) }
            j = text.index(after: j)
        }
        return (text.endIndex, false)
    }

    /// Whether every quoted span in `text` opens and closes on the same
    /// line.
    ///
    /// The precondition `SnippetVariableSubstitution.firstDeclarationProblem`
    /// needs before "this placeholder sits inside quotes" means anything: an
    /// unterminated quote makes every later position's quoting state a
    /// guess, and a span running across a line break -- legal in a shell,
    /// but not something a position check can reason about -- means the same.
    /// Reported as one boolean rather than a position, because the caller
    /// refuses on it; it does not point at it.
    ///
    /// Built on `tokens(in:language:)` so comments, and `#` characters
    /// inside strings, are treated exactly as the tokenizer treats them --
    /// this is not a second scanner with its own opinion.
    public static func quotingBalancesPerLine(in text: String) -> Bool {
        for token in tokens(in: text, language: .shell) where token.kind == .string {
            guard quotedSpan(in: text, openingAt: token.range.lowerBound).closed else {
                return false
            }
            guard !text[token.range].contains(where: \.isNewline) else { return false }
        }
        return true
    }
}
