import Foundation
import Testing

/// Guards that the pane-visibility PERSISTENCE wiring (P2 terminal-chrome
/// milestone, Task 4, fix round 1) is actually called from the two places
/// that are supposed to call it — not just that the underlying Core methods
/// (`SessionTab.effectivePaneVisibility`, `SessionListViewModel.
/// updatePaneVisibility`) are individually correct, which
/// `PaneVisibilityPersistenceTests`/`SessionListViewModelTests` already
/// cover without ever touching `ContentView.swift`/`ContentView+Lifecycle.swift`.
///
/// This is the exact shape `PaneRenderConditionGuardTests` (Task 3, fix
/// round 2) exists to catch: "the method is right and is not wired in" is
/// a Critical this project has already paid for once. Deleting either
/// `restorePaneVisibility(...)` from the connect path or a
/// `persistActivePaneVisibility()` after a toggle mutation compiles cleanly
/// and every OTHER test in the suite stays green — nothing but this guard
/// would notice.
///
/// Same boundary as `PaneRenderConditionGuardTests`/`TerminalPanelInsetTests`:
/// this project has no view-instantiation/rendering test tool, so this is a
/// SOURCE-TEXT scan, not a behavioral test that actually connects a session
/// or clicks a toggle.
///
/// Known blind spots, stated up front rather than discovered later:
/// - Line-based and literal, like the two existing guards. A reformat that
///   moves `persistActivePaneVisibility()` onto the same line as the
///   mutation it follows, or a rename of either method, defeats this. Aimed
///   at an accidental regression (someone deleting a line while editing
///   nearby code), not a hostile rewrite.
/// - The toggle-site scanner only recognizes the THREE literal call shapes
///   this task actually introduced (`activeTab.applyFilesToggleClick(`,
///   `session.terminal.toggle()`, `terminal.toggle()`). A FOURTH place that
///   starts flipping pane visibility some other way (a new call spelled
///   differently) would not be recognized as a toggle site at all, so a
///   missing `persistActivePaneVisibility()` there would not be caught.
/// - The connect-path check only looks for the substring
///   `restorePaneVisibility(` anywhere inside `connect(in tab: SessionTab,
///   stored: StoredSession)`'s body — it does not check the call is
///   reachable on every path through that `Task`, only that it appears at
///   all textually inside the function.
/// - `activeTab.transfersPanelVisible.toggle()` (a few lines below the
///   Transfers toolbar button, same file) is deliberately NOT recognized as
///   a pane-visibility toggle site — its trimmed text is neither
///   `session.terminal.toggle()` nor `terminal.toggle()` nor does it start
///   with `activeTab.applyFilesToggleClick(`, so the scanner correctly
///   leaves it alone. `scannerIgnoresTheUnrelatedTransfersToggle` below
///   pins that this is deliberate, not an accidental gap.
@Suite("Pane visibility wiring guard")
struct PaneVisibilityWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/PaneVisibilityWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `PaneRenderConditionGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")

    // MARK: - The guard

    /// `connect(in:stored:)` is the ONE place a stored session's saved
    /// `PaneVisibility` is available and a fresh `BrowserSession` has just
    /// been built for it (see `ContentView.restorePaneVisibility`'s own doc
    /// comment) — the restore call must live inside its body.
    @Test func connectRestoresPaneVisibility() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func connect(in tab: SessionTab, stored: StoredSession) {",
            in: lines)
        else {
            Issue.record("`connect(in tab: SessionTab, stored: StoredSession) {` not found — re-anchor this guard")
            return
        }
        let callsRestorePaneVisibility = range.contains { lines[$0].contains("restorePaneVisibility(") }
        #expect(callsRestorePaneVisibility, """
            `connect(in:stored:)` no longer calls `restorePaneVisibility(...)` — a \
            reconnected stored session would come up with whatever the tab's \
            in-memory state happens to be instead of what was last saved for it.
            """)
    }

    /// Each of the three call sites that flip built-in pane visibility
    /// (the Files toolbar button, the Terminal toolbar button in `.builtIn`
    /// mode, and the `tabCommands.toggleTerminal` menu bridge) must be
    /// immediately followed by `persistActivePaneVisibility()` — see
    /// `ContentView.persistActivePaneVisibility`'s own doc comment for why
    /// this has to run at every site rather than once centrally (there is
    /// no single chokepoint all three funnel through before this task).
    @Test func everyToggleSiteIsFollowedByAPersist() throws {
        let source = try String(contentsOf: Self.lifecycleFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let sites = Self.toggleSiteEndLines(in: lines)
        #expect(sites.count == 3, "expected 3 pane-visibility toggle sites in ContentView+Lifecycle.swift, found \(sites.count)")
        let unpersisted = sites.filter { !Self.isFollowedByPersist(afterLine: $0, in: lines) }
        #expect(unpersisted.isEmpty, """
            toggle site(s) ending at line(s) \(unpersisted.map { $0 + 1 }) are not \
            immediately followed by `persistActivePaneVisibility()` — a click there \
            flips the in-memory state without saving it, so a reconnected session \
            would silently lose that change.
            """)
    }

    /// The scanner's own honesty check: `activeTab.transfersPanelVisible.toggle()`,
    /// a few lines below the Files/Terminal buttons in the same file, is a
    /// DIFFERENT toggle (the transfers bar, not a pane) and must not be
    /// mistaken for one of the three sites above.
    @Test func scannerIgnoresTheUnrelatedTransfersToggle() throws {
        let source = try String(contentsOf: Self.lifecycleFile, encoding: .utf8)
        #expect(source.contains("activeTab.transfersPanelVisible.toggle()"),
                "re-anchor: the transfers toggle this test is about no longer exists in the file")
        let lines = source.components(separatedBy: "\n")
        let sites = Self.toggleSiteEndLines(in: lines)
        let transfersLine = lines.firstIndex { $0.contains("activeTab.transfersPanelVisible.toggle()") }
        #expect(!sites.contains(transfersLine!))
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The exact regression this guard exists to catch: the multi-line
    /// `applyFilesToggleClick(...)` call with no persist after it.
    @Test func scannerFlagsAMissingPersistAfterTheFilesToggle() {
        let source = """
            struct Fake {
                var body: some View {
                    Button {
                        activeTab.applyFilesToggleClick(
                            terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell)
                    } label: { EmptyView() }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let sites = Self.toggleSiteEndLines(in: lines)
        #expect(sites.count == 1)
        #expect(!Self.isFollowedByPersist(afterLine: sites[0], in: lines))
    }

    /// The passing shape: same call, persist call right after.
    @Test func scannerAcceptsAPersistRightAfterTheFilesToggle() {
        let source = """
            struct Fake {
                var body: some View {
                    Button {
                        activeTab.applyFilesToggleClick(
                            terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell)
                        persistActivePaneVisibility()
                    } label: { EmptyView() }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let sites = Self.toggleSiteEndLines(in: lines)
        #expect(sites.count == 1)
        #expect(Self.isFollowedByPersist(afterLine: sites[0], in: lines))
    }

    /// `session.terminal.toggle()`/`terminal.toggle()` are single-line
    /// sites; the persist call may sit right after skipping blank lines.
    @Test func scannerToleratesBlankLinesBeforeThePersistCall() {
        let source = """
            struct Fake {
                func toggle() {
                    session.terminal.toggle()

                    persistActivePaneVisibility()
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let sites = Self.toggleSiteEndLines(in: lines)
        #expect(sites.count == 1)
        #expect(Self.isFollowedByPersist(afterLine: sites[0], in: lines))
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `TerminalPanelInsetTests`'s and
    // `PaneRenderConditionGuardTests`'s scanners.

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `PaneRenderConditionGuardTests.range(ofBlockStartingWith:in:)`.
    private static func range(ofBlockStartingWith marker: String, in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 {
                return start...index
            }
        }
        return nil
    }

    /// The line index at which each pane-visibility toggle CALL closes
    /// (its matching close-paren, possibly several lines after the call
    /// starts — `applyFilesToggleClick(...)` spans three lines). Recognizes
    /// exactly the three literal call shapes this task introduced (see this
    /// suite's doc comment on why a fourth shape would not be recognized).
    private static func toggleSiteEndLines(in lines: [String]) -> [Int] {
        let singleLineMarkers = ["session.terminal.toggle()", "terminal.toggle()"]
        var ends: [Int] = []
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if singleLineMarkers.contains(trimmed) {
                ends.append(index)
            } else if trimmed.hasPrefix("activeTab.applyFilesToggleClick(") {
                if let end = endLineOfCall(startingAt: index, in: lines) {
                    ends.append(end)
                }
            }
        }
        return ends
    }

    /// Parenthesis-counts from `index` (which must contain the call's
    /// opening `(`) across as many following lines as needed until depth
    /// returns to zero, returning the line index where that happens.
    private static func endLineOfCall(startingAt index: Int, in lines: [String]) -> Int? {
        var depth = 0
        var sawOpenParen = false
        for lineIndex in index..<lines.count {
            for character in lines[lineIndex] {
                if character == "(" { depth += 1; sawOpenParen = true }
                if character == ")" { depth -= 1 }
            }
            if sawOpenParen && depth <= 0 {
                return lineIndex
            }
        }
        return nil
    }

    /// Whether the next NON-BLANK line after `afterLine` (0-based, the line
    /// a toggle call ends on) is exactly `persistActivePaneVisibility()`.
    private static func isFollowedByPersist(afterLine: Int, in lines: [String]) -> Bool {
        var next = afterLine + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            next += 1
        }
        guard next < lines.count else { return false }
        return lines[next].trimmingCharacters(in: .whitespaces) == "persistActivePaneVisibility()"
    }
}
