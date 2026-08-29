import Foundation
import Testing
@testable import MacSCPAppKit

/// Guards the half of the three-dot-menu rule that no type can carry
/// (backlog 2026-08-20, point 5): where the menu sits in a management
/// sheet's footer, that the file actions are drawn by the menu instead of
/// by footer buttons of their own, that the DESTRUCTIVE action stayed a
/// visible footer button, and that the symbol-only menu carries both a help
/// text and an accessibility label.
///
/// The population is DISCOVERED, never listed. A hand-written list of sheet
/// files is the failure mode this project keeps meeting: it holds exactly
/// the sheets its author thought of, and the next sheet joins the codebase
/// unwatched while the suite stays green. So two scans over
/// `Sources/MacSCPAppKit` replace that list — every file that constructs
/// the menu must place and label it correctly, and every file with a sheet
/// footer must keep file actions out of its own buttons.
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

    private static let sourceDirectory = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: sourceDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every Swift file of the app layer, sorted so failure messages read
    /// the same on every machine.
    private static func appKitSourceNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    /// The sheets that carry the menu — found by looking, not by listing.
    /// The menu's own file is excluded: it constructs nothing, it *is* the
    /// construct.
    private static func sheetsCarryingTheMenu() throws -> [String] {
        try appKitSourceNames()
            .filter { $0 != menuFile }
            .filter { try source($0).contains(menuConstruction) }
    }

    // MARK: - The guards

    /// Position, as decided: immediately left of "Close". The scan reports
    /// the footer's controls in source order; the last two must be the menu
    /// and then Close, with the menu appearing exactly once.
    ///
    /// The `!isEmpty` assertion is the positive half of the discovery: if
    /// the scan ever stops finding sheets, this loop would iterate over
    /// nothing and pass without checking a thing.
    @Test func everySheetCarryingTheMenuPlacesItImmediatelyLeftOfClose() throws {
        let sheets = try Self.sheetsCarryingTheMenu()
        #expect(!sheets.isEmpty, """
            No file under Sources/MacSCPAppKit constructs \(Self.menuConstruction) \
            — either the menu was removed from every footer, or this scan is \
            looking in the wrong place and the loop below checks nothing.
            """)
        for file in sheets {
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
        let sheets = try Self.sheetsCarryingTheMenu()
        #expect(!sheets.isEmpty, """
            No file under Sources/MacSCPAppKit constructs \(Self.menuConstruction) \
            — the loop below would then check nothing.
            """)
        for file in sheets {
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

    /// The half a discovery over menu-carrying files cannot reach: a sheet
    /// that never adopted the menu and still draws Export…/Import… of its
    /// own is invisible to every check above, because it is not in their
    /// population at all. That is exactly how `SnippetsSheet` sat outside
    /// the rule while the suite stayed green.
    ///
    /// So this walks EVERY app-layer file with a sheet footer and reads the
    /// label keys its footer buttons carry. A key whose last component
    /// names one of `SheetOverflowAction`'s cases — the vocabulary is read
    /// off the type, not spelled here — is a file action drawn as a footer
    /// button, which the rule forbids.
    ///
    /// Two positives pin the negative: footers were actually found, and
    /// label keys were actually read out of them. Without those a broken
    /// scanner reports "no offenders" and reads exactly like compliance.
    @Test func noSheetFooterDrawsAFileActionAsItsOwnButton() throws {
        var footersScanned = 0
        var keysScanned = 0
        var offenders: [String: [String]] = [:]

        for file in try Self.appKitSourceNames() {
            let text = try Self.source(file)
            // A file without the Close button has no sheet footer to judge.
            // One WITH it must yield a footer — `footerButtonKeys` throws
            // otherwise, so a footer this scanner can no longer parse fails
            // loudly instead of dropping out of the population.
            guard text.contains(Self.closeKey) else { continue }
            let keys = try Self.footerButtonKeys(in: text)
            footersScanned += 1
            keysScanned += keys.count
            let fileActions = keys.filter(Self.namesAFileAction)
            if !fileActions.isEmpty { offenders[file] = fileActions.sorted() }
        }

        #expect(footersScanned > 0, """
            No app-layer file yielded a sheet footer — the offender scan below \
            examined nothing and its silence means nothing.
            """)
        #expect(keysScanned > 0, """
            Footers were found but no button label key was read out of any of \
            them — the offender filter has nothing to filter and cannot fail.
            """)

        for exempt in Self.footersExemptedFromTheRule {
            #expect(offenders[exempt] != nil, """
                \(exempt) is listed as exempt but no longer draws a file action \
                in its footer. Remove the exemption — a stale one silently \
                excuses whatever that file does next.
                """)
        }

        let unexcused = offenders
            .filter { !Self.footersExemptedFromTheRule.contains($0.key) }
            .map { "\($0.key): \($0.value.joined(separator: ", "))" }
            .sorted()
        #expect(unexcused.isEmpty, """
            These sheet footers draw a file action as their own button instead \
            of putting it under the three-dot menu — \(unexcused.joined(separator: "; ")).
            """)
    }

    /// "Show only what is possible", applied to the control itself: an
    /// action that cannot apply is left out of the menu, so a greyed-out ⋯
    /// is the same broken promise one step up — it opens onto nothing and
    /// says nothing about why.
    ///
    /// The negative reads the menu's WHOLE statement, trailing modifiers
    /// included, because that is where a `.disabled(` would actually land;
    /// a scan of the argument list alone could never match one and would be
    /// a comment that runs. Two positives pin it: the span really starts at
    /// the construction, and it really extends past the action closure's
    /// end rather than stopping on the first line.
    @Test func theMenuItselfIsNeverGreyedOut() throws {
        let sheets = try Self.sheetsCarryingTheMenu()
        #expect(!sheets.isEmpty, """
            No file under Sources/MacSCPAppKit constructs \(Self.menuConstruction) \
            — the loop below would then check nothing.
            """)
        for file in sheets {
            let statement = try Self.footerMenuStatement(in: Self.source(file))
            #expect(statement.contains(Self.menuConstruction), """
                \(file): the scanned span does not start at the menu's own \
                construction, so the check below is reading something else.
                """)
            #expect(statement.contains("}"), """
                \(file): the scanned span stops before the action closure \
                closes, so a modifier attached after it would never be seen.
                """)
            #expect(!statement.contains(".disabled("), """
                \(file): the three-dot menu is greyed out. Nothing possible \
                means no control at all — SheetOverflowMenu draws nothing for \
                an empty action list, which is what replaces disabling it.
                """)
        }
    }

    /// The rule's exception, and the reason the menu is not simply "the
    /// buttons that fit": hiding a destructive action is the wrong economy.
    /// Negative half — no destructive entry anywhere in the menu's own file
    /// — stands beside two positives: the menu file exists and renders the
    /// actions, and some discovered footer still carries a destructive
    /// button, so a footer that quietly moved Delete… under the menu could
    /// not leave this loop with nothing to find.
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

        let sheetsKeepingADestructiveButton = try Self.sheetsCarryingTheMenu().filter { file in
            try Self.footerBlock(in: Self.source(file)).contains("role: .destructive")
        }
        #expect(!sheetsKeepingADestructiveButton.isEmpty, """
            No footer that carries the three-dot menu still carries a \
            destructive button. Delete… would save footer width under the \
            menu, and that is exactly the trade the rule refuses.
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
    /// all three scanners must FAIL CLOSED rather than report an empty
    /// result as an all-clear.
    @Test func scannersFailClosedWhenTheFooterCannotBeFound() {
        let source = "struct Empty: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) { try Self.footerControls(in: source) }
        #expect(throws: (any Error).self) { try Self.footerBlock(in: source) }
        #expect(throws: (any Error).self) { try Self.footerButtonKeys(in: source) }
    }

    /// The offender scan's two halves, exercised without the real tree: the
    /// key reader must report what a footer actually draws, and the
    /// file-action test must separate a selection action from a file one
    /// using `SheetOverflowAction`'s own vocabulary.
    @Test func scannerReadsTheLabelKeysAFooterActuallyDraws() throws {
        let keys = try Self.footerButtonKeys(in: Self.syntheticSheet(menuBeforeClose: true))
        #expect(keys == ["fake.new", "common.close"], """
            the key reader must report the footer's own button labels in source \
            order — otherwise the offender scan filters an empty list and can \
            never accuse anyone.
            """)
    }

    /// The span must reach modifiers written after the action closure —
    /// exactly where a `.disabled(` would sit — or the negative above could
    /// never match one.
    @Test func scannerReachesModifiersWrittenAfterTheMenusClosure() throws {
        let statement = try Self.footerMenuStatement(in: Self.syntheticMenuStatement(
            trailingModifiers: ["                .disabled(true)"]))
        #expect(statement.contains(".disabled(true)"), """
            the statement scan must include what follows the action closure, \
            not stop at its closing brace.
            """)
    }

    @Test func aFileActionIsRecognisedByTheMenusOwnVocabulary() {
        #expect(!Self.namesAFileAction("snippets.new"))
        #expect(!Self.namesAFileAction("common.close"))
        for action in SheetOverflowAction.allCases {
            #expect(Self.namesAFileAction("someSheet.\(action.rawValue)"), """
                a footer button keyed after \(action.rawValue) is exactly what \
                the rule moves under the menu, so the scan must recognise it.
                """)
        }
    }

    // MARK: - Scanner
    //
    // Line-based and block-isolated, like the other footer/menu guards in
    // this target: locate the footer `HStack` that carries the Close button,
    // then read only within it — so a button elsewhere in the file (an
    // editor sheet's own footer, a row's context menu) is never mistaken for
    // the sheet's footer.

    private enum ScanError: Error { case footerNotFound, menuNotFound }

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

    /// The footers allowed, for now, to draw a file action as their own
    /// button. Recorded 2026-08-29 while `SnippetsSheet` was brought under
    /// the rule: `AuditLogSheet`'s "Export as Text…" writes a transcript of
    /// the log rather than a re-importable document, has no Import beside
    /// it, and does not share the menu's `Export…` wording — so folding it
    /// in is a decision about that sheet, not a mechanical repeat, and it
    /// was left out rather than forced.
    ///
    /// The entry is PINNED: the guard requires each exempted file to still
    /// draw such a button, so converting the sheet without deleting its line
    /// here fails loudly. An exemption that excuses nothing is the same
    /// silent hole as a hand-written population.
    private static let footersExemptedFromTheRule: Set<String> = ["AuditLogSheet.swift"]

    /// Whether a footer button's label key names one of the menu's actions.
    /// The vocabulary comes from `SheetOverflowAction`, so adding a case
    /// widens this scan on its own and no literal here can drift from it.
    ///
    /// Blind spot worth naming: it matches on the key's last component, so
    /// an unrelated key that happens to contain "export" or "import" inside
    /// that component would be accused wrongly.
    private static func namesAFileAction(_ key: String) -> Bool {
        guard let last = key.split(separator: ".").last?.lowercased() else { return false }
        return SheetOverflowAction.allCases.contains { last.contains($0.rawValue) }
    }

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

    /// The localization keys of the footer's own buttons, in source order.
    /// Throws under the same condition as the other two scanners.
    private static func footerButtonKeys(in source: String) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let range = footerRange(in: lines) else { throw ScanError.footerNotFound }
        return lines[range].compactMap { line -> String? in
            guard line.contains("Button("), let keyStart = line.range(of: "L10n.string(\"")
            else { return nil }
            let rest = line[keyStart.upperBound...]
            guard let keyEnd = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<keyEnd])
        }
    }

    /// The menu's whole statement: its construction line, the action
    /// closure brace-counted to its end, and any modifier lines written
    /// after it. Throws when no footer, or no menu inside it, can be
    /// located.
    private static func footerMenuStatement(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let range = footerRange(in: lines) else { throw ScanError.footerNotFound }
        guard let start = lines[range].firstIndex(where: { $0.contains(menuConstruction) })
        else { throw ScanError.menuNotFound }
        var depth = 0
        var sawOpenBrace = false
        var end = start
        for index in start...range.upperBound {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 { end = index; break }
        }
        guard sawOpenBrace else { throw ScanError.menuNotFound }
        var last = end
        while last + 1 <= range.upperBound,
              lines[last + 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            last += 1
        }
        return lines[start...last].joined(separator: "\n")
    }

    /// The footer's text, for checks that read whole statements rather than
    /// a control sequence. Throws under the same condition.
    private static func footerBlock(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let range = footerRange(in: lines) else { throw ScanError.footerNotFound }
        return lines[range].joined(separator: "\n")
    }

    /// A footer whose menu carries the given modifier lines after its
    /// action closure — lets the self-test exercise the statement span
    /// without the real files.
    private static func syntheticMenuStatement(trailingModifiers: [String]) -> String {
        ([
            "struct Fake: View {",
            "    var body: some View {",
            "        VStack {",
            "            HStack {",
            "                SheetOverflowMenu(actions: []) { action in",
            "                    switch action {",
            "                    case .export: break",
            "                    case .import: break",
            "                    }",
            "                }",
        ] + trailingModifiers + [
            "                Button(L10n.string(\"common.close\", \"Close\")) { dismiss() }",
            "            }",
            "        }",
            "    }",
            "}",
        ]).joined(separator: "\n")
    }

    /// A footer shaped like the real ones, with the menu on either side of
    /// Close — lets the self-tests exercise the scanners without the real
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
