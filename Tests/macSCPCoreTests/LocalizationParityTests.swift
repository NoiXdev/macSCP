import Foundation
import Testing

/// Nothing held the four catalogs to describing the same set of strings.
/// `CoreL10nTests` proves that a key resolves to something other than
/// itself, which is a different question: it cannot see a key that exists in
/// English and nowhere else, nor a translation that lost a format specifier.
/// Both fail at runtime, in the one language nobody reviewing the change
/// reads — a missing key renders as the raw key, and a dropped `%@` makes
/// `String(format:)` print a sentence with a hole in it.
///
/// The locales are discovered from the directory rather than listed here.
/// A list would be a claim about the repo that goes stale the moment someone
/// adds a language, and it would go stale in the silent direction: the new
/// catalog would simply never be checked.
@Suite("Localization catalog parity")
struct LocalizationParityTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/LocalizationParityTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Both catalog sets, including the App's — which belongs to another
    /// target. Parity is a property of the files in the repo, not of either
    /// module's behaviour, and a second copy of this parser over in
    /// `macSCPAppKitTests` would test nothing the first one doesn't.
    private static let catalogDirectories = [
        "Sources/macSCPCore/Resources",
        "Sources/MacSCPAppKit/Resources",
    ]

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

    /// Every locale a catalog directory actually contains.
    private static func locales(in directory: String) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: repoRoot.appendingPathComponent(directory).path(percentEncoded: false))
        return contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
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
        try catalogDirectories.map { directory in
            let locales = try locales(in: directory)
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
}
