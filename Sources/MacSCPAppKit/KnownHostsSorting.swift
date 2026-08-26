import Foundation
import macSCPCore

// The known-hosts table's decidable part: which comparison rule belongs to
// which column, and where a value that is missing lands. Split out of
// `KnownHostsSheet.swift` so it can be stated in tests — no test in this
// project renders a view.

/// Wraps a `KnownHostKey` with a stable identity for `Table`/`List`
/// selection — `KnownHostKey` itself carries no id; host+port is its natural
/// key (the same pair `KnownHostsStore.remove(host:port:)` uses to identify
/// an entry).
struct KnownHostRow: Identifiable {
    let key: KnownHostKey

    /// The fingerprint the sort keys on, `nil` exactly when Core could not
    /// derive one — i.e. when `key.fingerprintSHA256` is about to return its
    /// placeholder instead of a digest.
    ///
    /// Stored rather than recomputed per comparison, and kept apart from the
    /// display value on purpose: the cell keeps drawing
    /// `key.fingerprintSHA256`, so the placeholder's spelling stays Core's
    /// business and is not duplicated here as a literal to compare against.
    let derivedFingerprint: String?

    init(key: KnownHostKey) {
        self.key = key
        self.derivedFingerprint = HostKeyFingerprint.sha256(ofKeyBlobBase64: key.publicKeyBase64)
    }

    var id: String { "\(key.host):\(key.port)" }
}

/// Which column a sort is keyed on. One case per column of the known-hosts
/// table, and `CaseIterable` so that a column added later has to be
/// classified here rather than quietly arriving unsortable — the wiring
/// guard counts the sheet's columns against this enum.
enum KnownHostSortKey: String, CaseIterable, Sendable {
    case host
    case port
    case keyType
    case fingerprint
    case added
}

/// The comparison rule of one column, in the shape SwiftUI's `Table` takes
/// for `sortUsing:`.
///
/// A hand-written `SortComparator` rather than a `KeyPathComparator` per
/// column because two of these columns can be missing a value, and a key
/// path has no way to say where a missing one goes. See
/// `KnownHostsSorting.primaryOrder` for the rules themselves.
///
/// `compare` applies `order` itself, as `SortComparator` requires — it
/// returns the reversed result, not the forward one for a caller to flip.
struct KnownHostComparator: SortComparator, Hashable, Sendable {
    var key: KnownHostSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: KnownHostRow, _ rhs: KnownHostRow) -> ComparisonResult {
        let result = KnownHostsSorting.primaryOrder(lhs, rhs, key: key)
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Sorts the known-hosts table's rows, and owns the per-column rules the
/// comparators above hand back.
///
/// **Where a missing value goes.** Two fields can be absent on real data,
/// and each is given the identity the file browser already gives the same
/// shape (`RemoteBrowserViewModel.sortedForDisplay`), so the two tables of
/// this app do not disagree about what "missing" means:
///
/// - A missing `addedAt` — every entry written before that field existed
///   decodes as `nil` — is the OLDEST possible date, first among ascending
///   results. That is also what it factually is: trusted before the app
///   recorded when.
/// - A fingerprint Core could not derive, because the stored blob is not
///   valid base64, is the GREATEST possible string, last among ascending
///   results. Compared as the `SHA256:?` text the cell draws, it would land
///   wherever `?` happens to fall among base64 digits; at the end it is
///   where the user can see there is nothing to copy.
///
/// Reversing a column flips which END those are, never the identity itself
/// — same mechanical reversal, and the same wording, as the file browser's.
///
/// **Ties.** Every comparison ends at host, then port, ascending — which is
/// the order `KnownHostsStore.allKeys()` itself returns, so the fallback is
/// never a surprise. It stays ascending even under a reversed column, the
/// way the file browser keeps its name tiebreaker ascending, so tied rows
/// read A→Z in both directions. Being total, it also makes the result
/// independent of the order the rows came in, which `sorted(by:)` alone
/// does not promise.
///
/// **Not persisted.** The sort lives in the sheet's `@State` and is gone
/// when the sheet closes. It is a modal management sheet the user opens to
/// find one host, and its sibling state — the search field, the selection —
/// is session-scoped for the same reason. Storing it would also mean
/// storing a column identifier that a later version can no longer resolve;
/// nothing here writes one, so that case cannot arise.
enum KnownHostsSorting {
    /// What the sheet opens on: host ascending, identical to the order
    /// `KnownHostsStore.allKeys()` hands it. Sortable headers therefore
    /// change nothing about the first thing the user sees.
    static let defaultOrder: [KnownHostComparator] = [KnownHostComparator(key: .host)]

    static func sorted(
        _ rows: [KnownHostRow], using order: [KnownHostComparator]
    ) -> [KnownHostRow] {
        rows.sorted { lhs, rhs in
            for comparator in order {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame {
                    return result == .orderedAscending
                }
            }
            return tiebreak(lhs, rhs) == .orderedAscending
        }
    }

    /// `ComparisonResult` for `lhs` vs. `rhs` under `key`, ascending and
    /// WITHOUT the tiebreaker (which `sorted` applies separately, always
    /// ascending).
    fileprivate static func primaryOrder(
        _ lhs: KnownHostRow, _ rhs: KnownHostRow, key: KnownHostSortKey
    ) -> ComparisonResult {
        switch key {
        case .host:
            // A name, so case-insensitive — even though `KnownHostKey`
            // lowercases on the way in and nothing else here relies on that.
            return lhs.key.host.localizedCaseInsensitiveCompare(rhs.key.host)
        case .port:
            return compare(lhs.key.port, rhs.key.port)
        case .keyType:
            // `SSH-RSA` and `ssh-rsa` name one algorithm and sort as one.
            return lhs.key.keyType.localizedCaseInsensitiveCompare(rhs.key.keyType)
        case .fingerprint:
            return compareFingerprint(lhs.derivedFingerprint, rhs.derivedFingerprint)
        case .added:
            return compareOptional(lhs.key.addedAt, rhs.key.addedAt)
        }
    }

    /// Host, then port, ascending — the total order everything falls back
    /// to.
    private static func tiebreak(_ lhs: KnownHostRow, _ rhs: KnownHostRow) -> ComparisonResult {
        let byHost = lhs.key.host.localizedCaseInsensitiveCompare(rhs.key.host)
        guard byHost == .orderedSame else { return byHost }
        return compare(lhs.key.port, rhs.key.port)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// A missing value is the SMALLEST/OLDEST possible one — first among
    /// ascending results.
    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (let lhs?, let rhs?): return compare(lhs, rhs)
        }
    }

    /// Present fingerprints compare EXACTLY: byte order, case-sensitive,
    /// not localized. A fingerprint is an identity rather than a name —
    /// base64 is case-sensitive, and two digests differing only in case are
    /// two different keys, which a case-insensitive comparison would call
    /// equal.
    ///
    /// A missing one (`nil`) is the GREATEST possible value — the opposite
    /// identity from `compareOptional`'s, and the same split the file
    /// browser makes between its missing dates and its missing names.
    private static func compareFingerprint(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lhs?, let rhs?): return compare(lhs, rhs)
        }
    }
}
