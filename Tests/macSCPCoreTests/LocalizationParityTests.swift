import Foundation
import Testing

/// Where the string catalogs are, and what format each one is in — found,
/// never listed.
///
/// Two of the three localization suites in this target
/// (`LocalizationParityTests` here and `GermanAddressFormTests`) used to
/// name the catalog directories while deriving the LOCALES inside each one
/// from the directory itself. That is half a derivation, and the half that
/// was missing is the one that fails silently: a third localized target
/// would have been read by nothing, and both suites would have gone on
/// reporting success over the two they knew about. A check that verifies
/// less than it believes is worse than none, because it reports success.
///
/// The third suite, `LocalizableStringsTests`, still names both the
/// locations and the locales — four literal paths and two literal locale
/// lists. It is deliberately left alone (it guards a different property:
/// that each file parses as a property list at all), and it is named here
/// so that this comment is not read as a claim that the target is done.
/// Add a third localized target and the two suites below cover it while
/// that one goes on reporting success over the two paths it lists.
///
/// The locations are derived twice, after
/// `ReconnectWiringGuardTests.everySourceDirectoryIsScannedOrExplicitlyExcluded`:
/// from what is on disk under `Sources/`, and from what `Package.swift`
/// declares — because a target's sources need not live under `Sources/` at
/// all. Test targets are left out: a `.lproj` under `Tests/` would be a
/// fixture, and a fixture is meant to be allowed to be wrong.
///
/// ## Two formats, because the project prescribes the one it does not use
///
/// A catalog location is a directory holding either a `.lproj`
/// subdirectory or a String Catalog (`*.xcstrings`) — and the second half
/// of that sentence is the one that was missing. `CLAUDE.md` prescribes
/// String Catalogs for user-facing strings; the tree has none today (every
/// catalog is `.lproj/Localizable.strings`), and a derivation that looked
/// only for `.lproj` therefore looked past the exact format the next
/// surface is supposed to arrive in. Planted one, and all eleven tests
/// across the two suites stayed green over a catalog with a missing German
/// key and a polite-form German value in it.
///
/// `excludedDirectories` is the one list that remains, and it is an escape
/// hatch rather than an enumeration: a catalog that must NOT be held to
/// parity is named there WITH a reason, and `theScanReachesEveryCatalog`
/// fails when a name on it no longer exists — so the hatch cannot rot into
/// a claim about files that are gone.
enum LocalizationCatalogs {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/LocalizationParityTests.swift`.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    struct ExcludedDirectory {
        let path: String
        let reason: String
    }

    /// Empty, and that is a statement rather than an omission: every
    /// catalog in the package is held to parity today. An entry here says
    /// that one set of translations is deliberately allowed to differ from
    /// its English original, which is a decision — so it carries the reason
    /// that makes it one.
    static let excludedDirectories: [ExcludedDirectory] = []

    private static var fileManager: FileManager { .default }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func url(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    /// A directory URL's path carries a trailing slash, and `repoRoot` is
    /// itself built by walking `#filePath` up — so both ends of this
    /// subtraction need the same spelling before either can be a prefix of
    /// the other.
    private static func absolutePath(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func relativePath(of url: URL) -> String {
        let root = absolutePath(of: repoRoot)
        let path = absolutePath(of: url)
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The shipped-target directories `Package.swift` declares, read per
    /// declaration so that a `path:` belonging to a TEST target cannot
    /// become one. A target may say where its sources live, and that
    /// directory is as much a target directory as `Sources/<name>` is.
    ///
    /// Separate from `targetDirectories()` so that
    /// `theScanReachesEveryCatalog` can pin this half on its own: the disk
    /// half alone already clears every floor there, so a manifest regex
    /// that stopped matching is precisely the condition those floors
    /// cannot report.
    static func manifestTargetDirectories() throws -> [String] {
        let manifest = try String(contentsOf: url("Package.swift"), encoding: .utf8)
        var directories: [String] = []
        for marker in [".executableTarget(", ".target("] {
            for declaration in manifest.components(separatedBy: marker).dropFirst() {
                let body = declaration
                    .components(separatedBy: ".executableTarget(")[0]
                    .components(separatedBy: ".testTarget(")[0]
                    .components(separatedBy: ".target(")[0]
                guard let name = try captures(#"name:\s*"([^"]+)""#, in: body).first
                else { continue }
                if let path = try captures(#"path:\s*"([^"]+)""#, in: body).first {
                    directories.append(path)
                } else {
                    directories.append("Sources/\(name)")
                }
            }
        }
        return directories
    }

    /// Every directory the package builds a shipped target out of, from
    /// disk and from the manifest both. A name from either derivation that
    /// is not a directory is dropped — the manifest may declare a target
    /// whose sources are somewhere this walk has no business following.
    static func targetDirectories() throws -> [String] {
        var candidates: Set<String> = []

        let sources = url("Sources")
        for entry in try fileManager.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: [.isDirectoryKey]) where isDirectory(entry)
        {
            candidates.insert("Sources/\(entry.lastPathComponent)")
        }

        for directory in try manifestTargetDirectories() { candidates.insert(directory) }

        return candidates.filter { isDirectory(url($0)) }.sorted()
    }

    /// The file extension of a String Catalog. Named once, here, because
    /// three lookups below have to agree on it.
    static let stringCatalogExtension = "xcstrings"

    /// Every directory under a shipped target that holds a catalog in
    /// either format — a `.lproj` subdirectory or a `*.xcstrings` file —
    /// the deliberately excluded ones included.
    static func allDirectories() throws -> [String] {
        var found: Set<String> = []
        for target in try targetDirectories() {
            guard let walk = fileManager.enumerator(
                at: url(target), includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for case let candidate as URL in walk {
                if candidate.pathExtension == "lproj", isDirectory(candidate) {
                    found.insert(relativePath(of: candidate.deletingLastPathComponent()))
                }
                if candidate.pathExtension == stringCatalogExtension, !isDirectory(candidate) {
                    found.insert(relativePath(of: candidate.deletingLastPathComponent()))
                }
            }
        }
        return found.sorted()
    }

    /// The catalog directories a check is meant to read.
    static func directories() throws -> [String] {
        let excluded = Set(excludedDirectories.map(\.path))
        return try allDirectories().filter { !excluded.contains($0) }
    }

    /// The `*.xcstrings` files sitting directly in a catalog directory.
    static func stringCatalogFiles(in directory: String) throws -> [String] {
        try fileManager.contentsOfDirectory(
            atPath: url(directory).path(percentEncoded: false))
            .filter { $0.hasSuffix(".\(stringCatalogExtension)") }
            .map { "\(directory)/\($0)" }
            .sorted()
    }

    /// Every locale a catalog directory actually contains: one per
    /// `.lproj`, plus every language a String Catalog in it declares —
    /// its `sourceLanguage` and every locale any of its keys is localized
    /// into.
    static func locales(in directory: String) throws -> [String] {
        let contents = try fileManager.contentsOfDirectory(
            atPath: url(directory).path(percentEncoded: false))
        var locales = Set(
            contents
                .filter { $0.hasSuffix(".lproj") }
                .map { String($0.dropLast(".lproj".count)) })
        for file in try stringCatalogFiles(in: directory) {
            let catalog = try StringCatalog(contentsOf: url(file))
            locales.insert(catalog.sourceLanguage)
            locales.formUnion(catalog.locales)
        }
        return locales.sorted()
    }

    /// Every catalog FILE that carries one locale, wherever a catalog
    /// directory has one — a `.lproj/Localizable.strings` and every
    /// `*.xcstrings` that declares the locale. A directory that lacks the
    /// locale contributes nothing rather than being reported here: which
    /// locales a catalog owes is the caller's property, not this lookup's.
    ///
    /// One directory can contribute more than one file, so this is not a
    /// per-directory list — see `directoriesHolding(locale:)` for that.
    static func catalogs(forLocale locale: String) throws -> [String] {
        try directories().flatMap { try files(in: $0, forLocale: locale) }
    }

    static func files(in directory: String, forLocale locale: String) throws -> [String] {
        var found: [String] = []
        let strings = "\(directory)/\(locale).lproj/Localizable.strings"
        if fileManager.fileExists(atPath: url(strings).path(percentEncoded: false)) {
            found.append(strings)
        }
        for file in try stringCatalogFiles(in: directory) {
            let catalog = try StringCatalog(contentsOf: url(file))
            if catalog.sourceLanguage == locale || catalog.locales.contains(locale) {
                found.append(file)
            }
        }
        return found
    }

    /// The catalog directories that carry a locale at all, whatever the
    /// format and however many files it took.
    static func directoriesHolding(locale: String) throws -> [String] {
        try directories().filter { try !files(in: $0, forLocale: locale).isEmpty }
    }

    /// The strings one catalog file holds for one locale, keyed as the
    /// runtime keys them. Both formats, so no caller has to know which one
    /// it was handed.
    ///
    /// `pluralized` names the keys whose value here is not one string but
    /// several joined — a String Catalog's plural or device variations.
    /// They are readable (a scan for register or for an empty value still
    /// works) but they are NOT comparable across locales by format
    /// specifier: German has two plural categories where Polish has four,
    /// and a check that counted `%lld`s across them would fail on a
    /// correct translation.
    struct CatalogFile {
        let relativePath: String
        let entries: [String: String]
        /// Keys in file order, duplicates included — see
        /// `LocalizationParityTests.parse`.
        let declaredKeys: [String]
        let pluralized: Set<String>
    }

    static func read(_ relativePath: String, locale: String) throws -> CatalogFile {
        let fileURL = url(relativePath)
        guard fileURL.pathExtension == stringCatalogExtension else {
            return CatalogFile(
                relativePath: relativePath,
                entries: try propertyListEntries(at: fileURL, relativePath: relativePath),
                declaredKeys: try declaredKeys(at: fileURL),
                pluralized: [])
        }
        let catalog = try StringCatalog(contentsOf: fileURL)
        let read = catalog.entries(forLocale: locale)
        return CatalogFile(
            relativePath: relativePath,
            entries: read.entries,
            declaredKeys: catalog.keysInFileOrder.filter { read.entries[$0] != nil },
            pluralized: read.pluralized)
    }

    private static func propertyListEntries(
        at fileURL: URL, relativePath: String
    ) throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        guard let entries = parsed as? [String: String] else {
            throw CatalogError.notAFlatCatalog(relativePath)
        }
        return entries
    }

    /// The flat scan that can still see a key declared twice, which
    /// Foundation's parser collapses. Keys are plain ASCII identifiers, so
    /// scanning to the closing quote is safe for them; values, which do
    /// carry escapes, are never read this way.
    private static func declaredKeys(at fileURL: URL) throws -> [String] {
        var declared: [String] = []
        for line in try String(contentsOf: fileURL, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            guard line.first == "\"" else { continue }
            let afterOpening = line.dropFirst()
            guard let closing = afterOpening.firstIndex(of: "\"") else { continue }
            declared.append(String(afterOpening[afterOpening.startIndex..<closing]))
        }
        return declared
    }

    enum CatalogError: Error, CustomStringConvertible {
        case notAFlatCatalog(String)
        case notAStringCatalog(String)

        var description: String {
            switch self {
            case .notAFlatCatalog(let path):
                return "\(path) is not a flat string catalog"
            case .notAStringCatalog(let path):
                return """
                    \(path) has a String Catalog's extension and not its shape — no top-level \
                    `strings` object. A catalog this cannot read is one no check below reads \
                    either, so it stops here rather than reporting parity over nothing.
                    """
            }
        }
    }

    /// A String Catalog (`*.xcstrings`), read far enough to say which
    /// keys it holds and what each one says in one language.
    ///
    /// The format is JSON: `sourceLanguage`, and `strings` mapping each key
    /// to its `localizations` per language. A `stringUnit` carries one
    /// value; `variations` carry several (plural categories, device
    /// classes), and every one of them is a string a user can see, so all
    /// of them are read. A key with no entry for the source language takes
    /// the key itself as its value, which is what the runtime does.
    struct StringCatalog {
        let sourceLanguage: String
        let locales: Set<String>
        let keysInFileOrder: [String]
        private let strings: [(key: String, localizations: [String: Any])]

        init(contentsOf fileURL: URL) throws {
            let relative = LocalizationCatalogs.relativePath(of: fileURL)
            let data = try Data(contentsOf: fileURL)
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let root = parsed as? [String: Any],
                let table = root["strings"] as? [String: Any]
            else { throw CatalogError.notAStringCatalog(relative) }

            sourceLanguage = root["sourceLanguage"] as? String ?? "en"
            // JSON objects are unordered, and `JSONSerialization` hands
            // them back as a dictionary — so "file order" is alphabetical
            // here. Nothing downstream needs more: a String Catalog cannot
            // declare a key twice (JSON would collapse it exactly as
            // Foundation's plist parser does), which is the only thing
            // file order was ever for.
            keysInFileOrder = table.keys.sorted()
            strings = keysInFileOrder.map { key in
                (key, (table[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:])
            }
            locales = strings.reduce(into: Set<String>()) { $0.formUnion($1.localizations.keys) }
        }

        func entries(
            forLocale locale: String
        ) -> (entries: [String: String], pluralized: Set<String>) {
            var entries: [String: String] = [:]
            var pluralized: Set<String> = []
            for (key, localizations) in strings {
                guard let localization = localizations[locale] as? [String: Any] else {
                    // The source language falls back to the key itself.
                    if locale == sourceLanguage { entries[key] = key }
                    continue
                }
                let values = Self.values(in: localization)
                guard !values.isEmpty else { continue }
                if values.count > 1 || localization["stringUnit"] == nil { pluralized.insert(key) }
                entries[key] = values.joined(separator: "\n")
            }
            return (entries, pluralized)
        }

        /// Every `stringUnit` value reachable from one localization, at any
        /// nesting depth — `variations` may nest by plural category, by
        /// device, or by both.
        private static func values(in object: [String: Any]) -> [String] {
            if let unit = object["stringUnit"] as? [String: Any],
                let value = unit["value"] as? String
            {
                return [value]
            }
            return object.values.compactMap { $0 as? [String: Any] }
                .flatMap(values(in:))
                .sorted()
        }
    }
}

/// Nothing held the catalogs to describing the same set of strings — eight
/// `Localizable.strings` files today (2 catalog directories × 4 locales,
/// counted in the pass that writes this sentence), plus whatever String
/// Catalogs a future surface brings.
/// `CoreL10nTests` proves that a key resolves to something other than
/// itself, which is a different question: it cannot see a key that exists in
/// English and nowhere else, nor a translation that lost a format specifier.
/// Both fail at runtime, in the one language nobody reviewing the change
/// reads — a missing key renders as the raw key, and a dropped `%@` makes
/// `String(format:)` print a sentence with a hole in it.
///
/// Neither the catalog directories nor the locales inside them are listed
/// here — both are discovered, see `LocalizationCatalogs`. A list would be a
/// claim about the repo that goes stale the moment someone adds a language
/// or a localized target, and it would go stale in the silent direction: the
/// new catalog would simply never be checked.
@Suite("Localization catalog parity")
struct LocalizationParityTests {
    private static let repoRoot = LocalizationCatalogs.repoRoot

    /// Every catalog set in the package, the App's included — and that one
    /// belongs to another target. Parity is a property of the files in the
    /// repo, not of either module's behaviour, and a second copy of this
    /// parser over in `macSCPAppKitTests` would test nothing the first one
    /// doesn't.
    private static func catalogDirectories() throws -> [String] {
        try LocalizationCatalogs.directories()
    }

    /// English is the default language (CLAUDE.md), so it is the reference
    /// every other catalog is measured against.
    private static let referenceLocale = "en"

    private struct Catalog {
        let directory: String
        let locale: String
        /// The file(s) this was read out of — one `.lproj/Localizable.strings`,
        /// or a String Catalog, or both where a directory carries both.
        let sources: [String]
        let entries: [String: String]
        /// Keys in file order, duplicates included — see `parse`.
        let declaredKeys: [String]
        /// Keys whose value is several joined variants; see
        /// `LocalizationCatalogs.CatalogFile.pluralized`.
        let pluralized: Set<String>
        var label: String { sources.joined(separator: " + ") }
    }

    /// Read twice, on purpose.
    ///
    /// `entries` comes from Foundation's own OpenStep parser, which
    /// understands the escapes a hand-written scanner gets wrong — but it
    /// also collapses a key declared twice, keeping one value and dropping
    /// the other without a word. `declaredKeys` is the flat scan that can
    /// still see both. `parserAndScannerAgree` is what keeps that
    /// assumption from rotting quietly.
    ///
    /// One locale can arrive in more than one file — a directory holding
    /// both a `.lproj` and a String Catalog — and they are merged here
    /// because the runtime merges them: a key in both is a key declared
    /// twice, which `noCatalogDeclaresAKeyTwice` is the place to say so.
    private static func parse(_ directory: String, _ locale: String) throws -> Catalog {
        let paths = try LocalizationCatalogs.files(in: directory, forLocale: locale)
        var entries: [String: String] = [:]
        var declared: [String] = []
        var pluralized: Set<String> = []
        for path in paths {
            let file = try LocalizationCatalogs.read(path, locale: locale)
            entries.merge(file.entries) { first, _ in first }
            declared.append(contentsOf: file.declaredKeys)
            pluralized.formUnion(file.pluralized)
        }
        return Catalog(directory: directory, locale: locale, sources: paths,
                       entries: entries, declaredKeys: declared, pluralized: pluralized)
    }

    /// The format specifiers of a string, in order. Order rather than a set:
    /// `String(format:)` consumes arguments positionally, so a translation
    /// that swaps two of them without switching to `%1$@`-style indexes
    /// prints the arguments in the wrong slots.
    private static func specifiers(in string: String) -> [String] {
        // `%%` is a literal percent and consumes no argument.
        let text = string.replacingOccurrences(of: "%%", with: "")
        let pattern = try? NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|li|@|d|f|s)")
        guard let pattern else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func allCatalogs() throws -> [(reference: Catalog, translations: [Catalog])] {
        try catalogDirectories().map { directory in
            let locales = try LocalizationCatalogs.locales(in: directory)
            #expect(locales.contains(referenceLocale),
                    "\(directory) has no \(referenceLocale).lproj to compare against")
            return (
                reference: try parse(directory, referenceLocale),
                translations: try locales
                    .filter { $0 != referenceLocale }
                    .map { try parse(directory, $0) }
            )
        }
    }

    /// A key only English has renders as the raw key for everyone else; a key
    /// only a translation has is dead weight that nothing will ever ask for.
    @Test func everyTranslationDeclaresExactlyTheEnglishKeys() throws {
        for (reference, translations) in try Self.allCatalogs() {
            let expected = Set(reference.entries.keys)
            for catalog in translations {
                let actual = Set(catalog.entries.keys)
                #expect(expected.subtracting(actual).sorted() == [],
                        "\(catalog.label) is missing keys \(expected.subtracting(actual).sorted())")
                #expect(actual.subtracting(expected).sorted() == [],
                        "\(catalog.label) has keys English does not: \(actual.subtracting(expected).sorted())")
            }
        }
    }

    /// A translation that drops or reorders a specifier does not fail to
    /// build and does not fail to load — it just prints the wrong sentence.
    ///
    /// Plural and device variants are exempt, and legitimately so: German
    /// has two plural categories where Polish has four, so the joined
    /// variants of one key hold a different number of specifiers in each
    /// language while every single variant is correct.
    @Test func everyTranslationKeepsTheEnglishFormatSpecifiers() throws {
        for (reference, translations) in try Self.allCatalogs() {
            for catalog in translations {
                for (key, english) in reference.entries
                where !reference.pluralized.contains(key) && !catalog.pluralized.contains(key) {
                    guard let translated = catalog.entries[key] else { continue }
                    #expect(Self.specifiers(in: english) == Self.specifiers(in: translated),
                            "\(catalog.label) key \(key): English has \(Self.specifiers(in: english)), it has \(Self.specifiers(in: translated))")
                }
            }
        }
    }

    /// A key declared twice keeps whichever value the parser saw last. The
    /// file reads as if both were in effect, and a reviewer editing the one
    /// that lost changes nothing at all.
    @Test func noCatalogDeclaresAKeyTwice() throws {
        for (reference, translations) in try Self.allCatalogs() {
            for catalog in [reference] + translations {
                let counted = Dictionary(grouping: catalog.declaredKeys, by: { $0 })
                let duplicated = counted.filter { $0.value.count > 1 }.keys.sorted()
                #expect(duplicated == [], "\(catalog.label) declares \(duplicated) more than once")
            }
        }
    }

    /// The scan and the parser must see the same keys. When they diverge,
    /// this suite's reading of the file has stopped matching Foundation's —
    /// a new escaping style in a key, a multi-line entry — and the duplicate
    /// check above would be quietly looking at the wrong thing.
    @Test func parserAndScannerAgree() throws {
        for (reference, translations) in try Self.allCatalogs() {
            for catalog in [reference] + translations {
                #expect(Set(catalog.declaredKeys) == Set(catalog.entries.keys),
                        "\(catalog.label): the flat scan and Foundation's parser disagree")
            }
        }
    }

    /// An empty translation renders as an empty label — harder to notice
    /// than a missing key, which at least shows its own name.
    @Test func noTranslationIsEmpty() throws {
        for (reference, translations) in try Self.allCatalogs() {
            for catalog in [reference] + translations {
                let blank = catalog.entries
                    .filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    .keys.sorted()
                #expect(blank == [], "\(catalog.label) has empty values for \(blank)")
            }
        }
    }

    /// The derivation every check above rides on. Without this, a lookup
    /// that came back empty would leave all five of them iterating nothing
    /// and reporting success — which is the failure this whole file was
    /// rewritten to make impossible, so it would be a poor place to
    /// reintroduce it.
    ///
    /// Floors and memberships rather than exact counts, so that adding a
    /// language or a localized target is not a test edit.
    @Test func theScanReachesEveryCatalog() throws {
        let targets = try LocalizationCatalogs.targetDirectories()
        #expect(targets.count >= 2, """
            only \(targets.count) target director(ies) derived from Sources/ and \
            Package.swift — the derivation is not reading the package it thinks it is.
            """)

        // The manifest half, pinned on its own. `targets` is a union, and
        // the disk half alone already clears the floor above — so a
        // manifest regex that stopped matching (a reformat to `name :`, a
        // macro, a moved manifest) is exactly the condition that floor
        // cannot report. Every directory the manifest declares must also
        // exist: one that does not is a target this walk never enters.
        let declared = try LocalizationCatalogs.manifestTargetDirectories()
        #expect(!declared.isEmpty, """
            Package.swift declares no shipped target this derivation can read. The manifest \
            half of `targetDirectories()` has stopped matching, and the disk half is carrying \
            the whole derivation without saying so.
            """)
        #expect(Set(declared).isSubset(of: Set(targets)), """
            Package.swift declares target director(ies) \
            \(Set(declared).subtracting(targets).sorted()) \
            that this walk does not enter. Either the manifest is wrong, or this derivation \
            reads `path:` differently from SwiftPM — and a target it drops is a target whose \
            catalogs nothing here reads.
            """)

        let found = try LocalizationCatalogs.allDirectories()
        #expect(found.count >= 2, """
            only \(found.count) catalog director(ies) found under \(targets) — the walk for \
            `.lproj` and `.\(LocalizationCatalogs.stringCatalogExtension)` is not reaching the \
            catalogs, and every check in this suite is then passing over nothing.
            """)

        let directories = try LocalizationCatalogs.directories()
        let withReference = try LocalizationCatalogs.directoriesHolding(
            locale: Self.referenceLocale)
        #expect(withReference == directories, """
            catalog directories \(directories), but \
            \(Set(directories).subtracting(withReference).sorted()) hold no \
            \(Self.referenceLocale) catalog in either format. English is the default language, \
            so a catalog directory without one is a set of translations with nothing to be a \
            translation of.
            """)

        let stale = Set(LocalizationCatalogs.excludedDirectories.map(\.path)).subtracting(found)
        #expect(stale.isEmpty, """
            \(stale.sorted()) are excluded from parity by name but hold no catalog any more — \
            an allowance for files that are gone is a lie about the files.
            """)
    }

    /// The plural catalogs, which sit inside the derived directories and
    /// which nothing above reads.
    ///
    /// `Localizable.stringsdict` is a second file in the same `.lproj`,
    /// and every check above reads exactly one filename. One suite does
    /// read them — `PluralCatalogTests` in `macSCPAppKitTests` — but by
    /// naming its keys and its languages, so it proves that the keys IT
    /// lists resolve, and says nothing about a key nobody has added to
    /// that list. A plural key present in English and missing from a
    /// translation therefore rendered as the raw key with no derived check
    /// looking at it; this is that check.
    ///
    /// Top-level keys only: what is INSIDE a plural entry is where the
    /// languages legitimately differ (`one`/`other` against
    /// `one`/`few`/`many`/`other`), and holding those to parity would fail
    /// on a correct Polish translation.
    ///
    /// The floor is the positive half. `stringsdict` is optional — a
    /// package can hold none — so "no offenders" is a verdict this check
    /// would also return after the walk stopped reaching them.
    @Test func everyPluralCatalogDeclaresExactlyTheEnglishKeys() throws {
        var read: [String] = []
        var offenders: [String] = []
        for directory in try LocalizationCatalogs.directories() {
            let locales = try LocalizationCatalogs.locales(in: directory)
            guard let english = try Self.pluralKeys(directory, Self.referenceLocale) else {
                var orphans: [String] = []
                for locale in locales where locale != Self.referenceLocale {
                    if try Self.pluralKeys(directory, locale) != nil { orphans.append(locale) }
                }
                if !orphans.isEmpty {
                    offenders.append(
                        """
                        \(directory): \(orphans) ship a Localizable.stringsdict where \
                        \(Self.referenceLocale) does not
                        """)
                }
                continue
            }
            read.append("\(directory)/\(Self.referenceLocale)")
            for locale in locales where locale != Self.referenceLocale {
                let label = "\(directory)/\(locale).lproj/Localizable.stringsdict"
                guard let translated = try Self.pluralKeys(directory, locale) else {
                    offenders.append("\(label) is missing, but \(Self.referenceLocale) has one")
                    continue
                }
                read.append("\(directory)/\(locale)")
                let missing = english.subtracting(translated).sorted()
                let extra = translated.subtracting(english).sorted()
                if !missing.isEmpty { offenders.append("\(label) is missing keys \(missing)") }
                if !extra.isEmpty {
                    offenders.append("\(label) has keys \(Self.referenceLocale) does not: \(extra)")
                }
            }
        }

        #expect(read.count >= 2, """
            only \(read.count) Localizable.stringsdict read across the catalog directories. \
            This project ships plural strings; if it genuinely stopped, delete this check \
            deliberately rather than leaving it to report success over nothing.
            """)
        #expect(offenders.isEmpty, """
            plural catalog(s) that do not describe the same keys as \(Self.referenceLocale):
            \(offenders.joined(separator: "\n"))

            A plural key a translation lacks renders as the raw key, in the one language \
            nobody reviewing the change reads.
            """)
    }

    /// The top-level keys of one `.lproj`'s `Localizable.stringsdict`, or
    /// `nil` where there is no such file. A file that exists and does not
    /// parse throws rather than reading as absent.
    private static func pluralKeys(_ directory: String, _ locale: String) throws -> Set<String>? {
        let relative = "\(directory)/\(locale).lproj/Localizable.stringsdict"
        let fileURL = LocalizationCatalogs.url(relative)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: fileURL), options: [], format: &format)
        let dictionary = try #require(
            parsed as? [String: Any], "\(relative) is not a property-list dictionary")
        return Set(dictionary.keys)
    }
}
