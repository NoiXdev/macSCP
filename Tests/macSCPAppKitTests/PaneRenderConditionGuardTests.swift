import Foundation
import Testing

/// Guards ONE property of `ContentView+Detail.swift`'s `detail`
/// (P2 terminal-chrome milestone, Task 3 review round 2): the two `if`s
/// that decide whether the file panes' `HSplitView` and the terminal panel
/// render must both read `visibility.showsFiles`/`visibility.showsTerminal`
/// — the repaired `PaneVisibility` `SessionTab.effectivePaneVisibility(...)`
/// assembles — and never the raw `tab.showsFiles`/`session.terminal.
/// isVisible` booleans directly.
///
/// Round 1 of this task fixed exactly this: those two raw booleans can
/// disagree (hide Files while Terminal is shown, disconnect, reconnect —
/// `showsFiles` stays `false` while a fresh `TerminalPanelViewModel` also
/// defaults `isVisible` to `false`), and reading them straight into two
/// independent `if`s rendered NEITHER half while the toolbar's Files
/// button — which DOES go through `PaneVisibility`'s repair via
/// `SessionTab.paneToggleState` — showed itself on-and-locked.
/// `SessionTabTests.reconnectAfterHidingFilesNeverRendersNeitherHalf`
/// (round 1) pins that `effectivePaneVisibility` itself computes the right
/// answer, but it never touches `detail` — had the method existed and
/// simply not been WIRED into the two `if`s (the exact shape the original
/// bug had), that test would still be green. This suite is the wiring
/// check that test cannot be.
///
/// This project has no view-instantiation/rendering test tool (the same
/// boundary `TerminalPanelInsetTests` and
/// `SnippetMenuItemsKeyboardShortcutGuardTests` already document), so —
/// like those two — this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/ContentView+Detail.swift`, not a rendered-view
/// assertion.
///
/// Known blind spots, so a green run is not mistaken for a proof (same
/// honesty `TerminalPanelInsetTests`/`SnippetMenuItemsKeyboardShortcutGuardTests`
/// hold themselves to):
/// - Line-based and literal. `if tab.showsFiles == true`, a reformat that
///   splits the condition across lines, or renaming `visibility` to
///   something else entirely would all slip past this exact pattern match
///   — a determined rewrite defeats it. It is aimed at the accidental
///   regression (a reformat, or someone "simplifying" one `if` back to the
///   direct property read), not a hostile one.
/// - It does not verify that `visibility` actually comes from
///   `effectivePaneVisibility` rather than some other local of the same
///   name — only that the two `if`s inside `detail` read `visibility.…`
///   and not the two raw expressions. `detailAssemblesVisibilityFromEffectivePaneVisibility`
///   below narrows that one specific gap (it pins where `visibility` is
///   bound), but a sufficiently determined rename could still fool both.
/// - Scoped to `detail` only, via brace-counting from `var detail: some
///   View {`; a THIRD render site added somewhere else in the file (or in
///   another file entirely) reading the raw booleans would not be seen.
@Suite("Pane render condition guard")
struct PaneRenderConditionGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/PaneRenderConditionGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `TerminalPanelInsetTests`/`SnippetMenuItemsKeyboardShortcutGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    // MARK: - The guard

    @Test func detailDoesNotReadTheRawBooleansAsRenderConditions() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines) else {
            Issue.record("`var detail: some View {` not found — re-anchor this guard")
            return
        }
        let violations = Self.rawBooleanConditionViolations(in: lines, range: range)
        #expect(violations.isEmpty, """
            `detail` reads a raw pane-visibility boolean directly as a render \
            condition at line(s) \(violations.map { $0 + 1 }) instead of the \
            assembled `visibility.showsFiles`/`visibility.showsTerminal` — see \
            this suite's doc comment for why that can disagree with the toolbar.
            """)
    }

    /// A present-tense check that both real render conditions still exist
    /// and still read the assembled visibility. Without this, a scanner
    /// that quietly stopped recognizing the `if visibility.…` pattern at
    /// all (say, a reformat) would report the all-clear above for the
    /// wrong reason: zero violations because zero conditions were seen, not
    /// because both real ones are correctly wired.
    @Test func detailStillGatesBothHalvesOnTheAssembledVisibility() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines) else {
            Issue.record("`var detail: some View {` not found — re-anchor this guard")
            return
        }
        let filesCondition = range.filter {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("if visibility.showsFiles")
        }
        let terminalCondition = range.filter {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("if visibility.showsTerminal")
        }
        #expect(filesCondition.count == 1, "expected exactly one `if visibility.showsFiles` in detail, found \(filesCondition.count)")
        #expect(terminalCondition.count == 1, "expected exactly one `if visibility.showsTerminal` in detail, found \(terminalCondition.count)")
    }

    /// Pins where `visibility` comes from — `SessionTab.
    /// effectivePaneVisibility`, not some other local shadowing the name.
    /// Narrower than the doc comment's "could still fool it" caveat
    /// suggests it fully closes, but it does rule out the specific case of
    /// `visibility` being computed some other way inside `detail`.
    @Test func detailAssemblesVisibilityFromEffectivePaneVisibility() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines) else {
            Issue.record("`var detail: some View {` not found — re-anchor this guard")
            return
        }
        let assemblyLines = range.filter {
            lines[$0].contains("let visibility = ") && lines[$0].contains("effectivePaneVisibility")
        }
        #expect(assemblyLines.count == 1, "expected exactly one `let visibility = …effectivePaneVisibility(...)` in detail, found \(assemblyLines.count)")
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact regression this guard exists to catch: `detail` quietly
    /// reads `tab.showsFiles` directly again instead of the assembled
    /// `visibility.showsFiles` — the shape round 1's Critical actually had.
    @Test func scannerFlagsARawShowsFilesCondition() {
        let source = """
            var detail: some View {
                let visibility = tab.effectivePaneVisibility(terminalIsVisible: false, hasShell: true)
                VStack {
                    if tab.showsFiles {
                        HSplitView { EmptyView() }
                    }
                    if visibility.showsTerminal {
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines)!
        #expect(!Self.rawBooleanConditionViolations(in: lines, range: range).isEmpty)
    }

    /// Same regression, on the terminal side.
    @Test func scannerFlagsARawTerminalIsVisibleCondition() {
        let source = """
            var detail: some View {
                let visibility = tab.effectivePaneVisibility(terminalIsVisible: false, hasShell: true)
                VStack {
                    if visibility.showsFiles {
                        HSplitView { EmptyView() }
                    }
                    if session.terminal.isVisible {
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines)!
        #expect(!Self.rawBooleanConditionViolations(in: lines, range: range).isEmpty)
    }

    @Test func scannerAcceptsBothAssembledVisibilityConditions() {
        let source = """
            var detail: some View {
                let visibility = tab.effectivePaneVisibility(terminalIsVisible: false, hasShell: true)
                VStack {
                    if visibility.showsFiles {
                        HSplitView { EmptyView() }
                    }
                    if visibility.showsTerminal {
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines)!
        #expect(Self.rawBooleanConditionViolations(in: lines, range: range).isEmpty)
    }

    /// `session.terminal.isVisible` legitimately appears inside `detail` as
    /// the ARGUMENT to `effectivePaneVisibility(terminalIsVisible:…)` — the
    /// scanner must not flag that use, only the raw expression sitting
    /// directly after an `if`.
    @Test func scannerIsQuietWhenTheRawExpressionIsOnlyAnArgument() {
        let source = """
            var detail: some View {
                let visibility = tab.effectivePaneVisibility(
                    terminalIsVisible: session.terminal.isVisible, hasShell: activeTabSupportsShell)
                VStack {
                    if visibility.showsFiles {
                        HSplitView { EmptyView() }
                    }
                    if visibility.showsTerminal {
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var detail: some View {", in: lines)!
        #expect(Self.rawBooleanConditionViolations(in: lines, range: range).isEmpty)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `TerminalPanelInsetTests`'s and
    // `SnippetMenuItemsKeyboardShortcutGuardTests`'s scanners.

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `TerminalPanelInsetTests.range(ofBlockStartingWith:in:)`.
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

    /// Within `range`, every line whose TRIMMED text starts with `if
    /// tab.showsFiles` or `if session.terminal.isVisible` — the raw
    /// booleans used directly as a render condition. Anchored on the line
    /// starting with `if `, not a bare substring search, so a legitimate
    /// use of either expression as an ARGUMENT elsewhere on an unrelated
    /// line (e.g. passed into `effectivePaneVisibility(terminalIsVisible:)`)
    /// is not flagged.
    private static func rawBooleanConditionViolations(in lines: [String], range: ClosedRange<Int>) -> [Int] {
        let rawConditionPrefixes = ["if tab.showsFiles", "if session.terminal.isVisible"]
        return range.filter { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return rawConditionPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }
}
