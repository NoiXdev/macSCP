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

    /// POSIX permits it. The resolved line then holds a newline, and that
    /// makes `SnippetSendPlanner.plan` refuse an insert it would otherwise
    /// send — a send SHAPE chosen by server data. The planner's job is to produce the line
    /// correctly; this test records that the shape changes, so the App task
    /// that sends it cannot be written in ignorance of it.
    @Test func aNameHoldingANewlineIsStillOneQuotedWordAndChangesTheSendShape() throws {
        let path = "/tmp/two\nlines"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "two\nlines")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])

        // Inserting without executing is the shape a newline changes: the
        // same call refuses a multi-line command and sends a one-line one.
        // (`bracketedPaste: true` would not show it, because that path
        // sends the multi-line command too, wrapped in the paste markers.)
        let hostile = SnippetSendPlanner.plan(
            command: produced[0], execute: false, bracketedPaste: false)
        #expect(hostile == .refusedMultilineInsert)

        let plainLine = try lines(action("wc -l {{PATH}}"), [item("/tmp/one", "one")])
        let plain = SnippetSendPlanner.plan(
            command: plainLine[0], execute: false, bracketedPaste: false)
        #expect(plain != .refusedMultilineInsert)
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
