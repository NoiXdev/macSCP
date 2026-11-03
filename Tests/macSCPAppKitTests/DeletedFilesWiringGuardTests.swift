import Foundation
import MacSCPTestSupport
import Testing

/// Guards the App-layer wiring of "show deleted files" (S3 version history,
/// Task 10), which a test cannot instantiate (the boundary
/// `PaneRenderConditionGuardTests` documents): a source-text scan over the
/// COMMENT-FREE view of each file.
///
/// Every behavioural test of this feature drives `RemoteBrowserViewModel`,
/// `S3DeletedFileSource`, `DeletedFileRestorer` or `BrowserContextMenu`
/// directly, so nothing else says the window connects them. A reviewer
/// planted two wiring violations and the whole suite stayed green: the
/// Lifecycle `.onChange` deleted (the Settings toggle and the View-menu entry
/// then do nothing for the whole session), and `BrowserPane` swallowing
/// `.restoreDeleted` (the Restore item drawn, enabled, and inert).
///
/// Every NEGATIVE check has a POSITIVE beside it asserting that the thing it
/// scans is there at all, and every slice is taken with a search that starts
/// after its anchor, so a source where the second anchor comes first fails an
/// expectation by name and never traps.
@Suite("Deleted files wiring guard")
struct DeletedFilesWiringGuardTests {
    private static let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")

    /// Whitespace runs collapsed to one space, so a call wrapped across lines
    /// reads the same as one on a single line.
    private static func code(_ file: String) throws -> String {
        let code = try SourceCorpus.commentFree(of: root.appendingPathComponent(file))
        return code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    /// The text from the first `anchor` to the first `end` AFTER it. Total:
    /// `nil` when either is missing, never a trap.
    private static func span(from anchor: String, to end: String, in code: String) -> String? {
        guard let start = code.range(of: anchor),
            let stop = code.range(of: end, range: start.upperBound..<code.endIndex)
        else { return nil }
        return String(code[start.lowerBound..<stop.upperBound])
    }

    // MARK: The switch reaches the panes

    @Test func theSettingIsObservedAndAppliedToTheRemotePaneOfEveryTab() throws {
        let code = try Self.code("ContentView+Lifecycle.swift")
        #expect(Self.occurrences(of: ".onChange(of: settingsStore.showDeletedFiles)", in: code) == 1)
        let observer = try #require(
            Self.span(
                from: ".onChange(of: settingsStore.showDeletedFiles)",
                to: "setShowDeletedFiles(newValue)", in: code))
        #expect(observer.contains("session.remote.setShowDeletedFiles(newValue)"))
        // EVERY tab: the loop is over the window's whole tab list, and nothing
        // narrows it. A tab moves between windows carrying its connection, so
        // a pane that missed the switch is a pane that shows a different
        // answer from the one the setting gives. (A reviewer's plant, a
        // `prefix(1)` on the list, left the earlier body green.)
        #expect(observer.contains("for tab in tabsModel.tabs {"))
        #expect(observer.contains("guard let session = tab.session else { continue }"))
        #expect(!observer.contains(".prefix("))
        #expect(!observer.contains(".first"))
        #expect(!observer.contains("break"))
        // The positive beside those negatives: the hidden-files observer, the
        // sibling this one copies, loops the same list the same way.
        let hidden = try #require(
            Self.span(
                from: ".onChange(of: settingsStore.showHiddenFiles)",
                to: "session.remote.showHiddenFiles = newValue", in: code))
        #expect(hidden.contains("for tab in tabsModel.tabs {"))
        // Negative: the local pane is never given the switch; positive beside
        // it: the hidden-files observer, which does name both panes, is there.
        #expect(!code.contains("local.setShowDeletedFiles"))
        #expect(!code.contains("local.showDeletedFiles"))
        #expect(code.contains("session.local.showHiddenFiles = newValue"))
    }

    @Test func aNewSessionGetsTheSourceAndTheSettingOnItsRemotePaneOnly() throws {
        let code = try Self.code("ContentView.swift")
        #expect(Self.occurrences(of: "tab.session?.remote.deletedFileSource = S3DeletedFileSource.make(", in: code) == 1)
        #expect(Self.occurrences(of: "tab.session?.remote.showDeletedFiles = settingsStore.showDeletedFiles", in: code) == 1)
        let made = try #require(
            Self.span(
                from: "tab.session?.remote.deletedFileSource = S3DeletedFileSource.make(",
                to: "S3Field.bucket", in: code))
        #expect(made.contains("versioning: tab.session?.bucketVersioning"))
        #expect(!code.contains("local.deletedFileSource"))
        #expect(!code.contains("local.showDeletedFiles"))
        #expect(code.contains("tab.session?.local.showHiddenFiles = settingsStore.showHiddenFiles"))
    }

    @Test func theSettingAndTheMenuEntryToggleTheSameSetting() throws {
        let settings = try Self.code("SettingsView.swift")
        #expect(Self.occurrences(of: "isOn: $store.showDeletedFiles", in: settings) == 1)
        let commands = try Self.code("MacSCPCommands.swift")
        #expect(Self.occurrences(of: "settingsStore.showDeletedFiles.toggle()", in: commands) == 1)
        #expect(commands.contains("settingsStore.showHiddenFiles.toggle()"))
    }

    // MARK: Restore reaches the window

    @Test func thePaneForwardsRestoreAndTheWindowCarriesItOut() throws {
        let pane = try Self.code("BrowserPane.swift")
        let arm = try #require(
            Self.span(
                from: "case .transferToOtherPane, .transferToSession,",
                to: "onMenuAction?(entry, selection, side)", in: pane))
        #expect(arm.contains(".restoreDeleted"))
        #expect(Self.occurrences(of: ".restoreDeleted", in: pane) == 1)

        let router = try Self.code("ContentView+MenuActions.swift")
        #expect(Self.occurrences(of: "case .restoreDeleted:", in: router) == 1)
        #expect(Self.occurrences(of: "restoreDeletedFiles(selection, side: side, in: tab, session: session)", in: router) == 1)
        let handler = try #require(
            Self.span(from: "func restoreDeletedFiles(", to: "remote.deletedFilesNotice = notice", in: router))
        #expect(handler.contains("DeletedFileRestorer(provider: provider, recorder: tab.auditRecorder)"))
        #expect(handler.contains("restorer.restore(rows, in: context)"))
        #expect(handler.contains("await remote.refresh()"))
        // The refresh comes first and the notice after it: `load()` clears the
        // notice as it starts, so the other order would never show one.
        let refresh = try #require(handler.range(of: "await remote.refresh()"))
        #expect(handler[refresh.upperBound...].contains("remote.deletedFilesNotice = notice"))
    }

    @Test func theTableDrawsTheRestoreItem() throws {
        let table = try Self.code("RemoteFileTableView.swift")
        let arm = try #require(Self.span(from: "case .restoreDeleted:", to: "selection: selection)", in: table))
        #expect(arm.contains("\"menu.restoreDeleted\""))
        #expect(Self.occurrences(of: "case .restoreDeleted:", in: table) == 1)
        #expect(table.contains("case .copyPath:"))
        // The deleted row's non-visual description reaches the cell it is for.
        #expect(Self.occurrences(of: "cell.setAccessibilityHelp(RemoteFileTableView.cellAccessibilityHelp(for: column, item: item))", in: table) == 1)
    }

    @Test func thePaneShowsTheNoticeItIsGiven() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(Self.occurrences(of: "if let notice = viewModel.deletedFilesNotice {", in: pane) == 1)
        let row = try #require(
            Self.span(from: "if let notice = viewModel.deletedFilesNotice {", to: "}", in: pane))
        #expect(row.contains("DeletedFilesNoticeRow(line: notice.line)"))
        // The stale line has its own slot beside it, so neither displaces the other.
        #expect(Self.occurrences(of: "if viewModel.deletedRowsAreStale {", in: pane) == 1)
        let stale = try #require(
            Self.span(from: "if viewModel.deletedRowsAreStale {", to: "}", in: pane))
        #expect(stale.contains("DeletedFilesNoticeRow(line: DeletedFilesLines.notRefreshed)"))
    }
}
