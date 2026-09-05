import Foundation

/// Blanking comments and string literals, for every test target's source
/// scans.
///
/// A guard that reads raw source cannot tell a call from a sentence about a
/// call. That is CLAUDE.md's "Source-scanning guards read comments too", and
/// it was measured on the AppKit target: a doc comment on `row(_:)` reading
/// "the row's trailing control comes from `cancelButton(item)`", planted
/// together with the DELETION of the real placement, left every one of the
/// sixteen transfer-bar guard tests green — the count anchor that exists to
/// catch a control the user can never reach was reading the sentence about
/// the control.
///
/// ## Two modes, because a scan wants two different things
///
/// A structural claim (where a body ends, how often a symbol is called,
/// which modifier a control carries) must be read from code alone, so both
/// comments and string literals are blanked. A claim about a catalogue key
/// (`L10n.string("transfers.cancel", …)`) is a claim ABOUT a literal, and
/// blanking it would delete the very thing being checked — but a comment
/// naming that key must still not satisfy it. Hence `blankingComments`,
/// which blanks comments and keeps literals.
///
/// ## Both modes preserve length, and that is load-bearing
///
/// Every consumed character is replaced by exactly one character (a space,
/// or a newline where a newline stood), never dropped. So the two views and
/// the raw source share one character indexing, and a span found in the
/// strict view — a brace-balanced declaration body, say — can be sliced out
/// of the literal-keeping view without searching for it a second time.
///
/// ## History
///
/// This is the converged form of what used to be four separate hand-rolled
/// strippers in `macSCPAppKitTests` (this file's ancestor, plus private
/// copies in `ReconnectWiringGuardTests`, `TabContextMenuWiringGuardTests`
/// and `ConnectingAttemptWiringGuardTests`) and a fifth, older one in
/// `macSCPCoreTests` that read `\(` as a plain escape pair and let a string
/// literal nested inside an interpolation pose as code. The interpolation
/// walk below (`endOfLiteral`/`endOfInterpolation`) is the AppKit ancestor's
/// fix for that, proved red first on 2026-09-03. Raw-string (`#"…"#`) and
/// extended-regex-literal (`#/…/#`) parsing is `TabContextMenuWiringGuardTests`'s
/// contribution — the AppKit ancestor and the Core original both refused to
/// guess where those close and threw instead; this merged form parses both,
/// so the fail-closed behaviour that used to be pinned for a raw-string
/// delimiter is gone, replaced by pinning that it parses correctly.
public enum SwiftSource {
    /// Raised when the source contains something this hand-rolled stripper
    /// cannot parse: a string or comment literal that never closes, or a
    /// raw-string/regex delimiter whose matching terminator is never found.
    /// Either one means the rest of the read is not trustworthy, so the scan
    /// must stop rather than silently hand back a truncated result.
    public enum StripError: Error, CustomStringConvertible {
        case unterminatedLiteral

        public var description: String {
            "unterminated string, comment or raw-string/regex literal"
        }
    }

    /// Blanks `//` and `/* */` comments AND string literals (plain, raw and
    /// multiline) and extended regex literals, interpolations included. The
    /// strict view: what survives is code, so a symbol found in it was
    /// called, not described or quoted.
    ///
    /// The converse does NOT hold: a symbol MISSING from the strict view may
    /// still be called, because an interpolated expression is blanked along
    /// with the literal that carries it (see `endOfLiteral`). Every check
    /// here is positive for that reason — "the call is present" — and a
    /// negative one must be read as "not present outside a literal".
    public static func blankingCommentsAndStrings(_ source: String) throws -> String {
        try blank(source, keepStringLiterals: false)
    }

    /// Blanks comments only; string and regex literals survive verbatim.
    /// For claims about a literal itself — a catalogue key, a format string
    /// — which the strict view above would have deleted. Literals are still
    /// PARSED, so a `//` inside one is not mistaken for a comment.
    public static func blankingComments(_ source: String) throws -> String {
        try blank(source, keepStringLiterals: true)
    }

    /// Compatibility name for the older Core-target API this file replaces.
    /// Every caller migrated here was checked to depend only on comment/
    /// string removal and on the resulting text's LINE structure (a
    /// newline-count-based line lookup, or a plain `contains`/`split`), so
    /// the strictly stronger length- and line-preserving `blankingCommentsAndStrings`
    /// is a safe drop-in — it never removes a `\n` that survived before, it
    /// only adds the fix for nested interpolation.
    public static func stripCommentsAndStrings(_ source: String) throws -> String {
        try blankingCommentsAndStrings(source)
    }

    /// Compatibility name for the older Core-target API this file replaces.
    /// See `stripCommentsAndStrings` above for why the swap is safe.
    public static func stripComments(_ source: String) throws -> String {
        try blankingComments(source)
    }

    /// Fails closed: an unterminated string, interpolation, comment or raw
    /// delimiter means the walk ran off the end of the file without finding
    /// what it was looking for — it throws rather than return whatever was
    /// collected so far. The alternative is a scan that silently reads less
    /// than the file it claims to have checked.
    ///
    /// The one form still parsed by approximation is a multiline literal:
    /// its span ends at the next `"""`, so a `"""` written INSIDE one of its
    /// interpolations would end it early. No such literal exists in the
    /// scanned tree, and the failure would be over-blanking (a check going
    /// red), not a literal posing as code.
    private static func blank(_ source: String, keepStringLiterals: Bool) throws -> String {
        let chars = Array(source)
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var index = 0
        var blockCommentDepth = 0

        func blanked(_ character: Character) -> Character {
            character == "\n" ? "\n" : " "
        }
        func appendBlanked(_ range: Range<Int>) {
            for position in range { result.append(blanked(chars[position])) }
        }
        func appendLiteral(_ range: Range<Int>) {
            for position in range {
                result.append(keepStringLiterals ? chars[position] : blanked(chars[position]))
            }
        }

        while index < chars.count {
            let character = chars[index]
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                    blockCommentDepth += 1
                    appendBlanked(index..<(index + 2))
                    index += 2
                    continue
                }
                if character == "*", index + 1 < chars.count, chars[index + 1] == "/" {
                    blockCommentDepth -= 1
                    appendBlanked(index..<(index + 2))
                    index += 2
                    continue
                }
                appendBlanked(index..<(index + 1))
                index += 1
                continue
            }
            if character == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" {
                    appendBlanked(index..<(index + 1))
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                blockCommentDepth = 1
                appendBlanked(index..<(index + 2))
                index += 2
                continue
            }
            if character == "#", let end = try endOfHashDelimited(in: chars, from: index) {
                appendLiteral(index..<end)
                index = end
                continue
            }
            if character == "\"" {
                let start = index
                index = try endOfLiteral(in: chars, from: index)
                appendLiteral(start..<index)
                continue
            }
            result.append(character)
            index += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return String(result)
    }

    /// The index just past the closing delimiter of a raw string (`#"…"#`,
    /// any number of leading `#`s, single- or triple-quoted) or an extended
    /// regex literal (`#/…/#`) starting at `start` (which must be `#`), or
    /// `nil` if `start` is not one of those two forms — a bare `#` before a
    /// macro (`#expect`, `#selector`, `#if`, …) is ordinary code and must
    /// fall through unconsumed.
    ///
    /// Neither form's body is parsed for a nested interpolation the way a
    /// plain string literal is (`endOfLiteral` below) — the body is scanned
    /// only for the matching close. That mirrors the one implementation
    /// among the four converged strippers that supported these forms at
    /// all, and nothing in the trees any of them scan nests an interpolation
    /// inside a raw string or a regex literal.
    private static func endOfHashDelimited(in chars: [Character], from start: Int) throws -> Int? {
        var lookahead = start
        while lookahead < chars.count, chars[lookahead] == "#" { lookahead += 1 }
        let hashes = lookahead - start

        if lookahead < chars.count, chars[lookahead] == "/" {
            var cursor = lookahead + 1
            while cursor < chars.count {
                if chars[cursor] == "/",
                    closesHashDelimiter(chars, at: cursor + 1, quotes: 0, hashes: hashes)
                {
                    return cursor + 1 + hashes
                }
                cursor += 1
            }
            throw StripError.unterminatedLiteral
        }

        if lookahead < chars.count, chars[lookahead] == "\"" {
            // Three quotes alone are ambiguous: `#"""#` is a perfectly
            // ordinary SINGLE-quote raw string whose one-character content
            // happens to be `"` — reading it as a triple-quote OPEN would
            // send the walker hunting for a closing `"""#` that is never
            // there. Swift's own rule for a multiline literal breaks the
            // tie: its opening `"""` must be immediately followed by a
            // line break, so that is what is required here too.
            let isMultiline =
                lookahead + 3 < chars.count && chars[lookahead + 1] == "\""
                    && chars[lookahead + 2] == "\"" && chars[lookahead + 3] == "\n"
            let quotes = isMultiline ? 3 : 1
            var cursor = lookahead + quotes
            while cursor < chars.count {
                if closesHashDelimiter(chars, at: cursor, quotes: quotes, hashes: hashes) {
                    return cursor + quotes + hashes
                }
                cursor += 1
            }
            throw StripError.unterminatedLiteral
        }

        return nil
    }

    /// Whether the terminator of a raw string or extended regex literal
    /// (`quotes` quote characters followed by `hashes` `#`s) starts at
    /// `index`. A regex literal's terminator carries no quotes
    /// (`quotes == 0`); a raw string's carries one or three.
    private static func closesHashDelimiter(
        _ chars: [Character], at index: Int, quotes: Int, hashes: Int
    ) -> Bool {
        guard index + quotes + hashes <= chars.count else { return false }
        for offset in 0..<quotes where chars[index + offset] != "\"" { return false }
        for offset in 0..<hashes where chars[index + quotes + offset] != "#" { return false }
        return true
    }

    /// The index just past the closing delimiter of the string literal that
    /// starts at `start` (which must be a `"`).
    ///
    /// Interpolations are WALKED rather than skipped as an escape pair. `\(`
    /// opens a parenthesised region of code, and a string literal written in
    /// there is a literal of its own with its own closing quote. Reading `\(`
    /// as a plain escape — which every one of the converged strippers except
    /// the AppKit ancestor did — makes the walker take the OPENING quote of
    /// such a nested literal for the outer literal's closing one: `let t = "a
    /// \(x ?? "}") b"` then emitted `}` as code, which is a brace the body
    /// counter cannot see is quoted. The whole literal is one span either
    /// way, so nothing inside an interpolation is ever treated as code —
    /// that is deliberate: this stripper's job is to make sure a quoted
    /// needle cannot pose as a call, and over-blanking an interpolated
    /// expression costs a guard nothing, where under-blanking one costs it
    /// the property it watches.
    private static func endOfLiteral(in chars: [Character], from start: Int) throws -> Int {
        if start + 2 < chars.count, chars[start + 1] == "\"", chars[start + 2] == "\"" {
            var cursor = start + 3
            while cursor + 2 < chars.count,
                !(chars[cursor] == "\"" && chars[cursor + 1] == "\"" && chars[cursor + 2] == "\"")
            {
                cursor += 1
            }
            guard cursor + 2 < chars.count else { throw StripError.unterminatedLiteral }
            return cursor + 3
        }
        var cursor = start + 1
        while cursor < chars.count, chars[cursor] != "\"" {
            guard chars[cursor] == "\\", cursor + 1 < chars.count else {
                cursor += 1
                continue
            }
            guard chars[cursor + 1] == "(" else {
                cursor += 2
                continue
            }
            cursor = try endOfInterpolation(in: chars, from: cursor + 2)
        }
        guard cursor < chars.count else { throw StripError.unterminatedLiteral }
        return cursor + 1
    }

    /// The index just past the `)` that closes the interpolation whose `\(`
    /// ended at `start`.
    ///
    /// Parentheses are counted, so a call inside the interpolation
    /// (`"x \(f("y")) z"`) does not end it early, and a nested literal is
    /// handed back to `endOfLiteral` — mutually recursive, because an
    /// interpolation may contain a literal that contains an interpolation.
    /// Running off the end means the file cannot be parsed, so it fails
    /// closed like every other unterminated form here.
    private static func endOfInterpolation(in chars: [Character], from start: Int) throws -> Int {
        var cursor = start
        var depth = 1
        while cursor < chars.count {
            switch chars[cursor] {
            case "\"":
                cursor = try endOfLiteral(in: chars, from: cursor)
            case "(":
                depth += 1
                cursor += 1
            case ")":
                depth -= 1
                cursor += 1
                if depth == 0 { return cursor }
            default:
                cursor += 1
            }
        }
        throw StripError.unterminatedLiteral
    }
}
