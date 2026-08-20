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

    // --- the class the review rounds opened, closed -------------------

    /// Every template a whole-branch review got past this check, each one
    /// verified by the reviewer against real `bash`: the resolved string was
    /// executed and a `$(touch …)` payload carried in the VALUE ran, because
    /// `PosixQuoting.singleQuoted` only protects a value in an unquoted
    /// position and each template put it in a quoted one the check could not
    /// see.
    ///
    /// FOUR separate causes, one class — counted here, in the pass that
    /// writes the number, because this project's rule says a number in a
    /// comment is a claim about the rest of the code:
    ///
    /// 1. the tokenizer ended a comment at the end of the TEXT rather than
    ///    the line, so a `#` anywhere killed every later `.string` token;
    /// 2. it did not honour a backslash escape inside a double-quoted span,
    ///    so `"a\"` looked closed;
    /// 3. a here-document cannot be expressed as a quote position at all;
    /// 4. a comment was started at ANY `#`, where a shell starts one only at
    ///    a word start — so `echo a#b "{{X}}"` read the quoted placeholder
    ///    as being inside a comment, and templates of that shape executed
    ///    the payload.
    ///
    /// The fourth is the one that ended the deny-list design: each round
    /// fixed the instances it was shown and the next round found a new
    /// construct, because *not understanding meant accepting*. The gate is
    /// now `SnippetCommandSurvey`, which accepts only what it positively
    /// recognises, and every template below lands on a NAMED outcome rather
    /// than on "some problem was reported" — the weaker assertion this test
    /// used to make stayed green under a mutation a sibling test caught.
    @Test(
        "every template a review broke the check with is refused, and for the stated reason",
        arguments: [
            (#"echo {{X}} "{{X}}""#, SnippetVariableSubstitution.Problem.placeholderInsideQuotes(name: "X")),
            ("# note\necho \"{{X}}\"", .placeholderInsideQuotes(name: "X")),
            ("echo hi # note\necho \"{{X}}\"", .placeholderInsideQuotes(name: "X")),
            (#"echo "a\"{{X}}""#, .placeholderInsideQuotes(name: "X")),
            ("cat <<EOF\n{{X}}\nEOF", .unanalyzableContext(kind: .heredoc)),
            (#"echo a#b "{{X}}""#, .placeholderInsideQuotes(name: "X")),
            (#"echo issue#42 "{{X}}""#, .placeholderInsideQuotes(name: "X")),
            (##"echo \# "{{X}}""##, .placeholderInsideQuotes(name: "X")),
            (#"curl http://e.com/a#b -d "{{X}}""#, .placeholderInsideQuotes(name: "X")),
            (#"echo a#b x "{{X}}""#, .placeholderInsideQuotes(name: "X")),
            (#"V=a#b; echo "{{X}}""#, .placeholderInsideQuotes(name: "X")),
            ("echo a#b '{{X}}'", .placeholderInsideQuotes(name: "X")),
            (#"echo x#y"{{X}}"z"#, .placeholderInsideQuotes(name: "X")),
            ("echo a#b\ncat <<EOF\n{{X}}\nEOF", .unanalyzableContext(kind: .heredoc)),
            ("echo $(({{X}}))", .unanalyzableContext(kind: .expansion)),
            ("eval {{X}}", .unanalyzableContext(kind: .evaluation)),
            ("echo hi && eval {{X}}", .unanalyzableContext(kind: .evaluation)),
            (#""eval" {{X}}"#, .unanalyzableContext(kind: .unrecognizedSyntax)),
            ("echo `id` {{X}}", .unanalyzableContext(kind: .commandSubstitution)),
            ("echo $(id) {{X}}", .unanalyzableContext(kind: .commandSubstitution)),
            ("(echo {{X}})", .unanalyzableContext(kind: .commandSubstitution)),
            ("echo hi > {{X}}", .placeholderNotInArgumentPosition(name: "X")),
            ("{{X}} --flag", .placeholderNotInArgumentPosition(name: "X")),
            ("echo hi # {{X}}", .placeholderNotInArgumentPosition(name: "X")),
        ])
    func theUnsafePlacementClassIsClosed(
        template: String, expected: SnippetVariableSubstitution.Problem
    ) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: template, variables: [placeholder("X")]) == expected)
    }

    /// The structural default itself — "covered by no recognised span is
    /// unsafe" — exercised through `firstDeclarationProblem`, which is where
    /// it is decided.
    ///
    /// Every entry in the corpus above lands on a span that EXISTS
    /// (`.commandName`, `.comment`, `.redirectionTarget`, `.quoted`), so not
    /// one of them produced a `nil` placement, and two mutations that switch
    /// the rule off — containment relaxed to `overlaps`, and an uncovered
    /// position accepted alongside `.argument` — both left the whole suite
    /// green. A default nothing exercises is a default nothing protects.
    ///
    /// These templates do produce `nil`: the backslash escape consumes the
    /// first `{`, so the `.argument` span begins one scalar INSIDE the
    /// occurrence. The occurrence therefore starts in text no span covers
    /// and ends inside an `.argument` — partly in, wholly in nothing,
    /// straddling the boundary between the two. Under `overlaps` it is
    /// accepted; under `case .argument, .none` it is accepted; here it is
    /// refused, and by the named problem rather than by "some problem".
    @Test(
        "a placeholder no single span contains is refused, and that is checked",
        arguments: [
            #"echo \{{X}}"#,
            #"echo pre\{{X}} post"#,
            #"echo a && echo \{{X}}"#,
        ])
    func anUncoveredPlaceholderIsRefused(template: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: template, variables: [placeholder("X")])
                == .placeholderNotInArgumentPosition(name: "X"))
    }

    /// The quoted assignment prefix, which this pass deliberately opened up.
    ///
    /// `PGPASSWORD='secret' psql -h {{HOST}}` is an everyday snippet, and
    /// before this pass the quotes around `secret` refused the whole command
    /// as `unrecognizedSyntax` — the command name had to be one plain
    /// literal word, and an assignment prefix is read in command-name
    /// position. A word a shell reads as an assignment is not a command name
    /// at all, so it no longer has to be readable as one. The placeholder
    /// still has to be a top-level argument after it.
    @Test(
        "a quoted assignment prefix no longer refuses the whole command",
        arguments: [
            "PGPASSWORD='secret' psql -h {{HOST}}",
            #"PGPASSWORD="secret" psql -h {{HOST}}"#,
            "MSG='hello world' ./notify.sh {{HOST}}",
            "PATH=/usr/bin:$PATH cmd {{HOST}}",
            "A='x y' B=2 echo {{HOST}}",
        ])
    func aQuotedAssignmentPrefixIsAccepted(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("HOST")]) == nil)
    }

    /// And the boundary of that opening, so it cannot be mistaken for "a
    /// command name may now be anything".
    ///
    /// A word only counts as an assignment when a POSIX identifier followed
    /// by `=` is spelled in plain literal scalars at its start; a quoted
    /// name is not one. And the value side stays fully surveyed: a
    /// placeholder inside it is not an argument, and a construct the
    /// recogniser cannot read still refuses the command.
    @Test(
        "the assignment-prefix opening does not widen anything else",
        arguments: [
            (#""A"=1 echo {{X}}"#, SnippetVariableSubstitution.Problem
                .unanalyzableContext(kind: .unrecognizedSyntax)),
            ("A='x' eval {{X}}", .unanalyzableContext(kind: .evaluation)),
            ("A=$(id) echo {{X}}", .unanalyzableContext(kind: .commandSubstitution)),
            ("A=${HOME} echo {{X}}", .unanalyzableContext(kind: .expansion)),
            ("A='{{X}}' echo hi", .placeholderInsideQuotes(name: "X")),
            ("A={{X}} echo hi", .placeholderNotInArgumentPosition(name: "X")),
        ])
    func theAssignmentPrefixOpeningStaysNarrow(
        template: String, expected: SnippetVariableSubstitution.Problem
    ) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: template, variables: [placeholder("X")]) == expected)
    }

    /// Shapes that stay refused and are named in the report's over-refusal
    /// list because of this test, not the other way round: a subshell or a
    /// function definition anywhere in the command refuses the whole
    /// command, even where the placeholder is plainly an argument elsewhere.
    @Test(
        "a subshell or a function definition still refuses the whole command",
        arguments: [
            "(cd /srv && ls) ; echo {{X}}",
            "f() { echo $1; }; f {{X}}",
            "echo {{X}} | (read x; echo $x)",
        ])
    func aGroupingConstructRefusesTheCommand(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
                == .unanalyzableContext(kind: .commandSubstitution))
    }

    /// The other direction, so the corpus above cannot be satisfied by
    /// refusing everything. These are ordinary snippets, and a gate that
    /// refuses them is a gate nobody can use — which is the failure mode
    /// worth having, but only in exchange for something.
    @Test(
        "legitimate snippets stay usable",
        arguments: [
            "echo {{X}}",
            "mysqldump {{X}} > out.sql",
            "awk '{print $1}' {{X}}",
            #"echo \"{{X}}\""#,
            "echo {{X}} # don't do this twice",
            "# back up the database\ncd /srv\nmysqldump {{X}} > out.sql  # dump it",
            "case \"$1\" in\n  start) echo starting {{X}} ;;\n  *) echo other ;;\nesac",
            "scp -i {{X}} host:/path && echo \"done\"",
            "cp {{X}} $HOME/backup",
            "if grep -q needle {{X}}; then echo yes; fi",
            "DB=live ./backup.sh {{X}}",
            "ls | grep {{X}} | wc -l",
        ])
    func aLegitimateSnippetStaysUsable(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) == nil)
    }

    /// An accepted template resolves to text a shell reads as ONE literal
    /// word — proven here on the payload the reviewers used, and confirmed
    /// by executing these strings in real `bash` in a scratch directory
    /// (the marker file was never created).
    @Test func anAcceptedTemplateResolvesThePayloadInert() {
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
    /// here-document. It is refused all the same, and under its own name: a
    /// process substitution is a command inside a command, with a quoting
    /// state of its own. This used to be ACCEPTED — the previous gate looked
    /// only for two adjacent `<`, found none, and concluded the command was
    /// safe. That conclusion is exactly the shape this wave removed.
    @Test("a process substitution is refused as a nested command, not as a here-document")
    func aSpacedRedirectionIsRefusedAsANestedCommand() {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "diff {{A}} < <(sort b)", variables: [placeholder("A")])
                == .unanalyzableContext(kind: .commandSubstitution))
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

    // MARK: - The gate and the emitter look for the same thing

    /// The checker and the emitter must find EXACTLY the same occurrences,
    /// and the way to guarantee that is for them to ask the same function —
    /// which is what `occurrences(of:in:)` now is.
    ///
    /// It was two searches: `range(of:)` in the checker, a walk over `{{`
    /// and `}}` in the emitter. A previous round left them apart on the
    /// reasoning that moving only one would turn a refusal into a silent
    /// non-substitution, and that reasoning was inherited rather than run.
    /// Run: a corpus of decorated templates — one decoration inserted at
    /// every position of `echo {{X}}`, six decorations — found the two
    /// agreeing on all sixty-six. So the reasoning held; the STRUCTURE did
    /// not, because two searches that agree today can drift tomorrow and the
    /// drift that costs the gate is silent (a value placed where nothing
    /// classified it).
    ///
    /// This test is that corpus, kept, and now asserting the property that
    /// matters rather than the coincidence: for every variant, the checker
    /// finding an occurrence and the emitter substituting one are the same
    /// event.
    @Test func theGateAndTheEmitterAgreeOnEveryDecoratedBrace() {
        let decorations = ["\u{0308}", "\u{FE0F}", "\u{0301}", "\u{20E3}", "\u{200D}", "\u{1AB0}"]
        let base = "echo {{X}}"
        var checked = 0
        for decoration in decorations {
            for position in 0...base.unicodeScalars.count {
                var scalars = Array(base.unicodeScalars)
                scalars.insert(contentsOf: Array(decoration.unicodeScalars), at: position)
                var view = String.UnicodeScalarView()
                for scalar in scalars { view.append(scalar) }
                let command = String(view)

                let found = SnippetVariableSubstitution.occurrences(of: "X", in: command)
                let resolved = SnippetVariableSubstitution.resolve(
                    command: command, variables: [placeholder("X")], values: ["X": "V"])
                // Asked as "did the text change at all" rather than by
                // searching for the quoted value: a cluster search for
                // `'V'` misses it when the template's next scalar is a
                // combining mark, which is the very confusion this test
                // exists to rule out of the code.
                let substituted = resolved != command
                #expect(
                    found.isEmpty != substituted,
                    "the checker and the emitter disagree about what an occurrence is")

                // And the checker's verdict follows from the same set, in
                // both directions. `unusedPlaceholder` means "found
                // nothing", so it must appear exactly when the finder found
                // nothing — a checker searching some other way would report
                // it for a template the emitter does fill, which is the
                // drift this whole arrangement exists to make impossible.
                let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: [placeholder("X")])
                #expect(
                    (problem == .unusedPlaceholder(name: "X")) == found.isEmpty,
                    "the checker looked for the placeholder somewhere the emitter did not")
                checked += 1
            }
        }
        #expect(checked == decorations.count * (base.unicodeScalars.count + 1))
    }

    /// The scalar walk sees an occurrence a cluster search cannot: a
    /// combining mark after the closing brace makes `}` and the mark one
    /// `Character`, so `range(of: "{{X}}")` finds nothing there. Both halves
    /// see it now, because there is only one half.
    ///
    /// The value still cannot reach anything live: it is placed complete,
    /// inside its own quotes, and the mark stays outside them.
    @Test func aTrailingCombiningMarkDoesNotHideAnOccurrence() {
        let command = "echo {{X}}\u{0308}"
        #expect(SnippetVariableSubstitution.occurrences(of: "X", in: command).count == 1)
        #expect(command.range(of: "{{X}}") == nil)
        // The checker agrees it is there — a cluster search here would call
        // the declaration unused while the emitter filled it.
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) == nil)
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")], values: ["X": "v"])
        #expect(resolved == "echo 'v'\u{0308}")
    }

    /// Two declared names in one command are found and filled independently,
    /// left to right, and a value that happens to contain another
    /// placeholder's token is never re-read — the ranges come from the
    /// original text.
    @Test func severalPlaceholdersAreFilledFromTheOriginalTextOnly() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "cp {{A}} {{B}} {{A}}",
            variables: [placeholder("A"), placeholder("B")],
            values: ["A": "{{B}}", "B": "two"])
        #expect(resolved == "cp '{{B}}' 'two' '{{B}}'")
    }
}
