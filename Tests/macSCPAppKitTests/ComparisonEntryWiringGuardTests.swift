import Foundation
import MacSCPTestSupport
import Testing

/// The source-level half of the diff view's entry points (Task 12).
/// `BrowserContextMenuTests` holds WHICH selection is offered which entry;
/// this holds what no value test can reach: that both panes actually handle
/// the two entries, that the menu bar has its own door, that every one of
/// them goes through the single function which starts a comparison and opens
/// the window for THAT comparison, and that a refused start opens nothing.
///
/// Every negative check has a positive one beside it asserting the thing it
/// scans is there at all.
@Suite("Comparison entry wiring guard")
struct ComparisonEntryWiringGuardTests {
    private static let sources = SourceCorpus.url(of: .sources)
    private static let appKit = sources.appendingPathComponent("MacSCPAppKit")
    private static let doorFile = "ContentView+Comparison.swift"

    /// Code only: comments and string literals blanked, whitespace collapsed
    /// so a rewrap cannot move an anchor.
    private static func code(_ file: String) throws -> String {
        let view = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return collapsed(view)
    }

    /// Comments blanked, literals KEPT — for a claim about a catalogue key,
    /// which is a claim about a literal. A comment naming the key still
    /// cannot satisfy it.
    private static func withLiterals(_ file: String) throws -> String {
        collapsed(try SourceCorpus.commentFree(of: appKit.appendingPathComponent(file)))
    }

    private static func collapsed(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    /// A declaration's own body, by brace matching, read from code alone and
    /// then collapsed — so a statement or a comment added to it cannot push a
    /// call out of a fixed-length window.
    private static func body(_ declaration: String, in file: String) throws -> String {
        let source = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return collapsed(
            try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source))
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    private static func swiftFiles() throws -> [URL] {
        try SourceCorpus.files(under: sources).filter { $0.pathExtension == "swift" }
    }

    // MARK: The two context-menu entries

    /// Both entries reach a handler in BOTH panes' `onMenuAction`. The
    /// switches there are exhaustive, so a missing arm is a build failure —
    /// but an arm that falls through to `break` is not, and that is what this
    /// catches: the entry would be offered and clicking it would do nothing.
    @Test func bothPanesHandleBothEntries() throws {
        let detail = try Self.code("ContentView+Detail.swift")
        // Positive: the two switches are still there, one per pane.
        #expect(Self.occurrences(of: "case .transferToOtherPane:", in: detail) == 2)
        // One arm per entry per pane, each calling its handler.
        #expect(Self.occurrences(of: "case .compareWithOtherPane:", in: detail) == 2)
        #expect(Self.occurrences(of: "case .compareTwoSelected:", in: detail) == 2)
        #expect(Self.occurrences(of: "compareWithOtherPane(selection, from: .local,", in: detail) == 1)
        #expect(Self.occurrences(of: "compareWithOtherPane(selection, from: .remote,", in: detail) == 1)
        #expect(Self.occurrences(of: "compareTwoSelected(selection, on: .local,", in: detail) == 1)
        #expect(Self.occurrences(of: "compareTwoSelected(selection, on: .remote,", in: detail) == 1)
    }

    /// `BrowserPane` forwards what it does not handle itself, so neither
    /// entry may be swallowed there.
    @Test func theBrowserPaneForwardsTheComparisonEntriesInsteadOfSwallowingThem() throws {
        let pane = try Self.code("BrowserPane.swift")
        // Positive: the forwarding default is there, and the pane does keep
        // other entries to itself.
        #expect(pane.contains("default: onMenuAction?(entry, selection)"))
        #expect(pane.contains("case .rename:"))
        // Negative: it claims neither comparison entry.
        #expect(!pane.contains("case .compareWithOtherPane"))
        #expect(!pane.contains("case .compareTwoSelected"))
    }

    /// Both items are titled from the catalogue, never from a literal in the
    /// view — CLAUDE.md's "never hardcode a display string".
    @Test func bothItemsAreTitledFromTheCatalogue() throws {
        let table = try Self.withLiterals("RemoteFileTableView.swift")
        // Positive: the neighbouring item this one sits beside still reads
        // its own key.
        #expect(table.contains("L10n.string(\"menu.copyPath\""))
        #expect(table.contains("L10n.string(\"menu.compare.otherPane\""))
        #expect(table.contains("L10n.string(\"menu.compare.twoSelected\""))
    }

    // MARK: One door, and it opens the window for what it started

    /// `SessionTab.startComparison` is called from exactly ONE place in the
    /// App, the function that also opens the window. A second caller is a
    /// comparison that runs with nothing on screen.
    @Test func everyComparisonIsStartedThroughTheOneFunctionThatOpensItsWindow() throws {
        var callers: [String] = []
        for url in try Self.swiftFiles() {
            let code = try SourceCorpus.code(of: url)
            if Self.occurrences(of: "startComparison(", in: Self.collapsed(code)) > 0 {
                callers.append(url.lastPathComponent)
            }
        }
        // The one caller's file, and the declaration's.
        #expect(callers.sorted() == [Self.doorFile, "SessionTab.swift"])

        let door = try Self.code(Self.doorFile)
        #expect(Self.occurrences(of: "tab.startComparison(", in: door) == 1)
        #expect(Self.occurrences(of: "openWindow(value: ComparisonSeed(", in: door) == 1)
    }

    /// The seed names the comparison that was JUST returned — never one
    /// lying around. A window resolves its seed once, so a seed built from
    /// anything else latches onto whatever that id still means, or onto
    /// nothing.
    @Test func theSeedIsBuiltFromTheComparisonThatWasJustStarted() throws {
        let open = try Self.body("func openComparison(", in: Self.doorFile)
        #expect(open.contains("guard let comparison = tab.startComparison("))
        #expect(open.contains("openWindow(value: ComparisonSeed(tabID: tab.id, comparisonID: comparison.id))"))

        // Negative beside it: nothing else in the App builds a seed. The
        // window file declares the type and the app declares the scene, and
        // neither constructs one.
        var builders: [String] = []
        for url in try Self.swiftFiles() {
            let code = Self.collapsed(try SourceCorpus.code(of: url))
            if Self.occurrences(of: "ComparisonSeed(", in: code) > 0 {
                builders.append(url.lastPathComponent)
            }
        }
        #expect(builders.sorted() == [Self.doorFile])
    }

    /// A refused start opens nothing: `startComparison` answers nil when the
    /// tab has no session or a teardown is running, and the only `openWindow`
    /// in the function stands after the `guard` that returns on it.
    @Test func aRefusedStartOpensNothing() throws {
        let open = try Self.body("func openComparison(", in: Self.doorFile)
        let guardRange = try #require(open.range(of: "else { return }"))
        let opens = try #require(open.range(of: "openWindow("))
        #expect(guardRange.upperBound <= opens.lowerBound)
        #expect(Self.occurrences(of: "openWindow(", in: open) == 1)
    }

    // MARK: What each door compares

    /// One row against the entry of the same name in the other pane's
    /// current directory, and the row's own kind decides which shape of
    /// comparison that is.
    @Test func theOneRowDoorMeasuresARowAgainstItsCounterpart() throws {
        let body = try Self.body("func compareWithOtherPane(", in: Self.doorFile)
        #expect(body.contains("RemotePath.join("))
        #expect(body.contains("session.remote.currentPath"))
        #expect(body.contains("session.local.currentPath"))
        #expect(body.contains("row.kind == .directory ? .folders : .filePair"))
    }

    /// Two selected files, against each other, both on this pane's side.
    @Test func theTwoRowDoorComparesTheTwoRowsOnOneSide() throws {
        let body = try Self.body("func compareTwoSelected(", in: Self.doorFile)
        #expect(body.contains("guard selection.count == 2 else { return }"))
        #expect(body.contains("leftRoot: selection[0].path"))
        #expect(body.contains("rightRoot: selection[1].path"))
        #expect(body.contains("kind: .filePair"))
        // Both sides are the same one: the pane's.
        #expect(body.contains("left: comparisonSide"))
        #expect(body.contains("right: comparisonSide"))
    }

    /// The menu bar compares the two panes' CURRENT DIRECTORIES as folders.
    @Test func theMenuBarDoorComparesTheTwoPanesCurrentDirectories() throws {
        let body = try Self.body("func compareBothPanes(", in: Self.doorFile)
        #expect(body.contains("leftRoot: session.local.currentPath"))
        #expect(body.contains("rightRoot: session.remote.currentPath"))
        #expect(body.contains("kind: .folders"))
    }

    /// The menu-bar item exists, is wired by the window that owns the tabs,
    /// and is disabled while nothing is connected — the same bridge shape as
    /// every other `tabCommands` entry.
    @Test func theMenuBarItemIsWiredThroughTheFocusedWindowsBridge() throws {
        let app = try Self.code("MacSCPApp.swift")
        #expect(app.contains("var compareBothPanes: (() -> Void)?"))

        let commands = try Self.withLiterals("MacSCPCommands.swift")
        #expect(commands.contains("L10n.string(\"menu.compare.panes\""))
        #expect(commands.contains("tabCommands?.compareBothPanes?()"))
        // Positive beside the gate below: the neighbouring item that reads
        // the same mirror is still there.
        #expect(commands.contains("tabCommands?.toggleTransfers?()"))
        let item = try #require(commands.range(of: "tabCommands?.compareBothPanes?()"))
        let rest = String(commands[item.upperBound...].prefix(160))
        #expect(rest.contains(".disabled(tabCommands?.isActiveTabConnected != true)"))

        let lifecycle = try Self.code("ContentView+Lifecycle.swift")
        #expect(Self.occurrences(of: "tabCommands.compareBothPanes =", in: lifecycle) == 1)
        #expect(lifecycle.contains("compareBothPanes(in: tabsModel.activeTab, session: session)"))
    }
}
