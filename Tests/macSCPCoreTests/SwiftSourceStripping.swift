import Foundation
import Testing

/// Blanking comments and string literals, for this target's source scans.
///
/// A guard that reads raw source cannot tell a call from a sentence about
/// a call: a doc comment naming the thing it looks for satisfies it, and a
/// commented-out line trips it. Both were measured on this branch, which is
/// why every scan in this target runs over stripped text.
///
/// It lives here rather than inside one suite because more than one guard
/// in this target reads Swift source, and a second hand-rolled parser
/// beside the first would be a second thing to keep fail-closed — with the
/// self-tests below covering only one of them.
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

    /// Strips `//` and `/* */` comments and string literals, preserving
    /// line breaks so a scan can still work line by line — a commented-out
    /// or quoted occurrence must neither trip a guard nor satisfy one.
    ///
    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end of the file without finding what it was looking
    /// for. Both throw rather than return whatever was collected so far —
    /// the alternative is a scan that silently reads less than the file it
    /// claims to have checked.
    static func stripCommentsAndStrings(_ source: String) throws -> String {
        try walk(source, keepingStringContents: false)
    }

    /// Blanks comments and keeps string literals — the other half a scan may
    /// need, and the reason it exists: blanking a literal blanks what it
    /// INTERPOLATES along with it, because a literal is consumed to its
    /// closing quote as one span. A rule about what a sentence may be built
    /// out of therefore cannot be checked on text this type has blanked; it
    /// has to read the literal and blank only the comments, so that a comment
    /// describing the forbidden shape still neither trips the check nor
    /// satisfies it.
    ///
    /// Fails closed on exactly the same two forms, for the same reason.
    static func stripComments(_ source: String) throws -> String {
        try walk(source, keepingStringContents: true)
    }

    /// The one walker both entry points above run, so there is a single
    /// place where a delimiter is recognised and a single place that decides
    /// what a file this stripper cannot parse does.
    ///
    /// `keepStringContents` changes only what is APPENDED for a literal, never
    /// how far the walk consumes: a literal is consumed to its closing
    /// delimiter either way, so a `//` or a `/*` inside one is never read as
    /// a comment in either mode.
    private static func walk(
        _ source: String, keepingStringContents keepStringContents: Bool
    ) throws -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    throw StripError.unrecognizedDelimiter
                }
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                let start = i
                i += 3
                var blanked = ""
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    blanked.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw StripError.unterminatedLiteral }
                i += 3
                if keepStringContents {
                    result.append(contentsOf: chars[start..<i])
                } else {
                    result.append(blanked)
                    result.append(" ")
                }
                continue
            }
            if c == "\"" {
                let start = i
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw StripError.unterminatedLiteral }
                i += 1
                if keepStringContents {
                    result.append(contentsOf: chars[start..<i])
                } else {
                    result.append(" ")
                }
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return result
    }
}

/// The stripper's own fail-closed cases, kept beside it rather than in the
/// suite that first needed them, so that what it does at the end of a file
/// it cannot parse is stated in one place.
///
/// Five suites in this target read what `stripCommentsAndStrings` returns,
/// counted in the pass that writes this sentence (it said four before that
/// pass, and `BackendDescriptorHostKeyWiringGuardTests` is the one that
/// joined them): `ConnectionViewModelSourceGuardTests`,
/// `PKCS12ImportIsolationGuardTests`, `DiagnosticsNoDescribingGuardTests`,
/// `BackendDescriptorHostKeyWiringGuardTests`, and the self-tests below.
/// That last suite is also the only caller of
/// `stripComments`, counted in the same pass. Two others
/// scan Swift source with blankers of their own and are NOT covered by
/// anything here — `IconTooltipLintTests` (its own `code(of:)`) and
/// `SnippetCommandSurveyTests`. Whether those fail closed is their own
/// question; this comment used to say "every guard in this target", which
/// would have let an audit of fail-closed behaviour stop here and miss both.
@Suite("Swift source stripping")
struct SwiftSourceStrippingTests {
    /// Comments and string literals must be blanked, and line structure
    /// must survive — a scan that reads line by line would otherwise see
    /// two statements joined into one.
    @Test func aQuotedOrCommentedOccurrenceSurvivesAsNeither() throws {
        let stripped = try SwiftSource.stripCommentsAndStrings("""
            // marker
            let text = "marker"
            /* marker */
            let real = marker
            """)
        #expect(stripped.split(separator: "\n").count == 4)
        #expect(stripped.components(separatedBy: "marker").count - 1 == 1,
                "only the one occurrence in code should survive: \(stripped)")
    }

    /// The complementary mode: comments go, literals stay — including what
    /// a literal interpolates, which is the whole reason the second entry
    /// point exists. A comment naming the same shape must still vanish, or
    /// the two modes would differ in what they hide rather than in what they
    /// keep.
    @Test func commentsGoAndLiteralsStay() throws {
        let stripped = try SwiftSource.stripComments("""
            // marker
            let text = "a \\(marker) sentence"
            /* marker */
            let real = marker
            """)
        #expect(stripped.split(separator: "\n").count == 4)
        #expect(stripped.components(separatedBy: "marker").count - 1 == 2,
                "the literal's interpolation and the code line should survive: \(stripped)")
    }

    /// A `//` inside a literal is part of the literal, not the start of a
    /// comment — the failure this mode would otherwise have: a line-comment
    /// strip that runs before the literal is recognised blanks the rest of
    /// the line, and a check reading that line could never match anything
    /// after an endpoint's scheme separator.
    @Test func aSlashPairInsideALiteralDoesNotStartAComment() throws {
        let stripped = try SwiftSource.stripComments("""
            let endpoint = "https://host/x" + marker
            """)
        #expect(stripped.contains("marker"))
    }

    /// Fail-closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse. Left unhandled, it used to desynchronize
    /// the plain-quote counting instead — `#"""#`, an entirely ordinary
    /// literal for one quote character, is read as one opening quote, one
    /// closing quote, and a fresh string that swallows everything up to the
    /// next real `"` in the file, which could be far below. Whatever a
    /// guard was looking for past that point would vanish from the scan
    /// along with it, and the guard would report success. So it must throw.
    @Test func stripperFailsClosedOnARawStringDelimiter() throws {
        let source = "static let quote = #\"\"\"#\nstate = .failed(message: m, field: f)"
        #expect(throws: (any Error).self) {
            try SwiftSource.stripCommentsAndStrings(source)
        }
    }

    /// Fail-closed: a string or block comment that never closes must not be
    /// treated as "closed at end of file" — that is the same truncation
    /// risk under a different cause.
    @Test func stripperFailsClosedOnAnUnterminatedLiteral() throws {
        #expect(throws: (any Error).self) {
            try SwiftSource.stripCommentsAndStrings("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.stripCommentsAndStrings("/* never closes")
        }
    }
}
