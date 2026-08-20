import Foundation
import Testing

@testable import macSCPCore

/// The quoting promise, proven the only way it can be proven: by handing the
/// result to a real shell and looking at the filesystem afterwards.
///
/// Every other test in this area asserts on strings, which is an assertion
/// about what *we* think a shell does. A review round broke that assumption
/// underneath every one of them at once: an apostrophe carrying U+0308
/// COMBINING DIAERESIS is one Swift `Character` that compares unequal to
/// `"'"` and that `replacingOccurrences(of: "'")` does not find, so the
/// quoter left it unescaped and a VALUE broke out of its own single quotes.
/// `echo {{X}}` — a template every version of the gate has accepted — plus
/// such a value executed arbitrary commands. The value need not even be
/// typed by the victim: a snippet's `defaultValue` arrives through import
/// and pre-fills the prompt.
///
/// So these tests run `bash`. Each one builds a command whose payload, if it
/// escaped its quotes, would create a marker file in a fresh scratch
/// directory; the assertion is that the file is not there. A marker is the
/// one signal that cannot be argued with.
///
/// Some tests here DELIBERATELY EXECUTE an attack payload on every `swift
/// test` run, and say so in their own doc comments. That is the point of
/// them: a refusal is only worth pinning while the shape it refuses would
/// still do damage, so the corpus that pins refusals is paired with tests
/// asserting that the marker IS created when the same template is resolved
/// anyway. Each runs `bash` in its own fresh scratch directory, with no
/// stdin and no inherited output, and every payload writes a marker file
/// into that directory and nothing else. The README's "Building from
/// source" section says so too, so a reader of a CI log is not surprised
/// by it.
///
/// No value a USER typed reaches a log, an error, an export or a failure
/// message anywhere in this area — `SnippetVariableSubstitution`,
/// `SnippetCommandSurvey` and `PosixQuoting` do no logging, and `Problem`
/// carries declaration names only. The failure messages here are a weaker
/// claim than that: swift-testing prints the ARGUMENTS of a parameterised
/// test, so a payload from this file's own `arguments:` lists can appear in
/// a failure line. Those are hard-wired test data, not anybody's value.
@Suite("shell quoting, executed")
struct ShellQuotingExecutionTests {
    /// `'` U+0308 — the apostrophe that is not an apostrophe to Swift.
    private static let markedQuote = "'\u{0308}"

    /// A scratch directory that exists for the duration of one test.
    private func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-quoting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// The installed `bash`'s own answer to "what builtins and reserved
    /// words do you have". It is the LOWER BOUND on
    /// `SnippetCommandSurvey.shellVocabulary` and nothing else: every name it
    /// reports must appear in the table, so a name macSCP has never seen goes
    /// red instead of sailing through as an ordinary command name.
    ///
    /// It is deliberately not allowed to make a name SAFE. That is the whole
    /// finding this shape answers: the snippet runs in the login shell of the
    /// remote host, `/bin/bash` here is pinned at 3.2.57 by macOS and CI runs
    /// on macOS, so this process cannot see what bash 5 or zsh do — and a
    /// previous version of this test read the same enumeration as a proof of
    /// completeness while three `-v` shapes ran on the other side.
    private func bashWords(_ compgenFlag: String) throws -> [String] {
        try shellWords(binary: "/bin/bash", arguments: ["-c", "compgen \(compgenFlag)"])
    }

    /// The same question asked of any locally installed shell.
    ///
    /// `bash` is not the only shell macOS ships, and since the table's scope
    /// widened past bash and zsh it is not the only lower bound worth
    /// having: `/bin/zsh` and `/bin/ksh` are both here, and `/bin/ksh` is an
    /// AT&T 93u+ whose builtin list contains names — `alarm`, `vmap`,
    /// `vpath`, `login`, `newgrp` — that no bash and no zsh has ever
    /// reported. A name absent from the table is a name this reader treats
    /// as an ordinary command, so asking every shell that is actually
    /// installed costs one process and closes that gap on the machine the
    /// tests run on.
    ///
    /// Names containing a `/` are dropped: ksh93 reports several builtins
    /// bound to a path (`/opt/ast/bin/cat`), and a path is not a name this
    /// table classifies — a template using one is read as an ordinary
    /// command name, which is what it is.
    private func shellWords(binary: String, arguments: [String]) throws -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.contains("/") }
    }

    /// Runs `command` with `bash` in `directory`, with no stdin and no
    /// inherited output, and waits for it. The exit status is ignored on
    /// purpose: a payload that fails to run and a payload that runs are both
    /// interesting only through the marker file.
    private func runInBash(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func markerExists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path)
    }

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

    /// Critical 1, the plain case: an accepted template, a hostile value.
    ///
    /// The template needs no craft at all — it is the first example in the
    /// snippet editor's own help text. Before the fix this resolved to
    /// `echo ''̈; touch MARKER; '̈'`, where `''` is an empty word, the
    /// combining mark is literal bytes, and `;` ends the command.
    @Test func aValueWhoseQuotesCarryACombiningMarkCannotBreakOut() throws {
        let marker = "marker-placeholder"
        let value = "\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let variables = [placeholder("X")]
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "echo {{X}}", variables: variables) == nil)
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{X}}", variables: variables, values: ["X": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "the value escaped its single quotes and ran as a command")
        }
    }

    /// The same payload with a variation selector rather than a combining
    /// diaeresis, and with a single marked quote rather than a pair. Both
    /// executed before the fix; both are the same defect, and neither is a
    /// shape a value is checked for anywhere.
    @Test(
        "a value cannot break out however its quote is decorated",
        arguments: [
            "'\u{FE0F}; touch marker-decorated; '\u{FE0F}",
            "'\u{0300}; touch marker-decorated; '\u{0300}",
            "'\u{20E3}; touch marker-decorated ;#",
            "'\u{200D}; touch marker-decorated; '\u{200D}",
        ])
    func aDecoratedQuoteInAValueCannotBreakOut(value: String) throws {
        let variables = [placeholder("X")]
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{X}}", variables: variables, values: ["X": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists("marker-decorated", in: directory),
                "the value escaped its single quotes and ran as a command")
        }
    }

    /// The `.environment` placement uses the same quoter and was affected
    /// identically — `V=''̈; touch E1; '̈' echo $V` ran the payload as its
    /// own command. The survey never sees this path (it is scoped to
    /// commands that declare a placeholder), so the quoter is the only thing
    /// standing between an imported default value and a shell here.
    @Test func anEnvironmentValueWhoseQuotesCarryACombiningMarkCannotBreakOut() throws {
        let marker = "marker-environment"
        let value = "\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo $V", variables: [environment("V")], values: ["V": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "the assignment's value escaped its single quotes and ran as a command")
        }
    }

    /// The other caller of `PosixQuoting.singleQuoted`: the `ssh` line handed
    /// to an external terminal app. Host, username and key path all come from
    /// a session, and a session arrives through import too, so the same
    /// marked quotes reach the same quoter by a completely different route.
    ///
    /// The key PATH carries the payload here, because host and username are
    /// additionally screened by `SSHConnectionConfig`'s ban lists (which this
    /// pass also moved onto scalars) while the key path is only checked for
    /// being non-empty. That makes it the honest test of the quoter: nothing
    /// but quoting stands between this value and the shell.
    ///
    /// Executed against a stub `ssh` on `PATH` rather than the real one: the
    /// question is whether the shell splits the line into more than one
    /// command, not what `ssh` does with it.
    @Test func anSSHCommandLineCannotBeBrokenByAMarkedQuoteInTheKeyPath() throws {
        let marker = "marker-ssh"
        let hostile = "/keys/\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: hostile, passphrase: nil))
        let command = SSHCommandBuilder.shellCommand(for: config)

        try withScratchDirectory { directory in
            let binDirectory = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)
            let stub = binDirectory.appendingPathComponent("ssh")
            try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path)

            try runInBash("PATH='\(binDirectory.path)':\"$PATH\"; \(command)", in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "an ssh argument escaped its single quotes and ran as a command")
        }
    }

    /// The host ban list, from the same angle: a metacharacter carrying a
    /// combining mark used to slip past a `Set<Character>` membership test.
    /// It is a second layer rather than the only one — the quoter is the
    /// first — but a second layer that can be walked through is not one.
    @Test(
        "a metacharacter carrying a combining mark does not pass the host ban list",
        arguments: ["ex\u{0027}\u{0308}ample.com", "ex\u{0024}\u{0308}ample.com",
                    "ex\u{003B}\u{0308}ample.com", "ex\u{0060}\u{0308}ample.com"])
    func aDecoratedMetacharacterIsBannedInAHost(host: String) {
        #expect(throws: (any Error).self) {
            try SSHConnectionConfig(host: host, username: "tim", auth: .password("x"))
        }
    }

    /// Critical 2 from the other side: the templates the recogniser could not
    /// see. Each one puts the placeholder inside quotes a shell honours and
    /// Swift's `Character` comparison did not, and each one created the
    /// marker before the fix. The assertion here is on the gate rather than
    /// on `bash`, because a refused template is never resolved and so never
    /// reaches a shell at all — refusal IS the protection.
    @Test(
        "a quote carrying a combining mark is seen by the recogniser",
        arguments: [
            "echo x'\u{0308}{{X}}'\u{0308}",
            "echo x\"\u{0308}{{X}}\"\u{0308}",
            "echo x'\u{FE0F}{{X}}'\u{FE0F}",
            "echo x'\u{200D}{{X}}'\u{200D}",
            "echo x'\u{0300}{{X}}'\u{0300}",
            "echo x'\u{20E3}{{X}}'\u{20E3}",
            "echo x'\u{1AB0}{{X}}'\u{1AB0}",
            "echo '\u{0308}{{X}}'\u{0308} end",
            "echo x'\u{0308}{{X}}'\u{0308}y'\u{0308}'\u{0308}",
            "git commit -m'\u{0308}{{X}}'\u{0308}",
            "curl -H Authorization:Bearer'\u{0308}{{X}}'\u{0308} https://example.invalid",
        ])
    func aMarkedQuoteIsNotInvisibleToTheGate(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) != nil,
            "a placeholder a shell reads as quoted was accepted as an argument")
    }

    // MARK: - A decorated `=` must not hide the command name behind it

    /// The gate asked about one `=` in two alphabets and got two answers.
    ///
    /// `opensAssignment` read SCALARS, found U+003D, and concluded "this is
    /// an assignment prefix", which skips the command-name checks. The line
    /// below it read `Character`s — `=` plus a combining mark is one cluster
    /// unequal to `"="` — concluded "no assignment here", and stopped
    /// expecting a command name. So the word after it was taken for an
    /// argument and never compared against `eval`. `bash` disagrees with the
    /// cluster half and agrees with the scalar half: measured, `A=̈1 sh -c
    /// 'echo $A'` prints the decorated value, so it IS an assignment and
    /// `eval` after it IS the command name.
    ///
    /// Both halves are asserted for every decoration, because the pair is
    /// the finding: the gate must refuse, AND the template must still be one
    /// that executes when resolved regardless — otherwise the refusal above
    /// would be pinning something that no longer defends anything.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test(
        "a decorated = does not hide an eval command name",
        arguments: ["\u{0308}", "\u{FE0F}", "\u{0301}", "\u{20E3}", "\u{200D}"])
    func aDecoratedEqualsDoesNotHideAnEvalCommandName(decoration: String) throws {
        let marker = "marker-decorated-assignment"
        let templates = [
            "A=\(decoration)1 eval {{X}}",
            "A=\(decoration)1 command eval {{X}}",
            "PGPASSWORD=\(decoration)'x' eval {{X}}",
        ]
        for command in templates {
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: [placeholder("X")])
                    == .unanalyzableContext(kind: .evaluation),
                "an assignment prefix with a decorated = hid the eval behind it")

            let resolved = SnippetVariableSubstitution.resolve(
                command: command, variables: [placeholder("X")],
                values: ["X": "$(touch \(marker))"])
            try withScratchDirectory { directory in
                try runInBash(resolved, in: directory)
                #expect(
                    markerExists(marker, in: directory),
                    """
                    this template no longer executes its payload; the refusal above may now \
                    be defending nothing
                    """)
            }
        }
    }

    /// The undecorated control, and the one that always worked: the same
    /// templates with a plain `=` are refused for the same reason.
    @Test func aPlainAssignmentPrefixStillGuardsTheCommandNameBehindIt() {
        for command in ["A=1 eval {{X}}", "A=1 command eval {{X}}", "PGPASSWORD='x' eval {{X}}"] {
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: [placeholder("X")])
                    == .unanalyzableContext(kind: .evaluation))
        }
    }

    // MARK: - A comment ends where bash ends one

    /// `bash` ends a `#` comment at U+000A and at nothing else — measured by
    /// running `ls # note<X>touch MARK` through `/bin/bash` for each
    /// candidate: only LF let the `touch` run.
    ///
    /// The recogniser used `Character.isNewline`, which also reports CR, VT,
    /// FF, NEL, U+2028 and U+2029. So it closed the comment at one of those,
    /// read what followed as a fresh command and the placeholder in it as
    /// `.argument`, while `bash` kept the whole tail inside the comment.
    /// `.comment` is documented unsafe for exactly the reason that then
    /// applies: a value containing a newline ends the comment, and
    /// everything after the newline is code again. A value can contain one —
    /// an imported `defaultValue` pre-fills the prompt.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test(
        "a comment is not ended by a terminator bash reads straight through",
        arguments: ["\u{000D}", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"])
    func aCommentIsNotEndedByATerminatorBashReadsThrough(terminator: String) throws {
        let marker = "marker-comment"
        let command = "ls # note\(terminator)echo {{X}}"
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) != nil,
            "a placeholder inside a bash comment was accepted as an argument")

        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "\ntouch \(marker)\n"])
        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                markerExists(marker, in: directory),
                """
                this template no longer executes its payload; the refusal above may now be \
                defending nothing
                """)
        }
    }

    /// The other side of the same rule, and the reason it is not simply
    /// "refuse anything with a comment in it": at a real line feed the
    /// comment really is over, the placeholder after it really is an
    /// argument, and the same newline-carrying value is inert there. Both
    /// spellings of a line ending are covered, since `"\r\n"` is one
    /// `Character` and two scalars and this file's whole subject is units
    /// disagreeing.
    @Test(
        "a comment ended by a real line feed leaves the next command's argument safe",
        arguments: ["\n", "\r\n"])
    func aCommentEndedByALineFeedLeavesTheNextArgumentSafe(terminator: String) throws {
        let marker = "marker-comment-clean"
        let command = "ls # note\(terminator)echo {{X}}"
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) == nil,
            "a placeholder in ordinary argument position after a comment was refused")

        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "\ntouch \(marker)\n"])
        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "a newline in the value escaped its single quotes and ran as a command")
        }
    }

    /// And the refusal of `echo x'̈{{X}}'̈` is load-bearing, not cosmetic:
    /// resolved anyway and executed, that template DOES run the payload. The
    /// template's own quotes close around the value's quotes, so `$(…)`
    /// lands unquoted — quoting cannot save this one, which is exactly why
    /// the recogniser has to see the marked quote and refuse.
    ///
    /// Asserting that a marker IS created is the unusual direction, and it
    /// is the point: if a later change made this shape inert, the corpus
    /// entry it is paired with would be pinning a refusal that no longer
    /// defends anything, and this test says so instead of staying quietly
    /// green.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test func theRefusedMarkedQuoteTemplateWouldOtherwiseExecute() throws {
        let marker = "marker-marked-template"
        let command = "echo x'\u{0308}{{X}}'\u{0308}"
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "$(touch \(marker))"])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                markerExists(marker, in: directory),
                """
                this template no longer executes its payload; the refusal it is pinned \
                against may now be defending nothing
                """)
        }
    }

    // MARK: - The table is the classification, and bash is only a lower bound

    /// Every builtin and reserved word the installed `bash` reports appears
    /// in `SnippetCommandSurvey.shellVocabulary`.
    ///
    /// This is the answer to a deny-list living inside an allow-list, which
    /// is the shape that produced a finding in most rounds of this branch —
    /// but it is only half of it, and the half that cannot decide anything.
    /// The table's verdicts come from execution against bash 3.2, bash 4.4,
    /// bash 5.2 and zsh 5.9; this test only refuses to let a name the local
    /// shell knows go unclassified. Its failure message says which way round
    /// that is, because reading it the other way is exactly what happened.
    @Test func everyLocalShellWordIsInTheTable() throws {
        let builtins = try bashWords("-b")
        let keywords = try bashWords("-k")
        #expect(builtins.count > 30, "compgen -b returned nothing usable")
        #expect(keywords.count > 10, "compgen -k returned nothing usable")

        // Every OTHER shell this machine has, for the reason `shellWords`
        // states: the table's scope is no longer bash and zsh, and the two
        // other shells macOS ships know names neither of them reports.
        // Absent rather than required, so the suite does not depend on a
        // layout of /bin — but present on macOS 15, which is what CI runs.
        var otherWords: [String] = []
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            otherWords += try shellWords(
                binary: "/bin/zsh",
                arguments: ["-fc", "print -l ${(k)builtins} ${(k)reswords}"])
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/ksh") {
            otherWords += try shellWords(binary: "/bin/ksh", arguments: ["-c", "builtin"])
        }

        for word in builtins + keywords + otherWords {
            #expect(SnippetCommandSurvey.classifiedShellWords.contains(word), """
                a shell installed on this machine reports a word this project has never \
                classified: \(word). Add it to SnippetCommandSurvey.shellVocabulary with \
                evidence — and get the evidence from the shells a SERVER runs, not only from \
                this one. Put a payload in every argument shape (a substitution, an array \
                subscript, an assignment through a subscript, a bare command word) under every \
                option letter, run it in bash 3.2, bash 5.x, zsh, mksh and ksh93, and look for \
                the marker. If any of them re-parses, the verdict is .reparses; being harmless \
                here is not evidence.
                """)
        }
    }

    /// The table is a table: one verdict per name, and no name twice.
    /// A duplicate would make the derived sets depend on which entry the
    /// reader happened to write second.
    @Test func theShellVocabularyNamesEachWordOnce() {
        var seen: Set<String> = []
        for fact in SnippetCommandSurvey.shellVocabulary {
            #expect(seen.insert(fact.name).inserted, "\(fact.name) is classified twice")
        }
        #expect(seen.count == SnippetCommandSurvey.classifiedShellWords.count)
    }

    /// A verdict of "harmless" has to rest on a measurement that came out
    /// inert. Two labels are not that, and both were in the accepted set:
    ///
    /// - `.reasoned` is the label for a behaviour no shell here can
    ///   demonstrate, and it is only ever a reason to REFUSE. A name talked
    ///   into the accepted set without a sweep behind it is the finding of
    ///   an earlier round in a new spelling.
    /// - `.executed` means A MARKER WAS CREATED, which is the opposite of
    ///   harmless. Six reserved words carried it while their own strings
    ///   said "no marker" — a review found the mislabel by reading, because
    ///   this test could not see it: the evidence said "measured, it fired"
    ///   and the verdict said "measured, it is safe", and nothing compared
    ///   the two. `.probedInert` is the label those six needed, and this
    ///   half is what makes the next such mislabel fail instead of read
    ///   oddly.
    @Test func nothingIsCalledHarmlessOnAReason() {
        for fact in SnippetCommandSurvey.shellVocabulary
        where fact.verdict == .doesNotReparse || fact.verdict == .takesAWordNotACommandName {
            switch fact.evidence {
            case .reasoned(let reason):
                Issue.record("""
                    \(fact.name) is classified as harmless on a reason rather than a \
                    measurement (\(reason)). Sweep it against bash 3.2, bash 5.x, zsh, mksh and \
                    ksh93, or refuse it.
                    """)
            case .executed(let shape):
                Issue.record("""
                    \(fact.name) is classified as harmless while carrying .executed (\(shape)), \
                    which means a marker was created. Either the verdict is wrong, or the \
                    measurement came out inert and the label should be .probedInert.
                    """)
            case .sweptInert, .probedInert:
                break
            }
        }
    }

    /// The reach is a property of re-parsing names and of nothing else, and
    /// the two derived sets are one set and a subset of it.
    ///
    /// `Verdict.reparses` carries its `Reach` as an associated value, so
    /// "harmless with a reach" is already unwritable; what this pins is the
    /// half a type cannot: that the template-wide names are a SUBSET of the
    /// re-parsing ones. Two independent lists would eventually disagree, and
    /// the disagreement that costs something is a name in the template-wide
    /// list that the reader never looks up because it is not in the other.
    @Test func theTemplateWideNamesAreASubsetOfTheReparsingOnes() {
        #expect(!SnippetCommandSurvey.templateWideReparsingCommands.isEmpty)
        #expect(
            SnippetCommandSurvey.templateWideReparsingCommands
                .isSubset(of: SnippetCommandSurvey.reparsingCommands),
            "a name is refused template-wide that the reader does not recognise at all")
        #expect(
            SnippetCommandSurvey.templateWideReparsingCommands
                != SnippetCommandSurvey.reparsingCommands,
            """
            every re-parsing name refuses the whole template again; the narrowing to the \
            placeholder's own command has been undone
            """)
    }


    /// What the gate must answer when the placeholder is an argument OF
    /// `name` — derived from the table's reach rather than written out, so
    /// the expectation cannot drift from the classification it is checking.
    private func expectedRefusal(
        forAnArgumentOf name: String
    ) -> SnippetVariableSubstitution.Problem {
        SnippetCommandSurvey.templateWideReparsingCommands.contains(name)
            ? .unanalyzableContext(kind: .evaluation)
            : .placeholderIsReparsedByItsCommand(name: "X")
    }

    /// A placeholder in the argument list of a re-parsing command is refused
    /// — every one of them, and by the mechanism its reach calls for. The
    /// pure half; the executing half is below.
    @Test func everyReparsingCommandRefusesAPlaceholderAmongItsArguments() {
        for name in SnippetCommandSurvey.reparsingCommands {
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: "\(name) {{X}}", variables: [placeholder("X")])
                    == expectedRefusal(forAnArgumentOf: name),
                "a command classified as re-parsing accepted a value in its own argument list")
        }
    }

    /// The other direction of the same rule, and the one that was too wide
    /// before: a re-parsing name somewhere ELSE in the template does not
    /// refuse a placeholder that never reaches it.
    ///
    /// The maintainer agreed to a price of three templates in which the
    /// placeholder is an argument TO the re-parsing command. What was
    /// actually charged was every template mentioning one of forty-five
    /// names anywhere — `tar czf {{OUT}} /srv && printf 'done\n'` was
    /// refused over a `printf` the value never goes near. A `printf` in a
    /// different command of the same line protects nothing, so it may not
    /// cost anything either.
    ///
    /// Built from the table, one template per name, so a name added later is
    /// covered without anybody remembering to add it. The names whose reach
    /// is the whole template are the exception and stay refused — after
    /// `eval` or `alias` or `hash -p`, "which command is this an argument
    /// of" has no honest answer.
    @Test func aReparsingNameElsewhereInTheTemplateDoesNotRefuseTheValue() {
        for name in SnippetCommandSurvey.reparsingCommands {
            let command = "echo {{X}}; \(name) z"
            let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
            if SnippetCommandSurvey.templateWideReparsingCommands.contains(name) {
                #expect(
                    problem == .unanalyzableContext(kind: .evaluation), """
                    \(name) can change what a later word runs, so a placeholder anywhere in the \
                    same template has to stay refused
                    """)
            } else {
                #expect(problem == nil, """
                    \(name) re-parses its own arguments only, and the placeholder here is an \
                    argument of echo. Refusing it is the over-wide refusal this test exists to \
                    keep closed.
                    """)
            }
        }
    }

    /// One entry of the executing corpus: a template, the value that arms
    /// it, and the shell state its builtin needs around it.
    ///
    /// `prefix`/`suffix` exist because some builtins only re-parse in a
    /// context — `local` wants a function, `unset` wants the array whose
    /// subscript it evaluates, `alias` wants the definition to be reached
    /// again — and refusing to model that would mean quietly dropping the
    /// builtins whose danger is deferred. What surrounds the template is
    /// ordinary shell state a live session may already hold; the template
    /// and the value are what the gate sees.
    struct ReparseCase: Sendable, CustomStringConvertible {
        let template: String
        let value: String
        var prefix = ""
        var suffix = ""

        var description: String { template }
    }

    /// Every builtin this project classifies as re-parsing, proven the way
    /// the `trap` finding was opened: payload in the VALUE, resolved through
    /// the real code, executed by real `bash` in a fresh scratch directory,
    /// marker checked.
    ///
    /// Both halves are asserted for each case, and the second half is the
    /// one that keeps this honest over time: the gate refuses the template,
    /// AND the same template resolved anyway creates the marker. Without the
    /// second, a later change could make one of these shapes inert and leave
    /// a refusal standing that defends nothing.
    ///
    /// The cases here are the ones the `bash` on THIS machine can be made to
    /// demonstrate, which is a smaller set than the table refuses — see
    /// `theTemplatesThisShellCannotDisproveAreStillRefused` below for the
    /// rest, and `SnippetCommandSurvey.shellVocabulary` for each entry's own
    /// evidence. Two members whose stated mechanism a later round measured
    /// FALSE and re-derived: `export` does not evaluate a subscript in bash
    /// at all (3.2.57, 4.4 and 5.2 all leave `export 'a[$(touch M)]=1'`
    /// inert, where `declare -x` on the same payload creates the marker) —
    /// it is refused because ZSH evaluates it; and `mapfile`/`readarray` are
    /// inert on the subscript shape and fire on `-C`, which is a callback
    /// command rather than an assignment.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test(
        "a re-parsing builtin is refused, and would run the value if it were not",
        arguments: [
            ReparseCase(template: "eval {{X}}", value: "$(touch MARKER)"),
            ReparseCase(template: "trap {{X}} EXIT", value: "$(touch MARKER)"),
            ReparseCase(template: "let {{X}}", value: "a[$(touch MARKER)]"),
            ReparseCase(template: "declare {{X}}", value: "x[$(touch MARKER)]=1"),
            ReparseCase(template: "typeset {{X}}", value: "x[$(touch MARKER)]=1"),
            ReparseCase(template: "read {{X}}", value: "a[$(touch MARKER)]"),
            ReparseCase(template: "compgen -W {{X}} x", value: "$(touch MARKER)"),
            ReparseCase(template: "command eval {{X}}", value: "touch MARKER"),
            ReparseCase(template: "builtin eval {{X}}", value: "touch MARKER"),
            ReparseCase(
                template: "local {{X}}", value: "x[$(touch MARKER)]=1",
                prefix: "reparse_case() { ", suffix: "; }\nreparse_case"),
            ReparseCase(
                template: "unset {{X}}", value: "a[$(touch MARKER)]",
                prefix: "a=(1 2)\n"),
            ReparseCase(
                template: "source {{X}}", value: "./sourced.sh",
                prefix: "echo 'touch MARKER' > sourced.sh\n"),
            ReparseCase(
                template: ". {{X}}", value: "./sourced.sh",
                prefix: "echo 'touch MARKER' > sourced.sh\n"),
            ReparseCase(
                template: "alias {{X}}", value: "reparse_alias=touch MARKER",
                prefix: "shopt -s expand_aliases\n", suffix: "\nreparse_alias"),
            // `hash -p` sat in the ACCEPTED set until a review ran it. It
            // takes a PATH, which is what a `{{PATH}}` placeholder holds,
            // and what it does with the path outlives the command: every
            // later `zzz` in the session runs it. That is why its reach is
            // the whole template rather than its own argument list.
            // A redirection between the command name and the placeholder.
            // While the `&` of `2>&1` was read as a command separator, all
            // three of these were ACCEPTED — the flag saying "this command
            // re-parses" was cleared by a command boundary that does not
            // exist, and `1` was read as the name of the command the value
            // supposedly belongs to. They fire on this machine's bash
            // 3.2.57, which is what makes them executable here rather than
            // pinned in the list below.
            ReparseCase(template: "declare 2>&1 {{X}}", value: "x[$(touch MARKER)]=1"),
            ReparseCase(template: "let >&2 {{X}}", value: "a[$(touch MARKER)]"),
            ReparseCase(template: "read 2>&1 {{X}}", value: "a[$(touch MARKER)]"),
            ReparseCase(
                template: "hash -p {{X}} zzz", value: "./reparse_hashed.sh",
                prefix: "printf '#!/bin/sh\\ntouch MARKER\\n' > reparse_hashed.sh\n"
                    + "chmod +x reparse_hashed.sh\n",
                suffix: "\nzzz"),
        ])
    func aReparsingBuiltinIsRefusedAndWouldOtherwiseRun(testCase: ReparseCase) throws {
        // The command name is the template's first word in every case here,
        // and the reach of that name decides which refusal is the right one
        // — the whole template for `eval` and `source`, this command's
        // argument list for `let` and `declare`.
        let commandName = String(testCase.template.split(separator: " ")[0])
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: testCase.template, variables: [placeholder("X")])
                == expectedRefusal(forAnArgumentOf: commandName),
            "the gate accepted a template whose command name re-parses its arguments")

        let resolved = SnippetVariableSubstitution.resolve(
            command: testCase.template, variables: [placeholder("X")],
            values: ["X": testCase.value])
        try withScratchDirectory { directory in
            try runInBash(testCase.prefix + resolved + testCase.suffix, in: directory)
            #expect(
                markerExists("MARKER", in: directory), """
                this template no longer executes its payload; the refusal above may now be \
                defending nothing
                """)
        }
    }

    /// `[[` is the reserved word the measurement caught, and the reason the
    /// keyword question is asked separately from the builtin one.
    ///
    /// `[[ 1 -eq 'a[$(touch MARKER)]' ]]` runs the substitution: a numeric
    /// comparison inside `[[ … ]]` evaluates its operands as arithmetic, and
    /// an array subscript in arithmetic is expanded. Read as an ordinary
    /// command name — which is what this reader did — `[[` would leave the
    /// placeholder in plain argument position and the gate would accept it.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test func aConditionalExpressionKeywordIsRefusedAndWouldOtherwiseRun() throws {
        let command = "[[ 1 -eq {{X}} ]]"
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
                == .unanalyzableContext(kind: .unrecognizedSyntax),
            "the gate read a conditional expression as an ordinary command")

        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "a[$(touch MARKER)]"])
        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                markerExists("MARKER", in: directory), """
                this template no longer executes its payload; the refusal above may now be \
                defending nothing
                """)
        }
    }

    /// The refusals this machine cannot disprove, pinned as verdicts.
    ///
    /// Every other executing test in this file asserts a marker as well as a
    /// refusal, because a refusal is only worth pinning while the shape it
    /// refuses would still do damage. These cannot: the shapes below are
    /// inert on `/bin/bash` 3.2.57 and create the marker on bash 4.4, bash
    /// 5.2 or zsh 5.9, and macOS pins `/bin/bash` at 3.2.57. Running them
    /// here would assert nothing; running them there is what
    /// `shellVocabulary` records as the evidence for each entry.
    ///
    /// So what is pinned is the GATE'S VERDICT, which is the thing this
    /// process can actually observe. It is the whole finding of the round
    /// that produced this test: every one of these templates was ACCEPTED
    /// while its payload ran on the other side, and every one of them reads
    /// harmlessly enough for an imported snippet to carry it.
    @Test(
        "a template only another shell re-parses is still refused",
        arguments: [
            "[ -v {{X}} ]",
            "test -v {{X}}",
            "printf -v {{X}} '%s' y",
            "print -v {{X}} y",
            "export {{X}}",
            "set -A {{X}} 1",
            "getopts ab {{X}}",
            "shift {{X}}",
            "exit {{X}}",
            "return {{X}}",
            "mapfile -C {{X}} -c 1 arr",
            "zstyle -g {{X}}",
            "ulimit {{X}}",
            "ulimit -n {{X}}",
            "nameref y={{X}}",
            "readonly {{X}}",
            "integer {{X}}",
        ])
    func theTemplatesThisShellCannotDisproveAreStillRefused(command: String) {
        let commandName = String(command.split(separator: " ")[0])
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")])
                == expectedRefusal(forAnArgumentOf: commandName),
            """
            the gate accepted a template whose command name re-parses on a shell macSCP may \
            well be talking to. This machine cannot show the marker; that is the reason the \
            verdict is pinned instead of the execution.
            """)
    }

    /// The union posture, stated as a cost rather than left implicit.
    ///
    /// `[ -f {{PATH}} ]` was rescued by name in an earlier round and is now
    /// refused, because the same builtin's `-v` runs a substitution on bash
    /// 4.2 and later. Modelling the OPTION instead of the name would keep
    /// it, at the price of a per-builtin option grammar this reader would
    /// have to get right — and a reader that gets it wrong accepts. This
    /// test exists so the cost shows up as a decision somebody made, not as
    /// a surprise in a bug report.
    ///
    /// These are the templates the maintainer accepted as refused, and the
    /// placeholder is that command's OWN argument in every one of them.
    /// That is what makes them the right pin for the narrowing below: the
    /// narrowing scopes a refusal to the placeholder's own command, and
    /// here the placeholder's own command is the re-parsing one — so the
    /// narrowing may not reach them, and this test fails if it ever does.
    @Test func theUnionPostureRefusesEverydayTemplatesAndSaysSo() {
        for command in ["[ -f {{X}} ]", "test -f {{X}}", "printf '%s' {{X}}", "export FOO={{X}}"] {
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: [placeholder("X")])
                    == .placeholderIsReparsedByItsCommand(name: "X"),
                "\(command) is accepted again; the union posture has been softened somewhere")
        }
    }

    /// And the cost that was NOT agreed, now not charged.
    ///
    /// Each of these has its placeholder in an ordinary command and a
    /// re-parsing name somewhere else on the line. Every one of them was
    /// refused before the refusal was narrowed to the placeholder's own
    /// command, and the reason each was refused — `printf`, `[`, `exit`,
    /// `set`, `return`, `break` — never sees the value at all.
    ///
    /// The second half is the one that makes this more than a preference:
    /// each template is resolved with a payload in the value and run, and
    /// the marker must NOT appear. An accepted template that executes its
    /// payload is the failure this whole area exists to prevent, and the
    /// narrowing is exactly the kind of change that could introduce one.
    ///
    /// EXECUTES THE PAYLOAD, on purpose, in a fresh scratch directory.
    @Test(
        "a re-parsing name in another command of the same template costs nothing",
        arguments: [
            "tar czf out.tgz {{X}} && printf 'done\\n'",
            "cd /tmp && [ -d .git ] && ls {{X}}",
            "rsync -a {{X}} /backup; exit 0",
            "cat {{X}} | head -n 100; return 0",
            "echo {{X}}; set -e",
            "echo {{X}}; test -f /etc/hosts",
            "for f in a b; do echo {{X}}; break; done",
            "if [ -d /tmp ]; then echo {{X}}; fi",
            "printf 'start\\n'; ls {{X}}",
            "export FOO=1; ls {{X}}",
            // The redirection shapes, from the accepting side. A snippet
            // that logs its own errors writes `2>&1`, and the placeholder
            // after it is an argument of the harmless command in front —
            // which is exactly what the reader must say, without the `&`
            // making it forget which command that is.
            "ls 2>&1 {{X}}",
            "cat {{X}} 2>&1 | head -n 100",
            "printf 'a\\n' >&2; ls {{X}}",
            "ls &>out.log {{X}}",
            "2>&1 ls {{X}}",
        ])
    func aNarrowedRefusalAcceptsAndStaysSafe(command: String) throws {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) == nil,
            """
            \(command) is refused although the placeholder is an argument of a harmless \
            command. This is the over-wide refusal the narrowing removed.
            """)

        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "$(touch MARKER)"])
        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists("MARKER", in: directory),
                "an accepted template executed its value; the narrowing opened a hole")
        }
    }
}
