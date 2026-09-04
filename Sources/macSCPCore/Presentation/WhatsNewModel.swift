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
    /// - `lastSeen == nil` (fresh install — nothing recorded yet): `[]`.
    ///   A fresh install has nothing to catch up on; showing every release
    ///   ever written would not be "what's new", it would be the whole
    ///   changelog.
    /// - `lastSeen == current` (already caught up): `[]`.
    /// - `current` older than `lastSeen` (a downgrade — a dev build
    ///   overwriting a newer release, or a reinstall of an older tag):
    ///   `[]`. There is nothing new to report going backwards, and
    ///   showing the sheet would misreport a downgrade as an update.
    /// - `current` newer than `lastSeen`: every release strictly newer
    ///   than `lastSeen` AND not newer than `current` — the second half
    ///   matters because a dev build's changelog can carry entries for
    ///   releases still ahead of the version actually running (the
    ///   changelog is written before the tag that ships it), and this
    ///   must not spoil what has not shipped yet.
    ///
    /// Ordering and filtering both come from `ChangelogParser
    /// .releases(newerThan:in:)`, which already returns newest-first.
    ///
    /// "Newer than" is decided ENTIRELY through that same function rather
    /// than a second comparison written here: `Changelog.swift` (Task 1)
    /// is off limits to this task, so there is no version-comparison entry
    /// point to call directly. Instead, `isNewer(_:than:)` below asks the
    /// question by construction — `a` is newer than `b` exactly when `a`
    /// shows up in "the releases newer than `b`" among a list containing
    /// only `a` itself. That is the same dotted, component-wise rule
    /// `Changelog.swift`'s own doc comment describes (`releases
    /// (newerThan:in:)`), reached without duplicating it — and, unlike
    /// `AppVersion`, tolerant of a non-SemVer running version such as a
    /// dev build's `"dev-<hash>"` (see `WhatsNewModelTests`).
    public static func releasesToShow(
        current: String, lastSeen: String?, in releases: [ChangelogRelease]
    ) -> [ChangelogRelease] {
        guard let lastSeen, isNewer(current, than: lastSeen) else { return [] }
        return ChangelogParser.releases(newerThan: lastSeen, in: releases)
            .filter { !isNewer($0.version, than: current) }
    }

    /// `a` compares newer than `b` by `ChangelogParser`'s own rule — see
    /// this type's doc comment for why it is reached this way rather than
    /// through a second comparison.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let probe = ChangelogRelease(version: a, date: nil, sections: [])
        return !ChangelogParser.releases(newerThan: b, in: [probe]).isEmpty
    }
}
