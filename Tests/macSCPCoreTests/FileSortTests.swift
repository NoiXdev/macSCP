import Foundation
import Testing
@testable import macSCPCore

/// Pure tests for `RemoteBrowserViewModel.sortedForDisplay(_:key:ascending:)`
/// (M11l/T1) — the sole sorting authority for the file listing, now
/// parameterized by key and direction. See the doc comment on
/// `sortedForDisplay` for the folders-first grouping and missing-value
/// rules this file pins down.
@Suite("RemoteBrowserViewModel.sortedForDisplay")
@MainActor
struct FileSortTests {
    private func file(_ name: String, size: UInt64? = nil, modifiedAt: Date? = nil) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .file, size: size, modifiedAt: modifiedAt)
    }

    private func dir(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .directory)
    }

    // MARK: - Folders always group first, for every key, both directions

    @Test func foldersFirstByNameAscending() {
        let items = [file("b.txt"), dir("Zdir"), file("a.txt")]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .name, ascending: true)
        #expect(sorted.map(\.name) == ["Zdir", "a.txt", "b.txt"])
    }

    @Test func foldersFirstByNameDescending() {
        let items = [file("b.txt"), dir("Zdir"), file("a.txt")]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .name, ascending: false)
        // Descending reverses WITHIN groups only — the folder still leads.
        #expect(sorted.map(\.name) == ["Zdir", "b.txt", "a.txt"])
    }

    @Test func foldersFirstBySizeAscending() {
        let items = [file("big.txt", size: 100), dir("adir"), file("small.txt", size: 1)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: true)
        #expect(sorted.map(\.name) == ["adir", "small.txt", "big.txt"])
    }

    @Test func foldersFirstBySizeDescending() {
        let items = [file("big.txt", size: 100), dir("adir"), file("small.txt", size: 1)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: false)
        #expect(sorted.map(\.name) == ["adir", "big.txt", "small.txt"])
    }

    @Test func foldersFirstByModifiedAscending() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let items = [file("new.txt", modifiedAt: newer), dir("adir"), file("old.txt", modifiedAt: older)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: true)
        #expect(sorted.map(\.name) == ["adir", "old.txt", "new.txt"])
    }

    @Test func foldersFirstByModifiedDescending() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let items = [file("new.txt", modifiedAt: newer), dir("adir"), file("old.txt", modifiedAt: older)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: false)
        #expect(sorted.map(\.name) == ["adir", "new.txt", "old.txt"])
    }

    // MARK: - .name ascending matches today's default; descending flips within groups

    @Test func parameterlessCallDefaultsToNameAscending() {
        let items = [file("zebra.txt"), dir("Alpha"), file("beta.txt")]
        let defaultSorted = RemoteBrowserViewModel.sortedForDisplay(items)
        let explicitSorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .name, ascending: true)
        #expect(defaultSorted.map(\.name) == explicitSorted.map(\.name))
        #expect(defaultSorted.map(\.name) == ["Alpha", "beta.txt", "zebra.txt"])
    }

    // MARK: - .size is numeric, never lexicographic

    @Test func sizeSortsNumericallyNotLexicographically() {
        // Lexicographic string order would yield 10, 100, 9 — numeric must
        // yield 9, 10, 100.
        let items = [file("a.txt", size: 100), file("b.txt", size: 9), file("c.txt", size: 10)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: true)
        #expect(sorted.map(\.size) == [9, 10, 100])
    }

    // MARK: - .modified sorts by timestamp, both directions

    @Test func modifiedSortsByTimestampAscendingAndDescending() {
        let t1 = Date(timeIntervalSince1970: 1)
        let t2 = Date(timeIntervalSince1970: 2)
        let t3 = Date(timeIntervalSince1970: 3)
        let items = [file("c.txt", modifiedAt: t3), file("a.txt", modifiedAt: t1), file("b.txt", modifiedAt: t2)]

        let ascending = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: true)
        #expect(ascending.map(\.name) == ["a.txt", "b.txt", "c.txt"])

        let descending = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: false)
        #expect(descending.map(\.name) == ["c.txt", "b.txt", "a.txt"])
    }

    // MARK: - Name tiebreaker: equal size/date sorts by name, stably

    @Test func equalSizeFallsBackToNameTiebreaker() {
        let items = [file("zebra.txt", size: 5), file("alpha.txt", size: 5), file("mid.txt", size: 5)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: true)
        #expect(sorted.map(\.name) == ["alpha.txt", "mid.txt", "zebra.txt"])
    }

    @Test func equalModifiedFallsBackToNameTiebreaker() {
        let same = Date(timeIntervalSince1970: 500)
        let items = [file("zebra.txt", modifiedAt: same), file("alpha.txt", modifiedAt: same)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: true)
        #expect(sorted.map(\.name) == ["alpha.txt", "zebra.txt"])
    }

    // MARK: - Missing size/date: deterministic position (documented: sorts as smallest/oldest)

    @Test func missingSizeSortsAsSmallestAscending() {
        let items = [file("known.txt", size: 5), file("unknown.txt", size: nil)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: true)
        #expect(sorted.map(\.name) == ["unknown.txt", "known.txt"])
    }

    @Test func missingSizeSortsAsSmallestEvenDescending() {
        // "Smallest" is a fixed identity, not a re-interpretation of
        // ascending/descending — descending still puts the missing-size
        // entry LAST (largest sizes first, "smallest" missing one at the end).
        let items = [file("known.txt", size: 5), file("unknown.txt", size: nil)]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .size, ascending: false)
        #expect(sorted.map(\.name) == ["known.txt", "unknown.txt"])
    }

    @Test func missingModifiedSortsAsOldestAscending() {
        let items = [
            file("known.txt", modifiedAt: Date(timeIntervalSince1970: 100)),
            file("unknown.txt", modifiedAt: nil),
        ]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: true)
        #expect(sorted.map(\.name) == ["unknown.txt", "known.txt"])
    }

    @Test func missingModifiedSortsAsOldestEvenDescending() {
        let items = [
            file("known.txt", modifiedAt: Date(timeIntervalSince1970: 100)),
            file("unknown.txt", modifiedAt: nil),
        ]
        let sorted = RemoteBrowserViewModel.sortedForDisplay(items, key: .modified, ascending: false)
        #expect(sorted.map(\.name) == ["known.txt", "unknown.txt"])
    }
}
