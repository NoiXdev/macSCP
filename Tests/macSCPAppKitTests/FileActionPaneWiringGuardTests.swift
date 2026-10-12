import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the user-defined file actions (file-actions plan,
/// 2026-10-12) where a unit test cannot reach: the pane dispatching the
/// menu entry, the sheet it opens, and — from Task 10 — the rule that a run
/// is owned by the activity rather than by a `Task` nothing owns.
///
/// Structural claims read `SourceCorpus.code` (comments AND string literals
/// blanked), catalogue-key claims read `SourceCorpus.commentFree`.
///
/// Known blind spot: SOURCE TEXT only. That the sheet renders and that the
/// confirm button is reachable by mouse are sight checks, and Task 12
/// assigns them to the maintainer.
@Suite("File action pane wiring guard")
struct FileActionPaneWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func literals(_ name: String) throws -> String {
        try SourceCorpus.commentFree(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: path("Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static let keys = [
        "fileAction.confirm.title",
        "fileAction.confirm.message",
        "fileAction.confirm.run",
        "fileAction.confirm.cancel",
        "fileAction.confirm.refused",
    ]

    @Test func theMenuEntryReachesTheExtensionAndNotAnInlineClosure() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("case .userFileAction(let action):"))
        #expect(pane.contains("beginFileAction(action, selection: selection)"))
    }

    @Test func theExtensionBuildsThePlanThroughThePlanner() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("FileActionPlanner.plan("))
        #expect(code.contains("fileActionRequest ="))
    }

    @Test func theSheetIsPresentedFromTheRequest() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("FileActionConfirmSheet("))
        #expect(pane.contains("$fileActionRequest"))
    }

    @Test func everyConfirmKeyIsInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                let value = entries[key] ?? ""
                #expect(value.isEmpty == false, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theSheetUsesTheCatalogueKeysAndNoBareStrings() throws {
        let literals = try Self.literals("FileActionConfirmSheet.swift")
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "the sheet does not use \(key)")
        }
    }

    /// The inline default is what a missing bundle falls back to, so it must be
    /// the `en` value to the byte. Read from the source with its key as the
    /// anchor; a key that matches nothing fails the positive check beside it.
    @Test func everyInlineDefaultEqualsTheEnglishCatalogueValue() throws {
        let literals = try Self.literals("FileActionConfirmSheet.swift")
        let english = try Self.catalog("en")
        for key in Self.keys {
            let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\",\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(literals.startIndex..., in: literals)
            let matches = regex.matches(in: literals, range: range)
            #expect(matches.count == 1, "\(key) is looked up \(matches.count) times in the sheet")
            guard let match = matches.first, let inline = Range(match.range(at: 1), in: literals)
            else { continue }
            #expect(String(literals[inline]) == english[key], "the default of \(key) drifted")
        }
    }

    /// The user's actions are the last run in the model, after `delete`; the
    /// table view puts one divider before the first of them. The positive
    /// half is the `.userFileAction` case being asked about at all.
    @Test func theTableViewDividesTheUserActionsFromTheBuiltInEntries() throws {
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(table.contains("if case .userFileAction = entry, menu.items.isEmpty == false"))
        #expect(table.contains("menu.addItem(.separator())"))
    }

    /// The same rule `ArchivePaneWiringGuardTests` holds the archive
    /// extension to, and for the same measured reason: a run owned by an
    /// unstructured `Task` survives the pane that started it, and a tab
    /// closed mid-run finds nothing to cancel. All eight spellings, because
    /// a guard that buys one and reveals another is not a guard.
    @Test func noRunHappensInATaskNothingOwns() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("viewModel.fileActionActivity.run("))
        #expect(!code.contains("Task {"))
        #expect(!code.contains("Task("))
        #expect(!code.contains("Task.detached"))
        #expect(!code.contains("Task.init"))
        #expect(!code.contains("Task<"))
        #expect(!code.contains("Task{"))
        #expect(!code.contains("DispatchQueue"))
        #expect(!code.contains("Thread"))
    }

    /// A remote action is TYPED into the shell, not executed by Core. The
    /// positive beside the absence: the send path is named.
    @Test func theRemotePathSendsAndDoesNotExecute() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("SnippetSendPlanner.plan("))
    }

    // MARK: - The activity row, the teardown and the shell

    private static let runKeys = [
        "fileAction.activity.running",
        "fileAction.activity.failed",
        "fileAction.activity.couldNotRun",
        "fileAction.activity.timedOut",
        "fileAction.activity.dismiss",
        "fileAction.run.busy",
        "fileAction.run.noShell",
        "fileAction.alert.title",
    ]

    /// The row shows the running action with its Cancel, the reload follows
    /// the activity going idle (a local run may have written files), and the
    /// tab's teardown cancels the activity on both panes: the one `cancel()`
    /// that reaches a run the pane started.
    @Test func theRowTheReloadAndTheTeardownAreWired() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("FileActionActivityRow(activity: viewModel.fileActionActivity)"))
        #expect(pane.contains(".onChange(of: viewModel.fileActionActivity.state)"))
        let teardown = try Self.code("TabTeardown.swift")
        #expect(teardown.contains("session.local.fileActionActivity.cancel()"))
        #expect(teardown.contains("session.remote.fileActionActivity.cancel()"))
        // Before the queue sweep, which is the first stage.
        let cancel = try #require(teardown.range(of: "session.remote.fileActionActivity.cancel()"))
        let sweep = try #require(teardown.range(of: "await tab.transferQueue.cancelAll("))
        #expect(cancel.upperBound <= sweep.lowerBound)
    }

    /// The confirm button starts the run: it no longer only closes the sheet.
    @Test func theConfirmButtonStartsTheRun() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("runFileAction(request)"))
        let extensionCode = try Self.code("BrowserPane+FileActions.swift")
        #expect(extensionCode.contains("func runFileAction("))
    }

    /// Only the remote pane is handed a way to reach the shell; the local one
    /// spawns, and has no shell to type into.
    @Test func onlyTheRemotePaneIsHandedTheShell() throws {
        let detail = try Self.code("ContentView+Detail.swift")
        // One region per `BrowserPane(` construction; the text before the
        // first is not a pane.
        let regions = Array(detail.components(separatedBy: "BrowserPane(").dropFirst())
        #expect(regions.count == 2, "ContentView+Detail builds \(regions.count) BrowserPane(s)")
        guard regions.count == 2 else { return }
        #expect(regions[0].contains("side: .local,"))
        #expect(regions[0].contains("shell: FileActionShell(") == false)
        #expect(regions[1].contains("side: .remote,"))
        #expect(regions[1].contains("shell: FileActionShell("))
    }

    @Test func everyRunKeyIsInAllFourCataloguesAndUsed() throws {
        let literals = try Self.literals("FileActionActivityRow.swift")
            + Self.literals("BrowserPane+FileActions.swift")
            + Self.literals("BrowserPane.swift")
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.runKeys {
                #expect((entries[key] ?? "").isEmpty == false, "\(locale) has no \(key)")
            }
        }
        for key in Self.runKeys {
            #expect(literals.contains("\"\(key)\""), "no source file uses \(key)")
        }
    }

    @Test func theTwoFormatSentencesKeepTheirPlaceholderInEveryLanguage() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in [
                "fileAction.activity.running", "fileAction.activity.failed",
                "fileAction.activity.couldNotRun", "fileAction.activity.timedOut",
            ] {
                #expect(entries[key]?.contains("%@") == true, "\(locale) \(key) lost its %@")
            }
        }
    }

    @Test func theGermanConfirmMessageAddressesTheUserAsDu() throws {
        let message = try #require(try Self.catalog("de")["fileAction.confirm.message"])
        #expect(message.contains(" du "))
    }
}
