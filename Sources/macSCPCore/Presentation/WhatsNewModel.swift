import Foundation

/// Decides which `CHANGELOG.md` releases a "What's New" sheet should show
/// after an update (What's New plan, Task 2). Pure and Core-side so it can
/// be tested without a bundle, a window, or a sheet: the App layer feeds it
/// two version strings and the parsed changelog, and draws whatever comes
/// back.
public enum WhatsNewModel {
    /// The releases to present, newest first, or `[]` when nothing should
    /// be shown.
    ///
    /// - `current` is not a NUMERIC version (Round 1 ruling — see
    ///   `isNumericVersion(_:)`): `[]`, always, regardless of `lastSeen`. A
    ///   dev build never shows the sheet. `MacSCPApp.decideWhatsNew(store:)`
    ///   still records `current` as `lastSeenVersion` in this case — this
    ///   function only decides what to SHOW, not what to remember.
    /// - `current` is numeric but `lastSeen` is non-`nil` and NOT numeric
    ///   (Round 1 ruling): `[]`, treated exactly like a fresh install —
    ///   there is no reliable version to compare `current` against, only a
    ///   dev-build string that carries no ordering guarantee.
    /// - `lastSeen == nil` (fresh install — nothing recorded yet): `[]`.
    ///   A fresh install has nothing to catch up on; showing every release
    ///   ever written would not be "what's new", it would be the whole
    ///   changelog.
    /// - `lastSeen == current` (already caught up): `[]`.
    /// - `current` older than `lastSeen` (a downgrade — a dev build
    ///   overwriting a newer release, or a reinstall of an older tag):
    ///   `[]`. There is nothing new to report going backwards, and
    ///   showing the sheet would misreport a downgrade as an update.
    /// - `current` newer than `lastSeen` (both numeric): every release
    ///   strictly newer than `lastSeen` AND not newer than `current` — the
    ///   second half matters because a dev build's changelog can carry
    ///   entries for releases still ahead of the version actually running
    ///   (the changelog is written before the tag that ships it), and this
    ///   must not spoil what has not shipped yet.
    ///
    /// Ordering and filtering both come from `ChangelogParser
    /// .releases(newerThan:in:)`, which already returns newest-first.
    ///
    /// "Newer than" is decided ENTIRELY through that same function rather
    /// than a second comparison written here: `isNewer(_:than:)` below asks
    /// the question by construction — `a` is newer than `b` exactly when
    /// `a` shows up in "the releases newer than `b`" among a list
    /// containing only `a` itself. That is the same dotted, component-wise
    /// rule `Changelog.swift`'s own doc comment describes (`releases
    /// (newerThan:in:)`), reached without duplicating it.
    ///
    /// ## Why `current`/`lastSeen` are checked for being numeric FIRST
    ///
    /// Before this Round 1 fix, a non-numeric string (a dev build's
    /// `"dev-<hash>"`) fell all the way through to `ChangelogParser`'s
    /// dotted comparator, which — for a component that fails to parse as
    /// `Int` on either side — falls back to a plain lexicographic compare.
    /// ASCII places every digit (`0x30`-`0x39`) below every lowercase
    /// letter (`0x61`-`0x7A`), so `"dev-abc1234"` compared as NEWER than
    /// any numeric version by that fallback — not because of anything
    /// about versions, but because `'d' > '9'`. That accident cut both
    /// ways: `current: "dev-<hash>", lastSeen: "1.3.0"` showed EVERY
    /// release newer than `1.3.0` once, the first time a dev build ran
    /// after a real release (verified red — see `WhatsNewModelTests`);
    /// `current: "1.4.0", lastSeen: "dev-<hash>"` happened to already read
    /// `[]` for that exact string shape, but only because `"dev-"` starts
    /// with a letter ASCII sorts above every digit — a different
    /// non-numeric prefix could have sorted the other way and shown every
    /// release just the same. Neither outcome was a rule; both were
    /// whatever `strcmp`-style ordering the two particular strings
    /// happened to produce. `isNumericVersion(_:)` makes the dev↔real
    /// transition an explicit decision instead, kept private to this type
    /// (rather than on `ChangelogParser`, which this task's brief allowed
    /// but did not require) because it exists to answer exactly one
    /// question this decision asks, not as a general-purpose version
    /// predicate `ChangelogParser`'s other callers might reach for.
    public static func releasesToShow(
        current: String, lastSeen: String?, in releases: [ChangelogRelease]
    ) -> [ChangelogRelease] {
        guard isNumericVersion(current) else { return [] }
        guard let lastSeen, isNumericVersion(lastSeen), isNewer(current, than: lastSeen) else {
            return []
        }
        return ChangelogParser.releases(newerThan: lastSeen, in: releases)
            .filter { !isNewer($0.version, than: current) }
    }

    /// `a` compares newer than `b` by `ChangelogParser`'s own rule — see
    /// this type's doc comment for why it is reached this way rather than
    /// through a second comparison. Only ever called on two versions
    /// `isNumericVersion` has already accepted (`releasesToShow`'s guards
    /// run first), so the accidental lexicographic fallback this Round 1
    /// fix exists to avoid never actually triggers here any more.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let probe = ChangelogRelease(version: a, date: nil, sections: [])
        return !ChangelogParser.releases(newerThan: b, in: [probe]).isEmpty
    }

    /// A version is "numeric" iff every dot-separated component parses as
    /// `Int`. An empty string is rejected by that same rule, with nothing
    /// extra needed for it: `split(separator:omittingEmptySubsequences:
    /// false)` on `""` returns `[""]`, never `[]`, so `allSatisfy` runs
    /// once over the empty component and `Int("")` is `nil`. This is
    /// deliberately NOT `AppVersion`: `AppVersion` requires exactly three
    /// components plus an optional pre-release suffix, which would reject
    /// a legitimate two-component tag before this predicate ever got a
    /// chance to say "compare these two". This only needs to keep a dev
    /// build's free-form string out of the dotted comparator, not validate
    /// a release tag's shape.
    private static func isNumericVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return components.allSatisfy { Int($0) != nil }
    }
}
