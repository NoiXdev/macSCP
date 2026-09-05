import MacSCPTestSupport
import Testing

/// The stripper's own behaviour, stated in one place rather than inside the
/// first suite that needed it: what each mode blanks, what both preserve,
/// and what it does at the end of a file it cannot parse.
///
/// This suite is the convergence point for what used to be two separate
/// self-test suites (`Tests/macSCPAppKitTests/SwiftSourceStripping.swift`
/// and `Tests/macSCPCoreTests/SwiftSourceStripping.swift`, both deleted) plus
/// three private strippers with no self-tests of their own beyond a fail-
/// closed check (`ReconnectWiringGuardTests`, `TabContextMenuWiringGuardTests`,
/// `ConnectingAttemptWiringGuardTests`, all in `macSCPAppKitTests`) — four
/// separate comment/string strippers in that target alone, per
/// `docs/BACKLOG.md`'s "Polish: terminal resize, transfer cancel and paths"
/// row. It lives in `macSCPCoreTests` rather than `macSCPAppKitTests` because
/// the shared implementation now lives in the plain `MacSCPTestSupport`
/// target both test targets depend on, and this is a test of that target,
/// not of anything AppKit-specific.
@Suite("Swift source stripping (shared)")
struct SwiftSourceStrippingTests {
    private static let sample = """
        // marker
        let text = "marker"
        /* marker */
        let real = marker
        """

    /// The strict view: only the occurrence in CODE survives. This is the
    /// property a planted doc comment once defeated on the AppKit target's
    /// transfer-bar guards (see the type's own doc comment).
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
    /// indexing (length AND line count preserved), which is what lets a
    /// span found in the strict view be sliced out of the literal view
    /// without searching for it again — and what makes the compatibility
    /// names (`stripCommentsAndStrings`/`stripComments`) a safe stand-in for
    /// the older, non-length-preserving Core implementation they replace:
    /// every caller migrated onto them read only line counts or
    /// `contains`/`split`, never an absolute length.
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

    /// An interpolation may carry string literals of its own, and their
    /// quotes are not the outer literal's closing quote. Read as a plain
    /// escape pair — which every converged stripper except the AppKit
    /// ancestor did — `\(` leaves the walker hunting for the next `"`,
    /// which is the OPENING quote of the nested literal; everything after it
    /// is emitted as code, so a needle planted in a quoted string satisfies
    /// a structural check.
    @Test func anInterpolationsOwnLiteralsDoNotLeakOutAsCode() throws {
        let source = "let t = \"a \\(\"b\" + \"c\") d\"\nlet after = marker"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(strict.count == source.count)
        let firstLine = String(
            strict.split(separator: "\n", omittingEmptySubsequences: false)[0])
        #expect(firstLine.trimmingCharacters(in: .whitespaces) == "let t =", """
            everything from the opening quote to the literal's real closing quote \
            must be blanked, interpolation included: \(firstLine)
            """)
        #expect(strict.contains("marker"), "the code after the literal must survive")
    }

    /// The same hole with a call inside the interpolation rather than an
    /// operator — the shape a real hint or format string takes.
    @Test func anInterpolatedCallCarryingALiteralDoesNotLeakOutAsCode() throws {
        let source = "let u = \"x \\(f(\"y\")) z\"\nlet after = marker"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(strict.count == source.count)
        let firstLine = String(
            strict.split(separator: "\n", omittingEmptySubsequences: false)[0])
        #expect(firstLine.trimmingCharacters(in: .whitespaces) == "let u =", """
            the interpolation's parentheses and its own literal must be blanked \
            with the literal that contains them: \(firstLine)
            """)
        #expect(strict.contains("marker"))
    }

    /// The consequence that reaches guards which count braces: a brace
    /// leaked out of an interpolated literal desynchronises a
    /// declaration-body range, so a body span ends early or late and every
    /// check over it reads the wrong region.
    @Test func aBraceInsideAnInterpolatedLiteralNeverReachesTheBraceCounter() throws {
        let source = "let v = \"a \\(x ?? \"}\") b\"\nfunc f() { }"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        let braces = strict.filter { $0 == "}" }.count
        #expect(braces == 1, """
            only the one brace in CODE may reach the counter — found \(braces) in \
            \(strict)
            """)
    }

    /// The literal-keeping view is unchanged by the same walk: an
    /// interpolation is part of the literal, so it survives verbatim.
    @Test func theLiteralViewKeepsAnInterpolationWhole() throws {
        let source = "let t = \"a \\(\"b\" + \"c\") d\"\nlet after = marker"
        let kept = try SwiftSource.blankingComments(source)
        #expect(kept.count == source.count)
        #expect(kept.contains("\"a \\(\"b\" + \"c\") d\""))
    }

    /// Raw strings (`#"…"#`, any hash count, single- or triple-quoted) are
    /// PARSED now, not fail-closed — the capability `TabContextMenuWiringGuardTests`'s
    /// own private stripper carried and the other three converged strippers
    /// did not. Content is blanked in the strict view, kept in the literal
    /// view, exactly like a plain string literal.
    @Test func rawStringsAreParsedInBothModes() throws {
        let single = "let a = #\"a \"quote\" b\"#\nlet after = marker"
        let strictSingle = try SwiftSource.blankingCommentsAndStrings(single)
        #expect(strictSingle.count == single.count)
        #expect(strictSingle.contains("marker"))
        #expect(!strictSingle.contains("quote"))
        let keptSingle = try SwiftSource.blankingComments(single)
        #expect(keptSingle.contains("#\"a \"quote\" b\"#"))

        let extraHashes = "let b = ##\"a \"# b\"##\nlet after = marker"
        let strictHashes = try SwiftSource.blankingCommentsAndStrings(extraHashes)
        #expect(strictHashes.count == extraHashes.count)
        #expect(strictHashes.contains("marker"))

        let multiline = """
            let c = #\"\"\"
                one "# two
                \"\"\"#
            let after = marker
            """
        let strictMultiline = try SwiftSource.blankingCommentsAndStrings(multiline)
        #expect(strictMultiline.count == multiline.count)
        #expect(strictMultiline.contains("marker"))
    }

    /// `#"""#` — an entirely ordinary SINGLE-line raw string whose one
    /// character of content happens to be `"` — is the exact shape that
    /// used to desynchronize the plain-quote counting in every stripper
    /// this one converged (`ReconnectWiringGuardTests`, before this
    /// suite's own convergence, carried the regression test for that
    /// original failure; this pins the shape directly, against the shared
    /// stripper itself). Three quotes together are not automatically a
    /// triple-quote OPEN: reading it as one would send the walker hunting
    /// for a closing `"""#` that this one-line input never has.
    @Test func aRawStringWithOneQuoteOfContentIsNotMisreadAsATripleQuoteOpen() throws {
        let source = "static let quote = #\"\"\"#\nlet after = marker"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(strict.count == source.count)
        #expect(strict.contains("marker"))
        let kept = try SwiftSource.blankingComments(source)
        #expect(kept.contains("#\"\"\"#"))
    }

    /// A multiline opener's `"""` may be followed by trailing spaces/tabs
    /// before the line break (SE-0168) — a formatter or an editor's
    /// trim-on-save can leave exactly that on the OPENER's own line even
    /// when it strips trailing whitespace everywhere else, since the
    /// content of a multiline literal is deliberately left alone.
    ///
    /// The content is built to make a wrong classification OBSERVABLE, not
    /// just theoretical: it embeds `"#`, one quote directly followed by
    /// one hash — exactly the terminator `opensMultilineLiteral` returning
    /// `false` would make the raw-string opener hunt for (a lone-quote
    /// close, `quotes: 1`, instead of the real `quotes: 3` terminator).
    /// Misread as trailing whitespace defeating the line-break check, the
    /// raw string would close right there, mid-content — and everything
    /// from that point on, `marker` included, would read as ordinary CODE
    /// instead of literal content, surviving in the STRICT (blanked) view
    /// where it must not. This is exactly the `#"""#` failure shape
    /// (`aRawStringWithOneQuoteOfContentIsNotMisreadAsATripleQuoteOpen`
    /// above) reached through trailing whitespace instead of through a
    /// single-character raw string.
    @Test func aMultilineOpenerTakesTrailingWhitespaceBeforeTheLineBreak() throws {
        let plain = "let a = \"\"\"   \nmarker\n\"\"\"\nlet after = code"
        let strictPlain = try SwiftSource.blankingCommentsAndStrings(plain)
        #expect(strictPlain.count == plain.count)
        #expect(strictPlain.contains("after = code"))
        #expect(!strictPlain.contains("marker"), """
            trailing whitespace before the opener's line break must not \
            stop the plain triple-quote opener from being recognised: \
            \(strictPlain)
            """)

        // The discriminating case: an embedded `"#` inside the content, on
        // the RAW-string opener (`opensMultilineLiteral`'s other caller).
        let raw = "let c = #\"\"\"   \nprefix \"# marker suffix\n\"\"\"#\nlet after = code"
        let strictRaw = try SwiftSource.blankingCommentsAndStrings(raw)
        #expect(strictRaw.count == raw.count)
        #expect(strictRaw.contains("after = code"))
        #expect(!strictRaw.contains("marker"), """
            trailing whitespace before the opener's line break must not \
            make the raw-string opener misread itself as a lone-quote \
            closer, closing early on the embedded `"#` instead of the \
            real terminator at the end: \(strictRaw)
            """)
    }

    /// The same rule accepts `\r\n` in place of a bare `\n` — a real form,
    /// not a hypothetical one: a file saved with Windows line endings
    /// carries it on every line, opener included. Same discriminating
    /// shape as the trailing-whitespace case above, so a wrong
    /// classification is observable rather than merely theoretical.
    @Test func aMultilineOpenerAcceptsCarriageReturnLineFeedLineEndings() throws {
        let plain = "let b = \"\"\"\r\nmarker\r\n\"\"\"\r\nlet after = code"
        let strictPlain = try SwiftSource.blankingCommentsAndStrings(plain)
        #expect(strictPlain.count == plain.count)
        #expect(strictPlain.contains("after = code"))
        #expect(!strictPlain.contains("marker"))

        let raw = "let d = #\"\"\"\r\nprefix \"# marker suffix\r\n\"\"\"#\r\nlet after = code"
        let strictRaw = try SwiftSource.blankingCommentsAndStrings(raw)
        #expect(strictRaw.count == raw.count)
        #expect(strictRaw.contains("after = code"))
        #expect(!strictRaw.contains("marker"), """
            `\\r\\n` after the opener's triple quote must not make the \
            raw-string opener misread itself as a lone-quote closer, \
            closing early on the embedded `"#` instead of the real \
            terminator at the end: \(strictRaw)
            """)
    }

    /// Extended regex literals (`#/…/#`) are parsed the same way — the bare
    /// form (`/…/`) is deliberately NOT parsed anywhere in this stripper's
    /// history: it cannot be told from division without parsing Swift, and
    /// every converged implementation would rather read one as code than
    /// guess.
    @Test func extendedRegexLiteralsAreParsed() throws {
        let source = "let r = #/a\\/b/#\nlet after = marker"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(strict.count == source.count)
        #expect(strict.contains("marker"))
    }

    /// A bare `#` before a macro (`#expect`, `#selector`, `#if`, …) is
    /// ordinary code, not a delimiter, and must fall through unconsumed.
    @Test func aBareHashBeforeAMacroIsOrdinaryCode() throws {
        let source = "#expect(entries.isEmpty)"
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(strict == source)
    }

    /// Fail-closed: a string or block comment, or a raw-string/regex
    /// delimiter, that never closes must not be treated as "closed at end
    /// of file" — the alternative is a scan that silently reads less than
    /// the file it claims to have checked.
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
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingCommentsAndStrings("let x = #\"unterminated raw")
        }
        #expect(throws: (any Error).self) {
            try SwiftSource.blankingCommentsAndStrings("let r = #/unterminated")
        }
    }

    /// The compatibility names forward to the blanking implementation
    /// exactly — no behavioural drift between the two spellings.
    @Test func compatibilityNamesForwardToBlanking() throws {
        #expect(try SwiftSource.stripCommentsAndStrings(Self.sample)
            == SwiftSource.blankingCommentsAndStrings(Self.sample))
        #expect(try SwiftSource.stripComments(Self.sample)
            == SwiftSource.blankingComments(Self.sample))
    }
}
