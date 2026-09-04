import Foundation
import Testing

@testable import macSCPCore

/// Pins `ChangelogParser` against the real `CHANGELOG.md` the release
/// script writes at the repo root, plus a handful of fixtures for the
/// grammar rules that a single real release can't exercise on its own
/// (an unparented bullet, an unknown line, version ordering) — What's New
/// plan, Task 1.
@Suite("Changelog parser")
struct ChangelogParserTests {
    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/ChangelogParserTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `CLISessionsCommandGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let realChangelog = try! String(
        contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)

    /// Selects one release by version instead of `releases.first`: the
    /// release workflow regenerates `CHANGELOG.md` with a new top section
    /// at every release, so pinning "first" would go red on the release
    /// commit for reasons unrelated to the parser. `"1.3.0"` is the
    /// version every real-file test below keys on.
    private static func release(_ version: String, in releases: [ChangelogRelease]) -> ChangelogRelease? {
        releases.first { $0.version == version }
    }

    // MARK: - The real CHANGELOG.md

    @Test("the real CHANGELOG.md's first release parses its heading")
    func realChangelogFirstReleaseHeading() {
        let releases = ChangelogParser.parse(Self.realChangelog)

        let release = Self.release("1.3.0", in: releases)
        #expect(release != nil, "CHANGELOG.md carries no 1.3.0 release section")
        #expect(release?.date == "2026-08-31")
    }

    @Test("the real CHANGELOG.md's first release parses its section titles")
    func realChangelogFirstReleaseSectionTitles() {
        let releases = ChangelogParser.parse(Self.realChangelog)

        let release = Self.release("1.3.0", in: releases)
        #expect(release != nil, "CHANGELOG.md carries no 1.3.0 release section")
        #expect(release?.sections.map(\.title) == ["Features", "Bug Fixes"])
    }

    /// Counted directly in the tree at Task 1 time (`## [1.3.0]` through
    /// the next `## [`): 55 `* ` bullets under `### Features`, 86 under
    /// `### Bug Fixes` — `awk '/^## \[/{c++} c==1' CHANGELOG.md | awk
    /// '/^### Features/{f=1;next} /^### /{f=0} f' | grep -c '^\* '` and
    /// the same with `Bug Fixes`. Neither section has any non-bullet line,
    /// so the bullet count equals the entry count for each.
    @Test("the real CHANGELOG.md's first release has the counted number of entries")
    func realChangelogFirstReleaseEntryCounts() {
        let releases = ChangelogParser.parse(Self.realChangelog)

        let release = Self.release("1.3.0", in: releases)
        #expect(release != nil, "CHANGELOG.md carries no 1.3.0 release section")
        let sections = release?.sections ?? []
        #expect(sections.count == 2)
        #expect(sections[0].entries.count == 55)
        #expect(sections[1].entries.count == 86)
    }

    /// The first `### Features` bullet in the real file today is
    /// `* **app:** ask for declared variables before a snippet runs
    /// ([e5ce80d](https://github.com/NoiXdev/macSCP/commit/e5ce80d…))` —
    /// pins the `**scope:**` → `scope` split and the trailing commit-link
    /// strip against real output, not just a hand-written fixture.
    @Test("a real bullet's scope and trailing link are split out")
    func realChangelogFirstEntryScopeAndText() {
        let releases = ChangelogParser.parse(Self.realChangelog)

        let release = Self.release("1.3.0", in: releases)
        #expect(release != nil, "CHANGELOG.md carries no 1.3.0 release section")
        let firstEntry = release?.sections.first?.entries.first
        #expect(firstEntry?.scope == "app")
        #expect(firstEntry?.text == "ask for declared variables before a snippet runs")
    }

    // MARK: - Bullet grammar (fixture)

    @Test("a bullet's **scope:** becomes scope, and its trailing link is dropped from text")
    func bulletScopeAndTrailingLinkAreSplit() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Features

            * **core:** parse the changelog into releases ([abc1234](https://example.com/commit/abc1234))
            """

        let releases = ChangelogParser.parse(fixture)
        let entry = releases.first?.sections.first?.entries.first

        #expect(entry?.scope == "core")
        #expect(entry?.text == "parse the changelog into releases")
    }

    @Test("a bullet with no **scope:** prefix keeps scope nil")
    func bulletWithoutScope() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Features

            * add the initial release ([abc1234](https://example.com/commit/abc1234))
            """

        let releases = ChangelogParser.parse(fixture)
        let entry = releases.first?.sections.first?.entries.first

        #expect(entry?.scope == nil)
        #expect(entry?.text == "add the initial release")
    }

    // MARK: - Link reduction (Round 1 review ruling, 2026-09-04)

    @Test("a hash link followed by a closes suffix leaves the suffix's own link reduced to its label")
    func hashLinkFollowedByClosesSuffixKeepsSuffixLabel() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Bug Fixes

            * **core:** make the guarantees say what the guards do ([abc1234](https://example.com/commit/abc1234)), closes [#12](https://example.com/issues/12)
            """

        let releases = ChangelogParser.parse(fixture)
        let entry = releases.first?.sections.first?.entries.first

        #expect(entry?.scope == "core")
        #expect(entry?.text == "make the guarantees say what the guards do, closes #12")
    }

    @Test("a hash link in the middle of the line is dropped, not just a trailing one")
    func hashLinkMidLineIsDropped() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Features

            * **core:** before ([abc1234](https://example.com/commit/abc1234)) after
            """

        let releases = ChangelogParser.parse(fixture)
        let entry = releases.first?.sections.first?.entries.first

        #expect(entry?.text == "before after")
    }

    @Test("a plain (non-hash) link keeps its label and drops the URL")
    func plainLinkKeepsLabel() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Features

            * **core:** see [the docs](https://example.com/docs) for more
            """

        let releases = ChangelogParser.parse(fixture)
        let entry = releases.first?.sections.first?.entries.first

        #expect(entry?.text == "see the docs for more")
    }

    @Test("the real CHANGELOG.md's guards and webdav bullets have their closes-suffix link reduced")
    func realChangelogClosesSuffixBulletsAreReduced() {
        let releases = ChangelogParser.parse(Self.realChangelog)

        let release = Self.release("1.3.0", in: releases)
        #expect(release != nil, "CHANGELOG.md carries no 1.3.0 release section")
        let bugFixes = release?.sections.last?.entries ?? []

        let guardsEntry = bugFixes.first { $0.scope == "guards" }
        #expect(guardsEntry?.text == "make the guarantees say what the guards do, closes PKCS#12")

        let webdavEntry = bugFixes.first {
            $0.text.hasPrefix("refuse a redirected certificate challenge")
        }
        #expect(webdavEntry?.text == "refuse a redirected certificate challenge and pin nothing, closes PKCS#12")
    }

    // MARK: - Totality: a bullet before any "### " heading opens an untitled section

    @Test("a bullet and a stray line before any section heading share one untitled section, in order")
    func contentBeforeAnySectionHeadingOpensUntitledSection() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            * **core:** a bullet with no section heading above it ([abc1234](https://example.com/commit/abc1234))
            A stray line, also with no section heading above it.
            """

        let releases = ChangelogParser.parse(fixture)
        let sections = releases.first?.sections ?? []

        #expect(sections.count == 1)
        #expect(sections.first?.title == "")
        #expect(sections.first?.entries.count == 2)
        #expect(sections.first?.entries.first?.scope == "core")
        #expect(sections.first?.entries.first?.text == "a bullet with no section heading above it")
        #expect(sections.first?.entries.last?.scope == nil)
        #expect(sections.first?.entries.last?.text == "A stray line, also with no section heading above it.")
    }

    // MARK: - Totality: an unknown line is kept, never dropped

    @Test("an unknown line under a section is kept as a plain-text entry with scope nil")
    func unknownLineIsKeptAsPlainText() {
        let fixture = """
            ## [1.0.0](https://example.com/compare/v0.9.0...v1.0.0) (2026-01-02)

            ### Features

            * **core:** first bullet ([abc1234](https://example.com/commit/abc1234))
            This is a stray paragraph, not a bullet.
            """

        let releases = ChangelogParser.parse(fixture)
        let entries = releases.first?.sections.first?.entries ?? []

        #expect(entries.count == 2)
        #expect(entries.last?.scope == nil)
        #expect(entries.last?.text == "This is a stray paragraph, not a bullet.")
    }

    // MARK: - Totality: no headings, no releases

    @Test("a document with no release heading yields an empty list")
    func noHeadingsYieldsEmptyList() {
        #expect(ChangelogParser.parse("") == [])
        #expect(ChangelogParser.parse("Just some prose, no headings at all.") == [])
    }

    // MARK: - releases(newerThan:in:)

    private static let threeReleaseFixture = """
        ## [1.3.0](https://example.com/compare/v1.2.0...v1.3.0) (2026-08-31)

        ### Features

        * **core:** third release ([abc0003](https://example.com/commit/abc0003))

        ## [1.2.0](https://example.com/compare/v1.1.0...v1.2.0) (2026-08-19)

        ### Features

        * **core:** second release ([abc0002](https://example.com/commit/abc0002))

        ## [1.1.0](https://example.com/compare/v1.0.0...v1.1.0) (2026-07-31)

        ### Features

        * **core:** first release ([abc0001](https://example.com/commit/abc0001))
        """

    @Test("releases(newerThan:) keeps only the release above the given version")
    func newerThanFiltersToLaterReleases() {
        let releases = ChangelogParser.parse(Self.threeReleaseFixture)
        #expect(releases.map(\.version) == ["1.3.0", "1.2.0", "1.1.0"])

        let newer = ChangelogParser.releases(newerThan: "1.2.0", in: releases)

        #expect(newer.map(\.version) == ["1.3.0"])
    }

    @Test("releases(newerThan:) returns matches sorted newest first, regardless of input order")
    func newerThanSortsDescendingRegardlessOfInputOrder() {
        let ascending = [
            ChangelogRelease(version: "1.1.0", date: nil, sections: []),
            ChangelogRelease(version: "1.2.0", date: nil, sections: []),
            ChangelogRelease(version: "1.3.0", date: nil, sections: []),
        ]

        let newer = ChangelogParser.releases(newerThan: "1.0.0", in: ascending)

        #expect(newer.map(\.version) == ["1.3.0", "1.2.0", "1.1.0"])
    }

    @Test("\"1.10.0\" sorts numerically above \"1.9.0\", not lexicographically")
    func dottedComparisonIsNumericNotLexicographic() {
        let fixture = """
            ## [1.10.0](https://example.com/compare/v1.9.0...v1.10.0) (2026-08-31)

            ### Features

            * **core:** tenth minor ([abc0010](https://example.com/commit/abc0010))

            ## [1.9.0](https://example.com/compare/v1.8.0...v1.9.0) (2026-07-31)

            ### Features

            * **core:** ninth minor ([abc0009](https://example.com/commit/abc0009))
            """

        let releases = ChangelogParser.parse(fixture)
        let newer = ChangelogParser.releases(newerThan: "1.9.0", in: releases)

        #expect(newer.map(\.version) == ["1.10.0"])
    }
}
