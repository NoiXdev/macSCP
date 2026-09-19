import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Wiring of the terminal type (plan of 2026-09-19, "Diagnostics and
/// terminal wishes", Task 4): the shell is opened with the RESOLVED type,
/// never a literal name; the app hands the panel a resolver that reads the
/// session's override and the global setting; both surfaces that choose a
/// type are on screen; and every string they show is in all four
/// catalogues.
///
/// Every negative check has a positive one beside it (CLAUDE.md, "Guards
/// that name what they watch"). The names a literal could spell are read
/// off `TerminalType.allCases`, not typed here a second time.
///
/// Known blind spots: SOURCE TEXT only. Nothing here renders a view, so it
/// cannot say the picker is legible or where it sits; the behaviour of the
/// resolver and of the panel is `TerminalTypeTests`' (Core).
@Suite("Terminal type wiring")
struct TerminalTypeWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let panelPath = "Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift"
    private static let contentViewPath = "Sources/MacSCPAppKit/ContentView.swift"
    private static let settingsViewPath = "Sources/MacSCPAppKit/SettingsView.swift"
    private static let formPath = "Sources/MacSCPAppKit/ConnectionFormView.swift"
    private static let pickerPath = "Sources/MacSCPAppKit/SessionEditorTerminalTypePicker.swift"
    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Comments AND strings blanked: structure only.
    private static func code(_ path: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(raw(path))
    }

    /// Comments blanked, string literals kept: what the code actually says.
    private static func withLiterals(_ path: String) throws -> String {
        try SwiftSource.blankingComments(raw(path))
    }

    private static func openIfNeededBody() throws -> (code: String, withLiterals: String) {
        let code = try Self.code(panelPath)
        let literals = try Self.withLiterals(panelPath)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "public func openIfNeeded()", in: code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: code),
                TransferQueueBarCancelGuardTests.slice(range, of: literals))
    }

    // MARK: - The panel opens with the resolved type

    /// Positive: `openIfNeeded` asks its resolver once, before the open
    /// task starts, and hands exactly that name to `openShell`.
    @Test func thePanelOpensTheShellWithTheResolvedName() throws {
        let body = try Self.openIfNeededBody().code
        #expect(body.contains("let terminalName = terminalType().rawValue"), """
            openIfNeeded() in \(Self.panelPath) no longer reads the resolved \
            terminal type into `terminalName`.
            """)
        #expect(body.contains("openShell(terminalName,"), """
            openIfNeeded() in \(Self.panelPath) no longer passes the resolved \
            name to openShell.
            """)
    }

    /// Negative, beside the positive above: no terminal name is spelled as
    /// a literal anywhere in the panel's source — neither one of the
    /// offered names nor any other xterm-family spelling.
    @Test func thePanelSpellsNoTerminalNameAsALiteral() throws {
        let literals = try Self.withLiterals(Self.panelPath)
        #expect(literals.contains("openShell("), """
            \(Self.panelPath) no longer calls openShell at all — the scan \
            below would be reading a file with nothing to find.
            """)
        let spelled = TerminalType.allCases.map { "\"\($0.rawValue)\"" }
            .filter { literals.contains($0) }
        #expect(spelled.isEmpty, "\(Self.panelPath) spells \(spelled) as a literal")
        #expect(!literals.contains("\"xterm"), """
            \(Self.panelPath) spells an xterm name as a literal.
            """)
    }

    // MARK: - The app hands the panel a resolver

    /// The panel's `terminalType:` argument has a default (`.default`), so
    /// the compiler would accept a construction that forgot it. The one
    /// construction in the app must pass it, and must build it from the
    /// session's override and the global setting through the one resolver.
    /// Read within the first 400 characters after the call opens — the
    /// closure is the first argument, and `openShell:` follows it.
    @Test func theAppBuildsThePanelWithTheResolver() throws {
        let code = try Self.code(Self.contentViewPath)
        let constructions = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "TerminalPanelViewModel(", in: code)
        #expect(constructions == 1, """
            expected exactly one TerminalPanelViewModel( in \
            \(Self.contentViewPath), found \(constructions).
            """)
        guard let start = code.range(of: "TerminalPanelViewModel(") else { return }
        let arguments = code[start.upperBound...].prefix(400)
        #expect(arguments.contains("terminalType:"), """
            ContentView builds TerminalPanelViewModel without `terminalType:` \
            — every shell would open with the default name.
            """)
        #expect(arguments.contains("TerminalType.resolved("), """
            ContentView's terminalType: closure does not go through \
            TerminalType.resolved(sessionOverride:global:).
            """)
        #expect(arguments.contains("settings.terminalType"), """
            ContentView's terminalType: closure does not read the global \
            setting when the shell opens.
            """)
        #expect(arguments.contains("TerminalType.sessionOverride(")
                && arguments.contains("tab?.activeStoredSessionID"), """
            ContentView's terminalType: closure does not look the override up \
            through the tab's connected stored session.
            """)
    }

    // MARK: - Both choosers are on screen

    @Test func settingsBindsTheGlobalType() throws {
        let code = try Self.code(Self.settingsViewPath)
        #expect(code.contains("$store.terminalType"), """
            \(Self.settingsViewPath) has no control bound to \
            SettingsStore.terminalType.
            """)
    }

    @Test func theSessionEditorDrawsTheOverridePicker() throws {
        let form = try Self.code(Self.formPath)
        #expect(form.contains("\(SessionEditorTerminalTypePicker.self)("), """
            \(Self.formPath) no longer draws SessionEditorTerminalTypePicker.
            """)
        let picker = try Self.code(Self.pickerPath)
        #expect(picker.contains("$viewModel.terminalTypeOverride"), """
            \(Self.pickerPath) is not bound to ConnectionViewModel.terminalTypeOverride.
            """)
        #expect(picker.contains("TerminalType.allCases"), """
            \(Self.pickerPath) no longer lists TerminalType.allCases — it \
            would offer a list of its own.
            """)
    }

    // MARK: - The catalogue

    private static func catalog(_ locale: String) throws -> [String: String] {
        let path = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return (parsed as? [String: String]) ?? [:]
    }

    /// The keys a file looks up with `L10n.string(` and a string literal as
    /// its first argument — on the same line or the next — read off the
    /// source rather than typed here.
    private static func lookedUpKeys(in source: String, prefix: String = "") -> Set<String> {
        var keys = Set<String>()
        var rest = Substring(source)
        while let open = rest.range(of: "L10n.string(") {
            let after = rest[open.upperBound...].drop { $0 == " " || $0 == "\n" }
            rest = after
            guard after.first == "\"" else { continue }
            let literal = after.dropFirst()
            guard let close = literal.firstIndex(of: "\"") else { break }
            let key = String(literal[..<close])
            if key.hasPrefix(prefix) { keys.insert(key) }
            rest = literal[close...]
        }
        return keys
    }

    /// Every name's label, the settings row and the editor row — in en,
    /// de, fr and pl, and resolving at run time rather than falling back.
    @Test func everyStringTheChoosersShowIsInAllFourCatalogues() throws {
        let labelKeys = Set(TerminalType.allCases.map(TerminalTypeLabel.key(for:)))
        let pickerKeys = Self.lookedUpKeys(in: try Self.withLiterals(Self.pickerPath))
        let settingsKeys = Self.lookedUpKeys(
            in: try Self.withLiterals(Self.settingsViewPath), prefix: "settings.terminal.type")
        #expect(!pickerKeys.isEmpty, "found no L10n.string( key in \(Self.pickerPath)")
        #expect(!settingsKeys.isEmpty, """
            found no settings.terminal.type… key in \(Self.settingsViewPath)
            """)

        let wanted = labelKeys.union(pickerKeys).union(settingsKeys)
        for locale in Self.catalogLocales {
            let catalog = try Self.catalog(locale)
            let missing = wanted.filter { (catalog[$0] ?? "").isEmpty }.sorted()
            #expect(missing.isEmpty, "\(locale).lproj lacks \(missing)")
        }
        for type in TerminalType.allCases {
            #expect(L10n.string(TerminalTypeLabel.key(for: type), "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        }
    }

    /// A label names the type by its own name, in every language: the name
    /// is what the server sees and what a person looks up, so a translation
    /// must not replace it.
    @Test func everyLabelKeepsTheNameItself() throws {
        for locale in Self.catalogLocales {
            let catalog = try Self.catalog(locale)
            for type in TerminalType.allCases {
                let label = catalog[TerminalTypeLabel.key(for: type)] ?? ""
                #expect(label.hasPrefix(type.rawValue + " "), """
                    \(locale): the label for \(type.rawValue) is "\(label)"
                    """)
            }
        }
    }
}
