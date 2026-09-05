import Foundation
import Testing
@testable import MacSCPAppKit

/// Guards ONE property of `ContentView+Detail.swift`'s `terminalPanel(_:)`
/// (Terminal-Fassung P2, Task 1, round 2 per
/// `docs/superpowers/specs/2026-08-10-snippets-round-2-design.md`,
/// "P2 — Terminal-Fassung"): the terminal surface (`SSHTerminalView`, shown
/// for `.running`/`.opening`), the `.ended` state's text block, AND
/// `TerminalPanelHeader` above them all read the SAME two `DesignTokens`
/// constants for their inset — `terminalPanelInsetHorizontal`/
/// `terminalPanelInsetVertical`, decided by the spec to be 14/8. Before
/// this task the terminal surface had no inset at all, `.ended` had its
/// own `8`/`14`, and the header had its own, DIFFERENT `12`/`6`; nothing
/// enforced that a future edit to any one of the three would also touch
/// the other two.
///
/// (Round 1 of this task shared the constant between only the header and
/// the terminal surface, at the header's pre-existing 12/6, leaving
/// `.ended` on its own separate literal. That was a misreading of an
/// under-specified brief — the spec actually decided 14/8 for the whole
/// panel, panes included, and has the header move to it. This suite was
/// rewritten to match: three readers, one value, 14/8.)
///
/// A test asserting "the inset is 14" would only prove someone typed 14 —
/// it would stay green even if any ONE of the three call sites quietly
/// kept, or regained, its own independent literal while the other two used
/// the shared constant. What this suite pins instead is the coupling: all
/// three call sites reference the identical two token names, and none
/// carries a raw numeric literal in a `.padding(.horizontal/.vertical, …)`
/// position within its own reader.
///
/// This project has no view-instantiation/rendering test tool (the same
/// boundary `SnippetMenuItemsKeyboardShortcutGuardTests` and
/// `SnippetMenuItems`/`SnippetsSheet` already document), so — like that
/// suite — this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/ContentView+Detail.swift`, not a rendered-view
/// assertion. Each reader region is located textually (each `switch`
/// `case` up to the next `case`, and `TerminalPanelHeader`'s `var body`
/// block by brace-counting) SPECIFICALLY so the scan does not also trip
/// over the file's other, unrelated numeric paddings — the resume/
/// edit-error banners further up the same file, which also happen to use
/// `.padding(.horizontal, 12)`.
///
/// Deliberately NOT covered, so a green run is not mistaken for a proof:
/// - Whether the padding is actually applied to `SSHTerminalView`/the
///   `.ended` `VStack`/the header's `HStack` rather than some unrelated
///   view that happens to sit in the same textual region — a source scan
///   cannot see SwiftUI's modifier-to-view binding, only which tokens are
///   written near which anchor text.
/// - This is a source-text scan, same limits as
///   `SnippetMenuItemsKeyboardShortcutGuardTests`/`IconTooltipLintTests`:
///   commented-out code or an unusual reformat could fool it.
@Suite("Terminal panel inset guard")
struct TerminalPanelInsetTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TerminalPanelInsetTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetMenuItemsKeyboardShortcutGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private static let designTokensFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/DesignTokens.swift")

    // MARK: - The guard

    @Test func terminalSurfaceReadsTheSharedConstants() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.rangeOfCase(startingWith: "case .running, .opening:", in: lines) else {
            Issue.record("`case .running, .opening:` not found — re-anchor this guard")
            return
        }
        let violations = Self.insetLiteralViolations(in: lines, range: range)
        #expect(violations.isEmpty, """
            Terminal surface has its own numeric padding at line(s) \
            \(violations.map { $0 + 1 }) instead of reading \
            `DesignTokens.terminalPanelInsetHorizontal`/`terminalPanelInsetVertical`.
            """)
    }

    @Test func endedBlockReadsTheSharedConstants() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.rangeOfCase(startingWith: "case .ended(", in: lines) else {
            Issue.record("`case .ended(` not found — re-anchor this guard")
            return
        }
        let violations = Self.insetLiteralViolations(in: lines, range: range)
        #expect(violations.isEmpty, """
            .ended block has its own numeric padding at line(s) \
            \(violations.map { $0 + 1 }) instead of reading \
            `DesignTokens.terminalPanelInsetHorizontal`/`terminalPanelInsetVertical`.
            """)
    }

    @Test func headerReadsTheSharedConstants() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofBlockStartingWith: "var body: some View {", in: lines) else {
            Issue.record("`var body: some View {` not found — re-anchor this guard")
            return
        }
        let violations = Self.insetLiteralViolations(in: lines, range: range)
        #expect(violations.isEmpty, """
            TerminalPanelHeader.body has its own numeric padding at line(s) \
            \(violations.map { $0 + 1 }) instead of reading \
            `DesignTokens.terminalPanelInsetHorizontal`/`terminalPanelInsetVertical`.
            """)
    }

    /// A present-tense check that all THREE readers still exist and still
    /// carry the shared tokens. Without this, a scanner that quietly
    /// stopped recognizing any padding call at all would report the
    /// all-clear above for the wrong reason: zero violations because zero
    /// calls were seen, not because all three real call sites are
    /// correctly coupled.
    @Test func allThreeReadersStillReferenceBothConstants() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let horizontalCount = Self.occurrenceCount(
            of: "DesignTokens.terminalPanelInsetHorizontal", in: source)
        let verticalCount = Self.occurrenceCount(
            of: "DesignTokens.terminalPanelInsetVertical", in: source)
        #expect(horizontalCount == 3, """
            Expected exactly 3 references to \
            `DesignTokens.terminalPanelInsetHorizontal` (terminal surface + \
            `.ended` + header), found \(horizontalCount).
            """)
        #expect(verticalCount == 3, """
            Expected exactly 3 references to \
            `DesignTokens.terminalPanelInsetVertical` (terminal surface + \
            `.ended` + header), found \(verticalCount).
            """)
    }

    /// Pins that there is exactly ONE source of truth for each constant:
    /// `DesignTokens.swift` defines each name once, not once per
    /// would-be reader.
    @Test func designTokensDefinesEachConstantExactlyOnce() throws {
        let source = try String(contentsOf: Self.designTokensFile, encoding: .utf8)
        let horizontalDefinitions = Self.occurrenceCount(
            of: "static let terminalPanelInsetHorizontal", in: source)
        let verticalDefinitions = Self.occurrenceCount(
            of: "static let terminalPanelInsetVertical", in: source)
        #expect(horizontalDefinitions == 1)
        #expect(verticalDefinitions == 1)
    }

    /// Pins the actual DECIDED value from
    /// `docs/superpowers/specs/2026-08-10-snippets-round-2-design.md`
    /// ("P2 — Terminal-Fassung": "Rand ums Terminal: 14 horizontal / 8
    /// vertikal") — unlike a bare "the inset is 14" test on its own, this
    /// is not standing in for the coupling guard above (that is what the
    /// three `…ReadsTheSharedConstants` tests are for); it only catches a
    /// typo in the ONE place the number is actually written, which the
    /// coupling tests cannot: they only ever compare token NAMES, never
    /// the value those names hold.
    @Test func sharedConstantsMatchTheDecidedSpecValue() {
        #expect(DesignTokens.terminalPanelInsetHorizontal == 14)
        #expect(DesignTokens.terminalPanelInsetVertical == 8)
    }

    /// Backs the doc comment's specific claim that the resume/edit-error
    /// banners further up this same file also use `.padding(.horizontal,
    /// 12)` and are NOT part of any of the three reader ranges — without
    /// this test, that claim was asserted in prose but never actually
    /// checked: nothing proved the banner lines exist, or that they fall
    /// outside all three ranges, as opposed to simply never being scanned
    /// by accident.
    @Test func bannerPaddingLiesOutsideAllThreeReaderRanges() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let bannerLines = lines.indices.filter { lines[$0].contains(".padding(.horizontal, 12)") }
        #expect(!bannerLines.isEmpty, "expected at least one unrelated `.padding(.horizontal, 12)` banner line")

        let ranges = [
            Self.rangeOfCase(startingWith: "case .running, .opening:", in: lines),
            Self.rangeOfCase(startingWith: "case .ended(", in: lines),
            Self.range(ofBlockStartingWith: "var body: some View {", in: lines),
        ]
        for lineIndex in bannerLines {
            for range in ranges {
                // A missing range passes on purpose: whether each range EXISTS is
                // what the three `…ReadsTheSharedConstants` tests pin; this test
                // only asks that no banner line falls inside one that does.
                #expect(
                    range?.contains(lineIndex) != true,
                    "banner line \(lineIndex + 1) lies inside a reader range \(String(describing: range))")
            }
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerFlagsALiteralInTheRunningOpeningCase() {
        let source = """
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            case .ended(let message):
                Text(message ?? "")
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.rangeOfCase(startingWith: "case .running, .opening:", in: lines)!
        #expect(!Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    @Test func scannerAcceptsTheConstantInTheRunningOpeningCase() {
        let source = """
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
            case .ended(let message):
                Text(message ?? "")
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.rangeOfCase(startingWith: "case .running, .opening:", in: lines)!
        #expect(Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    /// The exact regression this guard exists to catch on the `.ended`
    /// side: it quietly regains its own literal instead of reading the
    /// shared constants alongside the other two readers.
    @Test func scannerFlagsALiteralInTheEndedCase() {
        let source = """
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? "")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
            case .closed:
                Color.clear
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.rangeOfCase(startingWith: "case .ended(", in: lines)!
        #expect(!Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    @Test func scannerAcceptsTheConstantInTheEndedCase() {
        let source = """
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? "")
                }
                .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
                .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
            case .closed:
                Color.clear
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.rangeOfCase(startingWith: "case .ended(", in: lines)!
        #expect(Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    /// The exact regression this guard exists to catch on the header side:
    /// `TerminalPanelHeader.body` quietly regains its own literal while the
    /// terminal surface (elsewhere in the file) keeps the constant. This is
    /// the same mutation the fix report's manual re-run performs against
    /// the REAL file (put a bare `12` back on the header) — this synthetic
    /// version is the always-on regression test for it.
    @Test func scannerFlagsALiteralInHeaderBody() {
        let source = """
            var body: some View {
                HStack { Text(hostTitle) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var body: some View {", in: lines)!
        #expect(!Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    @Test func scannerAcceptsTheConstantInHeaderBody() {
        let source = """
            var body: some View {
                HStack { Text(hostTitle) }
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "var body: some View {", in: lines)!
        #expect(Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    /// The `.ended` case's own lines sit textually AFTER the `.running,
    /// .opening` case ends — proving the case-range finder stops there and
    /// does not pull `.ended`'s lines into the terminal-surface scan (and
    /// vice versa, the `.ended` range finder starts only at its own case).
    @Test func caseRangeFinderStopsAtTheNextCase() {
        let source = """
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? "")
                }
                .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
                .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
            case .closed:
                Color.clear
            """
        let lines = source.components(separatedBy: "\n")
        let runningRange = Self.rangeOfCase(startingWith: "case .running, .opening:", in: lines)!
        let endedRange = Self.rangeOfCase(startingWith: "case .ended(", in: lines)!
        #expect(!runningRange.overlaps(endedRange))
        #expect(Self.insetLiteralViolations(in: lines, range: runningRange).isEmpty)
        #expect(Self.insetLiteralViolations(in: lines, range: endedRange).isEmpty)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `IconTooltipLintTests`'s and
    // `SnippetMenuItemsKeyboardShortcutGuardTests`'s scanners.

    private static func occurrenceCount(of needle: String, in source: String) -> Int {
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<source.endIndex
        }
        return count
    }

    /// The line containing `marker` (a full `case …:` label, including the
    /// trailing colon) up to (but excluding) the next `case ` line. 0-based,
    /// inclusive of the case label's own line.
    private static func rangeOfCase(startingWith marker: String, in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        guard let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ")
        }) else { return nil }
        return start...(end - 1)
    }

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `SnippetMenuItemsKeyboardShortcutGuardTests.range(ofFunctionNamed:in:)`.
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

    /// Within `range`, every `.padding(.horizontal, …)`/`.padding(.vertical,
    /// …)` call whose argument is a numeric literal rather than
    /// `DesignTokens.terminalPanelInsetHorizontal`/`Vertical`. 0-based line
    /// indices, relative to the full `lines` array.
    private static func insetLiteralViolations(in lines: [String], range: ClosedRange<Int>) -> [Int] {
        let axisPrefixes = [".padding(.horizontal,", ".padding(.vertical,"]
        return range.filter { index in
            let line = lines[index]
            guard axisPrefixes.contains(where: { line.contains($0) }) else { return false }
            return !line.contains("DesignTokens.terminalPanelInset")
        }
    }
}
