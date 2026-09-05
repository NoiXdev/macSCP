import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// Task 3 (local-listing-never-blocks design, point 3): `load()`'s phase-two
/// merge, which replaces phase-one's `nil` size/modified/owner/group rows
/// with what `LocalMetadataSource.metadata(for:)` yields, one entry at a
/// time, as they arrive. `MetadataStreamFakeFS` below hand-drives that
/// stream via `AsyncStream.makeStream()` so these tests control exactly
/// when each entry "arrives", independent of any real clock or syscall —
/// mirroring `LocalFileSystemTests`' own `metadataAbandonsAStuckEntry…`
/// tests, but one layer up, at the view model.
///
/// `.timeLimit(.minutes(1))` in its own suite rather than added to the much
/// larger `RemoteBrowserViewModelTests` suite: only these tests poll via
/// `pollUntil` for a background merge Task to catch up, so only they need a
/// stated ceiling on how long that poll may run before the harness itself
/// calls it a hang (CLAUDE.md: "Tests never block the cooperative pool" —
/// every wait here is `pollUntil`'s `await Task.sleep`, never a blocking
/// wait, and the `.timeLimit` is the only clock any assertion reads).
@Suite("RemoteBrowserViewModel metadata merge", .timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserViewModelMetadataMergeTests {
    /// A `RemoteFileSystem` that ALSO conforms to `LocalMetadataSource`,
    /// whose `metadata(for:)` stream is driven entirely by the test that
    /// created it, via the `AsyncStream.Continuation`s this class collects
    /// (one per call — a test that navigates mid-stream needs to reach the
    /// FIRST, now-stale, continuation after a second call has already been
    /// made for the new directory).
    ///
    /// Plain class, not an actor: every access — the view model's merge
    /// loop (an explicitly `@MainActor` Task, per `RemoteBrowserViewModel
    /// .load()`) and every test in this `@MainActor` suite — runs on the
    /// SAME actor, so nothing here is ever touched from two threads at
    /// once; `@unchecked Sendable` states that explicitly rather than
    /// paying for an actor hop nothing needs, the same "safe by sequence"
    /// reasoning `ConnectionViewModelTests.DialFlag` already documents for
    /// itself in this test target.
    private final class MetadataStreamFakeFS: RemoteFileSystem, LocalMetadataSource, @unchecked Sendable {
        private var tree: [String: [RemoteFileItem]]
        /// One continuation per `metadata(for:)` call, in call order.
        private(set) var continuations: [AsyncStream<RemoteFileItem>.Continuation] = []
        /// One `items` array per `metadata(for:)` call, in call order — lets
        /// a test assert phase one's OWN listing (not `displayedAll`, which
        /// the merge mutates) was what got handed to the stream.
        private(set) var metadataCalls: [[RemoteFileItem]] = []

        init(tree: [String: [RemoteFileItem]]) {
            self.tree = tree
        }

        func list(path: String) async throws -> [RemoteFileItem] {
            guard let items = tree[path] else { throw RemoteFSError.notFound(path: path) }
            return items
        }

        func stat(path: String) async throws -> RemoteFileItem {
            let parent = RemotePath.parent(of: path)
            guard let siblings = tree[parent], let item = siblings.first(where: { $0.path == path }) else {
                throw RemoteFSError.notFound(path: path)
            }
            return item
        }

        func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
        func delete(path: String) async throws {}
        func createDirectory(at path: String) async throws {}
        func rename(from: String, to: String) async throws {}
        func setPermissions(path: String, permissions: UInt32) async throws {}
        func deleteTree(at path: String) async throws {}
        func disconnect() async {}
        func homeDirectoryPath() async throws -> String { "/" }

        func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem> {
            metadataCalls.append(items)
            let (stream, continuation) = AsyncStream<RemoteFileItem>.makeStream(of: RemoteFileItem.self)
            continuations.append(continuation)
            return stream
        }
    }

    /// Phase one publishes nil-sized rows immediately — `load()` returns as
    /// soon as phase one is on screen, without waiting for phase two's
    /// stream (see `RemoteBrowserViewModel.load()`'s own doc comment on
    /// `mergeTask`) — and yielding one item fills that row IN PLACE, found
    /// by `path`, once the background merge Task catches up.
    @Test func rowsAppearWithNilSizeThenFillInByPath() async throws {
        let fs = MetadataStreamFakeFS(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file),
            ]
        ])
        let vm = RemoteBrowserViewModel(fs: fs)

        await vm.load()

        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt"])
        #expect(vm.items.allSatisfy { $0.size == nil })
        #expect(fs.metadataCalls.count == 1)
        #expect(fs.metadataCalls[0].map(\.path) == ["/a.txt", "/b.txt"])

        let filledB = RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 42)
        fs.continuations[0].yield(filledB)

        try await pollUntil("b.txt's row to fill in") {
            vm.items.first(where: { $0.path == "/b.txt" })?.size == 42
        }
        #expect(vm.items.first(where: { $0.path == "/a.txt" })?.size == nil)

        fs.continuations[0].finish()
    }

    /// `.size` is fed by phase two: once every arrival is merged in (the
    /// stream finished, so the loop's final catch-up publish ran), the
    /// listing re-sorts by the now-known sizes — expected order written out
    /// explicitly, per the brief.
    @Test func sizeSortReordersOnceArrivalsAreMerged() async throws {
        let fs = MetadataStreamFakeFS(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file),
                RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file),
            ]
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        vm.sortKey = .size

        await vm.load()
        // Phase one: no sizes known yet, so `.size`'s "missing == smallest"
        // rule leaves every row tied — the name tiebreaker alone decides.
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])

        // Arrival order deliberately does NOT match the final sorted order,
        // to prove the result is a real re-sort and not just arrival order:
        // a=30, c=20, b=10 arrive in that sequence; ascending by size is
        // b(10), c(20), a(30).
        fs.continuations[0].yield(RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 30))
        fs.continuations[0].yield(RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file, size: 20))
        fs.continuations[0].yield(RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 10))
        fs.continuations[0].finish()

        try await pollUntil("the size sort to re-order after every arrival") {
            vm.items.map(\.name) == ["b.txt", "c.txt", "a.txt"]
        }
    }

    /// `.name` is NOT fed by phase two (phase one's kind/name are already
    /// final) — arrivals fill in `size` in place but must not disturb the
    /// name-sorted order, regardless of the order they arrive in.
    @Test func nameSortKeepsPhaseOneOrderAsMetadataArrives() async throws {
        let fs = MetadataStreamFakeFS(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file),
                RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file),
            ]
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        // `.name` is the default `sortKey`; set explicitly so the test
        // states its own precondition rather than relying on the default.
        vm.sortKey = .name

        await vm.load()
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])

        fs.continuations[0].yield(RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file, size: 1))
        fs.continuations[0].yield(RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 999))
        fs.continuations[0].yield(RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 50))
        fs.continuations[0].finish()

        try await pollUntil("every arrival to be merged in") {
            vm.items.allSatisfy { $0.size != nil }
        }
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(vm.items.map(\.size) == [999, 50, 1])
    }

    /// Navigating away mid-stream must both (a) cancel the old merge Task —
    /// see `RemoteBrowserViewModel.load()`'s `mergeTask` doc comment — and
    /// (b) be caught by the staleness guard inside the loop even if
    /// cancellation loses the race. A late yield on the OLD, now-stale
    /// continuation must never reach the NEW directory's listing.
    @Test func navigationMidStreamDropsLateRows() async throws {
        let fs = MetadataStreamFakeFS(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file),
                RemoteFileItem(name: "other", path: "/other", kind: .directory),
            ],
            "/other": [
                RemoteFileItem(name: "b.txt", path: "/other/b.txt", kind: .file)
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)

        await vm.load()
        #expect(vm.items.map(\.name) == ["other", "a.txt"])
        #expect(fs.continuations.count == 1)
        let staleContinuation = fs.continuations[0]

        let error = await vm.navigate(to: "/other")

        #expect(error == nil)
        #expect(vm.currentPath == "/other")
        #expect(vm.items.map(\.name) == ["b.txt"])
        #expect(fs.metadataCalls.count == 2, "the new directory's own metadata(for:) call")

        // A late arrival for the directory the user already left.
        staleContinuation.yield(RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 12345))
        staleContinuation.finish()
        // No `pollUntil` needed for an ABSENCE: give the merge loop's own
        // Task a chance to run at all (a single `Task.yield()`), then
        // assert nothing changed — a poll would only prove "eventually
        // true," never "never happens."
        await Task.yield()
        await Task.yield()

        #expect(vm.currentPath == "/other")
        #expect(vm.items.map(\.name) == ["b.txt"])
        #expect(vm.items.first?.size == nil)

        // And the NEW directory's own stream still merges normally —
        // proving the guard/cancellation dropped ONLY the stale arrival,
        // not the new directory's own metadata wiring.
        fs.continuations[1].yield(RemoteFileItem(name: "b.txt", path: "/other/b.txt", kind: .file, size: 7))
        try await pollUntil("the new directory's own arrival to merge") {
            vm.items.first?.size == 7
        }
        fs.continuations[1].finish()
    }

    /// A stream that never finishes (one entry permanently stuck, Task 2's
    /// accepted cost) must not keep `state` from being `.loaded` — phase one
    /// publishes and `load()` returns regardless of whether phase two's
    /// stream ever completes.
    @Test func unfinishedStreamDoesNotKeepStateFromBeingLoaded() async throws {
        let fs = MetadataStreamFakeFS(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file)]
        ])
        let vm = RemoteBrowserViewModel(fs: fs)

        await vm.load()

        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["a.txt"])
        #expect(vm.items.first?.size == nil)
        // Deliberately never finished or yielded to — `fs.continuations[0]`
        // is left open, standing in for a permanently stuck entry.
    }
}
