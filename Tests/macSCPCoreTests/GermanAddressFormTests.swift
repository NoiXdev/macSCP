import Foundation
import Testing

/// The German catalogs address the user as **du**, and this holds them to
/// it.
///
/// Measured before it was written, because the rule was not obvious from
/// the outside: **eleven** strings in the App catalog carry a du-pronoun
/// (`du`, `dich`, `dir`, `dein…`) — counted in the pass that writes this
/// sentence, over the catalog as it stands — and more use the du-imperative
/// without one ("Prüfe deine Internetverbindung und versuche es erneut.",
/// "Verschiebe macSCP in deinen Programme-Ordner", "Bearbeite die
/// Verbindung…"). Core's catalog addresses the user in neither register:
/// its one imperative is the neutral bare infinitive ("Bitte alle
/// erforderlichen S3-Felder ausfüllen.").
///
/// The pronouns are what gets counted, because they are what a count can
/// be checked against — an imperative is recognized by reading, and a
/// number nobody can recompute is a number that drifts. This one said
/// "eight" when it was written, in the same commit that moved two more
/// strings into the du-register, and "ten" through the pass that
/// restructured this file without recounting. Both times the sentence
/// read as plausible; that is the whole hazard. The eleven, counted here:
/// `connection.lost.body.needsPerson`,
/// `connection.lost.hint.noSavedSession`, `connection.saveName.replaces %@`,
/// `settings.cli.footer`, `settings.cli.status.translocated.detail`,
/// `settings.cli.systemWide.footer`, `settings.connection.keepAlive.footer`,
/// `settings.general.updateCheckHint`,
/// `settings.terminal.target.builtInFallback.footer`,
/// `snippets.variables.error.quotedPlaceholder %@`, `update.error.offline`.
///
/// Two strings used the polite form until the failed-connect surface's own
/// round 4, and both sat in `connection.lost.*`, which is how a user met
/// them one after the other.
///
/// ## Why a scan can decide this at all
///
/// German orthography does the work: the third-person pronouns *sie*,
/// *ihr* and *ihnen* are lowercase, while the polite *Sie*, *Ihr* and
/// *Ihnen* are capitalized wherever they stand. So a capitalized form that
/// is **not** at the start of a sentence is address, with no judgement
/// required. Sentence-initial position is the one place capitalization is
/// forced and therefore says nothing, so it is excluded.
///
/// That exclusion is a deliberate false negative: a polite `Sie` opening a
/// sentence is missed. It is the safe direction — a guard that flagged
/// every "Die Datei konnte nicht gelesen werden. Sie ist vorhanden…" would
/// be switched off by the first person it annoyed, and then it would
/// protect nothing. All four legitimate pronouns in the catalogs today
/// happen to be sentence-initial, and all three real address cases were
/// mid-sentence.
///
/// Note what is deliberately NOT a sentence boundary: `;` and the dashes,
/// after which German lowercases — so a capital there is meaningful and
/// must still be read as address. That claim is carried by a fixture
/// ("Das ging schief; Sie müssen es erneut versuchen.") rather than by
/// this sentence: the first version of this comment justified the rule
/// with one of the two strings the guard was written for, and that string
/// does not exercise it at all — its `Sie` sits mid-clause, several words
/// past the `;`, so the backward walk never reaches the semicolon. The
/// rule is right; the example was not, and a fixture cannot be wrong the
/// way a sentence can.
@Suite("German address form")
struct GermanAddressFormTests {
    private static let germanLocale = "de"

    /// The German catalogs, found rather than listed — see
    /// `LocalizationCatalogs`. Naming them here would have meant that a
    /// third localized target went unread while this suite reported
    /// success.
    ///
    /// `try?` is what a stored property costs, and it is the one hazard
    /// this rewrite could have reintroduced: a derivation that threw would
    /// leave the check below iterating an empty array, and a parameterized
    /// test with no arguments passes. `theScanReachesEveryGermanCatalog`
    /// recomputes the same list with the error left in and holds this one
    /// against it, so the swallowed error cannot stay swallowed.
    private static let catalogs: [String] =
        (try? LocalizationCatalogs.catalogs(forLocale: germanLocale)) ?? []

    private static let politeForms =
        #"\b(?:Sie|Ihnen|Ihr(?:e|em|en|er|es)?)\b"#

    /// Characters that stand between a sentence's terminator and its first
    /// word without being part of either.
    private static let transparent: Set<Character> = [
        " ", "\t", "„", "\"", "»", "‚", "'", "(", "[",
    ]

    /// What ends a sentence in a way that FORCES the next word's capital.
    /// `;` and dashes are absent on purpose — see this suite's own doc
    /// comment.
    private static let terminators: Set<Character> = [".", "!", "?", ":", "…", "\n"]

    private static func startsASentence(at index: String.Index, in value: String) -> Bool {
        var cursor = index
        while cursor > value.startIndex {
            cursor = value.index(before: cursor)
            let character = value[cursor]
            if transparent.contains(character) { continue }
            return terminators.contains(character)
        }
        return true
    }

    /// Every capitalized polite form in `value` that is not sentence-initial.
    static func politeAddress(in value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: politeForms)
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let matched = Range(match.range, in: value),
                !startsASentence(at: matched.lowerBound, in: value)
            else { return nil }
            return String(value[matched])
        }
    }

    // MARK: - The classifier, on the cases that made it necessary

    /// The four legitimate pronouns actually in the catalogs, quoted as
    /// they stand. Every one is a *sie/ihr* forced into a capital by
    /// sentence position — three feminine singulars and one plural — and a
    /// guard that flagged any of them would be the guard nobody keeps.
    ///
    /// Kept as literals rather than read from the files: these are the
    /// fixtures that prove the classifier DISCRIMINATES, and they have to
    /// go on proving it even after someone rewords the strings they were
    /// taken from.
    @Test(arguments: [
        "Die Schlüsseldatei konnte nicht gelesen werden. Sie ist vorhanden, lässt sich aber nicht decodieren — es ging kein Schlüssel verloren, und es wird nichts darüber geschrieben.",
        "Der Schlüssel wurde gespeichert, seine Passphrase jedoch nicht. Sie wird bei der nächsten Verbindung abgefragt.",
        "Die Snippet-Datei konnte nicht gelesen werden. Sie ist vorhanden, lässt sich aber nicht decodieren — es ging kein Snippet verloren, und es wird nichts darüber geschrieben.",
        "Einige Sitzungen konnten nicht mit dem neuen Login-Set verknüpft werden. Sie haben ihr eigenes Passwort behalten.",
    ])
    func aSentenceInitialPronounIsNotAddress(value: String) throws {
        #expect(try Self.politeAddress(in: value).isEmpty, """
            a `Sie` that merely opens a sentence was read as polite address. German forces a \
            capital there whatever the word means, so the position says nothing — and a guard \
            that cries wolf on an ordinary error message is one the next person switches off.
            """)
    }

    /// The other direction, on the three strings this rule was written for
    /// — the two pre-existing ones and the one the failed-connect surface
    /// introduced — plus two shapes they do not cover.
    @Test(arguments: [
        // `connection.lost.body.needsPerson`, as it read before round 4.
        "Der letzte Versuch endete bei einer Frage, die nur Sie beantworten können.",
        // `connection.lost.hint.noSavedSession`, likewise.
        "Diese Verbindung war nicht gespeichert; zum Wiederverbinden füllen Sie das Formular erneut aus.",
        // `connection.failed.body.adHoc`, as it read before round 4.
        "macSCP konnte den Host nicht erreichen. Bearbeiten Sie die Verbindung, um die Angaben zu prüfen und erneut zu verbinden.",
        // The reason `;` must not count as a sentence boundary: German
        // lowercases after one, so this capital is address. Unlike the
        // string above — whose `Sie` is several words past its `;` — this
        // one actually exercises the rule.
        "Das ging schief; Sie müssen es erneut versuchen.",
        // A polite possessive, which no sentence position excuses.
        "Der Vorgang wurde abgebrochen, weil Ihre Sitzung abgelaufen ist.",
        // And the dative.
        "macSCP hat Ihnen nichts weggenommen.",
    ])
    func aMidSentencePoliteFormIsAddress(value: String) throws {
        #expect(try !Self.politeAddress(in: value).isEmpty, """
            polite address went unnoticed in: \(value)
            """)
    }

    /// The lowercase third person must never match, whatever its position.
    @Test func theLowercaseThirdPersonIsNeverFlagged() throws {
        #expect(
            try Self.politeAddress(
                in: "Die Datei ist da, aber sie lässt sich nicht lesen; ihr Inhalt bleibt unklar.")
                .isEmpty)
    }

    // MARK: - The catalogs themselves

    @Test(arguments: GermanAddressFormTests.catalogs)
    func noGermanStringAddressesTheUserInThePoliteForm(relativePath: String) throws {
        let entries = try LocalizationCatalogs.read(
            relativePath, locale: Self.germanLocale).entries
        #expect(!entries.isEmpty, """
            no strings read from \(relativePath) — this check is not reading the catalog it \
            thinks it is. How many strings the catalogs hold between them is a question for \
            `theScanReachesEveryGermanCatalog`: a floor per catalog would be a claim about \
            the size of a directory this suite has never seen.
            """)

        var offenders: [String] = []
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let hits = try Self.politeAddress(in: value)
            if !hits.isEmpty { offenders.append("\(key): \(hits.joined(separator: ", "))") }
        }
        #expect(offenders.isEmpty, """
            German string(s) addressing the user in the polite form:
            \(offenders.joined(separator: "\n"))

            This app says du — eleven strings in the App catalog carry a du-pronoun and more \
            use the du-imperative ("Prüfe deine Internetverbindung und versuche es \
            erneut."). Two strings in \
            `connection.lost.*` used Sie until the failed-connect surface's own round 4, \
            which is how a user met both registers one after the other. Reword in the \
            du-form; if a string genuinely needs the polite form, that is a decision to make \
            for the whole catalog, not for one entry.
            """)
    }

    /// The derivation this suite rides on, and the German coverage it
    /// implies. Floors rather than counts, so that a new localized target
    /// is a catalog to translate and not a test to edit.
    @Test func theScanReachesEveryGermanCatalog() throws {
        let catalogs = try LocalizationCatalogs.catalogs(forLocale: Self.germanLocale)
        #expect(catalogs == Self.catalogs, """
            deriving the German catalogs threw where this suite's own list swallowed it — \
            the check above is running \(Self.catalogs.count) case(s) where \(catalogs.count) \
            catalog(s) exist.
            """)
        #expect(catalogs.count >= 2, """
            only \(catalogs.count) German catalog(s) found — the derivation is not reaching \
            the catalogs, and the check above is passing over nothing.
            """)

        let directories = try LocalizationCatalogs.directories()
        let withoutGerman = directories.filter { directory in
            !catalogs.contains { $0.hasPrefix(directory + "/") }
        }
        #expect(withoutGerman.isEmpty, """
            catalog director(ies) with no \(Self.germanLocale) catalog in any format: \
            \(withoutGerman). macSCP ships German, so a localized target without it is a \
            surface whose register nothing here reads — and the register is the whole point \
            of this suite.
            """)

        let strings = try catalogs.reduce(into: 0) { total, relativePath in
            total += try LocalizationCatalogs.read(
                relativePath, locale: Self.germanLocale).entries.count
        }
        #expect(strings >= 40, """
            \(strings) German string(s) across \(catalogs.count) catalog(s) — far too few \
            for the catalogs this project has, so the scan is reading something other than \
            what it names.
            """)
    }

}
