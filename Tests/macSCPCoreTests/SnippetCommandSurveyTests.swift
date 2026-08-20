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

    // MARK: - The gate is not the highlighter

    /// Three review rounds travelled the path "a change made for colouring
    /// moved a security verdict". They cannot any more, because the two
    /// share no code — and this test is what keeps that structural, rather
    /// than a thing somebody remembers.
    ///
    /// A source scan, in the idiom the App layer's wiring guards already
    /// use: `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/…`, so three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory.
    @Test func neitherTheRecogniserNorTheGateCallsTheHighlighter() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "Sources/macSCPCore/Terminal/SnippetCommandSurvey.swift",
            "Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift",
        ] {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            let code = source
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!code.contains { $0.contains("SnippetHighlighter") }, """
                \(relativePath) reaches into SnippetHighlighter. The highlighter is a colouring \
                tokenizer whose approximations are invisible when colouring and load-bearing \
                when gating; sharing it is how four review rounds got a payload past this check.
                """)
        }
    }
}
