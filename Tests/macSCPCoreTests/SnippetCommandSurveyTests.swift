import Foundation
import Testing

@testable import macSCPCore

@Suite("SnippetCommandSurvey")
struct SnippetCommandSurveyTests {
    /// The placement `survey` gives the first occurrence of `needle`, or
    /// `nil` when no single recognised span contains it. A `nil` here is the
    /// recogniser's whole point: reached, not classified, therefore unsafe.
    private func placement(
        of needle: String, in command: String
    ) -> SnippetCommandSurvey.Placement? {
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(command),
              let occurrence = command.range(of: needle)
        else { return nil }
        return SnippetCommandSurvey.placement(of: occurrence, in: spans)
    }

    private func refusal(_ command: String) -> SnippetCommandSurvey.Refusal? {
        guard case .refused(let refusal) = SnippetCommandSurvey.survey(command) else { return nil }
        return refusal
    }

    // MARK: - The one safe placement

    @Test(
        "an unquoted argument of a top-level command is recognised as an argument",
        arguments: [
            "echo {{X}}",
            "mysqldump {{X}} > out.sql",
            "scp -i {{X}} host:/path",
            "tar -czf backup.tgz --exclude={{X}} /srv",
            #"echo \"{{X}}\""#,
            "echo \"quoted\" {{X}}",
            "echo a#b {{X}}",
            "echo {{X}} # a comment with a ' in it",
            "cd /srv && ./run.sh {{X}}",
            "ls | grep {{X}}",
            "{ echo {{X}}; }",
            "if [ -f {{X}} ]; then echo yes; fi",
            "DB=live ./backup.sh {{X}}",
            "awk '{print $1}' {{X}}",
        ])
    func anUnquotedArgumentIsSafe(command: String) {
        #expect(placement(of: "{{X}}", in: command) == .argument)
    }

    /// The `#` rule a shell actually has: a comment starts only at a word
    /// start. Reading `a#b` as "everything after `#` is a comment" is what
    /// blinded the previous gate to fifteen templates, so the two halves are
    /// pinned separately — mid-word `#` is literal, word-start `#` is not.
    @Test func aHashInsideAWordIsLiteralAndAHashAtAWordStartIsAComment() {
        #expect(placement(of: "{{X}}", in: "echo a#b {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo a#b # {{X}}") == .comment)
        #expect(placement(of: "{{X}}", in: "echo a#b\n# {{X}}") == .comment)
        #expect(placement(of: "{{X}}", in: "echo hi;# {{X}}") == .comment)
    }

    // MARK: - Placements that are not safe

    @Test(
        "a placeholder inside quotes is recognised as quoted",
        arguments: [
            #"echo "{{X}}""#,
            "echo '{{X}}'",
            #"echo x#y"{{X}}"z"#,
            #"echo "a\"{{X}}""#,
            #"echo a#b "{{X}}""#,
            "echo a#b '{{X}}'",
            #"V=a#b; echo "{{X}}""#,
        ])
    func aQuotedPlaceholderIsRecognisedAsQuoted(command: String) {
        #expect(placement(of: "{{X}}", in: command) == .quoted)
    }

    @Test("the command word itself is not an argument") func commandNamePlacement() {
        #expect(placement(of: "{{X}}", in: "{{X}} --flag") == .commandName)
    }

    @Test("a redirection target is not an argument") func redirectionTargetPlacement() {
        #expect(placement(of: "{{X}}", in: "echo hi > {{X}}") == .redirectionTarget)
    }

    /// A comment looks inert and is not: a value carrying a newline ends the
    /// comment, and what follows the newline is code again.
    @Test("a comment is not an argument") func commentPlacement() {
        #expect(placement(of: "{{X}}", in: "echo hi # note {{X}}") == .comment)
    }

    /// The structural default in one assertion: a placeholder that straddles
    /// a boundary sits in no single span, so it is classified as nothing —
    /// and "nothing" is what the caller must treat as unsafe.
    @Test(
        "a placeholder that straddles a boundary is classified as nothing",
        arguments: [
            #"echo "{{X"}}"#,
            "echo {{X$}}",
        ])
    func aStraddlingPlaceholderIsUnclassified(command: String) {
        #expect(placement(of: "{{X", in: command) != .argument)
    }

    // MARK: - Refusals

    @Test(
        "a here-document is refused",
        arguments: [
            "cat <<EOF\n{{X}}\nEOF",
            "cat <<-EOF\n{{X}}\nEOF",
            "cat <<'EOF'\n{{X}}\nEOF",
            "cat <<<{{X}}",
            "echo a#b\ncat <<EOF\n{{X}}\nEOF",
        ])
    func aHeredocIsRefused(command: String) {
        #expect(refusal(command) == .heredoc)
    }

    @Test(
        "a command inside a command is refused",
        arguments: [
            "echo $(id -u) {{X}}",
            "echo `id -u` {{X}}",
            "(cd /srv && echo {{X}})",
            "diff {{X}} < <(sort b)",
            "tee >(cat) {{X}}",
            #"echo "value $(id -u)" {{X}}"#,
            "echo \"value `id -u`\" {{X}}",
        ])
    func aNestedCommandIsRefused(command: String) {
        #expect(refusal(command) == .commandSubstitution)
    }

    @Test(
        "an expansion that is not a plain variable is refused",
        arguments: [
            "echo $(({{X}}))",
            "echo ${HOME} {{X}}",
            "echo $'a\\nb' {{X}}",
            "echo $\"a\" {{X}}",
            "echo $ {{X}}",
            "echo $? {{X}}",
            #"echo "${HOME}" {{X}}"#,
        ])
    func anUnreadableExpansionIsRefused(command: String) {
        #expect(refusal(command) == .expansion)
    }

    /// A plain `$NAME` or `$1` stays readable — refusing those would make
    /// half of all real snippets unusable, and neither can contain a
    /// placeholder or change anyone's quoting state.
    @Test(
        "a plain variable reference is not a refusal",
        arguments: [
            "cp {{X}} $HOME/backup",
            "echo $1 {{X}}",
            #"echo "in $HOME" {{X}}"#,
        ])
    func aPlainVariableReferenceIsRead(command: String) {
        #expect(refusal(command) == nil)
        #expect(placement(of: "{{X}}", in: command) == .argument)
    }

    @Test(
        "a command that re-parses its arguments is refused",
        arguments: [
            "eval {{X}}",
            "command eval {{X}}",
            "builtin eval {{X}}",
            "DB=live eval {{X}}",
            "echo hi && eval {{X}}",
            "if eval {{X}}; then echo yes; fi",
        ])
    func aReparsingCommandIsRefused(command: String) {
        #expect(refusal(command) == .evaluation)
    }

    /// `"eval" {{X}}` is why a command name must be one plain literal word:
    /// a shell still runs `eval` there, and a name this recogniser cannot
    /// read cannot be compared against anything.
    @Test(
        "a command name that is not a plain literal word is refused",
        arguments: [
            #""eval" {{X}}"#,
            "'eval' {{X}}",
            "e\\val {{X}}",
            "$SHELL {{X}}",
        ])
    func anUnreadableCommandNameIsRefused(command: String) {
        #expect(refusal(command) != nil)
    }

    @Test(
        "quoting that does not close on its line is refused",
        arguments: [
            "echo \"abc",
            "echo 'abc",
            "echo \"spans\nlines\"",
            #"echo "a\""#,
            "echo 'unterminated {{X}}",
        ])
    func unbalancedQuotingIsRefused(command: String) {
        #expect(refusal(command) == .unbalancedQuoting)
    }

    @Test(
        "quoting that opens and closes on one line is read",
        arguments: [
            "echo 'a b' \"c d\"",
            #"echo "a\"b""#,
            "echo no quotes at all",
            "echo 'first'\necho \"second\"",
            "echo 'a # b' # a real comment with a ' in it",
        ])
    func balancedQuotingIsRead(command: String) {
        #expect(refusal(command) == nil)
    }

    /// The text running out mid-construct. There is no "well, probably a
    /// literal backslash" branch, because guessing is the failure mode this
    /// type exists to remove.
    @Test func aDanglingEscapeIsRefused() {
        #expect(refusal("echo {{X}} \\") == .unrecognizedSyntax)
    }

    // MARK: - The alphabet the reader works in

    /// A quote carrying a combining mark is one Swift `Character` that
    /// compares unequal to `"'"`. Reading shell text in `Character`s
    /// therefore walked straight past it, stayed in the unquoted state, and
    /// emitted an `.argument` span over a placeholder a shell reads as
    /// quoted — fourteen templates of this shape were accepted and executed
    /// their payload. Positive recognition is no defence when the span
    /// itself is wrong, which is why the reader now works in
    /// `Unicode.Scalar`s (see `ShellScalar`).
    @Test(
        "a quote carrying a combining mark still opens a quoted span",
        arguments: ["\u{0308}", "\u{FE0F}", "\u{200D}", "\u{0300}", "\u{20E3}", "\u{1AB0}"])
    func aDecoratedQuoteIsSeen(mark: String) {
        #expect(placement(of: "{{X}}", in: "echo x'\(mark){{X}}'\(mark)") == .quoted)
        #expect(placement(of: "{{X}}", in: "echo x\"\(mark){{X}}\"\(mark)") == .quoted)
    }

    /// The other half of that: reading in scalars is not "refuse anything
    /// containing a combining mark". A mark on ordinary text changes
    /// nothing, and marking only ONE quote of a pair still leaves a
    /// perfectly balanced pair — the mark is content, exactly as a shell
    /// reads it. (Under the old `Character` reading a single marked quote
    /// looked like an odd number of quotes and came out `.unbalancedQuoting`
    /// by accident, which is a right answer for a wrong reason.)
    @Test func aCombiningMarkIsOtherwiseOrdinaryContent() {
        #expect(placement(of: "{{X}}", in: "echo mu\u{0308}nchen {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo x\u{0308} {{X}}") == .argument)
        #expect(refusal("echo x'\u{0308}{{X}}'") == nil)
        #expect(placement(of: "{{X}}", in: "echo x'\u{0308}{{X}}'") == .quoted)
        #expect(placement(of: "{{X}}", in: "echo x'{{X}}'\u{0308}") == .quoted)
    }

    /// The line-handling check the scalar decision owes: `"\r\n"` is one
    /// `Character` and two scalars, so a scalar walk sees two line breaks
    /// where a character walk saw one. Both are state resets, so the
    /// outcomes are unchanged — verified here rather than assumed.
    @Test func carriageReturnsAreStillLineBreaks() {
        #expect(refusal("echo \"a\r\nb\" {{X}}") == .unbalancedQuoting)
        #expect(refusal("echo \"a\rb\" {{X}}") == .unbalancedQuoting)
        #expect(placement(of: "{{X}}", in: "echo foo\r\necho {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo foo\recho {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo hi # note\r\necho {{X}}") == .argument)
    }

    // MARK: - Containment, not overlap

    /// `placement(of:in:)` requires containment in ONE span, and two spans
    /// that abut do not add up to one. Built by hand because the shapes that
    /// produce it through `survey` are few: a range covering the end of one
    /// span and the start of the next is exactly the "classified by no
    /// rule" case, and it must come out `nil` rather than picking whichever
    /// span it happens to touch first.
    @Test func aRangeStraddlingTwoAbuttingSpansIsUnclassified() {
        let text = "abcdef"
        let middle = text.index(text.startIndex, offsetBy: 3)
        let spans = [
            SnippetCommandSurvey.Span(placement: .argument, range: text.startIndex..<middle),
            SnippetCommandSurvey.Span(placement: .argument, range: middle..<text.endIndex),
        ]
        let straddling =
            text.index(text.startIndex, offsetBy: 2)..<text.index(text.startIndex, offsetBy: 4)
        #expect(SnippetCommandSurvey.placement(of: straddling, in: spans) == nil)
        #expect(
            SnippetCommandSurvey.placement(of: text.startIndex..<middle, in: spans) == .argument)
    }

    // MARK: - The gate is not the highlighter

    /// Review rounds travelled the path "a change made for colouring moved a
    /// security verdict". They cannot any more, because the gate shares no
    /// code with the highlighter — and this test is what keeps that
    /// structural, rather than a thing somebody remembers.
    ///
    /// The scope is DERIVED, not listed: every Swift file under
    /// `Sources/macSCPCore` except the highlighter's own is scanned, so a
    /// third file introduced into the gate path is covered the moment it
    /// exists. An earlier version named two files, and a helper the survey
    /// delegated to would have slipped between them. The App layer is out of
    /// scope on purpose — colouring a text field is the highlighter's job
    /// and `SnippetCommandEditor` is supposed to call it.
    ///
    /// A source scan, in the idiom the App layer's wiring guards already
    /// use: `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/…`, so three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory. Fail-closed: if the directory
    /// cannot be walked, the test errors rather than passing.
    @Test func noCoreFileButTheHighlighterItselfNamesTheHighlighter() throws {
        let files = try Self.coreSourceFiles()
        #expect(!files.isEmpty, "the Core source tree could not be walked")
        for file in files where file.lastPathComponent != "SnippetHighlighter.swift" {
            let code = try Self.codeLines(of: file)
            #expect(!code.contains { $0.contains("SnippetHighlighter") }, """
                \(file.lastPathComponent) reaches into SnippetHighlighter. The highlighter is a \
                colouring tokenizer whose approximations are invisible when colouring and \
                load-bearing when gating; sharing it is how review round after review round got \
                a payload past this check.
                """)
        }
    }

    /// The comparison-unit decision, kept structural in the same way.
    ///
    /// `replacingOccurrences(of:with:)` matches on extended grapheme
    /// clusters and canonical equivalence, so escaping a shell or markup
    /// metacharacter with it silently misses every occurrence that carries a
    /// combining mark — which is how a value broke out of the single quotes
    /// the quoter had just put around it. Also derived rather than listed:
    /// the whole Core tree is scanned for the shape, so a new copy of the
    /// mistake anywhere in Core fails here rather than waiting for a review.
    @Test func noCoreFileEscapesAMetacharacterWithReplacingOccurrences() throws {
        let metacharacters = ["'", "\\\"", "`", "$", "&", "<", ">", ";", "|", "#", "\\\\"]
        let needles = metacharacters.map { #"replacingOccurrences(of: ""# + $0 + "\"" }
        for file in try Self.coreSourceFiles() {
            let code = try Self.codeLines(of: file)
            for needle in needles {
                #expect(!code.contains { $0.contains(needle) }, """
                    \(file.lastPathComponent) escapes a metacharacter with \
                    replacingOccurrences, which matches on grapheme clusters and misses any \
                    occurrence carrying a combining mark. Decide it one Unicode.Scalar at a \
                    time instead — see ShellScalar.
                    """)
            }
        }
    }

    /// Every `.swift` file under `Sources/macSCPCore`.
    private static func coreSourceFiles() throws -> [URL] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let core = repoRoot.appendingPathComponent("Sources/macSCPCore")
        let contents = try FileManager.default.subpathsOfDirectory(atPath: core.path)
        return contents
            .filter { $0.hasSuffix(".swift") }
            .map { core.appendingPathComponent($0) }
    }

    /// The lines of `file` that are not whole-line comments — so a doc
    /// comment may name what the code may not.
    private static func codeLines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
