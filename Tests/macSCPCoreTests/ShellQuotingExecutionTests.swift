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

    /// `/bin/bash`'s own answer to "what builtins do you have", as the
    /// classification test's input. Asking the shell rather than listing
    /// what we remember is the whole mechanism: a builtin this project has
    /// never seen shows up here and fails a test, instead of sailing through
    /// as an ordinary command name.
    private func bashWords(_ compgenFlag: String) throws -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "compgen \(compgenFlag)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
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

    // MARK: - The classification of builtins is complete by construction

    /// Every builtin `bash` reports is classified, one way or the other.
    ///
    /// This is the answer to a deny-list living inside an allow-list, which
    /// is the shape that produced a finding in most rounds of this branch:
    /// `reparsingCommands` held `eval`, `command` and `builtin`, and a
    /// review executed `trap {{X}} EXIT` and got a marker. Adding `trap`
    /// closes one instance. Asking the shell for the whole list closes the
    /// class — a builtin `bash` gains that macSCP has never seen fails here
    /// instead of being read as an ordinary command name.
    ///
    /// The input is `compgen -b` from the `bash` that is actually installed,
    /// so this is not a snapshot of somebody's memory of bash 3.2. The
    /// classification is spread over three places on purpose: `refused` and
    /// `introducers` are production sets the reader consults, and
    /// `builtinsThatDoNotReparse` is here in the test, because "this one is
    /// harmless" is a claim about a measurement rather than a rule the
    /// reader applies.
    @Test func everyBashBuiltinIsClassified() throws {
        let builtins = try bashWords("-b")
        #expect(builtins.count > 30, "compgen -b returned nothing usable")
        for builtin in builtins {
            let classified =
                SnippetCommandSurvey.reparsingCommands.contains(builtin)
                || SnippetCommandSurvey.commandIntroducers.contains(builtin)
                || Self.builtinsThatDoNotReparse.contains(builtin)
            #expect(classified, """
                bash reports a builtin this project has never classified: \(builtin). Decide \
                it against bash rather than from memory — put a payload in an argument, run \
                it, look for the marker. If the shell turns the argument into shell code, now \
                or later or out of a file it names, it belongs in \
                SnippetCommandSurvey.reparsingCommands; if the word after it is a command \
                name, in commandIntroducers; otherwise in builtinsThatDoNotReparse here, \
                with the shapes that were measured.
                """)
        }
    }

    /// Builtins measured NOT to turn an argument into shell code.
    ///
    /// Each was run through `/bin/bash` 3.2.57 with a payload in every
    /// argument shape the re-parsing ones fell to — `'$(touch M)'`, an array
    /// subscript `'a[$(touch M)]'`, an assignment through a subscript, the
    /// `-i` arithmetic form, and the option shapes `-v`, `-C`, `-x`, `-s`,
    /// `-f`, `-p`, `-e` — in a fresh scratch directory each time. None
    /// produced a marker.
    ///
    /// `test` and `[` are the interesting entries, because their sibling
    /// `[[` IS a re-parser: `[[ 1 -eq 'a[$(touch M)]' ]]` runs the
    /// substitution and `[ 1 -eq 'a[$(touch M)]' ]` does not. The
    /// conditional keyword evaluates its numeric operands as arithmetic; the
    /// builtin parses a number. Keeping them apart is what lets
    /// `[ -f {{PATH}} ]` stay a usable snippet.
    ///
    /// `compopt` is bash 4+, absent from the `bash` this was measured on,
    /// and listed from its documented surface: it takes completion option
    /// NAMES and no command.
    private static let builtinsThatDoNotReparse: Set<String> = [
        ":", "[", "bg", "break", "caller", "cd", "compopt", "continue", "dirs", "disown",
        "echo", "exit", "false", "fg", "getopts", "hash", "help", "jobs", "kill", "logout",
        "popd", "printf", "pushd", "pwd", "return", "set", "shift", "shopt", "suspend",
        "test", "times", "true", "type", "ulimit", "umask", "unalias", "wait",
    ]

    /// Every reserved word `bash` reports is classified too.
    ///
    /// The question a keyword raises is different from a builtin's: a
    /// keyword is syntax this reader does not model at all, and reading one
    /// as an ordinary command name means the word after it — which `bash`
    /// may well run as the command — is checked as an argument. So each is
    /// either an introducer (the word after it IS a command name), or
    /// refused outright (`unmodelledKeywords`), or measured to take a WORD
    /// rather than a command name.
    @Test func everyBashKeywordIsClassified() throws {
        let keywords = try bashWords("-k")
        #expect(keywords.count > 10, "compgen -k returned nothing usable")
        for keyword in keywords {
            let classified =
                SnippetCommandSurvey.commandIntroducers.contains(keyword)
                || SnippetCommandSurvey.unmodelledKeywords.contains(keyword)
                || Self.keywordsThatTakeAWordNotACommandName.contains(keyword)
            #expect(classified, """
                bash reports a reserved word this project has never classified: \(keyword). \
                Decide it against bash: if the word after it is a command name it belongs in \
                commandIntroducers, if the construct brings a sub-language this reader cannot \
                read it belongs in unmodelledKeywords, and if it simply takes a word say so \
                here — after measuring, the way `[[` was measured.
                """)
        }
    }

    /// Reserved words after which `bash` reads a WORD, not a command name.
    ///
    /// Measured, each with a payload in the position that follows it: `for`
    /// and `select` are syntax errors there, `case` matches the word against
    /// its patterns, `in` introduces a word list, `function` names a
    /// function. No marker from any of them. Listing them as introducers
    /// would be the stricter reading and would also refuse `case "$1" in`,
    /// which is an everyday snippet — so the measurement, not the reflex,
    /// decides.
    private static let keywordsThatTakeAWordNotACommandName: Set<String> = [
        "case", "for", "select", "in", "function",
    ]

    /// A re-parsing command in command-name position is refused, whatever
    /// else the template does. The pure half; the executing half is below.
    @Test func everyReparsingCommandIsRefusedAsACommandName() {
        for name in SnippetCommandSurvey.reparsingCommands {
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: "\(name) {{X}}", variables: [placeholder("X")])
                    == .unanalyzableContext(kind: .evaluation),
                "a command classified as re-parsing was accepted as a command name")
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
    /// The re-parsing members with no case here are the ones this `bash`
    /// cannot be made to demonstrate: `export` and `readonly` (the
    /// assignment family whose subscript evaluation `declare`, `typeset` and
    /// `local` show, but which 3.2.57 does not perform for these two);
    /// `complete`, `bind`, `fc` and `history` (they store a command string
    /// for an interactive shell to run later, and the shell here is not
    /// interactive — note the target of a snippet IS); `enable` (loads a
    /// builtin from a shared object, which needs one to exist); and
    /// `mapfile`/`readarray` (bash 4+, absent here — `-C` runs a callback
    /// command). They stay classified as re-parsing on the strict side.
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
        ])
    func aReparsingBuiltinIsRefusedAndWouldOtherwiseRun(testCase: ReparseCase) throws {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: testCase.template, variables: [placeholder("X")])
                == .unanalyzableContext(kind: .evaluation),
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

    /// And the counter-check that keeps the refusals from swallowing the
    /// shell: `test` and `[` take the same payload and stay inert, so
    /// `[ -f {{PATH}} ]` is still a snippet somebody can save.
    @Test func theConditionalBuiltinsAreNotConditionalKeywords() throws {
        for name in ["test", "["] {
            let command = name == "[" ? "[ 1 -eq {{X}} ]" : "test 1 -eq {{X}}"
            #expect(
                SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: [placeholder("X")]) == nil,
                "an ordinary conditional builtin was refused")

            let resolved = SnippetVariableSubstitution.resolve(
                command: command, variables: [placeholder("X")],
                values: ["X": "a[$(touch MARKER)]"])
            try withScratchDirectory { directory in
                try runInBash(resolved, in: directory)
                #expect(
                    !markerExists("MARKER", in: directory),
                    "this builtin evaluates arithmetic after all and must be reclassified")
            }
        }
    }
}
