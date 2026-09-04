import Foundation
import Testing

@testable import macSCPCore

/// Pins `WhatsNewModel.releasesToShow(current:lastSeen:in:)` (What's New
/// plan, Task 2) against the four rulings its doc comment states: a fresh
/// install shows nothing, an already-caught-up install shows nothing, an
/// update shows exactly the releases between the last-seen and running
/// versions, and a downgrade shows nothing.
@Suite("What's New model")
struct WhatsNewModelTests {
    private static func release(_ version: String) -> ChangelogRelease {
        ChangelogRelease(
            version: version, date: nil,
            sections: [ChangelogRelease.Section(
                title: "Features",
                entries: [ChangelogRelease.Section.Entry(scope: nil, text: "\(version) entry")])])
    }

    private static let allReleases = [
        release("1.0.0"), release("1.1.0"), release("1.2.0"), release("1.3.0"),
    ]

    @Test("fresh install shows nothing")
    func freshInstallShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.3.0", lastSeen: nil, in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    @Test("already caught up shows nothing")
    func alreadyCaughtUpShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.3.0", lastSeen: "1.3.0", in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    @Test("an update shows the releases between last seen and current, newest first")
    func updateShowsReleasesBetween() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.3.0", lastSeen: "1.1.0", in: Self.allReleases)
        #expect(shown.map(\.version) == ["1.3.0", "1.2.0"])
    }

    /// A dev build's changelog can carry entries written for a release
    /// still ahead of the version actually running (the changelog is
    /// written before the tag that ships it) — those must not appear.
    @Test("entries newer than the running version are withheld")
    func entriesAboveCurrentAreWithheld() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.2.0", lastSeen: "1.0.0", in: Self.allReleases)
        #expect(shown.map(\.version) == ["1.2.0", "1.1.0"])
    }

    @Test("a downgrade shows nothing")
    func downgradeShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.1.0", lastSeen: "1.3.0", in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    /// A non-SemVer running version — a dev build's `"dev-<hash>"`
    /// (`dev-build.sh`'s `MACSCP_VERSION`) — must not crash the decision,
    /// unlike `AppVersion`, which would fail to parse it outright. Two
    /// launches of the very same dev build record and re-read the same
    /// string, so this is the one case a dev build can rely on regardless
    /// of how `ChangelogParser`'s lexicographic fallback treats an
    /// all-non-numeric component against a numeric one.
    @Test("a non-SemVer current version equal to lastSeen shows nothing")
    func nonSemVerCurrentVersionEqualToLastSeenShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "dev-abc1234", lastSeen: "dev-abc1234", in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    @Test("a non-SemVer current version on a fresh install shows nothing")
    func nonSemVerCurrentVersionFreshInstallShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "dev-abc1234", lastSeen: nil, in: Self.allReleases)
        #expect(shown.isEmpty)
    }
}
