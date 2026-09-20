import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Wiring of the terminal theme (plan of 2026-09-19, "The answered
/// wishes", Task 3): the terminal surface takes its colours from the
/// RESOLVED theme rather than from the fixed `DesignTokens` pair it used
/// before; the one place a theme reaches SwiftTerm installs all sixteen
/// ANSI colours as well as the three surface colours; Settings binds the
/// choice and offers the import; a refused import shows a fixed sentence
/// and no parser text; and every string those surfaces show is in all four
/// catalogues.
///
/// Every negative check has a positive one beside it (CLAUDE.md, "Guards
/// that name what they watch"). The names a literal could spell are read
/// off `TerminalThemePreset.allCases`, not typed here a second time.
///
/// Known blind spots: SOURCE TEXT only. Nothing here renders a view, so it
/// cannot say the picker is legible, that the preview shows the right
/// colours, or that SwiftTerm paints what it is handed. The behaviour of
/// the resolution and of the reader is `TerminalThemeTests`' and
/// `ITermColorsImportTests`' (Core).
@Suite("Terminal theme wiring")
struct TerminalThemeWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let terminalViewPath = "Sources/MacSCPAppKit/SSHTerminalView.swift"
    private static let panelPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    private static let installerPath = "Sources/MacSCPAppKit/TerminalThemePresentation.swift"
    private static let settingsViewPath = "Sources/MacSCPAppKit/SettingsView.swift"
    private static let catalogLocales = ["en", "de", "fr", "pl"]

    /// Comments AND strings blanked: structure only. A long explanatory
    /// comment in any of these files therefore cannot answer a check here
    /// (CLAUDE.md, "Source-scanning guards read comments too").
    private static func code(_ path: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(path))
    }

    /// Comments blanked, string literals kept: what the code actually says.
    private static func withLiterals(_ path: String) throws -> String {
        try SourceCorpus.commentFree(of: repoRoot.appendingPathComponent(path))
    }

    // MARK: - The terminal surface takes the resolved theme

    /// Positive: both the first render and every later one resolve the
    /// theme off the settings store and hand it to the one installer.
    @Test func theTerminalViewPaintsItselfFromTheResolvedTheme() throws {
        let code = try Self.code(Self.terminalViewPath)
        let applications = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "TerminalThemeInstaller.apply(", in: code)
        #expect(applications == 2, """
            expected exactly two TerminalThemeInstaller.apply( in \
            \(Self.terminalViewPath) — one in makeNSView, one in updateNSView \
            — found \(applications).
            """)
        let reads = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "settingsStore.resolvedTerminalTheme", in: code)
        #expect(reads == 2, """
            expected exactly two reads of settingsStore.resolvedTerminalTheme \
            in \(Self.terminalViewPath), found \(reads).
            """)
        #expect(code.contains("appliedTheme"), """
            \(Self.terminalViewPath) no longer records the applied theme — \
            updateNSView would reinstall the palette on every re-render.
            """)
    }

    /// Negative, beside the positive above: the terminal surface names no
    /// fixed terminal colour any more. `DesignTokens.terminalBackground`
    /// and `.terminalText` are exactly what this task replaced, and a
    /// re-introduced one would leave the theme half-applied.
    @Test func theTerminalViewNamesNoFixedTerminalColour() throws {
        let code = try Self.code(Self.terminalViewPath)
        #expect(code.contains("nativeBackgroundColor") == false, """
            \(Self.terminalViewPath) sets nativeBackgroundColor itself \
            instead of going through TerminalThemeInstaller.
            """)
        for token in ["DesignTokens.terminalBackground", "DesignTokens.terminalText"] {
            #expect(!code.contains(token), "\(Self.terminalViewPath) still reads \(token)")
        }
    }

    /// The installer is the seam. It must set all four things a theme
    /// carries — the three surface colours and the sixteen-entry palette —
    /// or a chosen theme would apply to only part of the terminal.
    @Test func theInstallerAppliesTheWholeTheme() throws {
        let code = try Self.code(Self.installerPath)
        for call in [
            "terminal.nativeBackgroundColor = theme.background",
            "terminal.nativeForegroundColor = theme.foreground",
            "terminal.caretColor = theme.cursor",
            "terminal.layer?.backgroundColor = theme.background",
            "terminal.installColors(theme.ansi",
        ] {
            #expect(code.contains(call), "\(Self.installerPath) no longer does: \(call)")
        }
    }

    /// The palette is installed LAST: `installColors` rebuilds the
    /// 256-colour palette and, under the emulator's non-default palette
    /// strategies, reads the background and foreground while doing so.
    @Test func thePaletteIsInstalledAfterTheSurfaceColours() throws {
        let code = try Self.code(Self.installerPath)
        let background = try #require(code.range(of: "terminal.nativeBackgroundColor"))
        let foreground = try #require(code.range(of: "terminal.nativeForegroundColor"))
        let palette = try #require(code.range(of: "terminal.installColors("))
        #expect(background.lowerBound < palette.lowerBound)
        #expect(foreground.lowerBound < palette.lowerBound)
    }

    // MARK: - The whole panel is one surface

    /// Fix round 1, review Important #3 and Minor #10. Positive: every
    /// place the terminal panel paints itself — the frame the surface sits
    /// in, the "shell ended" message, the header strip and the snippet
    /// popover that hangs off it — reads the SAME resolved theme.
    @Test func everySurfaceOfTheTerminalPanelReadsTheResolvedTheme() throws {
        let code = try Self.code(Self.panelPath)
        let reads = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "settingsStore.resolvedTerminalTheme", in: code)
        #expect(reads == 1, """
            expected exactly one read of settingsStore.resolvedTerminalTheme \
            in \(Self.panelPath) — resolved once in terminalPanel and \
            handed on from there, so no two parts of one panel can resolve \
            differently — found \(reads).
            """)
        #expect(code.contains("TerminalPanelHeader(") && code.contains("theme: theme"), """
            \(Self.panelPath) no longer hands TerminalPanelHeader the theme \
            it resolved.
            """)
        #expect(code.contains("let theme: TerminalTheme"), """
            TerminalPanelHeader in \(Self.panelPath) does not take a theme.
            """)
        for painted in [
            "theme.background.swiftUIColor",
            "theme.foreground.swiftUIColor",
        ] {
            #expect(code.contains(painted), "\(Self.panelPath) no longer paints \(painted)")
        }
    }

    /// Negative, beside the positive above: no fixed terminal colour is
    /// left anywhere in that file. A single surviving token is exactly the
    /// half-themed panel this round exists to close — a dark strip above a
    /// light terminal.
    @Test func theTerminalPanelNamesNoFixedTerminalColour() throws {
        let code = try Self.code(Self.panelPath)
        for token in ["DesignTokens.terminalBackground", "DesignTokens.terminalText"] {
            #expect(!code.contains(token), "\(Self.panelPath) still reads \(token)")
        }
    }

    // MARK: - Settings chooses and imports

    @Test func settingsBindsTheGlobalChoiceAndListsThePresets() throws {
        let code = try Self.code(Self.settingsViewPath)
        #expect(code.contains("$store.terminalThemeChoice"), """
            \(Self.settingsViewPath) has no control bound to \
            SettingsStore.terminalThemeChoice.
            """)
        #expect(code.contains("TerminalThemePreset.allCases"), """
            \(Self.settingsViewPath) no longer lists TerminalThemePreset \
            .allCases — it would offer a list of its own.
            """)
        #expect(code.contains("TerminalThemeChoice.imported"), """
            \(Self.settingsViewPath) offers no row for the imported theme.
            """)
    }

    @Test func settingsImportsThroughTheOneReader() throws {
        let code = try Self.code(Self.settingsViewPath)
        #expect(code.contains("ITermColorsImport.theme(contentsOf:"), """
            \(Self.settingsViewPath) does not read a picked file through \
            ITermColorsImport.
            """)
        #expect(code.contains("ITermColorsImport.themeName("), """
            \(Self.settingsViewPath) does not take the imported theme's name \
            from the file's name.
            """)
        #expect(code.contains("startAccessingSecurityScopedResource()"), """
            \(Self.settingsViewPath) reads a picked file without the \
            security-scoped access every other picker here does.
            """)
    }

    /// Fix round 1, review Minor #9: a picker that FAILS is not a picker
    /// the user cancelled. Both used to fall out of the same `guard`, so a
    /// real failure left the Settings pane looking as if nothing had been
    /// asked for. The two outcomes are now spelled separately, in a named
    /// function this can read.
    @Test func aPickerFailureIsToldApartFromACancellation() throws {
        let literals = try Self.withLiterals(Self.settingsViewPath)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "private func themeImportResult(", in: literals)
        let body = TransferQueueBarCancelGuardTests.slice(range, of: literals)
        #expect(body.contains("case .success(let url)"), """
            themeImportResult in \(Self.settingsViewPath) no longer reads the \
            picked URL.
            """)
        #expect(body.contains("case .failure"), """
            themeImportResult in \(Self.settingsViewPath) does not name the \
            failure case — a real picker failure would be dropped as \
            silently as a cancellation.
            """)
        #expect(body.contains("themeImportRefused = true"), """
            themeImportResult in \(Self.settingsViewPath) does not raise the \
            refusal flag for a failure.
            """)
    }

    /// A refused import shows a FIXED sentence. Positive: the fixed key is
    /// looked up, and the flag the alert reads is a `Bool` rather than a
    /// message. Negative beside it, scoped to the import function's own
    /// body (comments blanked, literals kept — so an interpolated parser
    /// message would be visible): nothing in there names the refusal or
    /// carries an error into text.
    @Test func aRefusedImportShowsAFixedSentenceAndNoParserText() throws {
        let literals = try Self.withLiterals(Self.settingsViewPath)
        #expect(literals.contains("\"settings.terminal.theme.refused\""), """
            \(Self.settingsViewPath) no longer looks up the fixed refusal \
            text — the scan below would be reading a file with nothing to \
            find.
            """)
        #expect(literals.contains("@State private var themeImportRefused = false"), """
            \(Self.settingsViewPath)'s refusal flag is no longer a plain \
            Bool — a message-shaped one could carry a parser's words.
            """)
        #expect(!literals.contains("ITermColorsImport.Refusal"), """
            \(Self.settingsViewPath) names the reader's refusal type — the \
            App has no use for WHICH refusal it was, and naming it is how \
            one starts reaching the screen.
            """)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "private func importTheme(from url: URL)", in: literals)
        let body = TransferQueueBarCancelGuardTests.slice(range, of: literals)
        #expect(body.contains("themeImportRefused = true"), """
            importTheme in \(Self.settingsViewPath) no longer raises the \
            refusal flag at all.
            """)
        // No interpolation at all in that body: it is the one place a
        // parser's words could be turned into text, and it has nothing to
        // interpolate.
        for leak in ["\\(", "localizedDescription"] {
            #expect(!body.contains(leak), """
                importTheme in \(Self.settingsViewPath) contains \(leak) — a \
                refusal must reach the screen as the fixed sentence only.
                """)
        }
    }

    // MARK: - The catalogue

    private static func catalog(_ locale: String) throws -> [String: String] {
        let path = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        return (parsed as? [String: String]) ?? [:]
    }

    /// Every preset's label, every `settings.terminal.theme…` row and the
    /// imported row — in en, de, fr and pl, and resolving at run time
    /// rather than falling back to the English default the call site
    /// carries.
    @Test func everyStringTheThemeSurfacesShowIsInAllFourCatalogues() throws {
        let labelKeys = Set(TerminalThemePreset.allCases.map(TerminalThemeLabel.key(for:)))
        let settingsKeys = TerminalTypeWiringGuardTests.lookedUpKeys(
            in: try Self.withLiterals(Self.settingsViewPath), prefix: "settings.terminal.theme")
        #expect(!settingsKeys.isEmpty, """
            found no settings.terminal.theme… key in \(Self.settingsViewPath)
            """)

        let wanted = labelKeys.union(settingsKeys).union([TerminalThemeLabel.importedKey])
        for locale in Self.catalogLocales {
            let catalog = try Self.catalog(locale)
            let missing = wanted.filter { (catalog[$0] ?? "").isEmpty }.sorted()
            #expect(missing.isEmpty, "\(locale).lproj lacks \(missing)")
        }
        for preset in TerminalThemePreset.allCases {
            #expect(
                L10n.string(TerminalThemeLabel.key(for: preset), "ZZ-UNRESOLVED-ZZ")
                    != "ZZ-UNRESOLVED-ZZ")
        }
        #expect(
            L10n.string(TerminalThemeLabel.importedKey, "ZZ-UNRESOLVED-ZZ")
                != "ZZ-UNRESOLVED-ZZ")
    }

    /// The imported row falls back to a translated word only when the
    /// file's name yielded nothing.
    @Test func theImportedRowPrefersTheFilesOwnName() {
        #expect(TerminalThemeLabel.importedText(name: "Harbour") == "Harbour")
        #expect(TerminalThemeLabel.importedText(name: nil) != "")
        #expect(TerminalThemeLabel.importedText(name: nil) != "ZZ-UNRESOLVED-ZZ")
    }
}
