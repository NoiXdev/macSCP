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

    /// Without the synthesized variables the position of `{{PATH}}` would
    /// never be checked, and a quoted placeholder is exactly the position
    /// `.argument` exists to insist on. This is the test that pins the
    /// synthesis, so it is also the test that pins the design's central
    /// security claim.
    @Test func aSelectionPlaceholderInsideQuotesIsRefusedThoughNobodyDeclaredIt() {
        let action = remoteAction("wc -l '{{PATH}}'")
        let problem = FileActionTemplate.firstProblem(in: action)
        let isDeclarationProblem: Bool
        if case .declaration = problem { isDeclarationProblem = true } else { isDeclarationProblem = false }
        #expect(isDeclarationProblem)
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
        let problem = FileActionTemplate.firstProblem(in: action)
        #expect(problem != nil)
    }
}
