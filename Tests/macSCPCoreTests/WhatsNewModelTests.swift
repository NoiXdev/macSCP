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
        release("1.0.0"), release("1.1.0"), release("1.2.0"), release("1.3.0"), release("1.4.0"),
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

    // MARK: - Round 1: the dev<->real transition is a rule, not an ASCII accident

    /// This is the genuine regression `releasesToShow`'s old fallback had:
    /// `ChangelogParser`'s dotted comparator falls back to a plain
    /// lexicographic compare on a non-numeric component, and `'d'` (0x64)
    /// sorts above every digit — so `"dev-abc1234"` compared as NEWER than
    /// `"1.3.0"`, and the old code showed every release "newer than 1.3.0"
    /// (here, 1.4.0) to a dev-build user, once, the first time they ran a
    /// dev build after a real release. VERIFIED RED against the
    /// pre-Round-1 code: `(shown → [1.4.0]).isEmpty → false`. `current` is
    /// now checked for being fully numeric FIRST — a non-numeric `current`
    /// always shows nothing, on purpose (a dev build never shows the
    /// sheet), which closes exactly this path.
    @Test("a non-numeric current version after a numeric lastSeen shows nothing, not every release")
    func nonNumericCurrentAfterANumericLastSeenShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "dev-abc1234", lastSeen: "1.3.0", in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    /// The mirror combination — a NUMERIC `current` against a non-numeric
    /// `lastSeen` — already read `[]` under the OLD fallback for this exact
    /// string (`"1.4.0"` compares as NOT newer than `"dev-abc1234"`, the
    /// same `'d' > '1'` comparison as above, just asked in the other
    /// direction — NOT verified red; passed before this change too). That
    /// is exactly the accident this ruling removes: nothing here GUARANTEED
    /// that outcome — a differently-shaped non-numeric string could have
    /// compared the other way and shown every release instead. `lastSeen`
    /// being non-numeric is now an explicit rule ("treat as a fresh
    /// install"): `[]`, decided on purpose rather than on the ASCII value
    /// of whatever prefix a dev build happens to use.
    @Test("a numeric current version after a non-numeric lastSeen shows nothing")
    func numericCurrentAfterANonNumericLastSeenShowsNothing() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.4.0", lastSeen: "dev-abc1234", in: Self.allReleases)
        #expect(shown.isEmpty)
    }

    /// The numeric path itself — both versions ordinary release tags — is
    /// unchanged by the numeric check: it only ever turns an ASCII-accident
    /// "newer"/"not newer" into an explicit, string-shape-independent rule.
    /// Not verified red — this combination was never accident-dependent.
    @Test("two numeric versions still show the release between them")
    func twoNumericVersionsStillShowTheReleaseBetween() {
        let shown = WhatsNewModel.releasesToShow(
            current: "1.4.0", lastSeen: "1.3.0", in: Self.allReleases)
        #expect(shown.map(\.version) == ["1.4.0"])
    }
}
