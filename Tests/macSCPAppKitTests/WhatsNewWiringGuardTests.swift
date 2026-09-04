import Foundation
import Testing

/// Guards the "What's New" wiring (What's New plan, Task 2):
///
/// * **The launch path actually calls the decision, and records it.**
///   `MacSCPApp.swift` must call `WhatsNewModel.releasesToShow(` and must
///   write `lastSeenVersion` — a sheet built without either would silently
///   never decide anything, or decide correctly but never remember it (and
///   so re-show itself every launch).
/// * **The sheet's copy goes through the catalogue, not a literal.** Every
///   one of the three `whatsNew.*` keys must be looked up via
///   `L10n.string(` in `WhatsNewSheet.swift`, and no `Text(` in that same
///   file may take a hardcoded string instead — the two checks sit next to
///   each other on purpose (CLAUDE.md, "a negative check needs a positive
///   beside it"): the negative alone, if the file ever stopped rendering
///   any `Text` at all, would pass having verified nothing.
/// * **The four catalogues agree on the `whatsNew.` keys.** Same shape as
///   `SessionOverviewWiringGuardTests.theOverviewKeysAgreeAcrossAllFourCatalogues`,
///   reused here rather than re-invented: parse each catalogue as a
///   property list and diff the `whatsNew.`-prefixed key sets against
///   English's.
///
/// Known blind spot: source text only. Nothing here confirms the sheet
/// actually appears on screen, that the title formats the running version
/// correctly, or that German/French/Polish read well — `WhatsNewModelTests`
/// pins the decision itself, and `LocalizableStringsTests`/
/// `GermanAddressFormTests` already cover property-list validity and
/// address form for every catalogue, this one included.
@Suite("What's New wiring")
struct WhatsNewWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appFile = repoRoot.appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift")
    private static let sheetFile = repoRoot.appendingPathComponent(
        "Sources/MacSCPAppKit/WhatsNewSheet.swift")
    private static let settingsViewFile = repoRoot.appendingPathComponent(
        "Sources/MacSCPAppKit/SettingsView.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    private static let whatsNewKeys = [
        "\"whatsNew.title\"", "\"whatsNew.close\"", "\"whatsNew.none\"",
    ]

    // MARK: - Source access

    private static func views(of url: URL) throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw), try SwiftSource.blankingComments(raw))
    }

    // MARK: - The launch path

    @Test func theLaunchPathCallsTheDecisionAndRecordsTheVersion() throws {
        let code = try Self.views(of: Self.appFile).code
        #expect(code.contains("WhatsNewModel.releasesToShow("), """
            MacSCPApp.swift no longer calls WhatsNewModel.releasesToShow( — \
            nothing decides what to show any more.
            """)
        #expect(code.contains("lastSeenVersion ="), """
            MacSCPApp.swift no longer writes lastSeenVersion — even a correct \
            decision would re-show the same releases on every launch.
            """)
    }

    // MARK: - The sheet's copy

    @Test func everyWhatsNewKeyIsLookedUpThroughL10n() throws {
        let withLiterals = try Self.views(of: Self.sheetFile).withLiterals
        for key in Self.whatsNewKeys {
            #expect(withLiterals.contains("L10n.string(\(key)"), """
                WhatsNewSheet.swift no longer resolves \(key) through \
                L10n.string( — a translation could no longer reach this text.
                """)
        }
    }

    /// Positive anchor for the negative check below: `WhatsNewSheet.swift`
    /// really does render `Text(` at all, so a `Text`-less rewrite couldn't
    /// make the negative pass by having nothing left to scan.
    @Test func theSheetActuallyRendersText() throws {
        let code = try Self.views(of: Self.sheetFile).code
        #expect(Self.textCallCount(in: code) > 0, """
            WhatsNewSheet.swift no longer contains a Text( call at all — the \
            no-hardcoded-Text check below would then hold vacuously.
            """)
    }

    /// No `Text(` in `WhatsNewSheet.swift` may take a string literal
    /// directly — every user-visible string in that file must arrive
    /// through `L10n.string(`/`L10n.text(` or a value built elsewhere (the
    /// changelog's own version/date/section/entry text, which Global
    /// Constraints requires shown as is and which is never a localizable
    /// UI string to begin with). Read on the comments-blanked, LITERALS-KEPT
    /// view — the check is about a literal, so blanking it would delete the
    /// very thing being scanned.
    @Test func noTextCallTakesAHardcodedLiteral() throws {
        let withLiterals = try Self.views(of: Self.sheetFile).withLiterals
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            WhatsNewSheet.swift has a Text( call whose first argument is a \
            string literal instead of going through L10n.
            """)
    }

    /// `Text(` immediately followed (ignoring whitespace, and an optional
    /// `verbatim:` label) by a `"` — a literal passed straight in, either
    /// as `Text("…")` or as `Text(verbatim: "…")` (round 1 review: the
    /// original pattern named only the first form, so a hardcoded
    /// `Text(verbatim:` literal went unseen — `verbatim:` is not a
    /// localization call, it deliberately skips one). `Text(L10n.string
    /// (...))`, `Text(String(format: L10n.string(...), …))` and
    /// `Text(someHelper(value))` all have a non-`"` character right after
    /// the `(` (or after `verbatim:`), so none of them count.
    private static func hardcodedTextCallCount(in source: String) -> Int {
        Self.textLiteralRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)).count
    }

    private static func textCallCount(in source: String) -> Int {
        TransferQueueBarCancelGuardTests.occurrenceCount(of: "Text(", in: source)
    }

    private static let textLiteralRegex = try! NSRegularExpression(
        pattern: #"Text\(\s*(?:verbatim:\s*)?""#)

    // MARK: - The Settings pane's copy (round 1 review: same check, wider scope)

    /// The Settings sidebar's own "What's new" pane (`WhatsNewSettingsSection`
    /// in `SettingsView.swift`, What's New plan Task 3) renders the same
    /// changelog text as the launch sheet and carries the same risk — a
    /// `Text(` call bypassing `L10n.string(` — so this scan extends here
    /// rather than staying sheet-only. Same span-extraction shape
    /// `SettingsSectionCatalogGuardTests` uses for the same type: the
    /// declaration's brace-balanced body, via
    /// `TransferQueueBarCancelGuardTests.declarationBodyRange(of:in:)`.
    private static func settingsPaneSection() throws -> (code: String, withLiterals: String) {
        let all = try views(of: Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "private struct WhatsNewSettingsSection: View", in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    /// Positive anchor for the negative below (CLAUDE.md, "a negative check
    /// needs a positive beside it"): the pane really does call
    /// L10n.string( at least once (its "No changelog shipped with this
    /// build." message), so a rewrite that renders no localized text at
    /// all could not make the negative pass by having nothing left to scan.
    @Test func theSettingsPaneCallsL10nStringAtLeastOnce() throws {
        let code = try Self.settingsPaneSection().code
        #expect(code.contains("L10n.string("), """
            WhatsNewSettingsSection no longer calls L10n.string( anywhere \
            in its declaration — the no-hardcoded-Text check below would \
            then hold vacuously.
            """)
    }

    @Test func noTextCallInTheSettingsPaneTakesAHardcodedLiteral() throws {
        let withLiterals = try Self.settingsPaneSection().withLiterals
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            WhatsNewSettingsSection has a Text( call whose first argument \
            is a string literal instead of going through L10n.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The check names `Text(` specifically, so a hardcoded label on a
    /// DIFFERENT control — `Button`, in the real file's Close button — must
    /// not be reported by this check at all (it has nothing to say about
    /// it; a `Button`-label guard would be a separate check).
    @Test func scannerIgnoresAHardcodedLabelOnAControlThatIsNotText() throws {
        let source = """
            struct WhatsNewSheet: View {
                var body: some View {
                    Button("Close") { onClose() }
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            the scanner must not report a hardcoded Button( label as a \
            hardcoded Text( — the two are different checks
            """)
    }

    @Test func scannerCatchesAHardcodedNoneMessage() throws {
        let source = """
            struct WhatsNewSheet: View {
                var body: some View {
                    Text("No changelog shipped with this build.")
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 1, """
            the scanner failed to catch a Text( call given a literal string \
            directly
            """)
    }

    /// Round 1 review: the original pattern named only `Text("…")`, so a
    /// hardcoded `Text(verbatim: "…")` — a form that deliberately skips
    /// localization — went unseen. This is the regression test for the
    /// widened pattern.
    @Test func scannerCatchesAHardcodedVerbatimText() throws {
        let source = """
            struct WhatsNewSheet: View {
                var body: some View {
                    Text(verbatim: "No changelog shipped with this build.")
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 1, """
            the scanner failed to catch a Text(verbatim:) call given a \
            literal string directly
            """)
    }

    @Test func scannerAcceptsTextWrappingL10nOrAHelper() throws {
        let source = """
            struct WhatsNewSheet: View {
                var body: some View {
                    Text(L10n.string("whatsNew.none", "No changelog shipped with this build."))
                    Text(entryText(entry))
                    Text(String(format: L10n.string("whatsNew.title", "What's new in %@"), currentVersion))
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            the scanner must not flag Text( calls whose argument is \
            L10n.string(…)/L10n.text(…) or a helper call, only a literal \
            passed directly
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

    @Test func theWhatsNewKeysAgreeAcrossAllFourCatalogues() throws {
        let english = try Self.catalogKeys("en").filter { $0.hasPrefix("whatsNew.") }
        #expect(english == ["whatsNew.title", "whatsNew.close", "whatsNew.none"], """
            en.lproj's whatsNew. keys are not exactly the three this feature \
            defines — recount before changing this list.
            """)
        for locale in Self.catalogLocales where locale != "en" {
            let keys = try Self.catalogKeys(locale).filter { $0.hasPrefix("whatsNew.") }
            #expect(keys == english, """
                \(Self.catalogPath(locale))'s whatsNew. keys differ from en.lproj's.
                missing here: \(english.subtracting(keys).sorted())
                extra here: \(keys.subtracting(english).sorted())
                """)
        }
    }
}
