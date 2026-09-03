import Foundation
import Testing

/// Blanking comments and string literals, for this target's source scans.
///
/// A guard that reads raw source cannot tell a call from a sentence about a
/// call. That is CLAUDE.md's "Source-scanning guards read comments too", and
/// it was measured again on this branch: a doc comment on `row(_:)` reading
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
/// `bothModesPreserveLengthAndLineStructure` is what holds that property.
///
/// It lives in its own file rather than inside one suite because more than
/// one guard here reads Swift source. Three suites in this target still
/// carry private strippers of their own — `ReconnectWiringGuardTests`,
/// `TabContextMenuWiringGuardTests`, `ConnectingAttemptWiringGuardTests`,
/// counted in the pass that writes this sentence — and three more share
/// `SheetFacetWiringGuardTests.strippingLineComments`, which removes line
/// comments only. None of them is changed by this file; it is the place for
/// them to converge, not a claim that they have.
enum SwiftSource {
    /// Raised when the source contains something this hand-rolled stripper
    /// cannot parse: a raw-string delimiter it does not understand, or a
    /// string/comment literal that never closes. Either one means the rest
    /// of the read is not trustworthy, so the scan must stop rather than
    /// silently hand back a truncated result.
    enum StripError: Error, CustomStringConvertible {
        case unrecognizedDelimiter
        case unterminatedLiteral

        var description: String {
            switch self {
            case .unrecognizedDelimiter:
                return """
                    unrecognized string delimiter (a raw string's `#"`, `##"`, …) — this \
                    stripper does not parse raw strings and refuses to guess where one ends
                    """
            case .unterminatedLiteral:
                return "unterminated string or comment literal"
            }
        }
    }

    /// Blanks `//` and `/* */` comments AND string literals. The strict
    /// view: what survives is code, so a symbol found in it was called, not
    /// described or quoted.
    static func blankingCommentsAndStrings(_ source: String) throws -> String {
        try blank(source, keepStringLiterals: false)
    }

    /// Blanks comments only; string literals survive verbatim. For claims
    /// about a literal itself — a catalogue key, a format string — which the
    /// strict view above would have deleted. Literals are still PARSED, so a
    /// `//` inside one is not mistaken for a comment.
    static func blankingComments(_ source: String) throws -> String {
        try blank(source, keepStringLiterals: true)
    }

    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end of the file without finding what it was looking
    /// for. Both throw rather than return whatever was collected so far —
    /// the alternative is a scan that silently reads less than the file it
    /// claims to have checked.
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
            if character == "#" {
                var lookahead = index
                while lookahead < chars.count, chars[lookahead] == "#" { lookahead += 1 }
                if lookahead < chars.count, chars[lookahead] == "\"" {
                    throw StripError.unrecognizedDelimiter
                }
            }
            if character == "\"", index + 2 < chars.count,
                chars[index + 1] == "\"", chars[index + 2] == "\""
            {
                let start = index
                index += 3
                while index + 2 < chars.count,
                    !(chars[index] == "\"" && chars[index + 1] == "\"" && chars[index + 2] == "\"")
                {
                    index += 1
                }
                guard index + 2 < chars.count else { throw StripError.unterminatedLiteral }
                index += 3
                appendLiteral(start..<index)
                continue
            }
            if character == "\"" {
                let start = index
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count { index += 2 } else { index += 1 }
                }
                guard index < chars.count else { throw StripError.unterminatedLiteral }
                index += 1
                appendLiteral(start..<index)
                continue
            }
            result.append(character)
            index += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return String(result)
    }
}

/// The stripper's own behaviour, stated in one place rather than inside the
/// first suite that needed it: what each mode blanks, what both preserve,
/// and what it does at the end of a file it cannot parse.
@Suite("Swift source stripping (AppKit guards)")
struct SwiftSourceStrippingTests {
    private static let sample = """
        // marker
        let text = "marker"
        /* marker */
        let real = marker
        """

    /// The strict view: only the occurrence in CODE survives. This is the
    /// property the planted doc comment defeated.
    @Test func theStrictViewKeepsOnlyTheOccurrenceInCode() throws {
        let stripped = try SwiftSource.blankingCommentsAndStrings(Self.sample)
        #expect(stripped.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
        #expect(stripped.components(separatedBy: "marker").count - 1 == 1,
                "only the one occurrence in code should survive: \(stripped)")
    }

    /// The literal-keeping view: the quoted occurrence survives (a catalogue
    /// key must still be checkable), the commented ones do not.
    @Test func theLiteralViewKeepsTheQuotedOccurrenceButNoComment() throws {
        let stripped = try SwiftSource.blankingComments(Self.sample)
        #expect(stripped.components(separatedBy: "marker").count - 1 == 2,
                "the literal and the code occurrence, and neither comment: \(stripped)")
        #expect(stripped.contains("\"marker\""))
    }

    /// Load-bearing: the two views and the raw source share one character
    /// indexing, which is what lets a span found in the strict view be
    /// sliced out of the literal view without searching for it again.
    @Test func bothModesPreserveLengthAndLineStructure() throws {
        let source = """
            /* a
               block */
            let a = "one \\" two"
            // trailing
            let b = \"\"\"
                multi
                line
                \"\"\"
            """
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        let literals = try SwiftSource.blankingComments(source)
        #expect(strict.count == source.count)
        #expect(literals.count == source.count)
        let lineCount = { (text: String) in
            text.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        #expect(lineCount(strict) == lineCount(source))
        #expect(lineCount(literals) == lineCount(source))
    }

    /// A `//` inside a string literal is not a comment — the walker parses
    /// literals in both modes, and only decides afterwards whether to emit
    /// them.
    @Test func aSlashPairInsideALiteralDoesNotStartAComment() throws {
        let source = "let url = \"https://example.test\"\nlet after = marker"
        #expect(try SwiftSource.blankingCommentsAndStrings(source).contains("marker"))
        #expect(try SwiftSource.blankingComments(source).contains("marker"))
    }

    /// Fail-closed: a raw-string delimiter (`#"…"#`) is a form this stripper
    /// does not parse. Left unhandled it desynchronizes the plain-quote
    /// counting instead, and whatever a guard was looking for past that
    /// point vanishes from the scan along with it — while the guard reports
    /// success. So it must throw, in both modes.
    @Test func stripperFailsClosedOnARawStringDelimiter() {
        let source = "static let quote = #\"\"\"#\nstate = .failed(message: m)"
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingCommentsAndStrings(source)
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingComments(source)
        }
    }

    /// Fail-closed: a string or block comment that never closes must not be
    /// treated as "closed at end of file" — the same truncation risk under a
    /// different cause.
    @Test func stripperFailsClosedOnAnUnterminatedLiteral() {
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingCommentsAndStrings("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingCommentsAndStrings("/* never closes")
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingComments("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingComments("/* never closes")
        }
    }
}
