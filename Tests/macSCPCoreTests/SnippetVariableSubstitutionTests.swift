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
}
