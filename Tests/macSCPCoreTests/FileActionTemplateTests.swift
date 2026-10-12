import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionTemplate")
struct FileActionTemplateTests {
    // These fixtures leave the selection form at `FileAction`'s default on
    // purpose: they use `{{PATH}}`, so they also pin that the default form is
    // one in which the gate accepts it.
    private func remoteAction(
        _ command: String, variables: [SnippetVariable] = []
    ) -> FileAction {
        FileAction(name: "n", command: command, variables: variables, runsOn: [.remote])
    }

    private func localAction(
        _ command: String, variables: [SnippetVariable] = []
    ) -> FileAction {
        FileAction(name: "n", command: command, variables: variables, runsOn: [.local])
    }

    private func declared(_ name: String, placement: SnippetVariable.Placement) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "p", kind: .freeText, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    @Test func aPlainRemoteTemplateHasNoProblem() {
        #expect(FileActionTemplate.firstProblem(in: remoteAction("wc -l {{PATH}}")) == nil)
    }

    @Test func anActionDeclaringNoSideIsRefused() {
        let action = FileAction(name: "n", command: "wc -l {{PATH}}", runsOn: [])
        #expect(FileActionTemplate.firstProblem(in: action) == .noSideDeclared)
    }

    /// The four names the selection binds. `PATH` is the worst of them: a
    /// declared `PATH` with `.environment` placement would emit
    /// `export PATH='…';` into the user's own shell.
    @Test func eachReservedNameIsRefusedAsADeclaredVariable() {
        for name in ["PATH", "PATHS", "DIR", "NAME"] {
            let action = remoteAction(
                "wc -l {{\(name)}}", variables: [declared(name, placement: .placeholder)])
            #expect(
                FileActionTemplate.firstProblem(in: action) == .reservedVariableName(name),
                "\(name) was not refused")
        }
    }

    /// `.environment` prepends `export NAME='value';` as its own statement,
    /// and the local path has no shell to run a statement in.
    @Test func environmentPlacementIsRefusedForALocalCapableAction() {
        let action = localAction("wc -l {{PATH}}", variables: [declared("MODE", placement: .environment)])
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .environmentPlacementIsNotRunnableLocally(variable: "MODE"))
    }

    /// The same action is fine when it declares only the remote side, where
    /// there IS a shell.
    @Test func environmentPlacementIsAcceptedForARemoteOnlyAction() {
        let action = remoteAction(
            "wc -l $MODE {{PATH}}", variables: [declared("MODE", placement: .environment)])
        #expect(FileActionTemplate.firstProblem(in: action) == nil)
    }

    @Test func aPipelineIsRefusedForALocalCapableActionAndAcceptedForARemoteOne() {
        let command = "grep x {{PATH}} | wc -l"
        #expect(FileActionTemplate.firstProblem(in: localAction(command)) == .notOneSimpleCommandForLocal)
        #expect(FileActionTemplate.firstProblem(in: remoteAction(command)) == nil)
    }

    @Test func aRedirectionIsRefusedForALocalCapableAction() {
        #expect(
            FileActionTemplate.firstProblem(in: localAction("wc -l {{PATH}} > out.txt"))
                == .notOneSimpleCommandForLocal)
    }

    @Test func oneSimpleCommandIsRecognisedAsSuch() {
        #expect(FileActionTemplate.isOneSimpleCommand("wc -l {{PATH}}"))
        #expect(FileActionTemplate.isOneSimpleCommand("tar -czf out.tgz 'a b'"))
        #expect(FileActionTemplate.isOneSimpleCommand("ls | wc") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls; ls") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls > f") == false)
    }

    /// The survey treats a line feed as a command separator and appends no
    /// span for it, so it has to count as an uncovered scalar. A skip that
    /// is any wider than a blank or a tab (`isBlank`) would wave it through
    /// as whitespace, and `wc -l {{PATH}}` followed by a second line would
    /// be "one simple command".
    @Test func aLineFeedSeparatesCommandsSoItIsNotOneSimpleCommand() {
        #expect(FileActionTemplate.isOneSimpleCommand("ls\nrm -rf x") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("wc -l {{PATH}}\ntouch y") == false)
        #expect(
            FileActionTemplate.firstProblem(in: localAction("wc -l {{PATH}}\ntouch y"))
                == .notOneSimpleCommandForLocal)
    }

    /// `VAR=x cmd` needs a shell; an argv would run a binary named `VAR=x`.
    /// The survey reads the `VAR=` run as a command-name span, so the
    /// refusal comes from looking for `=` inside such a span.
    @Test func anAssignmentPrefixIsNotOneSimpleCommand() {
        #expect(FileActionTemplate.isOneSimpleCommand("VAR=x cmd") == false)
        #expect(
            FileActionTemplate.isOneSimpleCommand("PGPASSWORD='secret' psql -h {{HOST}}") == false)
        // An `=` inside an argument is not an assignment.
        #expect(FileActionTemplate.isOneSimpleCommand("ls --color=auto {{PATH}}"))
    }

    /// The rest of the boundary. Every `false` below is the safe direction:
    /// the survey leaves `$NAME` and a backslash unclassified, so they read
    /// as uncovered and a local-capable action cannot use them, which is
    /// right, because an argv does no expansion and no unescaping.
    @Test func theBoundaryOfOneSimpleCommandIsPinnedOnBothSides() {
        #expect(FileActionTemplate.isOneSimpleCommand("echo 'a b  c'"))
        #expect(FileActionTemplate.isOneSimpleCommand("wc -l {{PATH}} # note"))
        #expect(FileActionTemplate.isOneSimpleCommand("sleep 1 &") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls $HOME") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls my\\ file") == false)
    }

    /// Without the synthesized variables the position of `{{PATH}}` would
    /// never be checked, and a quoted placeholder is exactly the position
    /// `.argument` exists to insist on. This is the test that pins the
    /// synthesis, so it is also the test that pins the design's central
    /// security claim.
    @Test func aSelectionPlaceholderInsideQuotesIsRefusedThoughNobodyDeclaredIt() {
        let action = remoteAction("wc -l '{{PATH}}'")
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .declaration(.placeholderInsideQuotes(name: "PATH")))
    }

    /// `String.contains` compares by `Character`, and a combining mark after
    /// the closing braces fuses with the last `}` into one `Character`, so a
    /// cluster search does not find `{{PATH}}` there at all. The substitution
    /// finder walks scalars and does find it, so a gate that searched by
    /// cluster would answer "no problem" about a template whose server-chosen
    /// name then lands inside the author's quotes.
    @Test func aCombiningMarkAfterThePlaceholderDoesNotHideItFromThePositionCheck() {
        let action = remoteAction("wc -l '{{PATH}}\u{0308}'")
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .declaration(.placeholderInsideQuotes(name: "PATH")))
        #expect(
            FileActionTemplate.syntheticVariables(for: "wc -l '{{PATH}}\u{0308}'").map(\.name)
                == ["PATH"])
    }

    /// The same search feeds the form-fit check.
    @Test func aCombiningMarkAfterAPerFileNameDoesNotHideItFromTheFormCheck() {
        let action = FileAction(
            name: "n", command: "cp a {{NAME}}\u{0308}", runsOn: [.remote],
            perSelection: .onceWithEveryPath)
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .reservedNameDoesNotFitTheForm(name: "NAME", form: .onceWithEveryPath))
    }

    @Test func syntheticVariablesNamesOnlyTheReservedNamesTheCommandUses() {
        let names = FileActionTemplate.syntheticVariables(for: "cp {{PATH}} {{NAME}}.bak").map(\.name)
        #expect(names == ["NAME", "PATH"])
        #expect(
            FileActionTemplate.syntheticVariables(for: "zip -r o.zip {{PATHS}}").map(\.name)
                == ["PATHS"])
        #expect(FileActionTemplate.syntheticVariables(for: "ls -l").isEmpty)
    }

    @Test func aPerFileNameIsRefusedWhenOneInvocationCoversTheWholeSelection() {
        let everyPath = FileAction(
            name: "n", command: "cp {{PATH}} {{NAME}}.bak", runsOn: [.remote],
            perSelection: .onceWithEveryPath)
        #expect(
            FileActionTemplate.firstProblem(in: everyPath)
                == .reservedNameDoesNotFitTheForm(name: "NAME", form: .onceWithEveryPath))
        let perFile = FileAction(
            name: "n", command: "cp {{PATH}} {{NAME}}.bak", runsOn: [.remote],
            perSelection: .oncePerFile)
        #expect(FileActionTemplate.firstProblem(in: perFile) == nil)
    }

    @Test func theListNameIsRefusedInThePerFileForm() {
        let perFile = FileAction(
            name: "n", command: "zip -r out.zip {{PATHS}}", runsOn: [.remote],
            perSelection: .oncePerFile)
        #expect(
            FileActionTemplate.firstProblem(in: perFile)
                == .reservedNameDoesNotFitTheForm(name: "PATHS", form: .oncePerFile))
        let everyPath = FileAction(
            name: "n", command: "zip -r out.zip {{PATHS}}", runsOn: [.remote],
            perSelection: .onceWithEveryPath)
        #expect(FileActionTemplate.firstProblem(in: everyPath) == nil)
    }

    /// `{{DIR}}` is the one reserved name that fits both forms, because a
    /// pane's listing never spans directories.
    @Test func theDirectoryNameFitsBothForms() {
        for form in [FileActionPerSelection.oncePerFile, .onceWithEveryPath] {
            let command = form == .oncePerFile ? "ls {{DIR}} {{PATH}}" : "ls {{DIR}} {{PATHS}}"
            let action = FileAction(
                name: "n", command: command, runsOn: [.remote], perSelection: form)
            #expect(FileActionTemplate.firstProblem(in: action) == nil, "\(form) refused {{DIR}}")
        }
    }

    /// The placement check runs with no way to switch it off. A store file
    /// carrying the snippet subsystem's waiver key decodes — unknown keys
    /// are ignored — and the check still reports the problem, which is what
    /// makes the absence of the field a boundary rather than a default.
    @Test func aStoredWaiverKeyDoesNotSwitchOffThePlacementCheck() throws {
        let json = """
            {"id":"7E4F7E1C-0000-4000-8000-000000000002","name":"n",
             "command":"wc -l '{{MODE}}'","runsOn":["remote"],
             "perSelection":"onceWithEveryPath",
             "skipsPlaceholderPlacementCheck":true,
             "variables":[{"name":"MODE","prompt":"p","kind":{"freeText":{}},
                           "placement":"placeholder","defaultValue":"",
                           "remembersLastValue":false}]}
            """
        let action = try JSONDecoder().decode(FileAction.self, from: Data(json.utf8))
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .declaration(.placeholderInsideQuotes(name: "MODE")))
    }
}
