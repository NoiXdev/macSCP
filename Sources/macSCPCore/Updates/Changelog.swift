import Foundation

/// One release entry of `CHANGELOG.md`, as `conventional-changelog` writes
/// it: `## [1.3.0](https://…/compare/v1.2.0...v1.3.0) (2026-08-31)` followed
/// by one or more `### <section>` blocks of `* **scope:** text ([hash](url))`
/// bullets (What's New plan, Task 1).
public struct ChangelogRelease: Equatable, Sendable {
    /// The text inside the heading's `[...]`, e.g. `"1.3.0"` — never parsed
    /// into `AppVersion` here; that stays the App layer's decision about
    /// what "the current version" means (`UpdateChecker` already owns that
    /// comparison for the update check itself).
    public let version: String
    /// The heading's trailing `(...)`, e.g. `"2026-08-31"`. `nil` when the
    /// heading carries no parenthesized date — malformed input is kept,
    /// never rejected (ChangelogParser is total).
    public let date: String?
    public let sections: [Section]

    public init(version: String, date: String?, sections: [Section]) {
        self.version = version
        self.date = date
        self.sections = sections
    }

    /// One `### <title>` block within a release — `"Features"`,
    /// `"Bug Fixes"`, or whatever conventional-changelog's `type` mapping
    /// produced, taken verbatim.
    public struct Section: Equatable, Sendable {
        public let title: String
        public let entries: [Entry]

        public init(title: String, entries: [Entry]) {
            self.title = title
            self.entries = entries
        }

        /// One bullet line within a section.
        public struct Entry: Equatable, Sendable {
            /// The `**scope:**` bold prefix, e.g. `"core"` for
            /// `"* **core:** …"`. `nil` for a bullet with no scope prefix
            /// (conventional-changelog omits it when a commit carries no
            /// scope) and for any line kept as plain text rather than
            /// parsed as a bullet at all.
            public let scope: String?
            /// The bullet's remaining text with its own trailing
            /// `([hash](url))` commit link stripped, when that link sits
            /// at the very end of the line. A link followed by more text
            /// (conventional-changelog's `, closes [#N](url)` suffix) is
            /// not "trailing" by that rule and is left in `text` untouched
            /// — this parser drops nothing silently.
            public let text: String

            public init(scope: String?, text: String) {
                self.scope = scope
                self.text = text
            }
        }
    }
}

/// Parses `CHANGELOG.md` into `[ChangelogRelease]`.
///
/// Total by construction: every line is classified as a release heading, a
/// section heading, a bullet, a blank line, or — the fallback case — plain
/// text kept as an `Entry(scope: nil, text: …)` under whatever section is
/// currently open. Nothing is ever dropped silently, nothing throws, and
/// nothing scans past the input it was given. A document with no `## `
/// release heading yields `[]`.
public enum ChangelogParser {
    public static func parse(_ markdown: String) -> [ChangelogRelease] {
        // Regex literals build a `Regex` value, and `Regex` itself isn't
        // `Sendable` — kept as locals rather than `static let`s so Swift 6
        // strict concurrency has nothing global to complain about; a fresh
        // literal per `parse` call costs nothing a changelog-sized document
        // would notice.

        /// `## [<version>](<link>) (<date>)` — the link and the date are
        /// both optional so a malformed or hand-written heading still
        /// yields a version rather than being swallowed as plain text.
        let releaseHeading = /^##\s+\[([^\]]+)\](?:\([^)]*\))?(?:\s*\(([^)]*)\))?\s*$/

        /// `### <title>` — a second-level heading opening a new section
        /// within the release currently open.
        let sectionHeading = /^###\s+(.+?)\s*$/

        /// `* <rest>` or `- <rest>` — conventional-changelog always uses
        /// `*`; `-` is accepted too since CommonMark treats both as the
        /// same list marker and rejecting one spelling silently would be
        /// exactly the kind of drop this parser exists to avoid.
        let bulletMarker = /^[*-]\s+(.*)$/

        var releases: [ChangelogRelease] = []

        var version: String?
        var date: String?
        var sections: [ChangelogRelease.Section] = []

        var sectionTitle: String?
        var entries: [ChangelogRelease.Section.Entry] = []

        func closeSection() {
            if let sectionTitle {
                sections.append(ChangelogRelease.Section(title: sectionTitle, entries: entries))
            }
            sectionTitle = nil
            entries = []
        }

        func closeRelease() {
            closeSection()
            if let version {
                releases.append(ChangelogRelease(version: version, date: date, sections: sections))
            }
            version = nil
            date = nil
            sections = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            // Tolerate CRLF line endings without treating the carriage
            // return as part of any captured text.
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]

            if let match = line.wholeMatch(of: releaseHeading) {
                closeRelease()
                version = String(match.1)
                date = match.2.map(String.init)
                continue
            }

            guard version != nil else {
                // Content before any release heading (or after a
                // malformed one) belongs to no release, so it is not
                // collected — this is the "no headings → []" rule applied
                // one line at a time.
                continue
            }

            if let match = line.wholeMatch(of: sectionHeading) {
                closeSection()
                sectionTitle = String(match.1)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // A bullet or stray line found before any "### " heading has
            // no named section to join. Rather than drop it, it opens an
            // untitled section — real conventional-changelog output never
            // hits this path (every release's content sits under a typed
            // heading), so this only guards against a hand-edited file.
            if sectionTitle == nil {
                sectionTitle = ""
            }

            if let bulletMatch = trimmed.wholeMatch(of: bulletMarker) {
                entries.append(Self.parseEntry(String(bulletMatch.1)))
            } else {
                entries.append(ChangelogRelease.Section.Entry(scope: nil, text: trimmed))
            }
        }

        closeRelease()
        return releases
    }

    /// Splits a bullet's text into `scope` and `text`, then strips a
    /// trailing commit link off `text` (see `Entry.text`'s doc comment).
    /// Its two regexes are locals for the same `Regex` isn't-`Sendable`
    /// reason `parse(_:)`'s are — see that function's comment.
    private static func parseEntry(_ bulletText: String) -> ChangelogRelease.Section.Entry {
        /// `**scope:** <rest>` at the start of a bullet's text.
        let scopePrefix = /^\*\*([^*:]+):\*\*\s*(.*)$/

        /// A `([hash](url))` commit link anchored at the END of the text —
        /// only a link with nothing after it counts as "trailing" (see
        /// `Entry.text`'s doc comment).
        let trailingCommitLink = /^(.*?)\s*\(\[[^\]]+\]\([^)]*\)\)\s*$/

        let scope: String?
        let rest: String
        if let scopeMatch = bulletText.wholeMatch(of: scopePrefix) {
            scope = String(scopeMatch.1)
            rest = String(scopeMatch.2)
        } else {
            scope = nil
            rest = bulletText
        }

        let text: String
        if let linkMatch = rest.wholeMatch(of: trailingCommitLink) {
            text = String(linkMatch.1)
        } else {
            text = rest
        }

        return ChangelogRelease.Section.Entry(scope: scope, text: text)
    }

    /// The releases in `releases` whose `version` is numerically greater
    /// than `version`, in their original order.
    ///
    /// Comparison is a dotted, component-wise one: components at the same
    /// position compare as `Int` when BOTH sides parse as one (so
    /// `"1.10.0"` sorts above `"1.9.0"` — ten is greater than nine, not
    /// `"10" < "9"` as strings would read it); otherwise that component
    /// compares lexicographically as a plain string, and a version with
    /// fewer components is padded with `"0"` for the ones it lacks.
    public static func releases(
        newerThan version: String, in releases: [ChangelogRelease]
    ) -> [ChangelogRelease] {
        releases.filter { isVersion($0.version, newerThan: version) }
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        compareDottedVersions(lhs, rhs) > 0
    }

    /// Negative when `lhs` < `rhs`, zero when equal by this rule, positive
    /// when `lhs` > `rhs`. See `releases(newerThan:in:)`'s doc comment for
    /// the comparison rule itself.
    private static func compareDottedVersions(_ lhs: String, _ rhs: String) -> Int {
        let lhsParts = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rhsParts = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let left = index < lhsParts.count ? lhsParts[index] : "0"
            let right = index < rhsParts.count ? rhsParts[index] : "0"
            if left == right { continue }

            if let leftNumber = Int(left), let rightNumber = Int(right) {
                if leftNumber != rightNumber {
                    return leftNumber < rightNumber ? -1 : 1
                }
                continue
            }
            return left < right ? -1 : 1
        }
        return 0
    }
}
