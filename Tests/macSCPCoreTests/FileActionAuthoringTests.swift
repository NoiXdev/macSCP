import Foundation
import Testing

@testable import macSCPCore

/// What an import is allowed to store, and how a command is normalised on
/// its way in.
///
/// `FileActionExportCodec` does not validate: an imported action with no side
/// or with a placeholder in a refused position decodes fine. The context menu
/// declines to OFFER such an action, but nothing there stops it being STORED,
/// and an import file is the one route by which an action reaches the store
/// without the editor having looked at it.
@Suite("FileActionAuthoring")
struct FileActionAuthoringTests {
    private func exported(
        name: String = "Count", command: String = "wc -l {{PATH}}",
        runsOn: Set<BrowserPaneSide> = [.remote],
        perSelection: FileActionPerSelection = .oncePerFile,
        variables: [SnippetVariable] = []
    ) -> ExportedFileAction {
        ExportedFileAction(
            FileAction(
                name: name, command: command, variables: variables, runsOn: runsOn,
                perSelection: perSelection))
    }

    private func review(
        _ actions: [ExportedFileAction], existing: [FileAction] = []
    ) -> FileActionAuthoring.ImportReview {
        FileActionAuthoring.review(FileActionExportPayload(actions: actions), existing: existing)
    }

    // MARK: - The command

    @Test func aTrailingNewlineIsTrimmedFromTheCommand() {
        #expect(FileActionAuthoring.normalizedCommand("wc -l {{PATH}}\n") == "wc -l {{PATH}}")
        #expect(FileActionAuthoring.normalizedCommand("wc -l {{PATH}}\r\n") == "wc -l {{PATH}}")
        #expect(FileActionAuthoring.normalizedCommand("  wc -l {{PATH}} \t\n\n") == "wc -l {{PATH}}")
    }

    /// Only the ends. A command that spans lines on purpose keeps the break
    /// in the middle, so the gate still sees (and for a local-capable action
    /// refuses) the second command.
    @Test func aLineBreakInTheMiddleOfTheCommandStays() {
        #expect(FileActionAuthoring.normalizedCommand("ls\ntouch y\n") == "ls\ntouch y")
    }

    /// The trailing line feed is what the gate refuses for a local-capable
    /// action, so the trim is what turns a pasted command into a runnable
    /// one; the control is that the untrimmed text really is refused.
    @Test func theTrimIsWhatMakesAPastedLocalCommandPassTheGate() {
        let pasted = "wc -l {{PATH}}\n"
        let untrimmed = FileAction(name: "n", command: pasted, runsOn: [.local])
        #expect(FileActionTemplate.firstProblem(in: untrimmed) == .notOneSimpleCommandForLocal)
        let trimmed = FileAction(
            name: "n", command: FileActionAuthoring.normalizedCommand(pasted), runsOn: [.local])
        #expect(FileActionTemplate.firstProblem(in: trimmed) == nil)
    }

    // MARK: - Import

    @Test func aValidActionIsAcceptedWithAFreshIdentity() {
        let incoming = exported()
        let result = review([incoming])
        #expect(result.refused.isEmpty)
        #expect(result.accepted.count == 1)
        #expect(result.accepted.first?.name == "Count")
        #expect(result.accepted.first?.id != incoming.id)
    }

    @Test func anActionWithNoSideIsRefusedAndNotAccepted() {
        let result = review([exported(runsOn: [])])
        #expect(result.accepted.isEmpty)
        #expect(result.refused.map(\.reason) == [.template(.noSideDeclared)])
        #expect(result.refused.map(\.name) == ["Count"])
    }

    @Test func aPlaceholderInARefusedPositionIsRefused() {
        let result = review([exported(command: "echo \"{{PATH}}\"")])
        #expect(result.accepted.isEmpty)
        guard case .template(.declaration)? = result.refused.first?.reason else {
            Issue.record("expected a declaration problem, got \(result.refused)")
            return
        }
    }

    @Test func quotingInALocalCapableActionIsRefused() {
        let result = review([exported(command: "echo 'a b' {{NAME}}", runsOn: [.local])])
        #expect(result.accepted.isEmpty)
        #expect(result.refused.map(\.reason) == [.template(.quotingIsNotRunnableLocally)])
    }

    @Test func aNameThatFitsTheWrongFormIsRefused() {
        let result = review([exported(command: "zip out {{PATHS}}")])
        #expect(
            result.refused.map(\.reason)
                == [.template(.reservedNameDoesNotFitTheForm(name: "PATHS", form: .oncePerFile))])
    }

    @Test func aNameOfOnlyBlanksIsRefused() {
        let result = review([exported(name: "  \t")])
        #expect(result.accepted.isEmpty)
        #expect(result.refused.map(\.reason) == [.emptyName])
    }

    /// A file that carries both kinds reports both: the good ones are stored
    /// and the bad ones are named, in the order the file held them.
    @Test func aMixedFileAcceptsTheGoodAndNamesTheBad() {
        let result = review([
            exported(name: "Good one"),
            exported(name: "No side", runsOn: []),
            exported(name: "Good two", command: "gzip {{PATH}}"),
            exported(name: "Quoted", command: "echo 'a' {{NAME}}", runsOn: [.local]),
        ])
        #expect(result.accepted.map(\.name) == ["Good one", "Good two"])
        #expect(result.refused.map(\.name) == ["No side", "Quoted"])
    }

    /// The invariant itself, over every refusal above at once: nothing the
    /// review accepts is something the gate refuses.
    @Test func nothingAcceptedIsRefusedByTheGate() {
        let result = review([
            exported(name: "a"), exported(name: "b", runsOn: []),
            exported(name: "c", command: "echo \"{{PATH}}\""),
            exported(name: "d", command: "echo 'x' {{NAME}}", runsOn: [.local]),
            exported(name: "e", command: "zip out {{PATHS}}"),
            exported(name: "f", command: "wc -l {{PATH}}\n", runsOn: [.local]),
        ])
        #expect(result.accepted.isEmpty == false)
        for action in result.accepted {
            #expect(FileActionTemplate.firstProblem(in: action) == nil, "\(action.name)")
        }
    }

    @Test func aTrailingNewlineInAnImportedCommandIsTrimmedNotRefused() {
        let result = review([exported(command: "wc -l {{PATH}}\n", runsOn: [.local])])
        #expect(result.refused.isEmpty)
        #expect(result.accepted.map(\.command) == ["wc -l {{PATH}}"])
    }

    @Test func theNameIsTrimmed() {
        let result = review([exported(name: "  Count \n")])
        #expect(result.accepted.map(\.name) == ["Count"])
    }

    @Test func variablesAndFormTravelThrough() {
        let variable = SnippetVariable(
            name: "LEVEL", prompt: "Level", kind: .freeText, placement: .placeholder,
            defaultValue: "9", remembersLastValue: false)
        let result = review([
            exported(
                command: "zip -{{LEVEL}} out.zip {{PATHS}}", perSelection: .onceWithEveryPath,
                variables: [variable])
        ])
        #expect(result.refused.isEmpty)
        #expect(result.accepted.first?.variables == [variable])
        #expect(result.accepted.first?.perSelection == .onceWithEveryPath)
    }

    // MARK: - Importing twice

    @Test func anActionTheUserAlreadyHasIsCountedAndNotAddedAgain() {
        let have = exported().imported()
        let result = review([exported()], existing: [have])
        #expect(result.accepted.isEmpty)
        #expect(result.alreadyPresent == 1)
        #expect(result.refused.isEmpty)
    }

    @Test func aDuplicateInsideOneFileIsAddedOnce() {
        let result = review([exported(), exported()])
        #expect(result.accepted.count == 1)
        #expect(result.alreadyPresent == 1)
    }

    /// The control for the two above: a different command is not a duplicate,
    /// so the comparison is about content and not only the name.
    @Test func sameNameDifferentCommandIsNotADuplicate() {
        let have = exported().imported()
        let result = review([exported(command: "gzip {{PATH}}")], existing: [have])
        #expect(result.accepted.count == 1)
        #expect(result.alreadyPresent == 0)
    }

    @Test func aRefusedActionDoesNotCountAsPresent() {
        let have = exported(runsOn: []).imported()
        let result = review([exported(runsOn: [])], existing: [have])
        #expect(result.refused.count == 1)
        #expect(result.alreadyPresent == 0)
    }
}
