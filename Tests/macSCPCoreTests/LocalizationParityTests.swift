import Foundation
import Testing

/// Where the string catalogs are — found, never listed.
///
/// Both localization suites in this target used to name the catalog
/// directories while deriving the LOCALES inside each one from the
/// directory itself. That is half a derivation, and the half that was
/// missing is the one that fails silently: a third localized target would
/// have been read by nothing, and both suites would have gone on reporting
/// success over the two they knew about. A check that verifies less than it
/// believes is worse than none, because it reports success.
///
/// The locations are derived twice, after
/// `ReconnectWiringGuardTests.everySourceDirectoryIsScannedOrExplicitlyExcluded`:
/// from what is on disk under `Sources/`, and from what `Package.swift`
/// declares — because a target's sources need not live under `Sources/` at
/// all. Every directory so reached is searched for `.lproj` subdirectories,
/// and a directory that has one is a catalog location. Test targets are
/// left out: a `.lproj` under `Tests/` would be a fixture, and a fixture is
/// meant to be allowed to be wrong.
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

        let manifest = try String(contentsOf: url("Package.swift"), encoding: .utf8)
        for name in try captures(
            #"\.(?:executableTarget|target)\(\s*name:\s*"([^"]+)""#, in: manifest)
        {
            candidates.insert("Sources/\(name)")
        }
        // A target may say where its sources live, and that directory is as
        // much a target directory as `Sources/<name>` is.
        for path in try captures(#"path:\s*"([^"]+)""#, in: manifest) {
            candidates.insert(path)
        }

        return candidates.filter { isDirectory(url($0)) }.sorted()
    }

    /// Every directory under a shipped target that holds at least one
    /// `.lproj`, the deliberately excluded ones included.
    static func allDirectories() throws -> [String] {
        var found: Set<String> = []
        for target in try targetDirectories() {
            guard let walk = fileManager.enumerator(
                at: url(target), includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for case let candidate as URL in walk
            where candidate.pathExtension == "lproj" && isDirectory(candidate) {
                found.insert(relativePath(of: candidate.deletingLastPathComponent()))
            }
        }
        return found.sorted()
    }

    /// The catalog directories a check is meant to read.
    static func directories() throws -> [String] {
        let excluded = Set(excludedDirectories.map(\.path))
        return try allDirectories().filter { !excluded.contains($0) }
    }

    /// Every locale a catalog directory actually contains.
    static func locales(in directory: String) throws -> [String] {
        let contents = try fileManager.contentsOfDirectory(
            atPath: url(directory).path(percentEncoded: false))
        return contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    /// The `Localizable.strings` of one locale, wherever a catalog
    /// directory has one. A directory that lacks the locale is absent from
    /// the result rather than reported here: which locales a catalog owes
    /// is the caller's property, not this lookup's.
    static func catalogs(forLocale locale: String) throws -> [String] {
        try directories().compactMap { directory in
            let relative = "\(directory)/\(locale).lproj/Localizable.strings"
            let path = url(relative).path(percentEncoded: false)
            return fileManager.fileExists(atPath: path) ? relative : nil
        }
    }
}

/// Nothing held the four catalogs to describing the same set of strings.
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
        let entries: [String: String]
        /// Keys in file order, duplicates included — see `parse`.
        let declaredKeys: [String]
        var label: String { "\(directory)/\(locale).lproj" }
    }

    private static func url(_ directory: String, _ locale: String) -> URL {
        repoRoot
            .appendingPathComponent(directory)
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
    }

    /// Read twice, on purpose.
    ///
    /// `entries` comes from Foundation's own OpenStep parser, which
    /// understands the escapes a hand-written scanner gets wrong — but it
    /// also collapses a key declared twice, keeping one value and dropping
    /// the other without a word. `declaredKeys` is the flat scan that can
    /// still see both. Keys are plain ASCII identifiers, so scanning to the
    /// closing quote is safe for them; values, which do carry escapes, are
    /// never read this way. `parserAndScannerAgree` is what keeps that
    /// assumption from rotting quietly.
    private static func parse(_ directory: String, _ locale: String) throws -> Catalog {
        let fileURL = url(directory, locale)
        let data = try Data(contentsOf: fileURL)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        let entries = try #require(
            parsed as? [String: String],
            "\(directory)/\(locale).lproj is not a flat string catalog")

        var declared: [String] = []
        for line in try String(contentsOf: fileURL, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            guard line.first == "\"" else { continue }
            let afterOpening = line.dropFirst()
            guard let closing = afterOpening.firstIndex(of: "\"") else { continue }
            declared.append(String(afterOpening[afterOpening.startIndex..<closing]))
        }
        return Catalog(directory: directory, locale: locale,
                       entries: entries, declaredKeys: declared)
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
    @Test func everyTranslationKeepsTheEnglishFormatSpecifiers() throws {
        for (reference, translations) in try Self.allCatalogs() {
            for catalog in translations {
                for (key, english) in reference.entries {
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

        let found = try LocalizationCatalogs.allDirectories()
        #expect(found.count >= 2, """
            only \(found.count) catalog director(ies) found under \(targets) — the walk for \
            `.lproj` is not reaching the catalogs, and every check in this suite is then \
            passing over nothing.
            """)

        let directories = try LocalizationCatalogs.directories()
        let reference = try LocalizationCatalogs.catalogs(forLocale: Self.referenceLocale)
        #expect(reference.count == directories.count, """
            catalog directories \(directories) but only \(reference.count) \
            \(Self.referenceLocale).lproj/Localizable.strings among them. English is the \
            default language, so a catalog directory without one is a set of translations \
            with nothing to be a translation of.
            """)

        let stale = Set(LocalizationCatalogs.excludedDirectories.map(\.path)).subtracting(found)
        #expect(stale.isEmpty, """
            \(stale.sorted()) are excluded from parity by name but hold no catalog any more — \
            an allowance for files that are gone is a lie about the files.
            """)
    }
}
