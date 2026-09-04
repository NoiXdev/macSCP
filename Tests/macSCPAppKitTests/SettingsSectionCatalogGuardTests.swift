import Foundation
import Testing

/// Guards `SettingsSection`'s sidebar titles (`SettingsView.swift`,
/// What's New plan Task 3): every `title` arm resolves through
/// `L10n.string(`, and every `settings.tab.` key it names exists in all
/// four catalogues — the same "pin a pane case to a catalogue key" property
/// the coordinator asked this task to extend. The search the coordinator
/// pointed at (`grep -rln "settings.tab" Tests/macSCPAppKitTests`) turns up
/// only `KeyboardShortcutsCatalogTests.swift`, which guards the read-only
/// shortcuts TABLE, not the sidebar's own titles — there was no prior guard
/// of this shape to extend, so this file is new rather than an edit to that
/// one.
///
/// Swift's exhaustive `switch self { case .general: … }` (no `default:`)
/// already forces every `SettingsSection` case to carry a `title` arm at
/// COMPILE time — a case added without one does not build, so this guard
/// has nothing to add there. What compilation cannot catch: a `title` arm
/// that returns a hardcoded literal instead of going through
/// `L10n.string(` (invisible to every translation), or one whose key never
/// made it into en/de/fr/pl (a silent fallback to the English default text
/// in the other three languages).
///
/// Same shared scanner as `SettingsViewAppearanceToggleGuardTests` /
/// `SettingsViewTransfersToggleGuardTests`
/// (`TransferQueueBarCancelGuardTests.declarationBodyRange(of:in:)` /
/// `.declarationBody(of:in:)` / `.occurrenceCount(of:in:)`), reused rather
/// than copied. The catalogue-parity check is the same shape as
/// `WhatsNewWiringGuardTests.theWhatsNewKeysAgreeAcrossAllFourCatalogues`
/// (parse each catalogue as a property list, diff the prefixed key sets
/// against English's) — reused as a pattern, not as shared code, since that
/// helper is `private` to its own suite.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view — nothing
/// here confirms a title actually appears on screen, or that the German
/// text is any good (`GermanAddressFormTests` covers the du-form rule for
/// every catalogue, this key included).
@Suite("SettingsSection catalogue")
struct SettingsSectionCatalogGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    /// No trailing `{`, matching `SettingsViewAppearanceToggleGuardTests`'s
    /// convention: `declarationBodyRange` opens its span at the first `{`
    /// found after this text, which is `title`'s own opening brace since
    /// the real file writes `var title: String {` on one line.
    private static let titleDeclaration = "var title: String"

    // MARK: - Source access

    private static func views() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: settingsViewFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func titleBodies() throws -> (code: String, withLiterals: String) {
        let all = try views()
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.titleDeclaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    // MARK: - Every case arm goes through L10n.string(

    /// One `L10n.string(` call per `case .` arm inside `title`'s switch —
    /// equal counts is what rules out a `case` that returns a bare literal
    /// instead (that arm would still satisfy the exhaustive switch, so the
    /// compiler says nothing about it).
    @Test func everyTitleCaseArmResolvesThroughL10nStringExactlyOnce() throws {
        let body = try Self.titleBodies().code
        let cases = TransferQueueBarCancelGuardTests.occurrenceCount(of: "case .", in: body)
        let lookups = TransferQueueBarCancelGuardTests.occurrenceCount(of: "L10n.string(", in: body)
        #expect(cases > 0, """
            found no "case ." arm inside SettingsSection.title's switch — \
            the scanner is reading the wrong span.
            """)
        #expect(cases == lookups, """
            SettingsSection.title has \(cases) case arm(s) but only \
            \(lookups) L10n.string( call(s) — some case returns a title \
            that no translation can reach.
            """)
    }

    /// Positive anchor for the check above: the strict view must actually
    /// contain `title`'s own declaration, or an unreadable/empty read would
    /// make the equality above pass by counting zero and zero.
    @Test func theStrictViewStillContainsTheTitleProperty() throws {
        let code = try Self.views().code
        #expect(code.contains("var title: String"), """
            the strict view of SettingsView.swift no longer contains \
            SettingsSection's title property — the path or the stripper is \
            wrong, and the checks above are reading nothing.
            """)
    }

    /// `SettingsSection.whatsNew` (What's New plan, Task 3) must exist and
    /// resolve its title through the `settings.tab.whatsNew` catalogue key
    /// specifically — the count-equality check above would also pass if a
    /// DIFFERENT case were missing its lookup, so this pins the one this
    /// task actually adds.
    @Test func theWhatsNewCaseResolvesThroughItsOwnCatalogueKey() throws {
        let withLiterals = try Self.titleBodies().withLiterals
        #expect(withLiterals.contains("case .whatsNew:"), """
            SettingsSection.title has no `case .whatsNew:` arm — the "What's \
            new" pane case is missing from the sidebar's title switch.
            """)
        #expect(withLiterals.contains("L10n.string(\"settings.tab.whatsNew\""), """
            case .whatsNew must resolve its title through \
            L10n.string("settings.tab.whatsNew", …) — a hardcoded literal \
            here is invisible to every translation.
            """)
    }

    // MARK: - The catalogue

    private static func catalogKeys(_ locale: String) throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(Self.catalogPath(locale)))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let entries = parsed as? [String: String] else {
            throw CatalogError.unreadable(Self.catalogPath(locale))
        }
        return Set(entries.keys)
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let path): return "\(path) does not parse as a strings table"
            }
        }
    }

    /// Every `settings.tab.` key — general/transfers/openWith/terminal/
    /// shortcuts/whatsNew today — must exist in all four catalogues. Not
    /// hardcoded as an exact list (unlike `WhatsNewWiringGuardTests`'s three
    /// fixed keys): this guard is meant to keep holding as more panes are
    /// added, so English is the reference the other three are diffed
    /// against rather than a second copy of the same names.
    @Test func theSettingsTabKeysAgreeAcrossAllFourCatalogues() throws {
        let english = try Self.catalogKeys("en").filter { $0.hasPrefix("settings.tab.") }
        #expect(english.contains("settings.tab.whatsNew"), """
            en.lproj carries no settings.tab.whatsNew key yet.
            """)
        for locale in Self.catalogLocales where locale != "en" {
            let keys = try Self.catalogKeys(locale).filter { $0.hasPrefix("settings.tab.") }
            #expect(keys == english, """
                \(Self.catalogPath(locale))'s settings.tab. keys differ from en.lproj's.
                missing here: \(english.subtracting(keys).sorted())
                extra here: \(keys.subtracting(english).sorted())
                """)
        }
    }

    // MARK: - The pane body reuses WhatsNewList

    /// `WhatsNewSettingsSection` (the `case .whatsNew` pane body) must
    /// actually construct `WhatsNewList(` — a positive anchor that the pane
    /// reuses Task 2's list view rather than re-rendering the changelog by
    /// hand.
    @Test func thePaneBodyCallsWhatsNewList() throws {
        let code = try Self.views().code
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "private struct WhatsNewSettingsSection: View", in: code)
        let body = TransferQueueBarCancelGuardTests.slice(range, of: code)
        #expect(body.contains("WhatsNewList("), """
            WhatsNewSettingsSection's body no longer calls WhatsNewList( — \
            the Settings pane must reuse Task 2's reusable list view, not \
            render the changelog itself.
            """)
    }

    /// The detail switch must actually route `.whatsNew` to that struct —
    /// the body check above says nothing if nothing ever selects it.
    @Test func theDetailSwitchRoutesWhatsNewToItsSection() throws {
        let code = try Self.views().code
        #expect(code.contains("case .whatsNew:"), """
            SettingsView.body's detail switch has no `case .whatsNew:` arm.
            """)
        #expect(code.contains("WhatsNewSettingsSection()"), """
            no code constructs WhatsNewSettingsSection() — the detail \
            switch's case .whatsNew must build it.
            """)
    }

    // MARK: - The changelog is parsed once, not on every body evaluation

    /// Fix round 1: `releases` used to be a COMPUTED property, so `body`
    /// (which reads it twice — once for `releases.isEmpty`, once for
    /// `WhatsNewList(releases:)`) ran `ChangelogResource.load()` +
    /// `ChangelogParser.parse(` + `releases(newerThan:)` over the real
    /// changelog file on every evaluation, and `SettingsStore` being
    /// `@Observable` meant any tracked mutation while the pane was visible
    /// re-triggered both. The fix stores the parsed result in `@State` and
    /// loads it once, from a lifecycle callback (`.task`/`.onAppear`), not
    /// from `body`'s own evaluation.
    ///
    /// Positive first (CLAUDE.md, "a negative check needs a positive
    /// beside it"): the type still owns an `@State` property and still
    /// calls the load functions SOMEWHERE (proven over the whole struct,
    /// not `body` alone), and `body` really does carry a `.task`/
    /// `.onAppear` that could run them — so the negative below isn't
    /// satisfied by a body that lost the load entirely, only by one that
    /// stopped deferring it.
    @Test func theSectionDefersTheChangelogLoadToALifecycleCallback() throws {
        let code = try Self.views().code
        let sectionRange = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "private struct WhatsNewSettingsSection: View", in: code)
        let sectionBody = TransferQueueBarCancelGuardTests.slice(sectionRange, of: code)

        #expect(sectionBody.contains("@State"), """
            WhatsNewSettingsSection no longer declares an @State property \
            — a computed property parses the changelog on every body \
            evaluation instead of once.
            """)
        #expect(
            sectionBody.contains("ChangelogResource.load(")
                && sectionBody.contains("ChangelogParser.parse("),
            """
            WhatsNewSettingsSection no longer calls ChangelogResource.load( \
            and ChangelogParser.parse( anywhere in the type — the load \
            itself is gone.
            """)

        let bodyRange = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "var body: some View", in: sectionBody)
        let bodyText = TransferQueueBarCancelGuardTests.slice(bodyRange, of: sectionBody)

        #expect(bodyText.contains(".task") || bodyText.contains(".onAppear"), """
            WhatsNewSettingsSection.body carries neither .task nor \
            .onAppear — nothing defers the changelog load to run once per \
            appearance rather than on every body evaluation.
            """)

        // The negative: body's OWN span must not call the parse/load
        // functions directly, or every body evaluation — including one
        // triggered by an unrelated SettingsStore mutation, since it is
        // @Observable — would re-parse the real ~720-line changelog file.
        #expect(!bodyText.contains("ChangelogParser.parse("), """
            WhatsNewSettingsSection.body calls ChangelogParser.parse( \
            directly — every body evaluation re-parses the changelog \
            instead of loading it once into @State.
            """)
        #expect(!bodyText.contains("ChangelogResource.load("), """
            WhatsNewSettingsSection.body calls ChangelogResource.load( \
            directly — every body evaluation re-reads the bundled file \
            instead of loading it once into @State.
            """)
    }
}
