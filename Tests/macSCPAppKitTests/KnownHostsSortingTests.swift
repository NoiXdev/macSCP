import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Pins the comparison rule behind each column of the known-hosts table:
/// which field a column keys on, how it compares two present values, and
/// where a value that is MISSING lands.
///
/// The missing half is the reason this suite exists rather than a
/// `KeyPathComparator` per column. Two of the five columns can be missing a
/// value on real data:
///
/// - `addedAt` is optional in `KnownHostKey` for decode compatibility —
///   every entry written before it existed reads as `nil`.
/// - `fingerprintSHA256` is DERIVED from the stored blob, and Core hands
///   back a `SHA256:?` placeholder when that blob is not valid base64 (a
///   truncated or hand-edited known_hosts.json). Compared as text, that
///   placeholder lands wherever `?` happens to fall among base64 digits,
///   which is the definition of an arbitrary position.
///
/// Neither is decided by "whatever the default comparator does with it"
/// here; both are stated, and both are stated the way the file browser
/// already states the same two shapes (`RemoteBrowserViewModel`): a missing
/// DATE is the oldest possible date, a missing STRING is the greatest
/// possible string. Same app, same reflexes.
///
/// This suite proves the rules. It does not prove `KnownHostsSheet` asks
/// them — no test in this project renders a view;
/// `KnownHostsSortWiringGuardTests` is the wiring half.
@Suite("Known-hosts sorting")
struct KnownHostsSortingTests {
    // MARK: - Fixtures

    /// A blob that Core CAN derive a fingerprint from.
    private static func validBlob(_ seed: String) -> String {
        Data(seed.utf8).base64EncodedString()
    }

    /// Not valid base64 — `HostKeyFingerprint.sha256` returns nil for it,
    /// which is exactly the state that makes `fingerprintSHA256` fall back
    /// to its placeholder.
    private static let underivableBlob = "not base64!!"

    private static func row(
        host: String = "example.test",
        port: Int = 22,
        keyType: String = "ssh-ed25519",
        blob: String = validBlob("default"),
        addedAt: Date? = Date(timeIntervalSince1970: 1_000)
    ) -> KnownHostRow {
        KnownHostRow(
            key: KnownHostKey(
                host: host, port: port, keyType: keyType,
                publicKeyBase64: blob, addedAt: addedAt))
    }

    private static func hosts(_ rows: [KnownHostRow]) -> [String] {
        rows.map(\.key.host)
    }

    private static func sorted(
        _ rows: [KnownHostRow], by key: KnownHostSortKey, _ order: SortOrder = .forward
    ) -> [KnownHostRow] {
        KnownHostsSorting.sorted(rows, using: [KnownHostComparator(key: key, order: order)])
    }

    // MARK: - The fixture itself

    /// Guards the two blobs the rest of the suite reasons about: if Core
    /// ever derived a fingerprint from garbage, or stopped deriving one
    /// from a valid blob, the missing-fingerprint tests below would still
    /// pass while testing nothing.
    @Test func theFixtureBlobsAreWhatTheSuiteAssumes() {
        #expect(Self.row(blob: Self.validBlob("default")).derivedFingerprint != nil)
        #expect(Self.row(blob: Self.underivableBlob).derivedFingerprint == nil)
        #expect(Self.row(blob: Self.underivableBlob).key.fingerprintSHA256 == "SHA256:?")
    }

    // MARK: - One rule per column

    /// Hosts read as names: A→Z, ascending by default.
    @Test func theHostColumnOrdersHostsAlphabetically() {
        let rows = [Self.row(host: "zulu.test"), Self.row(host: "alpha.test")]
        #expect(Self.hosts(Self.sorted(rows, by: .host)) == ["alpha.test", "zulu.test"])
    }

    /// The port column keys on the NUMBER, not on the text the cell draws.
    /// Sorting the rendered strings would read 22 as greater than 2222.
    @Test func thePortColumnOrdersPortsNumerically() {
        let rows = [
            Self.row(host: "c.test", port: 2222),
            Self.row(host: "a.test", port: 22),
            Self.row(host: "b.test", port: 100),
        ]
        #expect(Self.sorted(rows, by: .port).map(\.key.port) == [22, 100, 2222])
    }

    /// A key type is the NAME of an algorithm, so its case carries no
    /// meaning: `SSH-RSA` and `ssh-rsa` are one algorithm and must sort as
    /// one. A byte-wise comparison would file every upper-case spelling
    /// ahead of every lower-case one.
    @Test func theKeyTypeColumnIgnoresCase() {
        let rows = [
            Self.row(host: "b.test", keyType: "SSH-RSA"),
            Self.row(host: "a.test", keyType: "ssh-ed25519"),
        ]
        #expect(
            Self.sorted(rows, by: .keyType).map(\.key.keyType) == ["ssh-ed25519", "SSH-RSA"])
    }

    /// A fingerprint is an identity, not a name: base64 is case-SENSITIVE,
    /// and two fingerprints differing only in case are two different keys —
    /// a case-insensitive comparison would call them equal. These two blobs
    /// are picked because their fingerprints (`SHA256:XI…` and `SHA256:ef…`)
    /// order one way byte-wise and the other way case-insensitively, so the
    /// assertion below distinguishes the two rules instead of agreeing with
    /// both.
    @Test func theFingerprintColumnComparesCaseSensitively() {
        let rows = [
            Self.row(host: "b.test", blob: Self.validBlob("host-key-3")),
            Self.row(host: "a.test", blob: Self.validBlob("host-key-2")),
        ]
        #expect(Self.hosts(Self.sorted(rows, by: .fingerprint)) == ["a.test", "b.test"])
    }

    /// Dates read as dates, oldest first ascending.
    @Test func theAddedColumnOrdersDatesOldestFirst() {
        let rows = [
            Self.row(host: "b.test", addedAt: Date(timeIntervalSince1970: 9_000)),
            Self.row(host: "a.test", addedAt: Date(timeIntervalSince1970: 1_000)),
        ]
        #expect(Self.hosts(Self.sorted(rows, by: .added)) == ["a.test", "b.test"])
    }

    // MARK: - Missing values

    /// An entry written before `addedAt` existed has no date. It is the
    /// OLDEST possible date — first ascending — because that is what it
    /// factually is: it was trusted before the app started recording when.
    @Test func aMissingDateSortsAsTheOldestDate() {
        let rows = [
            Self.row(host: "b.test", addedAt: Date(timeIntervalSince1970: 1_000)),
            Self.row(host: "a.test", addedAt: nil),
            Self.row(host: "c.test", addedAt: Date(timeIntervalSince1970: 9_000)),
        ]
        #expect(Self.hosts(Self.sorted(rows, by: .added)) == ["a.test", "b.test", "c.test"])
    }

    /// Reversing the column moves the missing date to the other END. What
    /// must NOT happen is the missing one staying put, or landing in the
    /// middle: its identity ("oldest") is fixed, only which end that is
    /// flips.
    @Test func aMissingDateSortsLastWhenTheColumnIsReversed() {
        let rows = [
            Self.row(host: "b.test", addedAt: Date(timeIntervalSince1970: 1_000)),
            Self.row(host: "a.test", addedAt: nil),
            Self.row(host: "c.test", addedAt: Date(timeIntervalSince1970: 9_000)),
        ]
        #expect(
            Self.hosts(Self.sorted(rows, by: .added, .reverse)) == ["c.test", "b.test", "a.test"])
    }

    /// A fingerprint that could not be derived is the GREATEST possible
    /// string — last ascending. It is the one row the user can do nothing
    /// with, so it belongs at the end of the list rather than wedged
    /// between two real fingerprints, which is where its `SHA256:?`
    /// placeholder would land as plain text.
    @Test func anUnderivableFingerprintSortsLast() {
        let rows = [
            Self.row(host: "b.test", blob: Self.underivableBlob),
            Self.row(host: "a.test", blob: Self.validBlob("host-key-2")),
            Self.row(host: "c.test", blob: Self.validBlob("host-key-3")),
        ]
        let ordered = Self.sorted(rows, by: .fingerprint)
        #expect(ordered.last?.key.host == "b.test")
        #expect(ordered.last?.derivedFingerprint == nil)
    }

    /// The mirror of the date case: reversing moves it to the front, it
    /// never sits in the middle.
    @Test func anUnderivableFingerprintSortsFirstWhenTheColumnIsReversed() {
        let rows = [
            Self.row(host: "b.test", blob: Self.underivableBlob),
            Self.row(host: "a.test", blob: Self.validBlob("host-key-2")),
            Self.row(host: "c.test", blob: Self.validBlob("host-key-3")),
        ]
        #expect(Self.sorted(rows, by: .fingerprint, .reverse).first?.key.host == "b.test")
    }

    /// Two rows that are both missing the same value are equal under that
    /// column and fall through to the tiebreaker — not into whatever order
    /// `sorted` happened to receive them in.
    @Test func twoMissingDatesFallThroughToTheTiebreaker() {
        let rows = [Self.row(host: "z.test", addedAt: nil), Self.row(host: "a.test", addedAt: nil)]
        #expect(Self.hosts(Self.sorted(rows, by: .added)) == ["a.test", "z.test"])
        #expect(Self.hosts(Self.sorted(rows, by: .added, .reverse)) == ["a.test", "z.test"])
    }

    // MARK: - Ties and direction

    /// Rows equal under the sorted column keep a fixed order — host, then
    /// port, always ascending. Without it `sorted(by:)` is free to return
    /// either, and the table would reshuffle equal rows on an unrelated
    /// redraw.
    @Test func equalRowsAreBrokenByHostThenPort() {
        let rows = [
            Self.row(host: "b.test", port: 22),
            Self.row(host: "a.test", port: 2222),
            Self.row(host: "a.test", port: 22),
        ]
        let ordered = Self.sorted(rows, by: .keyType)
        #expect(ordered.map { "\($0.key.host):\($0.key.port)" } == ["a.test:22", "a.test:2222", "b.test:22"])
    }

    /// The tiebreaker does NOT follow the column's direction: rows that
    /// tie still read A→Z under a reversed sort, the same way the file
    /// browser keeps its name tiebreaker ascending in a descending sort.
    @Test func theTiebreakerStaysAscendingUnderAReversedSort() {
        let rows = [
            Self.row(host: "b.test", keyType: "ssh-rsa"),
            Self.row(host: "a.test", keyType: "ssh-rsa"),
        ]
        #expect(Self.hosts(Self.sorted(rows, by: .keyType, .reverse)) == ["a.test", "b.test"])
    }

    /// Reversing a column reverses that column, and nothing else about the
    /// result is different.
    @Test func reversingAColumnReversesThatColumn() {
        let rows = [Self.row(host: "a.test"), Self.row(host: "z.test")]
        #expect(Self.hosts(Self.sorted(rows, by: .host, .reverse)) == ["z.test", "a.test"])
    }

    // MARK: - The order as a whole

    /// A second comparator decides rows the first one calls equal, and it
    /// decides them BEFORE the fixed tiebreaker gets a say — otherwise the
    /// table's secondary sort would be dead weight. The expectation is the
    /// OPPOSITE of what the tiebreaker alone would produce, so a build that
    /// ignored the second comparator fails here rather than agreeing by
    /// accident.
    @Test func aSecondComparatorDecidesRowsTheFirstCallsEqual() {
        let rows = [
            Self.row(host: "a.test", port: 22, keyType: "ssh-ed25519"),
            Self.row(host: "b.test", port: 22, keyType: "ssh-rsa"),
            Self.row(host: "c.test", port: 2222, keyType: "ssh-rsa"),
        ]
        let ordered = KnownHostsSorting.sorted(
            rows,
            using: [
                KnownHostComparator(key: .port),
                KnownHostComparator(key: .keyType, order: .reverse),
            ])
        #expect(Self.hosts(ordered) == ["b.test", "a.test", "c.test"])
    }

    /// An empty sort order is still a total order: the tiebreaker alone,
    /// which is exactly the order `KnownHostsStore.allKeys()` hands the
    /// sheet — so an empty order can never look like "unsorted garbage".
    @Test func anEmptyOrderFallsBackToHostThenPort() {
        let rows = [
            Self.row(host: "b.test", port: 22),
            Self.row(host: "a.test", port: 2222),
            Self.row(host: "a.test", port: 22),
        ]
        let ordered = KnownHostsSorting.sorted(rows, using: [])
        #expect(ordered.map { "\($0.key.host):\($0.key.port)" } == ["a.test:22", "a.test:2222", "b.test:22"])
    }

    /// The sheet opens on the order the store already returns, so putting
    /// sortable headers on the table changes nothing about what the user
    /// sees until they click one.
    ///
    /// Asked of a real `KnownHostsStore`, not of a copy of its sort written
    /// here: the claim is about the order `allKeys()` hands the sheet, and a
    /// copy would go on agreeing with itself after `allKeys()` changed. The
    /// store is pointed at a fresh temporary directory — no real
    /// configuration is read or written.
    @Test func theDefaultOrderMatchesWhatTheStoreReturns() throws {
        #expect(KnownHostsSorting.defaultOrder == [KnownHostComparator(key: .host, order: .forward)])

        // Hosts and ports picked so that host-then-port and port-then-host
        // disagree; under keys that ordered alike, this test would pass
        // whatever the store did.
        let keys = [
            KnownHostKey(host: "b.test", port: 22, keyType: "ssh-rsa", publicKeyBase64: Self.validBlob("b")),
            KnownHostKey(host: "a.test", port: 2222, keyType: "ssh-rsa", publicKeyBase64: Self.validBlob("a")),
            KnownHostKey(host: "a.test", port: 22, keyType: "ssh-rsa", publicKeyBase64: Self.validBlob("c")),
        ]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-knownhosts-sort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        for key in keys { try store.upsert(key) }

        let fromStore = try store.allKeys()
        #expect(fromStore.count == keys.count)
        // Sorted from the REVERSE of what the store returned, so a sort that
        // did nothing at all would fail here too.
        let ordered = KnownHostsSorting.sorted(
            fromStore.reversed().map(KnownHostRow.init), using: KnownHostsSorting.defaultOrder)
        #expect(ordered.map(\.id) == fromStore.map { "\($0.host):\($0.port)" })
    }

    /// Every key sorts, and sorting never loses or duplicates a row.
    /// Driven off `allCases` rather than a list written here, so a sixth
    /// column has to be classified instead of slipping past this suite.
    @Test func everyKeyIsATotalOrderOverTheSameRows() {
        let rows = [
            Self.row(host: "b.test", port: 22, keyType: "ssh-rsa", blob: Self.underivableBlob),
            Self.row(host: "a.test", port: 2222, keyType: "SSH-RSA", addedAt: nil),
            Self.row(host: "c.test", port: 22, keyType: "ssh-ed25519", blob: Self.validBlob("c")),
        ]
        for key in KnownHostSortKey.allCases {
            for order in [SortOrder.forward, .reverse] {
                let ordered = Self.sorted(rows, by: key, order)
                #expect(ordered.count == rows.count)
                #expect(Set(ordered.map(\.id)) == Set(rows.map(\.id)))
            }
        }
    }
}
