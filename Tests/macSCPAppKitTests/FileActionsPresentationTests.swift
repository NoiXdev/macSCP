import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the file-action editor and its sheet RENDER, as values: the sentence
/// for each of the gate's refusals, the import result, and the load outcome.
/// No test in this project draws a SwiftUI view; these are the decisions the
/// views read.
@Suite("File actions presentation")
struct FileActionsPresentationTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func problems() -> [FileActionTemplate.Problem] {
        [
            .declaration(.placeholderInsideQuotes(name: "NAME")),
            .reservedVariableName("PATH"),
            .environmentPlacementIsNotRunnableLocally(variable: "MODE"),
            .notOneSimpleCommandForLocal,
            .noSideDeclared,
            .reservedNameDoesNotFitTheForm(name: "PATHS", form: .oncePerFile),
            .quotingIsNotRunnableLocally,
            .emptyCommand,
        ]
    }

    /// The case name of a value or of a source line: the text up to the first
    /// parenthesis, colon or comma.
    private func caseName(_ text: some StringProtocol) -> String {
        String(text.prefix { $0 != "(" && $0 != ":" && $0 != "," && $0 != " " })
    }

    // MARK: - One sentence per case

    /// The cases are counted in the source, not remembered: the enum's own
    /// case lines against the arms of the function that words them. A case
    /// added to `FileActionTemplate.Problem` fails here before it can fall
    /// into a sentence written for another one, and the list above is held
    /// to the same count.
    @Test func everyProblemCaseHasItsOwnArm() throws {
        let template = try SourceCorpus.code(
            of: Self.repoRoot.appendingPathComponent(
                "Sources/macSCPCore/FileActions/FileActionTemplate.swift"))
        let enumStart = try #require(template.range(of: "public enum Problem"))
        let enumBody = String(template[enumStart.upperBound...])
        let enumEnd = try #require(enumBody.range(of: "\n    }\n"))
        let declaredLines = enumBody[..<enumEnd.lowerBound]
            .split(separator: "\n").filter { $0.hasPrefix("        case ") }
        let declaredNames = Set(declaredLines.map { caseName($0.dropFirst("        case ".count)) })
        let declared = declaredLines.count

        let presentation = try SourceCorpus.code(
            of: Self.repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/FileActionsPresentation.swift"))
        let start = try #require(
            presentation.range(of: "func fileActionProblemText(for problem"))
        let body = String(presentation[start.upperBound...])
        let end = try #require(body.range(of: "\n}\n"))
        let function = body[..<end.lowerBound]
        let armLines = function.split(separator: "\n").filter { $0.hasPrefix("    case .") }
        let armNames = Set(armLines.map { caseName($0.dropFirst("    case .".count)) })
        let arms = armLines.count

        #expect(declared > 0, "the enum could not be read")
        #expect(arms == declared, "\(declared) cases, \(arms) arms")
        // By name and not only by number: a case added to the enum is named
        // in the failure, whichever of the arms or the fixture lacks it.
        #expect(armNames == declaredNames, "arms differ from the enum by \(armNames.symmetricDifference(declaredNames))")
        let fixtureNames = Set(problems().map { caseName(String(describing: $0)) })
        #expect(fixtureNames == declaredNames, "the fixture differs from the enum by \(fixtureNames.symmetricDifference(declaredNames))")
        #expect(function.contains("default:") == false)
    }

    @Test func everyCaseReadsAsItsOwnSentenceThatSaysWhatToDo() {
        let sentences = problems().map(fileActionProblemText(for:))
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == sentences.count, "two cases share a sentence")
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "not a sentence: \(sentence)")
        }
    }

    @Test func theSentencesNameWhatTheyAreAbout() {
        let declaration = fileActionProblemText(for: .declaration(.placeholderInsideQuotes(name: "TARGET")))
        #expect(declaration.contains("TARGET"))
        #expect(declaration.localizedCaseInsensitiveContains("quote"))
        let reserved = fileActionProblemText(for: .reservedVariableName("PATH"))
        #expect(reserved.contains("PATH"))
        let environment = fileActionProblemText(
            for: .environmentPlacementIsNotRunnableLocally(variable: "MODE"))
        #expect(environment.contains("MODE"))
        #expect(environment.localizedCaseInsensitiveContains("shell"))
        let pipe = fileActionProblemText(for: .notOneSimpleCommandForLocal)
        #expect(pipe.localizedCaseInsensitiveContains("pipe"))
        #expect(pipe.localizedCaseInsensitiveContains("redirection"))
        let side = fileActionProblemText(for: .noSideDeclared)
        #expect(side.localizedCaseInsensitiveContains("remote pane"))
        #expect(side.localizedCaseInsensitiveContains("local pane"))
        let quoting = fileActionProblemText(for: .quotingIsNotRunnableLocally)
        #expect(quoting.localizedCaseInsensitiveContains("quotes"))
    }

    /// The other declaration problems are the snippet editor's own sentences,
    /// shared rather than worded twice: an unused variable and a command the
    /// survey cannot read still get a sentence of their own.
    @Test func theOtherDeclarationProblemsAreStillSentences() {
        let inner: [SnippetVariableSubstitution.Problem] = [
            .invalidName(name: "1x"), .unusedPlaceholder(name: "X"),
            .placeholderNotInArgumentPosition(name: "X"),
            .placeholderIsReparsedByItsCommand(name: "X"),
            .unanalyzableContext(kind: .heredoc),
        ]
        let sentences = inner.map { fileActionProblemText(for: .declaration($0)) }
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == sentences.count)
    }

    // MARK: - The form mismatch names the other placeholder

    /// `{{PATH}}` for once per file, `{{PATHS}}` for once for the whole
    /// selection: the sentence says the name to write, and the name it says
    /// is one the gate accepts for that form. The positive reading (the
    /// recommended name is found by asking the gate's own set) is beside the
    /// negative one (the name that was used is not recommended).
    @Test func theMismatchSentenceNamesTheOtherPlaceholder() {
        let cases: [(used: String, form: FileActionPerSelection, expected: String)] = [
            ("PATHS", .oncePerFile, "PATH"),
            ("PATH", .onceWithEveryPath, "PATHS"),
            ("NAME", .onceWithEveryPath, "PATHS"),
        ]
        for (used, form, expected) in cases {
            let sentence = fileActionProblemText(
                for: .reservedNameDoesNotFitTheForm(name: used, form: form))
            #expect(sentence.contains("{{\(used)}}"), "\(used) not named")
            let recommended = FileActionTemplate.names(fitting: form)
                .filter { sentence.contains("{{\($0)}}") }
            #expect(recommended == [expected], "\(used) in \(form): \(recommended)")
            #expect(FileActionTemplate.names(fitting: form).contains(expected))
            #expect(FileActionTemplate.names(fitting: form).contains(used) == false)
        }
    }

    /// The gate's own refusals reach the sentence they should: a real
    /// action, run through `firstProblem`, then worded.
    @Test func aRealRefusalIsWordedEndToEnd() throws {
        let action = FileAction(
            name: "n", command: "zip out {{PATHS}}", runsOn: [.remote], perSelection: .oncePerFile)
        let problem = try #require(FileActionTemplate.firstProblem(in: action))
        let sentence = fileActionProblemText(for: problem)
        #expect(sentence.contains("{{PATHS}}"))
        #expect(sentence.contains("{{PATH}}"))
        #expect(sentence.contains(fileActionFormPhrase(.oncePerFile)))
    }

    // MARK: - Untrusted text

    /// A declared variable's name can come from an imported file. A sentence
    /// that interpolated it raw could carry a bidirectional override or a
    /// line break into the user's reading of it.
    @Test func aHostileNameIsMarkedInTheSentenceAndNeverPassedThrough() {
        let hostile = "A\u{202E}B\nC"
        let sentences = [
            fileActionProblemText(for: .reservedVariableName(hostile)),
            fileActionProblemText(for: .environmentPlacementIsNotRunnableLocally(variable: hostile)),
            fileActionProblemText(for: .declaration(.placeholderInsideQuotes(name: hostile))),
            fileActionProblemText(for: .declaration(.unusedPlaceholder(name: hostile))),
            fileActionProblemText(for: .reservedNameDoesNotFitTheForm(name: hostile, form: .oncePerFile)),
        ]
        for sentence in sentences {
            #expect(sentence.contains("<U+202E>"))
            #expect(sentence.contains("\u{202E}") == false)
            #expect(sentence.contains("\n") == false)
        }
        // An invalid name is reported WITHOUT the name — the snippet editor's
        // own sentence, so a hostile one is not quoted back at all.
        let nameFree = fileActionProblemText(for: .declaration(.invalidName(name: hostile)))
        #expect(nameFree.contains("\u{202E}") == false)
        #expect(nameFree.contains("\n") == false)
        // The control: a plain name is left alone.
        #expect(fileActionProblemText(for: .reservedVariableName("PATH")).contains("PATH"))
    }

    @Test func aVisibleNameSpellsTheMarkersOut() {
        #expect(FileActionPlanDisplay.visible("plain") == "plain")
        #expect(FileActionPlanDisplay.visible("a\u{202E}b") == "a<U+202E>b")
        #expect(FileActionPlanDisplay.visible("a\nb") == "a<U+000A>b")
    }

    // MARK: - Import

    private func review(
        accepted: Int = 0, refused: [FileActionAuthoring.Refused] = [], present: Int = 0
    ) -> FileActionAuthoring.ImportReview {
        FileActionAuthoring.ImportReview(
            accepted: (0..<accepted).map { FileAction(name: "a\($0)", command: "ls") },
            refused: refused, alreadyPresent: present)
    }

    @Test func theResultCountsWhatLandedWasAlreadyThereAndWasRefused() {
        let text = fileActionImportResultText(
            review: review(
                accepted: 3,
                refused: [
                    FileActionAuthoring.Refused(name: "Broken", reason: .template(.noSideDeclared)),
                    FileActionAuthoring.Refused(name: "", reason: .emptyName),
                ],
                present: 2),
            storeFailures: 0)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Imported: 3")
        #expect(lines.contains("Already there: 2"))
        #expect(lines.contains("Not imported: 2"))
        #expect(lines.contains { $0.contains("Broken") && $0.contains("Choose where this action runs") })
        #expect(lines.contains { $0.contains("It has no name.") })
    }

    @Test func aCleanImportSaysNothingAboutRefusals() {
        let text = fileActionImportResultText(review: review(accepted: 1), storeFailures: 0)
        #expect(text == "Imported: 1")
    }

    @Test func aFailedWriteIsReportedAndNotCountedAsImported() {
        let text = fileActionImportResultText(review: review(accepted: 3), storeFailures: 1)
        #expect(text.contains("Imported: 2"))
        #expect(text.contains("Not saved due to an error: 1"))
    }

    /// A refused action's NAME is text from the file.
    @Test func aRefusedNameIsDrawnWithItsMarkers() {
        let text = fileActionImportResultText(
            review: review(refused: [
                FileActionAuthoring.Refused(name: "x\u{202E}y", reason: .template(.noSideDeclared))
            ]),
            storeFailures: 0)
        #expect(text.contains("x<U+202E>y"))
        #expect(text.contains("\u{202E}") == false)
    }

    /// `probe` throws for a file of another kind, and so does `decode`. Both
    /// land in the same generic sentence, and a newer version in its own.
    @Test func theImportErrorsMapToTheirSentences() {
        let generic = fileActionImportErrorText(for: .notAnExportFile)
        #expect(generic.contains("file actions"))
        for error in [SessionExportError.passwordRequired, .wrongPasswordOrCorrupted] {
            #expect(fileActionImportErrorText(for: error) == generic)
        }
        let newer = fileActionImportErrorText(for: .unsupportedVersion(99))
        #expect(newer != generic)
    }

    /// The real thing, not a hand-built error: a snippets file offered to the
    /// actions codec throws exactly what the mapping reads.
    @Test func aSnippetsFileIsRefusedAsNotAnActionsFile() throws {
        let snippets = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(Snippet(name: "n", command: "ls"))]))
        do {
            _ = try FileActionExportCodec.probe(snippets)
            Issue.record("probe accepted a snippets file")
        } catch let error as SessionExportError {
            #expect(error == .notAnExportFile)
            #expect(fileActionImportErrorText(for: error).contains("file actions"))
        }
    }

    // MARK: - The load outcome

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-actions-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aMissingFileIsEmptyAndAnUndecodableOneIsUnreadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActionStore(directory: directory)
        #expect(FileActionsLoad(reading: store) == .loaded([]))
        #expect(FileActionsLoad(reading: store).isUnreadable == false)

        try Data("not json".utf8).write(to: directory.appendingPathComponent("file-actions.json"))
        let load = FileActionsLoad(reading: store)
        #expect(load.isUnreadable)
        #expect(load.actions.isEmpty)
    }

    @Test func aStoredActionIsLoadedInStoreOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActionStore(directory: directory)
        try store.save(FileAction(name: "B", command: "ls"))
        try store.save(FileAction(name: "A", command: "ls"))
        #expect(FileActionsLoad(reading: store).actions.map(\.name) == ["B", "A"])
    }

    // MARK: - Rows and preview

    @Test func theSidesAreNamedAsThePanesAre() {
        #expect(fileActionSidesText([.remote]) == "Remote")
        #expect(fileActionSidesText([.local]) == "Local")
        #expect(fileActionSidesText([.remote, .local]) == "Local · Remote")
        #expect(fileActionSidesText([]) == "")
    }

    @Test func aStoredActionTheGateRefusesIsLabelledNotOffered() {
        let text = fileActionNotOfferedText(for: .noSideDeclared)
        #expect(text.hasPrefix("Not offered in the menu: "))
        #expect(text.contains(fileActionProblemText(for: .noSideDeclared)))
    }

    /// The preview asks the planner exactly as the pane does, so the sample
    /// selection must be one the planner accepts for each form on each side
    /// an action may declare, with the reserved names the form supplies.
    @Test func thePreviewSelectionIsOneThePlannerAccepts() throws {
        #expect(fileActionPreviewSelection(for: .oncePerFile).count == 1)
        #expect(fileActionPreviewSelection(for: .onceWithEveryPath).count == 2)
        let perFile = FileAction(
            name: "n", command: "wc -l {{PATH}} {{DIR}} {{NAME}}", runsOn: [.local, .remote])
        let everyPath = FileAction(
            name: "n", command: "zip out.zip {{PATHS}}", runsOn: [.local, .remote],
            perSelection: .onceWithEveryPath)
        for action in [perFile, everyPath] {
            for side in BrowserPaneSide.allCases {
                let result = FileActionPlanner.plan(
                    action: action,
                    selection: fileActionPreviewSelection(for: action.perSelection), side: side)
                guard case .success(let plan) = result else {
                    Issue.record("\(action.command) refused on \(side): \(result)")
                    continue
                }
                #expect(FileActionPlanDisplay.lines(for: plan).isEmpty == false)
            }
        }
    }

    // MARK: - Where the previewed plan goes

    /// The caption is read off the plan's own case, never off the action's
    /// `runsOn`: an action that declares both panes has two plans, and the
    /// surface shows one of them. `.shellLines` is typed into the
    /// connection's shell; `.invocations` is spawned directly with no shell
    /// at all, and saying "shell" there would tell the user the wrong place.
    @Test func theDestinationIsDerivedFromThePlanAndNotFromTheSidesTheActionDeclares() throws {
        let both = FileAction(
            name: "n", command: "wc -l {{PATH}}", runsOn: [.local, .remote])
        let selection = fileActionPreviewSelection(for: .oncePerFile)
        var captions: [BrowserPaneSide: String] = [:]
        for side in BrowserPaneSide.allCases {
            let result = FileActionPlanner.plan(action: both, selection: selection, side: side)
            captions[side] = fileActionDestinationText(for: try result.get())
        }
        let remote = try #require(captions[.remote])
        let local = try #require(captions[.local])
        #expect(remote != local, "one action, two panes, one caption")
        #expect(remote.localizedCaseInsensitiveContains("shell"))
        #expect(remote.localizedCaseInsensitiveContains("no shell") == false)
        #expect(local.localizedCaseInsensitiveContains("no shell"))
    }

    @Test func eachPlanShapeHasItsOwnCaption() {
        let shell = fileActionDestinationText(for: .shellLines(["ls"]))
        let direct = fileActionDestinationText(
            for: .invocations([FileActionInvocation(executable: "ls", arguments: [])]))
        #expect(shell.isEmpty == false)
        #expect(direct.isEmpty == false)
        #expect(shell != direct)
    }

    @Test func aDeclaredVariablePreviewsAsItsDefaultThenItsFirstOptionThenASample() {
        func variable(_ kind: SnippetVariable.Kind, _ defaultValue: String) -> SnippetVariable {
            SnippetVariable(
                name: "V", prompt: "", kind: kind, placement: .placeholder,
                defaultValue: defaultValue, remembersLastValue: false)
        }
        #expect(fileActionPreviewValue(for: variable(.freeText, "9")) == "9")
        #expect(fileActionPreviewValue(for: variable(.selection(["a", "b"]), "")) == "a")
        #expect(fileActionPreviewValue(for: variable(.freeText, "")) == "sample")
    }
}
