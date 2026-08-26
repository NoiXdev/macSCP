import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Pins the comparison rule behind each column of the audit-log table:
/// which field a column keys on, what text it compares, where an EMPTY
/// value lands, and what the sheet opens on before the user clicks
/// anything.
///
/// Two things make this suite necessary rather than a `KeyPathComparator`
/// per column:
///
/// - The audit log is a chronological record. Its opening order is a
///   promise, not a default that may drift, so it is pinned here against a
///   real `AuditLogStore` rather than against a copy of its sort written
///   out in this file.
/// - Two of the columns do not compare a stored field at all. The Event
///   column compares the LOCALIZED label the cell draws, and the Detail
///   column compares the drawn text including the error suffix the cell
///   appends. A key path would compare `kind`'s raw value and a `detail`
///   the user cannot fully see.
///
/// The label assertions are written so they hold in every language the app
/// ships: the expected order is derived from the labels themselves in the
/// language the test process resolved, and the claim that carries the
/// weight is the NEGATIVE one — the result is neither the enum's
/// declaration order nor its raw-value order. No pair of kinds separates
/// those three orders in all four catalogues, so a hard-coded pair would
/// assert nothing in at least one of them.
///
/// This suite proves the rules. It does not prove `AuditLogSheet` asks
/// them — no test in this project renders a view;
/// `AuditLogSortWiringGuardTests` is the wiring half.
@Suite("Audit-log sorting")
struct AuditLogSortingTests {
    // MARK: - Fixtures

    private static func event(
        at seconds: TimeInterval,
        kind: AuditEvent.Kind = .connected,
        detail: String = "detail",
        isError: Bool = false,
        errorMessage: String? = nil
    ) -> AuditEvent {
        AuditEvent(
            timestamp: Date(timeIntervalSince1970: seconds),
            kind: kind,
            detail: detail,
            isError: isError,
            errorMessage: errorMessage)
    }

    private static func sorted(
        _ events: [AuditEvent], by key: AuditSortKey, _ order: SortOrder = .forward
    ) -> [AuditEvent] {
        AuditLogSorting.sorted(events, using: [AuditEventComparator(key: key, order: order)])
    }

    private static func times(_ events: [AuditEvent]) -> [TimeInterval] {
        events.map(\.timestamp.timeIntervalSince1970)
    }

    private static func details(_ events: [AuditEvent]) -> [String] {
        events.map(AuditEventText.detail(for:))
    }

    // MARK: - The fixture itself

    /// Guards what the label assertions below rest on: the catalogue was
    /// actually found, and no two kinds draw the SAME label in this
    /// language. Two kinds sharing a label would be decided by the
    /// tiebreaker, and the Event-column tests would be measuring that
    /// instead of the label rule.
    @Test func theKindLabelsAreDistinctAndResolvedInThisLanguage() {
        let labels = AuditEvent.Kind.allCases.map(AuditEventText.kindLabel)
        #expect(Set(labels).count == AuditEvent.Kind.allCases.count)
        for kind in AuditEvent.Kind.allCases {
            #expect(AuditEventText.kindLabel(kind) != kind.rawValue, """
                `audit.kind.\(kind.rawValue)` fell back to its raw value — the catalogue did not \
                resolve, and every label assertion in this suite would be comparing raw values.
                """)
        }
    }

    // MARK: - One rule per column

    /// Times read as times: oldest first ascending. The column's REVERSE
    /// is what the sheet opens on, which is pinned separately below.
    @Test func theTimeColumnOrdersOldestFirstAscending() {
        let events = [Self.event(at: 9_000), Self.event(at: 1_000), Self.event(at: 5_000)]
        #expect(Self.times(Self.sorted(events, by: .time)) == [1_000, 5_000, 9_000])
    }

    /// The Event column groups by the label the user READS, so the groups
    /// arrive in the alphabetical order of their own language.
    @Test func theEventColumnGroupsByTheLabelTheUserSees() {
        let ordered = Self.sorted(Self.oneEventPerKind(), by: .kind)
        let labels = ordered.map { AuditEventText.kindLabel($0.kind) }
        for (earlier, later) in zip(labels, labels.dropFirst()) {
            #expect(earlier.localizedCaseInsensitiveCompare(later) == .orderedAscending, """
                `\(earlier)` was placed before `\(later)`, which is not the order a reader of \
                this language would put them in.
                """)
        }
    }

    /// The claim with teeth: the resulting grouping is NEITHER the order
    /// the enum cases happen to be written in NOR their raw-value order.
    /// Both of those are spellings inside the source; a user clicking
    /// "Event" is owed the order of the words on their screen.
    ///
    /// Non-vacuous in every catalogue the app ships — checked one language
    /// at a time while writing this, not assumed from English.
    @Test func theEventColumnDoesNotFallBackOnTheEnumsOwnOrder() {
        let ordered = Self.sorted(Self.oneEventPerKind(), by: .kind).map(\.kind)
        #expect(ordered != AuditEvent.Kind.allCases)
        #expect(ordered != AuditEvent.Kind.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    /// One event per kind, handed over in an order that is neither of the
    /// two orders the test above rules out, so a sort that did nothing at
    /// all cannot pass by accident either.
    private static func oneEventPerKind() -> [AuditEvent] {
        AuditEvent.Kind.allCases.reversed().enumerated().map { index, kind in
            event(at: TimeInterval(1_000 + index), kind: kind, detail: kind.rawValue)
        }
    }

    /// The Detail column keys on the text the CELL draws, error suffix
    /// included — not on the stored `detail`, half of which the user never
    /// sees on an error row.
    ///
    /// The two events share a `detail`, so a sort keyed on the stored field
    /// alone would call them equal and hand them to the tiebreaker. The
    /// timestamps are picked so that the tiebreaker would then put the
    /// ERROR row first: the expectation below is the opposite of what a
    /// stored-field sort produces, not merely different from it.
    @Test func theDetailColumnOrdersTheTextTheCellDraws() {
        let plain = Self.event(at: 1_000, detail: "sync")
        let failed = Self.event(
            at: 9_000, detail: "sync", isError: true, errorMessage: "aborted")
        #expect(Self.details(Self.sorted([failed, plain], by: .detail)) == ["sync", "sync — aborted"])
        #expect(
            Self.details(Self.sorted([plain, failed], by: .detail, .reverse))
                == ["sync — aborted", "sync"])
    }

    /// A detail is a sentence the app wrote, not an identity, so its case
    /// carries no meaning. A byte-wise comparison would file every line
    /// that happens to start with a capital ahead of every other one, which
    /// is not an order anybody reads in.
    @Test func theDetailColumnIgnoresCase() {
        let events = [
            Self.event(at: 1_000, detail: "Beta"),
            Self.event(at: 2_000, detail: "alpha"),
        ]
        #expect(Self.details(Self.sorted(events, by: .detail)) == ["alpha", "Beta"])
    }

    // MARK: - Empty values

    /// `AuditEvent` has exactly one field that can be absent
    /// (`errorMessage`), and it is not a column: it only ever appends to
    /// the Detail cell. What CAN be empty is the drawn detail itself, and
    /// an empty one is the GREATEST possible string — last ascending.
    ///
    /// Left to the plain string comparison it would be the smallest and
    /// head the list, pushing every row with something to read below a row
    /// with nothing in it. Same identity the file browser gives a missing
    /// name, and the same one the known-hosts table gives a fingerprint it
    /// could not derive.
    @Test func anEmptyDetailSortsLast() {
        let events = [
            Self.event(at: 1_000, detail: ""),
            Self.event(at: 2_000, detail: "alpha"),
            Self.event(at: 3_000, detail: "beta"),
        ]
        #expect(Self.details(Self.sorted(events, by: .detail)) == ["alpha", "beta", ""])
    }

    /// Reversing the column moves the empty detail to the other END. What
    /// must not happen is it staying put, or landing in the middle: its
    /// identity ("greatest") is fixed, only which end that is flips.
    @Test func anEmptyDetailSortsFirstWhenTheColumnIsReversed() {
        let events = [
            Self.event(at: 1_000, detail: ""),
            Self.event(at: 2_000, detail: "alpha"),
            Self.event(at: 3_000, detail: "beta"),
        ]
        #expect(Self.details(Self.sorted(events, by: .detail, .reverse)) == ["", "beta", "alpha"])
    }

    /// Emptiness is judged on the DRAWN text, so an error row whose stored
    /// `detail` is empty still has something to read and is not banished to
    /// the end with the genuinely empty row.
    @Test func anErrorRowWithAnEmptyStoredDetailIsNotEmpty() {
        let blank = Self.event(at: 1_000, detail: "")
        let failed = Self.event(at: 2_000, detail: "", isError: true, errorMessage: "boom")
        let named = Self.event(at: 3_000, detail: "alpha")
        let ordered = Self.sorted([blank, failed, named], by: .detail)
        #expect(AuditEventText.detail(for: ordered.last!).isEmpty)
        #expect(ordered.last == blank)
        #expect(ordered.contains(failed))
        #expect(ordered.firstIndex(of: failed)! < ordered.firstIndex(of: blank)!)
    }

    /// Two rows that are both empty are equal under the column and fall
    /// through to the tiebreaker — not into whatever order `sorted`
    /// happened to receive them in.
    @Test func twoEmptyDetailsFallThroughToTheTiebreaker() {
        let events = [Self.event(at: 1_000, detail: ""), Self.event(at: 9_000, detail: "")]
        #expect(Self.times(Self.sorted(events, by: .detail)) == [9_000, 1_000])
        #expect(Self.times(Self.sorted(events, by: .detail, .reverse)) == [9_000, 1_000])
    }

    // MARK: - Ties and direction

    /// Rows equal under the sorted column keep a fixed order: newest
    /// first, which is the direction the log itself reads in. Without it
    /// `sorted(by:)` is free to return either, and the table would
    /// reshuffle equal rows on an unrelated redraw.
    @Test func equalRowsAreBrokenByNewestFirst() {
        let events = [
            Self.event(at: 1_000, kind: .rename),
            Self.event(at: 9_000, kind: .rename),
            Self.event(at: 5_000, kind: .rename),
        ]
        #expect(Self.times(Self.sorted(events, by: .kind)) == [9_000, 5_000, 1_000])
    }

    /// The tiebreaker does NOT follow the column's direction: rows that tie
    /// still read newest-first under a reversed sort, the same way the file
    /// browser and the known-hosts table keep their own tiebreakers
    /// ascending in a descending sort.
    @Test func theTiebreakerStaysNewestFirstUnderAReversedSort() {
        let events = [
            Self.event(at: 1_000, kind: .rename),
            Self.event(at: 9_000, kind: .rename),
        ]
        #expect(Self.times(Self.sorted(events, by: .kind, .reverse)) == [9_000, 1_000])
    }

    /// Reversing a column reverses that column, and nothing else about the
    /// result is different.
    @Test func reversingAColumnReversesThatColumn() {
        let events = [Self.event(at: 1_000), Self.event(at: 9_000)]
        #expect(Self.times(Self.sorted(events, by: .time, .reverse)) == [9_000, 1_000])
    }

    /// The last resort is reached only by rows that agree on everything the
    /// user can see, and it is deterministic: the same rows in a different
    /// input order come out the same way. Otherwise the table would be free
    /// to reshuffle them on a redraw.
    @Test func rowsAgreeingOnEverythingVisibleStillHaveOneFixedOrder() {
        let a = Self.event(at: 1_000, kind: .rename, detail: "same")
        let b = Self.event(at: 1_000, kind: .rename, detail: "same")
        for key in AuditSortKey.allCases {
            #expect(Self.sorted([a, b], by: key).map(\.id) == Self.sorted([b, a], by: key).map(\.id))
        }
    }

    // MARK: - The order as a whole

    /// A second comparator decides rows the first one calls equal, and it
    /// decides them BEFORE the fixed tiebreaker gets a say — otherwise the
    /// table's secondary sort would be dead weight. The expectation is the
    /// OPPOSITE of what the tiebreaker alone would produce, so a build that
    /// ignored the second comparator fails here rather than agreeing by
    /// accident.
    @Test func aSecondComparatorDecidesRowsTheFirstCallsEqual() {
        let events = [
            Self.event(at: 9_000, kind: .rename, detail: "zulu"),
            Self.event(at: 1_000, kind: .rename, detail: "alpha"),
        ]
        let ordered = AuditLogSorting.sorted(
            events,
            using: [
                AuditEventComparator(key: .kind),
                AuditEventComparator(key: .detail),
            ])
        #expect(Self.details(ordered) == ["alpha", "zulu"])
    }

    /// An empty sort order is still a total order — newest first, which is
    /// exactly what the sheet opens on, so an empty order can never look
    /// like "unsorted garbage".
    @Test func anEmptyOrderFallsBackToNewestFirst() {
        let events = [Self.event(at: 1_000), Self.event(at: 9_000), Self.event(at: 5_000)]
        #expect(Self.times(AuditLogSorting.sorted(events, using: [])) == [9_000, 5_000, 1_000])
    }

    /// The sheet opens newest-first — the order the audit log has been
    /// shown in since it existed — so putting sortable headers on the table
    /// changes nothing about what the user sees until they click one.
    ///
    /// Asked of a real `AuditLogStore`, not of a copy of its order written
    /// here: the claim is about the events `events(for:)` hands the sheet.
    /// The store is pointed at a fresh temporary directory — no real
    /// configuration, session store or keychain is touched.
    ///
    /// The events go in oldest-first and are handed to the sort SHUFFLED,
    /// so neither "return the input untouched" nor "reverse the input"
    /// passes; only an order that actually reads the timestamps does.
    @Test func theDefaultOrderIsNewestFirstAsTheStoreHandsThemOver() {
        #expect(AuditLogSorting.defaultOrder == [AuditEventComparator(key: .time, order: .reverse)])

        let sessionID = UUID()
        let appended = (0..<5).map {
            Self.event(at: TimeInterval(1_000 + $0 * 100), detail: "entry \($0)")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-auditlog-sort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AuditLogStore(directory: directory)
        for event in appended { store.append(event, for: sessionID) }

        // The store's own contract, measured rather than assumed: it hands
        // the sheet the events in the order they were recorded.
        let fromStore = store.events(for: sessionID)
        #expect(fromStore.map(\.id) == appended.map(\.id))

        let scrambled = [fromStore[2], fromStore[0], fromStore[4], fromStore[1], fromStore[3]]
        let ordered = AuditLogSorting.sorted(scrambled, using: AuditLogSorting.defaultOrder)
        #expect(ordered.map(\.id) == fromStore.reversed().map(\.id))
    }

    /// Where the sort sits relative to the filter and the search: sorting
    /// the whole log and then filtering it gives the SAME sequence as
    /// filtering first and sorting the result. That is a property of the
    /// order being total, and it is why the sheet may sort the filter
    /// result — the cheaper and more obvious placement — without that
    /// choice being observable.
    ///
    /// It stops being true the moment the order is not total: the sheet's
    /// previous `timestamp >` comparison left rows with equal timestamps in
    /// whatever order `sorted` returned, and those two placements could
    /// then disagree. The fixture below therefore contains such rows.
    @Test func sortingBeforeAndAfterFilteringAgree() {
        let events = [
            Self.event(at: 1_000, kind: .rename, detail: "keep alpha"),
            Self.event(at: 1_000, kind: .delete, detail: "drop"),
            Self.event(at: 1_000, kind: .rename, detail: "keep beta"),
            Self.event(at: 9_000, kind: .delete, detail: "drop later"),
            Self.event(at: 5_000, kind: .rename, detail: "keep gamma"),
        ]
        let matches: (AuditEvent) -> Bool = { $0.detail.hasPrefix("keep") }
        for key in AuditSortKey.allCases {
            for order in [SortOrder.forward, .reverse] {
                let sortThenFilter = Self.sorted(events, by: key, order).filter(matches)
                let filterThenSort = Self.sorted(events.filter(matches), by: key, order)
                #expect(sortThenFilter.map(\.id) == filterThenSort.map(\.id))
            }
        }
    }

    /// Every key sorts, and sorting never loses or duplicates a row.
    /// Driven off `allCases` rather than a list written here, so a fourth
    /// column has to be classified instead of slipping past this suite.
    @Test func everyKeyIsATotalOrderOverTheSameEvents() {
        let events = [
            Self.event(at: 1_000, kind: .rename, detail: ""),
            Self.event(at: 1_000, kind: .delete, detail: "beta", isError: true, errorMessage: "why"),
            Self.event(at: 9_000, kind: .connected, detail: "alpha"),
        ]
        for key in AuditSortKey.allCases {
            for order in [SortOrder.forward, .reverse] {
                let ordered = Self.sorted(events, by: key, order)
                #expect(ordered.count == events.count)
                #expect(Set(ordered.map(\.id)) == Set(events.map(\.id)))
            }
        }
    }
}
