import Testing
@testable import macSCPCore

@Suite("SnippetVariableSubstitution")
struct SnippetVariableSubstitutionTests {
    private func placeholder(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    private func environment(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
    }

    @Test("a placeholder is replaced by the quoted value")
    func placeholderIsQuoted() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "mysqldump {{DB}} > out.sql", variables: [placeholder("DB")],
            values: ["DB": "kunden db"])
        #expect(resolved == "mysqldump 'kunden db' > out.sql")
    }

    @Test("a value that tries to inject a command stays one word")
    func placeholderValueCannotInject() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{MSG}}", variables: [placeholder("MSG")],
            values: ["MSG": "hi; rm -rf /"])
        #expect(resolved == "echo 'hi; rm -rf /'")
    }

    /// The collision this design had to answer: double braces occur in real
    /// commands. Only declared names are substituted, so a Go template
    /// survives untouched — no dialect, no escape rule.
    @Test("an undeclared double-brace expression is left alone")
    func undeclaredBracesSurvive() {
        let command = "kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{end}}'"
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [], values: [:])
        #expect(resolved == command)
    }

    @Test("an environment variable is prepended to a single-line command")
    func environmentSingleLine() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "./backup.sh", variables: [environment("DB")],
            values: ["DB": "kunden db"])
        #expect(resolved == "DB='kunden db' ./backup.sh")
    }

    /// A multi-line body cannot take a leading assignment on the same line —
    /// it would only scope to the first line. It becomes its own line, which
    /// is why the variable then outlives the run in that session.
    @Test("an environment variable becomes its own line for a multi-line body")
    func environmentMultiLine() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "cd /srv\nmake all", variables: [environment("DB")],
            values: ["DB": "x"])
        #expect(resolved == "DB='x'\ncd /srv\nmake all")
    }

    @Test("several environment variables keep declaration order")
    func environmentOrder() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "./run.sh", variables: [environment("A"), environment("B")],
            values: ["A": "1", "B": "2"])
        #expect(resolved == "A='1' B='2' ./run.sh")
    }

    @Test("a declared placeholder that appears nowhere is a problem")
    func unusedPlaceholderIsRejected() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: "ls -la", variables: [placeholder("DB")])
        #expect(problem == .unusedPlaceholder(name: "DB"))
    }

    /// Deliberately NOT a problem: an environment variable that the command
    /// never mentions is the normal case — the called script reads it.
    @Test("an environment variable the command never mentions is fine")
    func unmentionedEnvironmentIsFine() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: "./backup.sh", variables: [environment("DB")])
        #expect(problem == nil)
    }

    @Test("a placeholder inside quotes is a problem")
    func quotedPlaceholderIsRejected() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"echo "{{DB}}""#, variables: [placeholder("DB")])
        #expect(problem == .placeholderInsideQuotes(name: "DB"))
    }

    @Test("a placeholder outside quotes is fine even when the command has quotes elsewhere")
    func unquotedPlaceholderBesideQuotesIsFine() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"echo "start" {{DB}}"#, variables: [placeholder("DB")])
        #expect(problem == nil)
    }

    /// The bug an earlier review found by reproducing it: chaining
    /// `replacingOccurrences` calls re-scans an already-substituted value
    /// for the next variable's token. Here A's value literally contains
    /// `{{B}}`; a chained implementation would substitute inside A's
    /// already-emitted quotes and break them open. The expected output is
    /// exactly what a shell reads as two separate quoted words -- A's quotes
    /// still hold its `{{B}}` text as inert literal characters, and B is
    /// quoted on its own.
    @Test("an earlier placeholder's value cannot smuggle in a later placeholder's token")
    func chainedPlaceholderValueCannotEscapeQuotes() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{A}} {{B}}",
            variables: [placeholder("A"), placeholder("B")],
            values: ["A": "x {{B}} y", "B": "PWNED; touch /tmp/pwned"])
        #expect(resolved == "echo 'x {{B}} y' 'PWNED; touch /tmp/pwned'")
    }

    /// The exploit a review found by executing it, not reasoning about it:
    /// `PosixQuoting.singleQuoted` only protects a value in an UNQUOTED
    /// position. When the same declared name also occurs a second time
    /// inside the template's own double quotes, the value's emitted single
    /// quotes are literal characters there, while anything in the value
    /// that IS special inside double quotes -- `$(...)` command
    /// substitution -- stays live and runs. `scp -i {{KEY}} … && echo
    /// "used {{KEY}}"` is exactly this shape and an entirely ordinary thing
    /// to write, which is why every occurrence is checked, not just the
    /// first.
    @Test("a placeholder repeated once bare and once inside quotes is a problem")
    func repeatedPlaceholderInsideQuotesOnSecondOccurrenceIsRejected() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"echo {{DB}} "{{DB}}""#, variables: [placeholder("DB")])
        #expect(problem == .placeholderInsideQuotes(name: "DB"))
    }

    /// Guards against the fix overcorrecting into "any command containing
    /// quotes is rejected": two different placeholders, one of them right
    /// next to quoted text but never inside it, must both stay fine.
    @Test("two different placeholders near quotes, neither inside them, are fine")
    func twoDifferentPlaceholdersNearQuotesAreFine() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"scp -i {{KEY}} host:/path && echo "done" {{MSG}}"#,
            variables: [placeholder("KEY"), placeholder("MSG")])
        #expect(problem == nil)
    }

    // --- the class the review opened, closed ------------------------------

    /// Every template a whole-branch review got past this check, each one
    /// verified by the reviewer against real `bash`: the resolved string was
    /// executed and a `$(touch …)` payload carried in the VALUE ran, because
    /// `PosixQuoting.singleQuoted` only protects a value in an unquoted
    /// position and each template put it in a quoted one the check could not
    /// see.
    ///
    /// Three separate causes, one class: the tokenizer ended a comment at
    /// the end of the TEXT rather than the line (so a `#` anywhere killed
    /// every later `.string` token), it did not honour a backslash escape
    /// inside a double-quoted span (so `"a\"` looked closed), and a
    /// here-document cannot be expressed as a quote position at all. The
    /// first two are fixed in `SnippetHighlighter`; the third is refused
    /// (`Problem.unanalyzableContext`).
    ///
    /// The assertion is that the check REFUSES. The other acceptable outcome
    /// — accepted, and the resolved string runs the payload inertly — is not
    /// what any of these five do, and pinning "refused" is what would go red
    /// if one of the three causes came back.
    @Test(
        "every template the review broke the check with is refused",
        arguments: [
            #"echo {{X}} "{{X}}""#,
            "# note\necho \"{{X}}\"",
            "echo hi # note\necho \"{{X}}\"",
            #"echo "a\"{{X}}""#,
            "cat <<EOF\n{{X}}\nEOF",
        ])
    func theQuotedContextClassIsClosed(template: String) {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: template, variables: [placeholder("X")])
        #expect(problem != nil, """
            this template was accepted -- a review executed the resolved string against real \
            bash and a command substitution carried in the value ran. Whichever of the three \
            causes came back (comment-to-end-of-text, unhonoured backslash escape, \
            here-document), the value would be placed in a context the check cannot see.
            """)
    }

    /// The other direction, so the five above cannot be satisfied by
    /// refusing everything: an ordinary multi-line command with a comment in
    /// it, a placeholder outside quotes, still resolves — and to exactly the
    /// inert text a shell reads as one word.
    @Test("a multi-line command with a comment and an unquoted placeholder still resolves")
    func aCommentedMultiLineCommandWithAnUnquotedPlaceholderIsFine() {
        let command = "# back up the database\nmysqldump {{DB}} > out.sql"
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("DB")]) == nil)
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("DB")],
            values: ["DB": "$(touch /tmp/macscp-marker)"])
        #expect(resolved == "# back up the database\nmysqldump '$(touch /tmp/macscp-marker)' > out.sql")
    }

    // --- contexts the check refuses to analyse -----------------------------

    @Test(
        "a here-document is refused rather than analysed",
        arguments: [
            "cat <<EOF\n{{X}}\nEOF",
            "cat <<-EOF\n{{X}}\nEOF",
            "cat <<'EOF'\n{{X}}\nEOF",
            "cat <<<{{X}}",
        ])
    func aHeredocIsRefused(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
                == .unanalyzableContext(kind: .heredoc))
    }

    /// `<` and `<` with a space between them is process substitution, not a
    /// here-document — the refusal must not spread to it.
    @Test("a redirection followed by a process substitution is not a here-document")
    func aSpacedRedirectionIsNotAHeredoc() {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "diff {{A}} < <(sort b)", variables: [placeholder("A")]) == nil)
    }

    /// A `<<` inside a string or a comment is text, not an operator — the
    /// detector reads tokens, so it never sees one there.
    @Test(
        "a << inside a string or a comment is not a here-document",
        arguments: [
            #"echo "shift << 2" {{X}}"#,
            "echo {{X}} # pipe it with <<",
        ])
    func aQuotedOrCommentedShiftIsNotAHeredoc(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) == nil)
    }

    @Test(
        "quoting that does not close on its line is refused",
        arguments: [
            "echo 'unterminated {{X}}",
            "echo \"spans\nlines\" {{X}}",
        ])
    func unbalancedQuotingIsRefused(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
                == .unanalyzableContext(kind: .unbalancedQuoting))
    }

    /// Scoped to commands that declare a placeholder: the refusal exists to
    /// protect the quote-position check, and a here-document with no
    /// placeholder in it has nothing for that check to get wrong. An
    /// environment variable is prepended as its own assignment and never
    /// lands inside the command's quoting either.
    @Test("a here-document with only an environment variable stays savable")
    func aHeredocWithoutPlaceholdersIsFine() {
        let command = "cat <<EOF > $HOME/note.txt\nhello\nEOF"
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [environment("HOME_NOTE")]) == nil)
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(command: command, variables: [])
                == nil)
    }

    // --- the name rule, in Core ------------------------------------------

    /// The editor enforces `SnippetVariable.isValidName` on the field, but
    /// import carries declarations in from a file that never passed one.
    @Test("a name that is not a shell identifier is a problem")
    func anInvalidNameIsAProblem() {
        let hostile = SnippetVariable(
            name: "A;touch /tmp/m;B", prompt: "p", kind: .freeText, placement: .environment,
            defaultValue: "v", remembersLastValue: false)
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "echo hi", variables: [hostile])
                == .invalidName(name: "A;touch /tmp/m;B"))
    }

    /// And `resolve` holds the same line on its own, because the run path
    /// reaches it without consulting the check above: the assignment is
    /// never emitted, so what a shell would read as three commands stays one.
    @Test("resolve emits no assignment for a name that is not a shell identifier")
    func resolveSkipsAnInvalidEnvironmentName() {
        let hostile = SnippetVariable(
            name: "A;touch /tmp/m;B", prompt: "p", kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo hi", variables: [hostile], values: ["A;touch /tmp/m;B": "v"])
        #expect(resolved == "echo hi")
    }

    /// The placeholder half of the same rule: no value is substituted, so
    /// the template's own `{{…}}` text stands as the inert literal it is.
    @Test("resolve substitutes nothing for a placeholder whose name is not a shell identifier")
    func resolveSkipsAnInvalidPlaceholderName() {
        let hostile = SnippetVariable(
            name: "A B", prompt: "p", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{A B}}", variables: [hostile], values: ["A B": "x"])
        #expect(resolved == "echo {{A B}}")
    }

    /// A valid declaration standing next to an invalid one still resolves —
    /// the skip is per declaration, not a whole-command bail-out.
    @Test("a valid declaration beside an invalid one still resolves")
    func avalidDeclarationSurvivesAnInvalidNeighbour() {
        let hostile = SnippetVariable(
            name: "A;touch /tmp/m", prompt: "p", kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{MSG}}", variables: [hostile, placeholder("MSG")],
            values: ["A;touch /tmp/m": "v", "MSG": "hi"])
        #expect(resolved == "echo 'hi'")
    }
}
