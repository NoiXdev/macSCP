import Foundation
import Testing
@testable import MacSCPAppKit

/// Guards the half of the three-dot-menu rule that no type can carry
/// (backlog 2026-08-20, point 5): where the menu sits in the two management
/// sheets' footers, that the file actions are drawn by the menu instead of
/// by footer buttons of their own, that the DESTRUCTIVE action stayed a
/// visible footer button, and that the symbol-only menu carries both a help
/// text and an accessibility label.
///
/// Every negative check below stands beside a positive one, and both
/// scanners throw rather than return an empty result — a footer or a menu
/// file that cannot be located is a loud failure, not a silent all-clear.
/// The action keys are read off `SheetOverflowAction`, never spelled, so a
/// renamed key moves the guard with it.
///
/// Known blind spot, shared with the other source-text guards in this
/// target: it reads source text, so commented-out code or an unusual
/// reformat can fool it, and it confirms which construct sits in which
/// position — not that SwiftUI draws what the text implies.
@Suite("Sheet overflow menu wiring")
struct SheetOverflowMenuWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SheetOverflowMenuWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ name: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/MacSCPAppKit/\(name)"),
            encoding: .utf8)
    }

    /// The two sheets the decision names. Both, so the rule holds in one
    /// place rather than one of two.
    private static let sheetFiles = ["LoginSetsSheet.swift", "SSHKeysSheet.swift"]

    // MARK: - The guards

    /// Position, as decided: immediately left of "Close". The scan reports
    /// the footer's controls in source order; the last two must be the menu
    /// and then Close, with the menu appearing exactly once.
    @Test func bothSheetsPlaceTheMenuImmediatelyLeftOfClose() throws {
        for file in Self.sheetFiles {
            let controls = try Self.footerControls(in: Self.source(file))
            #expect(controls.suffix(2) == [.overflowMenu, .close], """
                \(file): the footer must end with the three-dot menu and then \
                Close — found \(controls) instead.
                """)
            #expect(controls.filter { $0 == .overflowMenu }.count == 1, """
                \(file): the footer must draw exactly one three-dot menu — \
                found \(controls).
                """)
        }
    }

    /// The file actions are drawn BY the menu, so no footer may draw a
    /// button carrying one of the menu's own labels. Positive half in the
    /// same assertion: the footer really does construct the menu, so this
    /// cannot pass by scanning a footer that has neither.
    @Test func theFooterDrawsNoButtonForAnActionTheMenuOwns() throws {
        for file in Self.sheetFiles {
            let footer = try Self.footerBlock(in: Self.source(file))
            #expect(footer.contains(Self.menuConstruction), """
                \(file): the footer does not construct \(Self.menuConstruction) \
                at all — the absence check below would then be vacuous.
                """)
            for action in SheetOverflowAction.allCases {
                #expect(!footer.contains("\"\(action.labelKey)\""), """
                    \(file): the footer draws \(action.labelKey) itself. File \
                    actions belong to the three-dot menu, which labels them \
                    from SheetOverflowAction.
                    """)
            }
        }
    }

    /// The rule's exception, and the reason the menu is not simply "the
    /// buttons that fit": hiding a destructive action is the wrong economy.
    /// Negative half — no destructive entry anywhere in the menu's own file
    /// — stands beside two positives: the menu file exists and renders the
    /// actions, and the login footer still carries a destructive button.
    @Test func theDestructiveActionStaysAVisibleFooterButtonAndNeverEntersTheMenu() throws {
        let menuSource = try Self.source(Self.menuFile)
        #expect(menuSource.contains("SheetOverflowAction"), """
            \(Self.menuFile) does not mention SheetOverflowAction — this guard \
            is scanning the wrong file, and its absence check means nothing.
            """)
        #expect(!menuSource.contains("role: .destructive"), """
            \(Self.menuFile) carries a destructive entry. Selection actions \
            stay visible and destructive ones stay visible with them; only \
            file actions move under the menu.
            """)

        let loginFooter = try Self.footerBlock(in: Self.source("LoginSetsSheet.swift"))
        #expect(loginFooter.contains("role: .destructive"), """
            LoginSetsSheet's footer lost its destructive button. Delete… would \
            save footer width under the menu, and that is exactly the trade \
            the rule refuses.
            """)
    }

    /// Symbol only, no word — which makes both affordances mandatory rather
    /// than optional. They are different affordances sharing one key, the
    /// house form set by `SettingsView`'s remove-rule button.
    @Test func theSymbolOnlyMenuCarriesBothHelpAndAccessibilityLabel() throws {
        let menuSource = try Self.source(Self.menuFile)
        #expect(menuSource.contains("Image(systemName:"), """
            \(Self.menuFile) no longer labels the menu with a symbol — if it \
            gained a word, the two assertions below stopped being mandatory.
            """)
        #expect(menuSource.contains(".help("), """
            \(Self.menuFile): a symbol-only control without .help( has no \
            hover tooltip to say what it does.
            """)
        #expect(menuSource.contains(".accessibilityLabel("), """
            \(Self.menuFile): a symbol-only control without \
            .accessibilityLabel( is announced by VoiceOver as its SF Symbol.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerSeesTheMenuPlacedOnTheWrongSideOfClose() throws {
        let controls = try Self.footerControls(in: Self.syntheticSheet(menuBeforeClose: false))
        #expect(controls.suffix(2) == [.close, .overflowMenu], """
            the scanner must report the controls in their actual source order, \
            not a hardcoded one — otherwise it could never catch this.
            """)
    }

    @Test func scannerAcceptsAMenuImmediatelyLeftOfClose() throws {
        let controls = try Self.footerControls(in: Self.syntheticSheet(menuBeforeClose: true))
        #expect(controls == [.button, .overflowMenu, .close])
    }

    /// A footer with no Close button, and a source with no footer at all —
    /// both scanners must FAIL CLOSED rather than report an empty result as
    /// an all-clear.
    @Test func scannersFailClosedWhenTheFooterCannotBeFound() {
        let source = "struct Empty: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) { try Self.footerControls(in: source) }
        #expect(throws: (any Error).self) { try Self.footerBlock(in: source) }
    }

    // MARK: - Scanner
    //
    // Line-based and block-isolated, like the other footer/menu guards in
    // this target: locate the footer `HStack` that carries the Close button,
    // then read only within it — so a button elsewhere in the file (an
    // editor sheet's own footer, a row's context menu) is never mistaken for
    // the sheet's footer.

    private enum ScanError: Error { case footerNotFound }

    /// What a footer line draws, at the granularity the position rule needs.
    private enum FooterControl: Equatable {
        case button
        case overflowMenu
        case close
    }

    private static let menuFile = "SheetOverflowMenu.swift"
    private static let menuConstruction = "SheetOverflowMenu("
    /// The Close button's key. Spelled once, here — and the scan throws when
    /// it cannot find it, so a rename fails loudly instead of quietly
    /// matching nothing.
    private static let closeKey = "\"common.close\""

    /// The line range of the footer `HStack { ... }`: the nearest such line
    /// above the Close button, then brace-counted to its end. 0-based and
    /// inclusive of both ends.
    private static func footerRange(in lines: [String]) -> ClosedRange<Int>? {
        guard let closeLine = lines.firstIndex(where: { $0.contains(closeKey) }) else { return nil }
        guard let start = lines[..<closeLine].lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "HStack {"
        }) else { return nil }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 { return start...index }
        }
        return nil
    }

    /// The footer's controls in source order. Throws when no footer can be
    /// located — see `scannersFailClosedWhenTheFooterCannotBeFound`.
    private static func footerControls(in source: String) throws -> [FooterControl] {
        let lines = source.components(separatedBy: "\n")
        guard let range = footerRange(in: lines) else { throw ScanError.footerNotFound }
        return lines[range].compactMap { line in
            if line.contains(closeKey) { return .close }
            if line.contains(menuConstruction) { return .overflowMenu }
            if line.contains("Button(") { return .button }
            return nil
        }
    }

    /// The footer's text, for checks that read whole statements rather than
    /// a control sequence. Throws under the same condition.
    private static func footerBlock(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let range = footerRange(in: lines) else { throw ScanError.footerNotFound }
        return lines[range].joined(separator: "\n")
    }

    /// A footer shaped like the real ones, with the menu on either side of
    /// Close — lets the self-tests exercise the scanner without the real
    /// files.
    private static func syntheticSheet(menuBeforeClose: Bool) -> String {
        let menu = "                SheetOverflowMenu(actions: []) { _ in }"
        let close = "                Button(L10n.string(\"common.close\", \"Close\")) { dismiss() }"
        let tail = menuBeforeClose ? [menu, close] : [close, menu]
        return ([
            "struct Fake: View {",
            "    var body: some View {",
            "        VStack {",
            "            HStack {",
            "                Button(L10n.string(\"fake.new\", \"New…\")) { }",
        ] + tail + [
            "            }",
            "        }",
            "    }",
            "}",
        ]).joined(separator: "\n")
    }
}
