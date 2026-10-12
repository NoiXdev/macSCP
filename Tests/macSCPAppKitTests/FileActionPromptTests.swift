import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// A file action may declare variables, as a snippet may, and the editor lets
/// an author declare them (file-actions plan, Task 11). The pane has to ASK
/// for their values before it plans: `FileActionPlanner.plan` fills a
/// declared placeholder from `promptedValues` and, given none, fills it with
/// the empty string. Nothing asked, and an action typed or spawned with an
/// empty argument where the author expected a value.
@Suite("File action prompt")
struct FileActionPromptTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(
            of: repoRoot.appendingPathComponent("Sources/MacSCPAppKit/\(name)"))
    }

    private let level = SnippetVariable(
        name: "LEVEL", prompt: "Level", kind: .freeText, placement: .placeholder,
        defaultValue: "9", remembersLastValue: false)

    /// Stored, not computed: a computed property would mint a new id at each
    /// read, and the identity is one of the things the prompt must carry.
    private let action = FileAction(
        name: "Zip", command: "zip -r {{LEVEL}} out.zip {{PATH}}",
        variables: [
            SnippetVariable(
                name: "LEVEL", prompt: "Level", kind: .freeText, placement: .placeholder,
                defaultValue: "9", remembersLastValue: false)
        ],
        runsOn: [.remote])

    private let file = RemoteFileItem(name: "a.txt", path: "/home/u/a.txt", kind: .file)

    /// The behaviour that makes the prompt necessary, pinned: with no value
    /// the placeholder becomes an empty quoted word. It is the reason the
    /// pane must not plan a declaring action before asking.
    @Test func withoutAValueADeclaredPlaceholderBecomesAnEmptyWord() throws {
        let result = FileActionPlanner.plan(action: action, selection: [file], side: .remote)
        guard case .success(.shellLines(let lines)) = result else {
            Issue.record("expected shell lines, got \(result)")
            return
        }
        #expect(lines == ["zip -r '' out.zip '/home/u/a.txt'"])
    }

    @Test func withAPromptedValueItIsQuotedIntoTheLine() throws {
        let result = FileActionPlanner.plan(
            action: action, selection: [file], side: .remote, promptedValues: ["LEVEL": "5"])
        guard case .success(.shellLines(let lines)) = result else {
            Issue.record("expected shell lines, got \(result)")
            return
        }
        #expect(lines == ["zip -r '5' out.zip '/home/u/a.txt'"])
    }

    @Test func thePromptIsTheSnippetPromptOverTheActionsOwnDeclarations() {
        let snippet = fileActionPromptSnippet(for: action)
        #expect(snippet.variables == [level])
        #expect(snippet.command == action.command)
        #expect(snippet.id == action.id)
        #expect(snippet.name == "Zip")
        // It starts on each declaration's default, and remembers nothing:
        // there is no remembered value to read for an action.
        #expect(fileActionPromptValues(for: action) == ["LEVEL": "9"])
    }

    /// The prompt's title shows the name, and a name can come from a file.
    @Test func theNameOnThePromptIsDrawnThroughTheMarkerRenderer() {
        let hostile = FileAction(
            name: "A\u{202E}B\nC", command: "ls {{LEVEL}}", variables: [level], runsOn: [.remote])
        let snippet = fileActionPromptSnippet(for: hostile)
        #expect(snippet.name.contains("<U+202E>"))
        #expect(snippet.name.contains("\u{202E}") == false)
        #expect(snippet.name.contains("\n") == false)
    }

    // MARK: - The pane

    @Test func thePaneAsksBeforeItPlansAnActionThatDeclaresVariables() throws {
        let extensionCode = try Self.code("BrowserPane+FileActions.swift")
        #expect(extensionCode.contains("action.variables.isEmpty"))
        #expect(extensionCode.contains("fileActionPrompt = FileActionPrompt("))
        // The one place a plan is made, and it is handed what was asked for.
        #expect(extensionCode.components(separatedBy: "FileActionPlanner.plan(").count - 1 == 1)
        #expect(extensionCode.contains("promptedValues: promptedValues"))
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains(".sheet(item: $fileActionPrompt)"))
        #expect(pane.contains("SnippetVariablePromptSheet("))
        // Confirming plans; cancelling does not.
        #expect(pane.contains("presentFileActionRequest("))
    }

    /// The prompt remembers nothing: no remembered-value store is reachable
    /// from the extension that asks.
    @Test func thePromptStoresNoValue() throws {
        let extensionCode = try Self.code("BrowserPane+FileActions.swift")
        #expect(extensionCode.contains("fileActionPrompt"))
        #expect(extensionCode.contains(".remember(") == false)
        #expect(extensionCode.contains("SnippetVariableMemoryStore") == false)
    }
}
