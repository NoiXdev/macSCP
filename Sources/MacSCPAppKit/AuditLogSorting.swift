import Foundation
import macSCPCore

// The audit-log table's decidable part: what text a column compares, which
// comparison rule belongs to which column, and where an empty value lands.
// Split out of `AuditLogSheet.swift` so it can be stated in tests — no test
// in this project renders a view. Same split, and the same reasons, as
// `KnownHostsSorting`.

/// The text an audit row DRAWS, in one place.
///
/// Two of the table's columns do not compare a stored field: the Event
/// column compares a localized label, and the Detail column compares a text
/// the cell assembles. Both are here so that the cell and the comparison
/// cannot drift apart — a column that sorts on text the user is not looking
/// at is wrong in a way no rule test would notice.
enum AuditEventText {
    /// Kind labels are the only localized part of an event row (spec M9b
    /// §1) — `detail` and `errorMessage` are finished English plain text
    /// and are always shown verbatim. The fallback is the raw value, so a
    /// missing catalogue entry degrades to a readable identifier rather
    /// than to an empty cell.
    static func kindLabel(_ kind: AuditEvent.Kind) -> String {
        L10n.string("audit.kind.\(kind.rawValue)", kind.rawValue)
    }

    /// Detail cell text (M9b/T4 review, finding 4): error rows append
    /// ` — <errorMessage>` so the failure reason is visible without opening
    /// search or export — both of which already included it.
    static func detail(for event: AuditEvent) -> String {
        guard event.isError, let errorMessage = event.errorMessage else { return event.detail }
        return "\(event.detail) — \(errorMessage)"
    }
}

/// Which column a sort is keyed on. One case per column of the audit-log
/// table, and `CaseIterable` so that a column added later has to be
/// classified here rather than quietly arriving unsortable — the wiring
/// guard counts the sheet's columns against this enum.
enum AuditSortKey: String, CaseIterable, Sendable {
    case time
    case kind
    case detail
}

/// The comparison rule of one column, in the shape SwiftUI's `Table` takes
/// for `sortUsing:`.
///
/// A hand-written `SortComparator` rather than a `KeyPathComparator` per
/// column because no column compares its stored field as-is: two compare
/// text the cell assembles, and one of those has an empty case a key path
/// has no way to place. See `AuditLogSorting.primaryOrder` for the rules
/// themselves.
///
/// `compare` applies `order` itself, as `SortComparator` requires — it
/// returns the reversed result, not the forward one for a caller to flip.
struct AuditEventComparator: SortComparator, Hashable, Sendable {
    var key: AuditSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: AuditEvent, _ rhs: AuditEvent) -> ComparisonResult {
        let result = AuditLogSorting.primaryOrder(lhs, rhs, key: key)
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Sorts the audit-log table's rows, and owns the per-column rules the
/// comparators above hand back.
///
/// **What the sheet opens on.** Newest first — `defaultOrder` is the time
/// column REVERSED, which is the order the audit log has been shown in
/// since it existed and the order a chronological record is read in. The
/// store hands the sheet its events oldest-first (recording order), so the
/// default is not a no-op; it is the promise that sortable headers change
/// nothing until the user clicks one.
///
/// **What the Event column means to the user.** The label the cell draws,
/// compared case-insensitively and localized — so the groups arrive in the
/// alphabetical order of the reader's own language, and rows showing the
/// same words sit together. Not the enum's declaration order and not its
/// raw value: both are spellings inside this source that no user can see,
/// and both change meaning the moment the catalogue is translated.
///
/// **Where an empty value goes.** `AuditEvent`'s only field that can be
/// absent is `errorMessage`, and it is not a column of its own — it only
/// appends to the Detail cell. The Detail cell's own text, on the other
/// hand, can be empty (a stored `detail` of `""` on a non-error row), and
/// an empty one is the GREATEST possible string: last among ascending
/// results. Left to the plain string comparison it would be the smallest
/// and head the list, pushing every row with something to read below a row
/// with nothing in it. That is the identity the file browser gives a
/// missing name (`RemoteBrowserViewModel.sortedForDisplay`) and the one the
/// known-hosts table gives a fingerprint it could not derive, so the tables
/// of this app do not disagree about what "nothing there" means. Reversing
/// the column flips which END that is, never the identity itself.
///
/// **Ties.** Every comparison ends newest-first, then on `id`. Newest-first
/// because that is the direction the log reads in, so grouping by Event or
/// by Detail still shows the most recent entry of each group at its top; it
/// stays newest-first even under a reversed column, the way the file
/// browser keeps its name tiebreaker ascending. `id` is the last resort and
/// is reached only by rows that agree on everything the user can see: it
/// means nothing to a reader, and exists so the result never depends on the
/// order the rows arrived in, which `sorted(by:)` alone does not promise.
///
/// **Being total is what makes the placement free.** The sheet sorts the
/// FILTER RESULT rather than the whole log. Because the order above is
/// total and depends on nothing but the two rows compared, that is the same
/// sequence as sorting the whole log and filtering afterwards — the choice
/// is the obvious one to read, not a behaviour. It only became free with
/// this order: the sheet's previous `timestamp >` comparison left rows with
/// equal timestamps wherever `sorted` put them, and the two placements
/// could then disagree.
///
/// **Not persisted.** The sort lives in the sheet's `@State` and is gone
/// when the sheet closes, exactly as in `KnownHostsSorting` and for the
/// same reasons: it is a modal viewer whose sibling state (the segment
/// filter, the search field) is session-scoped, and storing a column
/// identifier would mean handling the day a later version can no longer
/// resolve one.
enum AuditLogSorting {
    /// Newest first — see the type's doc comment.
    static let defaultOrder: [AuditEventComparator] = [
        AuditEventComparator(key: .time, order: .reverse)
    ]

    static func sorted(
        _ events: [AuditEvent], using order: [AuditEventComparator]
    ) -> [AuditEvent] {
        events.sorted { lhs, rhs in
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
    /// newest-first).
    fileprivate static func primaryOrder(
        _ lhs: AuditEvent, _ rhs: AuditEvent, key: AuditSortKey
    ) -> ComparisonResult {
        switch key {
        case .time:
            return compare(lhs.timestamp, rhs.timestamp)
        case .kind:
            return AuditEventText.kindLabel(lhs.kind)
                .localizedCaseInsensitiveCompare(AuditEventText.kindLabel(rhs.kind))
        case .detail:
            return compareDetail(
                AuditEventText.detail(for: lhs), AuditEventText.detail(for: rhs))
        }
    }

    /// Newest first, then `id` — the total order everything falls back to.
    private static func tiebreak(_ lhs: AuditEvent, _ rhs: AuditEvent) -> ComparisonResult {
        let byTime = compare(rhs.timestamp, lhs.timestamp)
        guard byTime == .orderedSame else { return byTime }
        return compare(lhs.id.uuidString, rhs.id.uuidString)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Present details compare as prose: case-insensitive and localized,
    /// the same rule the file browser gives a file name. A detail is a
    /// sentence the app wrote, not an identity, so a byte-wise comparison
    /// would only file every capitalized line ahead of every other one.
    ///
    /// An EMPTY detail is the GREATEST possible string — see the type's
    /// doc comment for why that end.
    private static func compareDetail(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): return lhs.localizedCaseInsensitiveCompare(rhs)
        }
    }
}
