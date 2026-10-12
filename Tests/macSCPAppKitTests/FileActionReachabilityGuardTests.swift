import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Guards that a user's file action can actually REACH a menu, and that the
/// name it carries is drawn safely wherever it is shown (file-actions plan,
/// Task 11).
///
/// A feature can be complete in every part and unreachable as a whole, and a
/// green suite does not show it: for ten tasks `BrowserContextMenu.entries`
/// took `userFileActions:` and nothing in the App passed it, so no action
/// appeared in any menu. The chain is store -> window -> pane -> table view
/// -> `entries`, and each link is asserted here, with the behaviour of the
/// ends tested as values.
///
/// Structural claims read `SourceCorpus.code` (comments AND string literals
/// blanked). Every negative check has a positive check beside it.
///
/// Known blind spot: SOURCE TEXT only. That a right click on a real file shows
/// the entry is a sight check for the maintainer (Task 12).
@Suite("File action reachability guard")
struct FileActionReachabilityGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(
            of: repoRoot.appendingPathComponent("Sources/MacSCPAppKit/\(name)"))
    }

    // MARK: - The chain

    @Test func theTableViewPassesTheUsersActionsToTheMenuModel() throws {
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(table.contains("var userFileActions: (() -> [FileAction])?"))
        #expect(table.contains("userFileActions: userFileActions?() ?? []"))
        // Both places that hand a closure to the coordinator: the first
        // build and every update, or an edit made while the pane is on
        // screen would not reach it.
        #expect(table.components(separatedBy: "coordinator.userFileActions = userFileActions").count - 1 == 2)
    }

    @Test func thePaneForwardsThemToTheTableView() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("var userFileActions: (() -> [FileAction])?"))
        #expect(pane.contains("userFileActions: userFileActions,"))
    }

    /// Both panes are given them, each from the store, read afresh: the
    /// closure runs at each right click, so an action saved a moment ago
    /// is in the very next menu.
    @Test func bothPanesAreHandedTheStoreAndNotAFrozenList() throws {
        let detail = try Self.code("ContentView+Detail.swift")
        let regions = Array(detail.components(separatedBy: "BrowserPane(").dropFirst())
        #expect(regions.count == 2, "ContentView+Detail builds \(regions.count) BrowserPane(s)")
        for region in regions {
            #expect(region.contains("userFileActions: { fileActionsForMenu() }"))
        }
        let contentView = try Self.code("ContentView.swift")
        #expect(contentView.contains("func fileActionsForMenu() -> [FileAction]"))
        #expect(contentView.contains("FileActionsLoad(reading: fileActionStore).actions"))
    }

    // MARK: - The ends, as values

    /// The store read as the window reads it, through the menu model: a valid
    /// action appears for the side it declares, and one the gate refuses (a
    /// hand-edited file) does not. This is the behaviour the chain carries.
    @Test func aStoredActionReachesTheMenuModelAndARefusedOneDoesNot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-actions-reach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActionStore(directory: directory)
        let good = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let noSide = FileAction(name: "Nowhere", command: "ls", runsOn: [])
        try store.save(good)
        try store.save(noSide)

        let file = RemoteFileItem(name: "a.txt", path: "/home/u/a.txt", kind: .file)
        let entries = BrowserContextMenu.entries(
            for: [file], side: .remote,
            userFileActions: FileActionsLoad(reading: store).actions)
        #expect(entries.contains(.userFileAction(good)))
        #expect(entries.contains(.userFileAction(noSide)) == false)
        // And on the pane the action does not declare, it is absent: the
        // side is the filter, not the list.
        let local = BrowserContextMenu.entries(
            for: [file], side: .local,
            userFileActions: FileActionsLoad(reading: store).actions)
        #expect(local.contains(.userFileAction(good)) == false)
    }

    @Test func anUnreadableStoreOffersNothingAndDoesNotCrashTheMenu() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-actions-reach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("file-actions.json"))
        let file = RemoteFileItem(name: "a.txt", path: "/home/u/a.txt", kind: .file)
        let entries = BrowserContextMenu.entries(
            for: [file], side: .remote,
            userFileActions: FileActionsLoad(reading: FileActionStore(directory: directory)).actions)
        #expect(entries.isEmpty == false)
        #expect(entries.contains { if case .userFileAction = $0 { true } else { false } } == false)
    }

    // MARK: - A name is drawn through the marker renderer

    /// The confirmation sheet's title was the one displayed string that
    /// skipped the renderer, on the reasoning that the name is not server
    /// data. An action can now be imported from a file, so a right-to-left
    /// override or a line break in a name could mislabel the action there.
    @Test func theConfirmationTitleGoesThroughTheMarkerRenderer() throws {
        let sheet = try Self.code("FileActionConfirmSheet.swift")
        #expect(sheet.contains("FileActionPlanDisplay.runs(of: request.action.name)"))
        #expect(sheet.contains("Text(request.action.name)") == false)
    }

    @Test func theMenuTitleGoesThroughTheMarkerRenderer() throws {
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(table.contains("title: FileActionPlanDisplay.visible(action.name)"))
        #expect(table.contains("title: action.name") == false)
    }

    /// Every use of the run's title in the activity row's sentences is
    /// wrapped, counted against the unwrapped uses rather than against a
    /// figure.
    @Test func theActivityRowSentencesNameTheActionThroughTheRenderer() throws {
        let row = try Self.code("FileActionActivityRow.swift")
        #expect(row.contains("FileActionPlanDisplay.visible(title)"))
        let wrapped = row.components(separatedBy: "FileActionPlanDisplay.visible(outcome.title)").count - 1
        let all = row.components(separatedBy: "outcome.title").count - 1
        #expect(wrapped > 0)
        #expect(wrapped == all, "\(all - wrapped) use(s) of outcome.title skip the renderer")
    }

    @Test func aHostileTitleIsMarkedInTheActivityRowSentences() {
        let hostile = "A\u{202E}B\nC"
        let running = FileActionPresentation.runningText(title: hostile)
        #expect(running.contains("<U+202E>"))
        #expect(running.contains("\u{202E}") == false)
        #expect(running.contains("\n") == false)
        for ending: FileActionActivity.Ending in [.failed(status: 1), .timedOut, .couldNotRun] {
            let message = FileActionPresentation.message(
                for: FileActionActivity.Outcome(title: hostile, ending: ending))
            #expect(message?.contains("<U+202E>") == true, "\(ending)")
            #expect(message?.contains("\u{202E}") == false, "\(ending)")
        }
        // The control: an ordinary title is left alone.
        #expect(FileActionPresentation.runningText(title: "Count") == "Running “Count”")
    }
}
