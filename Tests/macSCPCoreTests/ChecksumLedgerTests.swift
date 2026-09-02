import Foundation
import Testing

@testable import macSCPCore

/// What the per-tab checksum ledger remembers, and what it refuses to.
///
/// The ledger never computes anything; it only records the outcome of a
/// request that already happened and answers a lookup keyed on the file's
/// identity (`path`, `size`, `modifiedAt`), not on `path` alone.
@Suite("Checksum ledger")
struct ChecksumLedgerTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func item(
        path: String = "/report.csv",
        size: UInt64? = 42,
        modifiedAt: Date? = referenceDate
    ) -> RemoteFileItem {
        RemoteFileItem(name: "report.csv", path: path, kind: .file, size: size, modifiedAt: modifiedAt)
    }

    private static func digest(_ algorithm: ChecksumAlgorithm = .sha256, hex: Character = "a") -> FileChecksum {
        let length = algorithm.hexDigitCount
        return FileChecksum.computedOnRemote(algorithm, hex: String(repeating: hex, count: length))!
    }

    @Test func recordThenReadReturnsTheSameValue() {
        var ledger = ChecksumLedger()
        let file = Self.item()
        let value = Self.digest()

        ledger.record(.checksum(value), for: file)

        #expect(ledger.value(for: file, algorithm: .sha256) == value)
    }

    @Test func readingUnderADifferentAlgorithmFindsNothing() {
        var ledger = ChecksumLedger()
        let file = Self.item()
        ledger.record(.checksum(Self.digest(.sha256)), for: file)

        #expect(ledger.value(for: file, algorithm: .md5) == nil)
    }

    @Test func aDifferentSizeReadsAsAbsent() {
        var ledger = ChecksumLedger()
        let recorded = Self.item(size: 42)
        let changed = Self.item(size: 43)
        ledger.record(.checksum(Self.digest()), for: recorded)

        #expect(ledger.value(for: changed, algorithm: .sha256) == nil)
    }

    @Test func aDifferentModificationDateReadsAsAbsent() {
        var ledger = ChecksumLedger()
        let recorded = Self.item(modifiedAt: Self.referenceDate)
        let changed = Self.item(modifiedAt: Self.referenceDate.addingTimeInterval(1))
        ledger.record(.checksum(Self.digest()), for: recorded)

        #expect(ledger.value(for: changed, algorithm: .sha256) == nil)
    }

    /// Two items that both carry `nil` size and `nil` modification date
    /// still form one identity and compare equal on it — a listing that
    /// carries neither figure cannot distinguish two versions of a file
    /// either, so the ledger is not asked to do better than its input.
    @Test func nilSizeAndDateStillFormAKeyAndTwoNilsMatch() {
        var ledger = ChecksumLedger()
        let recorded = Self.item(size: nil, modifiedAt: nil)
        let lookedUp = Self.item(size: nil, modifiedAt: nil)
        ledger.record(.checksum(Self.digest()), for: recorded)

        #expect(ledger.value(for: lookedUp, algorithm: .sha256) == Self.digest())
    }

    @Test func aFailedResultRecordsNothing() {
        var ledger = ChecksumLedger()
        let file = Self.item()

        ledger.record(.failed("timed out"), for: file)

        #expect(ledger.value(for: file, algorithm: .sha256) == nil)
    }

    @Test func anUnavailableResultRecordsNothing() {
        var ledger = ChecksumLedger()
        let file = Self.item()

        ledger.record(.unavailableOnThisConnection, for: file)

        #expect(ledger.value(for: file, algorithm: .sha256) == nil)
    }

    /// The sheet's own sentence for a multipart ETag is "not the file's
    /// checksum" — the ledger holds it to the same line by simply never
    /// storing a `FileChecksum` whose provenance says so.
    @Test func aMultipartETagResultIsNotRecorded() {
        var ledger = ChecksumLedger()
        let file = Self.item()
        let multipart = FileChecksum.objectStorageETag(
            "\"\(String(repeating: "b", count: 32))-3\"")!
        #expect(!multipart.describesFileContent)

        ledger.record(.checksum(multipart), for: file)

        #expect(ledger.value(for: file, algorithm: .md5) == nil)
    }

    @Test func forgetDropsEveryAlgorithmForThatPath() {
        var ledger = ChecksumLedger()
        let file = Self.item()
        ledger.record(.checksum(Self.digest(.sha256)), for: file)
        ledger.record(.checksum(Self.digest(.md5, hex: "c")), for: file)

        ledger.forget(path: file.path)

        #expect(ledger.value(for: file, algorithm: .sha256) == nil)
        #expect(ledger.value(for: file, algorithm: .md5) == nil)
    }

    @Test func twoPathsDoNotInterfere() {
        var ledger = ChecksumLedger()
        let first = Self.item(path: "/a.csv")
        let second = Self.item(path: "/b.csv")
        let firstValue = Self.digest(.sha256, hex: "a")
        let secondValue = Self.digest(.sha256, hex: "d")

        ledger.record(.checksum(firstValue), for: first)
        ledger.record(.checksum(secondValue), for: second)

        #expect(ledger.value(for: first, algorithm: .sha256) == firstValue)
        #expect(ledger.value(for: second, algorithm: .sha256) == secondValue)

        ledger.forget(path: first.path)

        #expect(ledger.value(for: first, algorithm: .sha256) == nil)
        #expect(ledger.value(for: second, algorithm: .sha256) == secondValue)
    }
}
