import Foundation
import Testing

/// Guards ONE property of `ContentView+Detail.swift`'s `terminalPanel(_:)`
/// (Terminal-Fassung P2, Task 1): the terminal surface (`SSHTerminalView`,
/// shown for `.running`/`.opening`) and `TerminalPanelHeader` above it must
/// read the SAME two `DesignTokens` constants for their inset —
/// `terminalPanelInsetHorizontal`/`terminalPanelInsetVertical`. Before this
/// task the terminal surface had no inset at all and the header carried its
/// own `12`/`6` literals; nothing enforced that a future edit to one side
/// would also touch the other.
///
/// A test asserting "the inset is 12" would only prove someone typed 12 —
/// it would stay green even if the header quietly kept, or regained, its
/// own independent literal while the terminal surface used the shared
/// constant (or vice versa). What this suite pins instead is the coupling:
/// both call sites reference the identical two token names, and neither
/// carries a raw numeric literal in a `.padding(.horizontal/.vertical, …)`
/// position within its own reader.
///
/// This project has no view-instantiation/rendering test tool (the same
/// boundary `SnippetMenuItemsKeyboardShortcutGuardTests` and
/// `SnippetMenuItems`/`SnippetsSheet` already document), so — like that
/// suite — this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/ContentView+Detail.swift`, not a rendered-view
/// assertion. Each reader region is located textually (the `.running,
/// .opening` case up to the next `case`, and `TerminalPanelHeader`'s `var
/// body` block by brace-counting) SPECIFICALLY so the scan does not also
/// trip over the file's other, unrelated numeric paddings — the `.ended`
/// state's own separate `8`/`14` literals (deliberately left untouched,
/// see the task brief) and the resume/edit-error banners further up the
/// same file, which also happen to use `.padding(.horizontal, 12)`.
///
/// Deliberately NOT covered, so a green run is not mistaken for a proof:
/// - Whether the padding is actually applied to `SSHTerminalView`/the
///   header's `HStack` rather than some unrelated view that happens to sit
///   in the same textual region — a source scan cannot see SwiftUI's
///   modifier-to-view binding, only which tokens are written near which
///   anchor text.
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
        guard let range = Self.rangeOfRunningOpeningCase(in: lines) else {
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

    /// A present-tense check that BOTH readers still exist and still carry
    /// the shared tokens. Without this, a scanner that quietly stopped
    /// recognizing any padding call at all would report the all-clear above
    /// for the wrong reason: zero violations because zero calls were seen,
    /// not because both real call sites are correctly coupled.
    @Test func bothReadersStillReferenceBothConstants() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let horizontalCount = Self.occurrenceCount(
            of: "DesignTokens.terminalPanelInsetHorizontal", in: source)
        let verticalCount = Self.occurrenceCount(
            of: "DesignTokens.terminalPanelInsetVertical", in: source)
        #expect(horizontalCount == 2, """
            Expected exactly 2 references to \
            `DesignTokens.terminalPanelInsetHorizontal` (terminal surface + \
            header), found \(horizontalCount).
            """)
        #expect(verticalCount == 2, """
            Expected exactly 2 references to \
            `DesignTokens.terminalPanelInsetVertical` (terminal surface + \
            header), found \(verticalCount).
            """)
    }

    /// Pins that there is exactly ONE source of truth for each constant
    /// (Schritt 2 of the brief): `DesignTokens.swift` defines each name
    /// once, not once per would-be reader.
    @Test func designTokensDefinesEachConstantExactlyOnce() throws {
        let source = try String(contentsOf: Self.designTokensFile, encoding: .utf8)
        let horizontalDefinitions = Self.occurrenceCount(
            of: "static let terminalPanelInsetHorizontal", in: source)
        let verticalDefinitions = Self.occurrenceCount(
            of: "static let terminalPanelInsetVertical", in: source)
        #expect(horizontalDefinitions == 1)
        #expect(verticalDefinitions == 1)
    }

    /// The `.ended` state's own inset is explicitly out of scope for the
    /// coupling (see this suite's doc comment) — a present-tense check that
    /// it is UNCHANGED, so nobody mistakes a future silent edit there for
    /// something this guard would catch.
    @Test func endedBlockKeepsItsOwnUntouchedLiterals() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        #expect(source.contains(".padding(.vertical, 8)\n                    .padding(.horizontal, 14)"))
    }

    /// Backs the doc comment's specific claim that the resume/edit-error
    /// banners further up this same file also use `.padding(.horizontal,
    /// 12)` and are NOT part of either reader range — without this test,
    /// that claim was asserted in prose but never actually checked: nothing
    /// proved the banner lines exist, or that they fall outside both
    /// ranges, as opposed to simply never being scanned by accident.
    @Test func bannerPaddingLiesOutsideBothReaderRanges() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let bannerLines = lines.indices.filter { lines[$0].contains(".padding(.horizontal, 12)") }
        #expect(!bannerLines.isEmpty, "expected at least one unrelated `.padding(.horizontal, 12)` banner line")

        let caseRange = Self.rangeOfRunningOpeningCase(in: lines)
        let headerRange = Self.range(ofBlockStartingWith: "var body: some View {", in: lines)
        for lineIndex in bannerLines {
            #expect(caseRange.map { !$0.contains(lineIndex) } ?? true)
            #expect(headerRange.map { !$0.contains(lineIndex) } ?? true)
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerFlagsALiteralInTheRunningOpeningCase() {
        let source = """
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            case .ended(let message):
                Text(message ?? "")
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.rangeOfRunningOpeningCase(in: lines)!
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
        let range = Self.rangeOfRunningOpeningCase(in: lines)!
        #expect(Self.insetLiteralViolations(in: lines, range: range).isEmpty)
    }

    /// The exact regression this guard exists to catch on the header side:
    /// `TerminalPanelHeader.body` quietly regains its own literal while the
    /// terminal surface (elsewhere in the file) keeps the constant.
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

    /// The `.ended` case's own literals sit textually AFTER the
    /// `.running, .opening` case ends — proving the case-range finder
    /// stops there and does not pull `.ended`'s untouched `8`/`14` into the
    /// terminal-surface scan.
    @Test func caseRangeFinderExcludesTheFollowingEndedCase() {
        let source = """
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
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
        let range = Self.rangeOfRunningOpeningCase(in: lines)!
        #expect(Self.insetLiteralViolations(in: lines, range: range).isEmpty)
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

    /// The `case .running, .opening:` line up to (but excluding) the next
    /// `case ` line. 0-based, inclusive of the case label's own line.
    private static func rangeOfRunningOpeningCase(in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains("case .running, .opening:") })
        else { return nil }
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
