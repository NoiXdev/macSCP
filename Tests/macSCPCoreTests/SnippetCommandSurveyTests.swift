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
    /// blinded a previous gate to a batch of templates, so the two halves
    /// are pinned separately — mid-word `#` is literal, word-start `#` is
    /// not.
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
    /// quoted — templates of this shape were accepted and executed their
    /// payload. Positive recognition is no defence when the span
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

    /// Line handling, against `bash`'s rules rather than Swift's.
    ///
    /// An earlier version of this test asked only the Swift half — `"\r\n"`
    /// is one `Character` and two scalars, both are state resets, so the
    /// outcome is unchanged — and that half is true and is still pinned
    /// below. The half it did not ask is whether the scalar is a line
    /// terminator TO BASH at all. It is not: `bash` ends a line at U+000A
    /// and reads CR, VT, FF, NEL, U+2028 and U+2029 as ordinary bytes
    /// (measured; `ShellQuotingExecutionTests` runs the comment case through
    /// a real shell). So a comment ended early for us and kept running for
    /// `bash`, and the placeholder in between was called an argument while
    /// sitting inside `bash`'s comment.
    ///
    /// The same measurement settles word splitting: `bash`'s blanks are
    /// space and tab, so a CR does not end a word either — `foo\recho` is
    /// ONE argument word, and the classification below says so.
    @Test func linesAndWordsEndWhereBashEndsThem() {
        // The wide set still refuses a quoted span, which is the one
        // direction where being wider than `bash` costs only a nuisance.
        #expect(refusal("echo \"a\r\nb\" {{X}}") == .unbalancedQuoting)
        #expect(refusal("echo \"a\rb\" {{X}}") == .unbalancedQuoting)
        #expect(refusal("echo \"a\u{2028}b\" {{X}}") == .unbalancedQuoting)

        // A line feed resets the command; a CR is word content, so the
        // placeholder is an argument either way — but for different reasons.
        #expect(placement(of: "{{X}}", in: "echo foo\r\necho {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo foo\recho {{X}}") == .argument)

        // A comment ends at a line feed and at nothing else.
        #expect(placement(of: "{{X}}", in: "echo hi # note\r\necho {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo hi # note\necho {{X}}") == .argument)
        #expect(placement(of: "{{X}}", in: "echo hi # note\recho {{X}}") == .comment)
        #expect(placement(of: "{{X}}", in: "echo hi # note\u{000B}echo {{X}}") == .comment)
        #expect(placement(of: "{{X}}", in: "echo hi # note\u{2028}echo {{X}}") == .comment)

        // And a `#` that a CR pushed into the middle of a word is not a
        // comment for `bash`, so it is not one here (`printf` builds one
        // argument out of `ls\r#`).
        #expect(placement(of: "{{X}}", in: "ls\r# {{X}}") == .argument)
    }

    /// The keyword sets stay ASCII.
    ///
    /// This used to be justified by a claim that is simply false — that
    /// canonical equivalence cannot map another scalar sequence onto an
    /// all-ASCII string. It can: `"\u{212A}" == "K"` is `true`. What makes
    /// `ShellWord.isOneOf` sound is the direction of every one of its
    /// callers, and `ShellWord`'s own comment now carries that argument.
    ///
    /// What this test is still worth: a non-ASCII entry would make the
    /// comparison a question about equivalence classes rather than about
    /// bytes, and nobody reading this area should have to hold that in their
    /// head. It pins tidiness, not the gate.
    @Test func shellWordKeywordSetsAreASCII() {
        let keywords = SnippetCommandSurvey.reparsingCommands
            .union(SnippetCommandSurvey.commandIntroducers)
            .union(SnippetCommandSurvey.unmodelledKeywords)
        #expect(!keywords.isEmpty)
        for keyword in keywords {
            #expect(
                keyword.unicodeScalars.allSatisfy { $0.isASCII },
                "a non-ASCII keyword makes the word comparison a cluster comparison")
        }
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
    /// use — see `swiftFiles(under:)` for how the repo root is recovered.
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

    /// The comparison-unit decision, kept structural — and kept in the
    /// shapes the mistake has actually taken, not only the one already
    /// repaired.
    ///
    /// The previous version of this guard matched the literal spelling
    /// `replacingOccurrences(of: "<metachar>"` and nothing else. A review
    /// injected the other shapes into a Core file one at a time and the
    /// guard stayed green for every one of them — including
    /// `value.contains("=")`, which was sitting in Core at that moment and
    /// was the critical finding of that round. A guard that misses the shape
    /// of the bug is the finding; the hole it happens to catch is not the
    /// defence.
    ///
    /// **Scope.** Banning `Character` across all of Core is not possible:
    /// `AppVersion` and `SigV4Signer` use it for things that are not shell
    /// or markup syntax, and `SSHConnectionConfig` keeps `Character` ALLOW
    /// lists on purpose (an allow list survives the wrong alphabet — a
    /// decorated cluster is simply not on it, and `Character.isASCII` is
    /// false for every one of them). So this guard covers the files that
    /// lex shell text scalar by scalar, and
    /// `everySourceFileOnTheShellPathIsClassified` below keeps that list
    /// from going stale by failing the moment a file joins the shell path
    /// without being classified.
    ///
    /// **What this guard is and is not.** An earlier version of this comment
    /// claimed that in a file where no `Character` exists, a literal
    /// comparison cannot be one. That was false twice over. A textual scan
    /// cannot type-check a receiver, so it cannot tell `String.contains {
    /// $0 == "=" }` from the same call on a scalar view; and
    /// `SnippetVariableSubstitution` was on the list below while walking the
    /// command in `Character`s through `command[index]`, naming the type
    /// nowhere and passing this guard. A review injected nine cluster-unit
    /// spellings into a listed file one at a time and seven of them stayed
    /// green, including `value.contains { $0 == "=" }` — literally the
    /// previous round's critical finding with a closure instead of a
    /// literal.
    ///
    /// So this is a TRIPWIRE for known spellings, not a proof. What actually
    /// holds the unit is structural and lives in the code: `ShellWord` hands
    /// out no character access, so `word.contains("=")` does not compile;
    /// the reader holds a `String.UnicodeScalarView` and no `String`; and
    /// `SnippetVariableSubstitution.occurrences(of:in:)` is now a scalar
    /// walk, so the last `Character` walk under this ban is gone. The scan
    /// exists to make a NEW spelling of the old mistake announce itself.
    ///
    /// **The receiver rule.** Some of these questions are perfectly correct
    /// on a scalar and wrong on a `Character` — `scalar == "'"` and
    /// `scalars[start..<end].contains { $0 == "=" }` are both in the code and
    /// both right. A textual scan cannot tell them from the `String`
    /// spellings, so those shapes are banned unless the LINE also names the
    /// scalar it asks about. That is a convention, not a type check, and it
    /// is stated here rather than implied: a line that asks a per-element
    /// question about shell text must show the scalar it asks it of. One
    /// parameter was renamed to `quoteScalar` to keep it, which is the
    /// convention paying for itself in the only currency it has.
    @Test func noShellLexingFileAsksACharacterQuestion() throws {
        for file in try Self.shellLexingSourceFiles() {
            let lines = try Self.codeLines(of: file)
            let code = lines.joined(separator: "\n")
            for shape in Self.characterShapedPatterns {
                #expect(
                    code.range(of: shape, options: .regularExpression) == nil, """
                    \(file.lastPathComponent) asks a Character-shaped question (\(shape)) about \
                    shell text. A Character is an extended grapheme cluster, so a metacharacter \
                    carrying a combining mark is not an occurrence of it — which is how a value \
                    broke out of its own single quotes and how a decorated `=` hid an eval. \
                    Decide it one Unicode.Scalar at a time — see ShellScalar.
                    """)
            }
            for line in lines {
                for shape in Self.perElementPatterns
                where line.range(of: shape, options: .regularExpression) != nil {
                    #expect(
                        line.lowercased().contains("scalar"), """
                        \(file.lastPathComponent) asks a per-element question (\(shape)) about \
                        shell text without naming the scalar it asks it of. On a String every \
                        one of these works on grapheme clusters, so a metacharacter carrying a \
                        combining mark is not an element — the shape of the `A=̈1 eval` escape, \
                        rewritten as a closure. Ask it of a Unicode.Scalar and name it — see \
                        ShellScalar.
                        """)
                }
            }
        }
    }

    /// The shapes the guard above looks for. Each one was measured against a
    /// decorated metacharacter before being listed, and each is a shape a
    /// review found green under the previous guard.
    ///
    /// - `Character` as a type name covers `Set<Character>`, `[Character]`,
    ///   `: Character` and `Character(…)`.
    /// - `.contains("…")` covers the critical finding's own line.
    /// - `.first` (other than `first { … }` / `first(where:)`, which are the
    ///   `Collection` methods) yields a `Character` from a `String`.
    /// - `.isNewline` is a `Character` property, and "what is a line break"
    ///   is the question that has to be `bash`'s rather than Unicode's.
    /// - the rest are `String` APIs that match on clusters and canonical
    ///   equivalence: `replacingOccurrences` in any spelling, including one
    ///   reached through a variable or an interpolation, plus `split`,
    ///   `firstIndex`/`lastIndex`, `hasPrefix`/`hasSuffix`.
    /// - `range(of:)`, `components(separatedBy:)`, `prefix`/`suffix` are the
    ///   shapes a review found green and are banned outright: none of them
    ///   has a scalar-view spelling this code needs, and the one caller that
    ///   used `range(of:)` — the placeholder search — is a scalar walk now.
    private static let characterShapedPatterns = [
        #"\bCharacter\b"#,
        #"\.contains\(""#,
        #"\.first\b(?!\s*[({])"#,
        #"\.isNewline\b"#,
        #"\.replacingOccurrences\("#,
        #"\.split\(separator:"#,
        #"\.(first|last)Index\(of:"#,
        #"\.has(Prefix|Suffix)\("#,
        #"\.range\(of:"#,
        #"\.components\(separatedBy:"#,
        #"\.(prefix|suffix)\("#,
    ]

    /// Shapes that are a cluster question on a `String` and the right
    /// question on a scalar view, so the guard asks the LINE to name the
    /// view rather than banning the call. Every one of them was measured
    /// green under the previous guard while expressing the critical finding
    /// of the round before it.
    ///
    /// - a comparison against a literal is the whole family in one line, and
    ///   it is the rule that catches the shapes a scan cannot enumerate:
    ///   `v.contains { $0 == "=" }`, `for c in v where c == "="`,
    ///   `v[v.startIndex] == "="` all reduce to a literal compared against
    ///   something whose unit the line does not name. Every literal
    ///   comparison in these files today reads `scalar == "…"` or
    ///   `scalars[i] == "…"`, so the convention costs nothing to keep.
    /// - `contains { … }` and `contains(where:)` are `value.contains("=")`
    ///   with the literal moved into a closure, where `$0` is a `Character`.
    /// - `firstIndex(where:)` / `lastIndex(where:)` are the same question
    ///   asked for a position.
    /// - a subscript by an index or a start/end bound yields a `Character`
    ///   from a `String`; `v[v.startIndex] == "="` was green.
    private static let perElementPatterns = [
        #"[=!]= ""#,
        #"\.contains\s*[{]"#,
        #"\.contains\(where:"#,
        #"\.(first|last)Index\(where:"#,
        #"\[\w*[Ii]ndex\]"#,
        #"\[\w+\.(startIndex|endIndex)\]"#,
    ]

    /// The Core files that lex shell text scalar by scalar.
    ///
    /// Named rather than derived, because "does this file decide shell
    /// syntax" is not a property a directory listing knows — but the naming
    /// is fail-closed twice over: a name that no longer exists fails here,
    /// and a file that joins the shell path without being named fails
    /// `everySourceFileOnTheShellPathIsClassified`.
    private static let shellLexingFileNames = [
        "ShellScalar.swift",
        "PosixQuoting.swift",
        "SnippetCommandSurvey.swift",
        "SnippetVariableSubstitution.swift",
    ]

    /// Core files that CALL the shell-lexing code without lexing themselves.
    /// They are excluded from the `Character` ban for stated reasons:
    /// `SSHConnectionConfig` keeps two `Character` allow lists (see the
    /// guard above), and the other two only hand a value to
    /// `PosixQuoting.singleQuoted`.
    private static let shellCallerFileNames = [
        "SSHConnectionConfig.swift",
        "SSHCommandBuilder.swift",
        "CLIToolInstaller.swift",
    ]

    private static func shellLexingSourceFiles() throws -> [URL] {
        let files = try coreSourceFiles()
        return try shellLexingFileNames.map { name in
            guard let file = files.first(where: { $0.lastPathComponent == name }) else {
                throw GuardFailure.missingShellLexingFile(name)
            }
            return file
        }
    }

    private enum GuardFailure: Error {
        case missingShellLexingFile(String)
    }

    /// Every source file that names `ShellScalar` or `PosixQuoting` in code
    /// is either a shell-lexing file or a listed caller.
    ///
    /// This is what stops the list above from being the stale hand-written
    /// list that a previous round rightly objected to. A new file that joins
    /// the shell path — a helper the survey delegates to, a third quoter —
    /// has to name one of those two to do its job, and the moment it does,
    /// this test fails until somebody decides which side of the ban it is
    /// on. Deciding is the point; the failure message says so.
    ///
    /// The walk covers `Sources` whole and not just `Sources/macSCPCore`.
    /// A review measured that gap: an App-layer file lexing shell text and
    /// calling `PosixQuoting` was invisible here, and `PosixQuoting` is
    /// `public`, so nothing stops one existing. No file outside Core names
    /// either type today, which is exactly why widening the walk costs
    /// nothing and closes the case before there is one.
    ///
    /// The gap it still does not close, recorded rather than claimed shut: a
    /// new file that brings its OWN alphabet — lexes shell text in
    /// `Character`s without naming either type — is derived by nothing here.
    /// The executing corpus is what catches that one, since a recogniser
    /// that mis-reads a template shows up as a marker file, not as a name.
    @Test func everySourceFileOnTheShellPathIsClassified() throws {
        let classified = Set(Self.shellLexingFileNames + Self.shellCallerFileNames)
        var onThePath: [String] = []
        for file in try Self.allSourceFiles() {
            let code = try Self.codeLines(of: file)
            if code.contains(where: { $0.contains("ShellScalar") || $0.contains("PosixQuoting") }) {
                onThePath.append(file.lastPathComponent)
            }
        }
        #expect(!onThePath.isEmpty, "the source tree could not be walked")
        for name in onThePath {
            #expect(classified.contains(name), """
                \(name) names ShellScalar or PosixQuoting in code but is on neither list in \
                SnippetCommandSurveyTests. Decide whether it lexes shell text — then it goes on \
                shellLexingFileNames and must not name Character — or only calls the quoter, \
                which puts it on shellCallerFileNames.
                """)
        }
    }

    /// The Core-wide half, unchanged in intent and kept broad: escaping a
    /// metacharacter with `replacingOccurrences` is wrong wherever it
    /// appears, shell path or not, because it matches on grapheme clusters
    /// and canonical equivalence. The S3 XML escaper is in Core and is not a
    /// shell-lexing file, and it had this exact shape.
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
        try swiftFiles(under: "Sources/macSCPCore")
    }

    /// Every `.swift` file under `Sources`, App layer and CLI included.
    private static func allSourceFiles() throws -> [URL] {
        try swiftFiles(under: "Sources")
    }

    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/…`, so three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory. Fail-closed: a directory that
    /// cannot be walked throws rather than yielding an empty list that every
    /// caller would then pass vacuously.
    private static func swiftFiles(under relativePath: String) throws -> [URL] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repoRoot.appendingPathComponent(relativePath)
        let contents = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return contents
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0) }
    }

    /// The lines of `file` that are not whole-line comments — so a doc
    /// comment may name what the code may not.
    private static func codeLines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
