import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionPlanner")
struct FileActionPlannerTests {
    private func item(_ path: String, _ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: .file)
    }

    private func action(
        _ command: String, runsOn: Set<BrowserPaneSide> = [.remote],
        form: FileActionPerSelection = .oncePerFile
    ) -> FileAction {
        FileAction(name: "n", command: command, runsOn: runsOn, perSelection: form)
    }

    private func lines(
        _ action: FileAction, _ selection: [RemoteFileItem]
    ) throws -> [String] {
        let plan = try FileActionPlanner.plan(
            action: action, selection: selection, side: .remote).get()
        guard case .shellLines(let lines) = plan else {
            Issue.record("expected shell lines, got \(plan)")
            return []
        }
        return lines
    }

    // MARK: - The two forms

    @Test func oncePerFileProducesOneLinePerItem() throws {
        let produced = try lines(
            action("wc -l {{PATH}}"), [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["wc -l '/a/x'", "wc -l '/a/y'"])
    }

    @Test func onceWithEveryPathProducesOneLineHoldingEveryPath() throws {
        let produced = try lines(
            action("zip -r out.zip {{PATHS}}", form: .onceWithEveryPath),
            [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["zip -r out.zip '/a/x' '/a/y'"])
    }

    @Test func theDirectoryIsTheOneTheSelectionShares() throws {
        let produced = try lines(
            action("ls {{DIR}} {{PATHS}}", form: .onceWithEveryPath),
            [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["ls '/a' '/a/x' '/a/y'"])
    }

    // MARK: - Review Focus 1: a file name that is itself shell syntax

    /// The quoter holds. Every test that pins it today pins a value the USER
    /// typed; this one pins a value that arrived from a directory listing,
    /// which is the only kind this subsystem ever sees.
    @Test func aNameThatIsShellSyntaxStaysOneLiteralWord() throws {
        let hostile = [
            "/tmp/$(id)",
            "/tmp/`id`",
            "/tmp/; rm -rf ~ ;",
            "/tmp/${HOME}",
            "/tmp/a&&b",
        ]
        for path in hostile {
            let produced = try lines(action("wc -l {{PATH}}"), [item(path, "x")])
            #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"], "\(path)")
        }
    }

    /// A single quote in the name is the case the quoter exists for: it has
    /// to close, escape and reopen.
    @Test func aNameHoldingASingleQuoteIsQuotedByTheProjectsQuoter() throws {
        let path = "/tmp/it's"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "it's")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])
    }

    // MARK: - Review Focus 2: a newline in a file name

    /// POSIX permits one in a file name. This test used to record that the
    /// line came out as "one quoted word" and only changed the send shape
    /// (`aNameHoldingANewlineIsStillOneQuotedWordAndChangesTheSendShape`).
    /// That is withdrawn: a single-line remote command is typed with no
    /// bracketed paste, so a newline in a value is Enter to the line
    /// editor and quoting cannot help. It is refused instead; the whole
    /// family is pinned in "Fix round 1" below.
    @Test func aNameHoldingANewlineIsRefusedOnTheRemotePath() {
        let path = "/tmp/two\nlines"
        let result = FileActionPlanner.plan(
            action: action("wc -l {{PATH}}"), selection: [item(path, "two\nlines")], side: .remote)
        #expect(result == .failure(.valueHoldsAControlCharacter(name: "PATH", value: path)))
    }

    // MARK: - Review Focus 3: a name beginning with a hyphen

    /// Refused on the LOCAL path, where there is no shell and the only way a
    /// value stops being a value is by being read as an option. Refused
    /// rather than prefixed `./`, because the author placed the placeholder
    /// and macSCP cannot know whether a prefix belongs there.
    @Test func aNameBeginningWithAHyphenIsRefusedOnTheLocalPath() {
        let result = FileActionPlanner.plan(
            action: action("gzip {{NAME}}", runsOn: [.local]),
            selection: [item("/a/-rf", "-rf")], side: .local)
        #expect(
            result == .failure(.valueWouldBeReadAsAnOption(name: "NAME", value: "-rf")))
    }

    /// The positive beside it: `{{PATH}}` cannot trip that refusal, because
    /// it is absolute and so begins with a slash. Without this the test
    /// above would also pass on a planner that refused everything.
    @Test func anAbsolutePathIsNeverRefusedAsAnOption() throws {
        let plan = try FileActionPlanner.plan(
            action: action("gzip {{PATH}}", runsOn: [.local]),
            selection: [item("/a/-rf", "-rf")], side: .local).get()
        #expect(plan == .invocations([FileActionInvocation(executable: "gzip", arguments: ["/a/-rf"])]))
    }

    /// And on the remote path the same name is fine, because the quoting
    /// holds and a quoted `-rf` is an operand.
    @Test func aNameBeginningWithAHyphenIsNotRefusedOnTheRemotePath() throws {
        let produced = try lines(action("gzip {{NAME}}"), [item("/a/-rf", "-rf")])
        #expect(produced == ["gzip '-rf'"])
    }

    // MARK: - Review Focus 4: a combining mark after a metacharacter

    /// The exact shape `ShellScalar.swift` records — an apostrophe followed
    /// by U+0308 COMBINING DIAERESIS is ONE `Character` that does not
    /// compare equal to `"'"` — now arriving from a listing rather than
    /// from a text field.
    @Test func anApostropheFollowedByACombiningMarkIsStillEscaped() throws {
        let path = "/tmp/a'\u{0308}b"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "a'\u{0308}b")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])
        let quotedCloses = produced[0].hasSuffix("'")
        #expect(quotedCloses)
    }

    // MARK: - Review Focus 5: nothing to run

    @Test func anEmptySelectionIsRefusedRatherThanPlannedAsNoCommands() {
        #expect(
            FileActionPlanner.plan(action: action("wc -l {{PATH}}"), selection: [], side: .remote)
                == .failure(.nothingToRun))
    }

    // MARK: - Sides and quoting

    @Test func aSideTheActionDidNotDeclareIsRefused() {
        #expect(
            FileActionPlanner.plan(
                action: action("wc -l {{PATH}}", runsOn: [.remote]),
                selection: [item("/a/x", "x")], side: .local)
                == .failure(.sideNotDeclared(.local)))
    }

    @Test func aTemplateProblemIsReportedBeforeAnythingElse() {
        let noSide = FileAction(name: "n", command: "wc -l {{PATH}}", runsOn: [])
        #expect(
            FileActionPlanner.plan(action: noSide, selection: [], side: .remote)
                == .failure(.template(.noSideDeclared)))
    }

    @Test func aLocalInvocationSplitsTheTemplateIntoWords() throws {
        let plan = try FileActionPlanner.plan(
            action: action("gzip -k {{PATH}}", runsOn: [.local]),
            selection: [item("/a/x", "x")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(executable: "gzip", arguments: ["-k", "/a/x"])
            ]))
    }

    @Test func aPlaceholderInsideAWordBecomesOneArgument() throws {
        let plan = try FileActionPlanner.plan(
            action: action("cp {{PATH}} {{NAME}}.bak", runsOn: [.local]),
            selection: [item("/a/x", "x")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(executable: "cp", arguments: ["/a/x", "x.bak"])
            ]))
    }

    @Test func everyPathBecomesSeveralArgumentsInOneLocalInvocation() throws {
        let plan = try FileActionPlanner.plan(
            action: action("zip -r out.zip {{PATHS}}", runsOn: [.local], form: .onceWithEveryPath),
            selection: [item("/a/x", "x"), item("/a/y", "y")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(
                    executable: "zip", arguments: ["-r", "out.zip", "/a/x", "/a/y"])
            ]))
    }

    // MARK: - What a name chosen by the server must not be able to reach
    //
    // Everything below is beyond the brief's sixteen, and each case pins a
    // failure the brief's own implementation had.

    private func variable(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    private func invocations(
        _ action: FileAction, _ selection: [RemoteFileItem],
        promptedValues: [String: String] = [:]
    ) throws -> [FileActionInvocation] {
        let plan = try FileActionPlanner.plan(
            action: action, selection: selection, side: .local,
            promptedValues: promptedValues).get()
        guard case .invocations(let invocations) = plan else {
            Issue.record("expected invocations, got \(plan)")
            return []
        }
        return invocations
    }

    /// The list is spliced in after every other placeholder is resolved, so
    /// a path that SPELLS a placeholder is never read as one. A file called
    /// `{{DIR}}` inside a directory called `$(id)` is the whole attack:
    /// scanned again, the placeholder would be replaced by the quoted
    /// directory INSIDE the quotes of its own list entry, which closes them,
    /// and the directory's `$(id)` would stand unquoted.
    @Test func aPathSpellingADirectoryPlaceholderIsNotSubstitutedInsideTheList() throws {
        let hostile = "/tmp/$(id)/{{DIR}}"
        let produced = try lines(
            action("ls {{DIR}} {{PATHS}}", form: .onceWithEveryPath),
            [item(hostile, "{{DIR}}")])
        let expected =
            "ls \(PosixQuoting.singleQuoted("/tmp/$(id)")) \(PosixQuoting.singleQuoted(hostile))"
        #expect(produced == [expected])
    }

    /// The same, for a variable the author declared and the user filled in.
    @Test func aPathSpellingADeclaredVariableIsNotSubstitutedInsideTheList() throws {
        let hostile = "/tmp/{{WHERE}}"
        let withVariable = FileAction(
            name: "n", command: "cp {{PATHS}} {{WHERE}}", variables: [variable("WHERE")],
            runsOn: [.remote], perSelection: .onceWithEveryPath)
        let plan = try FileActionPlanner.plan(
            action: withVariable, selection: [item(hostile, "{{WHERE}}")], side: .remote,
            promptedValues: ["WHERE": "$(id)"]).get()
        let expected =
            "cp \(PosixQuoting.singleQuoted(hostile)) \(PosixQuoting.singleQuoted("$(id)"))"
        #expect(plan == .shellLines([expected]))
    }

    /// An environment variable is still prepended once, ahead of the whole
    /// line, when the list is spliced in.
    @Test func anEnvironmentVariableIsPrependedOnceAroundTheList() throws {
        let env = SnippetVariable(
            name: "TOKEN", prompt: "", kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
        let withEnvironment = FileAction(
            name: "n", command: "ls {{PATHS}} {{PATHS}}", variables: [env],
            runsOn: [.remote], perSelection: .onceWithEveryPath)
        let plan = try FileActionPlanner.plan(
            action: withEnvironment, selection: [item("/a/x", "x"), item("/a/y", "y")],
            side: .remote, promptedValues: ["TOKEN": "t"]).get()
        #expect(plan == .shellLines(["export TOKEN='t'; ls '/a/x' '/a/y' '/a/x' '/a/y'"]))
    }

    /// Local, one pass: a name that spells another placeholder is a name.
    @Test func aNameSpellingAPlaceholderIsNotSubstitutedOnTheLocalPath() throws {
        let produced = try invocations(
            action("echo {{NAME}}", runsOn: [.local]), [item("/a/{{PATH}}", "{{PATH}}")])
        #expect(produced == [FileActionInvocation(executable: "echo", arguments: ["{{PATH}}"])])
    }

    /// A hyphen followed by a combining mark is one `Character` that is not
    /// `"-"`, so a cluster-wise prefix test says the word does not begin
    /// with a hyphen while a tool reads it byte for byte and sees one.
    @Test func aHyphenFollowedByACombiningMarkIsStillRefusedAsAnOption() {
        let name = "-\u{0308}rf"
        let result = FileActionPlanner.plan(
            action: action("gzip {{NAME}}", runsOn: [.local]),
            selection: [item("/a/" + name, name)], side: .local)
        #expect(result == .failure(.valueWouldBeReadAsAnOption(name: "NAME", value: name)))
    }

    /// The refusal is about the value being the START of a word. A word the
    /// author began with a hyphen of their own is theirs, whatever follows.
    @Test func aValueAfterTheAuthorsOwnHyphenIsNotRefused() throws {
        let produced = try invocations(
            action("gzip --suffix={{NAME}}", runsOn: [.local]), [item("/a/-rf", "-rf")])
        #expect(
            produced == [FileActionInvocation(executable: "gzip", arguments: ["--suffix=-rf"])])
    }

    /// `U+00A0` is `Character.isWhitespace` and is not a blank to a shell, so
    /// splitting on the first splits a word the second keeps whole.
    @Test func aNoBreakSpaceInsideAWordDoesNotSplitIt() throws {
        let produced = try invocations(
            action("echo a\u{00A0}b {{NAME}}", runsOn: [.local]), [item("/a/x", "x")])
        #expect(
            produced == [
                FileActionInvocation(executable: "echo", arguments: ["a\u{00A0}b", "x"])
            ])
    }

    /// A comment covers a span and so counts as part of one simple command;
    /// it is not an argument.
    @Test func aTrailingCommentIsNotAnArgument() throws {
        let produced = try invocations(
            action("wc -l {{PATH}} # count them", runsOn: [.local]), [item("/a/x", "x")])
        #expect(produced == [FileActionInvocation(executable: "wc", arguments: ["-l", "/a/x"])])
    }

    @Test func aLocalTemplateHoldingQuotingIsRefused() {
        #expect(
            FileActionPlanner.plan(
                action: action("echo 'a b' {{NAME}}", runsOn: [.local]),
                selection: [item("/a/x", "x")], side: .local)
                == .failure(.quotingIsNotRunnableLocally))
    }

    /// `{{PATHS}}` becomes several arguments, which only makes sense as a
    /// word of its own. Inside a longer word the list would have to be
    /// glued to text it cannot be glued to, and the placeholder must not
    /// reach the program as literal text either.
    @Test func everyPathInsideALongerWordIsRefusedOnTheLocalPath() {
        #expect(
            FileActionPlanner.plan(
                action: action(
                    "zip --files={{PATHS}}", runsOn: [.local], form: .onceWithEveryPath),
                selection: [item("/a/x", "x")], side: .local)
                == .failure(.everyPathNeedsAWordOfItsOwn))
    }

    /// The program is always the template's own word. The gate refuses a
    /// placeholder there, and this pins that it does.
    @Test func aPlaceholderAsTheProgramIsRefused() {
        let result = FileActionPlanner.plan(
            action: action("{{NAME}} -k", runsOn: [.local]),
            selection: [item("/a/x", "x")], side: .local)
        var isTemplateRefusal = false
        if case .failure(.template) = result { isTemplateRefusal = true }
        #expect(isTemplateRefusal)
    }

    /// `execve` truncates an argument at the first NUL, so `a\0b` would run
    /// on a file called `a` while the confirmation sheet displayed another.
    /// A POSIX path cannot hold one; an SFTP name can.
    @Test func aNameHoldingANulCharacterIsRefusedOnTheLocalPath() {
        let name = "a\u{0}b"
        let result = FileActionPlanner.plan(
            action: action("gzip {{NAME}}", runsOn: [.local]),
            selection: [item("/a/" + name, name)], side: .local)
        #expect(result == .failure(.valueHoldsANulCharacter(name: "NAME", value: name)))
    }

    @Test func aPathHoldingANulCharacterIsRefusedOnTheLocalPath() {
        let path = "/a/x\u{0}y"
        let result = FileActionPlanner.plan(
            action: action("gzip {{PATH}}", runsOn: [.local]),
            selection: [item(path, "xy")], side: .local)
        #expect(result == .failure(.valueHoldsANulCharacter(name: "PATH", value: path)))
    }

    @Test func aNulCharacterInOneOfEveryPathIsRefusedOnTheLocalPath() {
        let hostile = "/a/y\u{0}z"
        let result = FileActionPlanner.plan(
            action: action("zip out.zip {{PATHS}}", runsOn: [.local], form: .onceWithEveryPath),
            selection: [item("/a/x", "x"), item(hostile, "yz")], side: .local)
        #expect(result == .failure(.valueHoldsANulCharacter(name: "PATHS", value: hostile)))
    }

    // MARK: - Fix round 1: a control character in a server value, remote path

    /// A single-line remote command is TYPED into the terminal with no
    /// bracketed paste, so a C0 byte inside a quoted value reaches the line
    /// discipline and the line editor, which act on it below the shell's
    /// parser. Quoting cannot help. U+0015 (^U) kills the line being typed,
    /// a tab completes, a newline is Enter, DEL erases.
    private static let hostileControls: [(label: String, scalar: String)] = [
        ("ctrl-U", "\u{15}"), ("tab", "\t"), ("newline", "\n"), ("DEL", "\u{7F}"),
        ("NUL", "\u{0}"), ("ESC", "\u{1B}"), ("ctrl-C", "\u{3}"), ("CR", "\r"),
        ("unit separator, the last C0", "\u{1F}"),
    ]

    @Test func aControlCharacterInANameIsRefusedOnTheRemotePath() {
        for (label, scalar) in Self.hostileControls {
            let name = "a" + scalar + "b"
            let result = FileActionPlanner.plan(
                action: action("wc -l {{NAME}}"), selection: [item("/a/x", name)], side: .remote)
            #expect(
                result == .failure(.valueHoldsAControlCharacter(name: "NAME", value: name)),
                "\(label) in NAME")
        }
    }

    @Test func aControlCharacterInAPathOrADirectoryIsRefusedOnTheRemotePath() {
        let path = "/a\u{15}/x"
        let byPath = FileActionPlanner.plan(
            action: action("wc -l {{PATH}}"), selection: [item(path, "x")], side: .remote)
        #expect(byPath == .failure(.valueHoldsAControlCharacter(name: "PATH", value: path)))

        // `DIR` is the parent of the normalized path, so the same path
        // reaches it when the template asks for the directory alone.
        let byDir = FileActionPlanner.plan(
            action: action("ls {{DIR}}"), selection: [item(path, "x")], side: .remote)
        #expect(byDir == .failure(.valueHoldsAControlCharacter(name: "DIR", value: "/a\u{15}")))
    }

    @Test func aControlCharacterInOneOfEveryPathIsRefusedOnTheRemotePath() {
        let hostile = "/a/y\t"
        let result = FileActionPlanner.plan(
            action: action("zip out.zip {{PATHS}}", form: .onceWithEveryPath),
            selection: [item("/a/x", "x"), item(hostile, "y")], side: .remote)
        #expect(result == .failure(.valueHoldsAControlCharacter(name: "PATHS", value: hostile)))
    }

    /// The refusal is about a value that is PLACED. A name the template never
    /// uses reaches no shell, so it does not stop the action.
    @Test func aControlCharacterInAValueTheTemplateDoesNotUseIsNotRefused() throws {
        let produced = try lines(action("ls {{DIR}}"), [item("/a/x\u{15}", "x\u{15}")])
        #expect(produced == ["ls '/a'"])
    }

    /// A prompted value is the user's own text, and an author's template is
    /// the author's: neither is server data, and neither is refused here.
    @Test func aPromptedValueHoldingACtrlUIsNotRefusedOnTheRemotePath() throws {
        let withVariable = FileAction(
            name: "n", command: "echo {{NOTE}} {{PATH}}", variables: [variable("NOTE")],
            runsOn: [.remote])
        let plan = try FileActionPlanner.plan(
            action: withVariable, selection: [item("/a/x", "x")], side: .remote,
            promptedValues: ["NOTE": "a\u{15}b"]).get()
        #expect(plan == .shellLines(["echo 'a\u{15}b' '/a/x'"]))
    }

    /// The same name is accepted on the local path: no line editor sits
    /// between an argv and the program, so only NUL (`execve`) matters there.
    /// The two refusals overlap on NUL for different reasons on different
    /// paths, and that is deliberate.
    @Test func theSameNameIsAcceptedOnTheLocalPathExceptForNul() throws {
        for (label, scalar) in Self.hostileControls where scalar != "\u{0}" {
            let name = "a" + scalar + "b"
            let produced = try invocations(
                action("gzip {{NAME}}", runsOn: [.local]), [item("/a/x", name)])
            #expect(
                produced == [FileActionInvocation(executable: "gzip", arguments: [name])],
                "\(label) in NAME, local")
        }
        let nul = "a\u{0}b"
        #expect(
            FileActionPlanner.plan(
                action: action("gzip {{NAME}}", runsOn: [.local]),
                selection: [item("/a/x", nul)], side: .local)
                == .failure(.valueHoldsANulCharacter(name: "NAME", value: nul)))
    }

    /// The boundary of the refusal: the first scalar above C0 and the
    /// printable ones stay legal, so an ordinary unicode name still runs.
    @Test func theScalarsAroundTheRefusedRangeAreNotRefused() throws {
        for name in ["a b", "a~b", "a\u{80}b", "ä", "日本語"] {
            let produced = try lines(action("wc -l {{NAME}}"), [item("/a/x", name)])
            #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(name))"], "\(name)")
        }
    }

    /// Nothing stops an author declaring one name twice, so the template
    /// holds two identical ranges for it. Assembling the word must skip the
    /// second rather than slice backwards over the first, which traps.
    @Test func aVariableDeclaredTwiceFillsItsPlaceholderOnceOnTheLocalPath() throws {
        let twice = FileAction(
            name: "n", command: "gzip {{LEVEL}}",
            variables: [variable("LEVEL"), variable("LEVEL")], runsOn: [.local])
        let produced = try invocations(
            twice, [item("/a/x", "x")], promptedValues: ["LEVEL": "-9"])
        #expect(produced == [FileActionInvocation(executable: "gzip", arguments: ["-9"])])
    }

    /// The remote path reaches the same declarations through `resolve`,
    /// which carries its own guard; pinned so that stays true.
    @Test func aVariableDeclaredTwiceFillsItsPlaceholderOnceOnTheRemotePath() throws {
        let twice = FileAction(
            name: "n", command: "gzip {{LEVEL}}",
            variables: [variable("LEVEL"), variable("LEVEL")], runsOn: [.remote])
        let plan = try FileActionPlanner.plan(
            action: twice, selection: [item("/a/x", "x")], side: .remote,
            promptedValues: ["LEVEL": "-9"]).get()
        #expect(plan == .shellLines(["gzip '-9'"]))
    }

    @Test func theSamePlaceholderTwiceInOneLocalWordIsFilledTwice() throws {
        let produced = try invocations(
            action("cp {{PATH}} {{NAME}}-{{NAME}}", runsOn: [.local]), [item("/a/x", "x")])
        #expect(
            produced == [FileActionInvocation(executable: "cp", arguments: ["/a/x", "x-x"])])
    }

    @Test func twoAdjacentPlaceholdersInOneLocalWordAreFilledInOrder() throws {
        let produced = try invocations(
            action("echo {{DIR}}{{NAME}}", runsOn: [.local]), [item("/a/x", "x")])
        #expect(produced == [FileActionInvocation(executable: "echo", arguments: ["/ax"])])
    }

    /// One hostile item among ordinary ones refuses the whole plan: nothing
    /// is returned for the ordinary items, so nothing runs on a selection
    /// the user did not see refused.
    @Test func oneHostileItemAmongOrdinaryOnesRefusesTheWholeLocalPlan() throws {
        let selection = [item("/a/x", "x"), item("/a/-rf", "-rf"), item("/a/y", "y")]
        let result = FileActionPlanner.plan(
            action: action("gzip {{NAME}}", runsOn: [.local]), selection: selection,
            side: .local)
        #expect(result == .failure(.valueWouldBeReadAsAnOption(name: "NAME", value: "-rf")))

        // The positive beside it: the same selection through `{{PATH}}` is
        // three ordinary invocations, in order.
        let produced = try invocations(action("gzip {{PATH}}", runsOn: [.local]), selection)
        #expect(
            produced == [
                FileActionInvocation(executable: "gzip", arguments: ["/a/x"]),
                FileActionInvocation(executable: "gzip", arguments: ["/a/-rf"]),
                FileActionInvocation(executable: "gzip", arguments: ["/a/y"]),
            ])
    }

    /// A declared variable's prompted value fills its placeholder on the
    /// local path; it is the user's own text, so a leading hyphen is theirs.
    @Test func aPromptedValueFillsItsPlaceholderOnTheLocalPath() throws {
        let withVariable = FileAction(
            name: "n", command: "gzip {{LEVEL}} {{PATH}}", variables: [variable("LEVEL")],
            runsOn: [.local])
        let produced = try invocations(
            withVariable, [item("/a/x", "x")], promptedValues: ["LEVEL": "-9"])
        #expect(
            produced == [FileActionInvocation(executable: "gzip", arguments: ["-9", "/a/x"])])
    }
}
