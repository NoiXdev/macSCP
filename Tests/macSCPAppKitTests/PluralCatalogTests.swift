import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards the two `%lld`-count messages that read as "1 snippets"/"1 logins"
/// without real plural support: `snippets.export.confirm.message %lld` and
/// `logins.export.summary %lld`. Both are backed by a `Localizable.stringsdict`
/// per language (alongside the existing `Localizable.strings`, which still
/// carries the same keys — see the suite doc comment on `catalogKeys()`
/// below for why both must exist).
///
/// Measured before writing this suite (not assumed):
/// - `L10n.string` wraps `NSLocalizedString(key:bundle:value:comment:)`,
///   which DOES resolve a `.stringsdict` entry ahead of a same-keyed
///   `.strings` entry, returning the `%#@count@` format placeholder; a
///   following `String(format:)` call then substitutes the correct plural
///   variant. Verified with a throwaway bundle (deliberately conflicting
///   `.strings`/`.stringsdict` values, `.strings` version never appeared in
///   the output) and confirmed again here in `resolvesThroughTheProductionLookupPath`.
/// - SwiftPM's `.process("Resources")` declaration on `MacSCPAppKit` (see
///   `Package.swift`) copies a `.stringsdict` sitting in `<lang>.lproj`
///   into the built resource bundle exactly like `.strings` — confirmed by
///   inspecting the built `macSCP_MacSCPAppKit.bundle` after `swift build`.
/// - Plain `String(format:)` (no explicit `Locale`, matching the call sites
///   in `SnippetsSheet.swift`/`SessionExportImportSheets.swift`) selects the
///   plural category using the CURRENT PROCESS locale, not the language of
///   the `.lproj` the format string came from. A specific language's
///   category rules (Polish `few`/`many`, French treating 0 like 1) are
///   therefore only exercised correctly here by pairing an explicitly
///   loaded per-language bundle with an explicit `Locale(identifier:)` in
///   `String(format:locale:)` — that combination does correctly reproduce
///   each language's CLDR plural rule, independent of the test machine's
///   own system locale (verified against `de_DE`, `pl_PL`, `fr_FR`).
@Suite("Plural catalogs")
struct PluralCatalogTests {
    private static let languages = ["en", "de", "fr", "pl"]

    private static func catalogKeys() -> [(key: String, defaultValue: String)] {
        [
            ("snippets.export.confirm.message %lld", "%lld snippets will be written to the file."),
            ("logins.export.summary %lld", "%lld logins will be written to the file."),
            (
                "tabs.closeOthers.incomingTransfers %lld",
                "%lld of them are receiving transfers from other tabs; closing cancels those."
            ),
        ]
    }

    /// `tabs.closeOthers.activeTransfers %1$lld %2$lld` (Task 3's bulk-close
    /// warning) carries a SECOND, non-pluralized `%2$lld` argument
    /// (`transferring`) alongside the pluralized `%1$lld` (`tabsClosing`),
    /// so it doesn't fit `catalogKeys()`'s single-`count` shape and gets its
    /// own helpers/tests below rather than folding into the generic ones.
    /// The `.stringsdict` ties plural selection to argument 1 only
    /// (`NSStringLocalizedFormatKey` = `%1$#@tabs@`, variable name `tabs`
    /// not `count`) — `transferring` never changes the noun's category.
    private static let activeTransfersKey = "tabs.closeOthers.activeTransfers %1$lld %2$lld"
    private static let activeTransfersDefault =
        "Closing %1$lld tabs cancels active transfers in %2$lld of them."

    /// Loads the `.lproj` bundle for one language directly (rather than
    /// letting `NSLocalizedString` negotiate a language from the process's
    /// own preferences), so each language's catalog content can be targeted
    /// on its own regardless of the machine `swift test` runs on.
    private static func bundle(forLanguage language: String) -> Bundle? {
        guard let lprojPath = L10n.bundle.path(forResource: language, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: lprojPath)
    }

    /// Resolves one plural form the same way the app does — `NSLocalizedString`
    /// through the App layer's own `bundle`/`value`/`comment` shape — except
    /// with an explicit per-language `Locale` passed to `String(format:)` so
    /// the CLDR plural category matches `language` instead of the process's
    /// ambient locale.
    private static func resolvedForm(
        key: String, defaultValue: String, language: String, count: Int
    ) -> String? {
        guard let languageBundle = bundle(forLanguage: language) else { return nil }
        let format = NSLocalizedString(key, bundle: languageBundle, value: defaultValue, comment: "")
        return String(format: format, locale: Locale(identifier: language), count)
    }

    /// Same resolution path as `resolvedForm`, for `activeTransfersKey`'s
    /// two arguments. `transferring` is passed through untouched — only
    /// `tabsClosing` (argument 1) selects the plural category.
    private static func resolvedActiveTransfersForm(
        language: String, tabsClosing: Int, transferring: Int
    ) -> String? {
        guard let languageBundle = bundle(forLanguage: language) else { return nil }
        let format = NSLocalizedString(
            Self.activeTransfersKey, bundle: languageBundle, value: Self.activeTransfersDefault, comment: "")
        return String(format: format, locale: Locale(identifier: language), tabsClosing, transferring)
    }

    /// Every resolved form embeds the count itself (`"1 snippet…"` vs.
    /// `"2 snippets…"`), so comparing the raw strings for two different
    /// counts would trivially differ even with NO plural support at all —
    /// the digits alone differ. Stripping digits isolates the wording
    /// around the number, which is the part that must actually change
    /// between plural categories.
    private static func wordingIgnoringDigits(_ text: String?) -> String? {
        text.map { $0.filter { !$0.isNumber } }
    }

    @Test(arguments: PluralCatalogTests.languages)
    func everyLanguageDistinguishesOneFromTwoForBothKeys(language: String) {
        for entry in Self.catalogKeys() {
            let one = Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: language, count: 1)
            let two = Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: language, count: 2)
            #expect(one != nil, "\(language) is missing its .lproj bundle")
            #expect(
                Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
                "\(language) resolved the same wording for 1 and 2 on \(entry.key): \(one ?? "nil")")
        }
    }

    /// Polish has a third category (`many`, roughly 5+) distinct from both
    /// `one` (1) and `few` (2-4) — a two-way `one`/`other` split, which is
    /// all the other three languages need, would be wrong here.
    @Test
    func polishSelectsTheThirdCategoryForFive() {
        for entry in Self.catalogKeys() {
            let one = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 1))
            let few = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 2))
            let many = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 5))
            #expect(one != few && few != many && one != many, "\(entry.key): 1=\(one ?? "nil") 2=\(few ?? "nil") 5=\(many ?? "nil")")
        }
    }

    /// French treats a count of 0 like 1 (its `one` category covers both),
    /// unlike English/German where 0 takes the plural form.
    @Test
    func frenchTreatsZeroLikeOne() {
        for entry in Self.catalogKeys() {
            let zero = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 0))
            let one = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 1))
            let two = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 2))
            #expect(zero == one, "\(entry.key): 0 should read like 1 in French, got 0=\(zero ?? "nil") 1=\(one ?? "nil")")
            #expect(one != two, "\(entry.key): 1 and 2 should differ in French")
        }
    }

    /// The production call sites (`SnippetsSheet.swift`,
    /// `SessionExportImportSheets.swift`) use `L10n.string` and plain
    /// `String(format:)` with no explicit bundle or locale override — this
    /// exercises that exact path end to end, proving the `.stringsdict`
    /// entry is reachable through it rather than only through the
    /// per-language bundle helper above.
    @Test
    func resolvesThroughTheProductionLookupPath() {
        for entry in Self.catalogKeys() {
            let format = L10n.string(entry.key, entry.defaultValue)
            let one = String(format: format, 1)
            let two = String(format: format, 2)
            #expect(
                Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
                "\(entry.key) did not distinguish 1 from 2 through L10n.string + String(format:): \(one)")
        }
    }

    /// Structural backstop asked for by the task brief: each `.stringsdict`
    /// must declare `NSStringPluralRuleType`, and Polish's `count` rule must
    /// carry `one`/`few`/`many` (not just `one`/`other`).
    @Test(arguments: PluralCatalogTests.languages)
    func stringsdictDeclaresThePluralRuleType(language: String) {
        guard let languageBundle = Self.bundle(forLanguage: language),
            let url = languageBundle.url(forResource: "Localizable", withExtension: "stringsdict"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            Issue.record("\(language) is missing a parseable Localizable.stringsdict")
            return
        }
        for entry in Self.catalogKeys() {
            guard let rule = plist[entry.key] as? [String: Any],
                let countRule = rule["count"] as? [String: Any]
            else {
                Issue.record("\(language) stringsdict is missing a count rule for \(entry.key)")
                continue
            }
            #expect(countRule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
            if language == "pl" {
                #expect(countRule["one"] != nil && countRule["few"] != nil && countRule["many"] != nil)
            } else {
                #expect(countRule["one"] != nil && countRule["other"] != nil)
            }
        }
    }

    // MARK: - `tabs.closeOthers.activeTransfers %1$lld %2$lld` (two-argument key)
    //
    // Same five properties as above, adapted for a plural variable driven by
    // argument 1 (`tabsClosing`) while argument 2 (`transferring`) rides
    // along unpluralized — `catalogKeys()`'s single-`count` helpers can't
    // exercise that, so these are separate rather than folded in.

    @Test(arguments: PluralCatalogTests.languages)
    func everyLanguageDistinguishesOneFromTwoForActiveTransfers(language: String) {
        let one = Self.resolvedActiveTransfersForm(language: language, tabsClosing: 1, transferring: 1)
        let two = Self.resolvedActiveTransfersForm(language: language, tabsClosing: 2, transferring: 1)
        #expect(one != nil, "\(language) is missing its .lproj bundle")
        #expect(
            Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
            "\(language) resolved the same wording for 1 and 2 tabs closing: \(one ?? "nil")")
    }

    @Test
    func polishSelectsTheThirdCategoryForFiveTabsClosing() {
        let one = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 1, transferring: 1))
        let few = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 2, transferring: 1))
        let many = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 5, transferring: 1))
        #expect(one != few && few != many && one != many, "1=\(one ?? "nil") 2=\(few ?? "nil") 5=\(many ?? "nil")")
    }

    @Test
    func frenchTreatsZeroTabsClosingLikeOne() {
        let zero = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 0, transferring: 0))
        let one = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 1, transferring: 0))
        let two = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 2, transferring: 0))
        #expect(zero == one, "0 should read like 1 in French, got 0=\(zero ?? "nil") 1=\(one ?? "nil")")
        #expect(one != two, "1 and 2 should differ in French")
    }

    @Test
    func activeTransfersResolvesThroughTheProductionLookupPath() {
        let format = L10n.string(Self.activeTransfersKey, Self.activeTransfersDefault)
        let one = String(format: format, 1, 3)
        let two = String(format: format, 2, 3)
        #expect(
            Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
            "did not distinguish 1 from 2 tabs closing through L10n.string + String(format:): \(one)")
    }

    /// Same structural backstop as `stringsdictDeclaresThePluralRuleType`,
    /// but for the `tabs` variable (not `count`) that
    /// `tabs.closeOthers.activeTransfers %1$lld %2$lld` uses.
    @Test(arguments: PluralCatalogTests.languages)
    func stringsdictDeclaresThePluralRuleTypeForActiveTransfers(language: String) {
        guard let languageBundle = Self.bundle(forLanguage: language),
            let url = languageBundle.url(forResource: "Localizable", withExtension: "stringsdict"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let rule = plist[Self.activeTransfersKey] as? [String: Any],
            let tabsRule = rule["tabs"] as? [String: Any]
        else {
            Issue.record("\(language) stringsdict is missing a tabs rule for \(Self.activeTransfersKey)")
            return
        }
        #expect(tabsRule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
        if language == "pl" {
            #expect(tabsRule["one"] != nil && tabsRule["few"] != nil && tabsRule["many"] != nil)
        } else {
            #expect(tabsRule["one"] != nil && tabsRule["other"] != nil)
        }
    }
}
