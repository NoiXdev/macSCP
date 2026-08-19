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

            // A comment runs to the end of the line -- but only outside a
            // string, which is why quotes are consumed whole below.
            if c == "#" {
                tokens.append(SnippetToken(kind: .comment, range: i..<text.endIndex))
                break
            }

            if c == "'" || c == "\"" {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != c { j = text.index(after: j) }
                // An unterminated quote runs to the end rather than
                // dropping the rest of the line on the floor.
                let end = j < text.endIndex ? text.index(after: j) : text.endIndex
                tokens.append(SnippetToken(kind: .string, range: i..<end))
                i = end
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
}
