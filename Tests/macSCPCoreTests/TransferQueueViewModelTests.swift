import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferQueueViewModel")
@MainActor
struct TransferQueueViewModelTests {

    // MARK: - Test doubles (signal-based, no sleeps)

    /// One-shot signal: `wait()` blocks until `fire()` is called; if the
    /// waiting task is cancelled, `wait()` throws `CancellationError`. This
    /// lets a gated transfer be cancelled without `fire()` ever arriving.
    actor TestSignal {
        private var fired = false
        private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

        func fire() {
            fired = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending.values { continuation.resume() }
        }

        func wait() async throws {
            if fired { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if fired {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuations[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        private func cancelWaiter(_ id: UUID) {
            if let continuation = continuations.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Controllable file system: content plus optional signals per source path
    /// (`started` fires on the first chunk pull, `gate` blocks before it).
    /// Unregistered paths make `stat` throw `RemoteFSError.notFound`.
    /// Writes are logged in order.
    actor QueueTestFS: RemoteFileSystem {
        struct Read {
            var content: Data
            var started: TestSignal?
            var gate: TestSignal?
            /// Cancellation-UNAWARE parking before the chunk at this index: the
            /// `readStream` loop waits there via `Task.isCancelled` (does NOT
            /// throw). This is the only way cancelling a running transfer is
            /// caught exclusively via `copyFile`'s `checkCancellation` (M5c/T2) —
            /// not via a cancellation-aware `gate`.
            var spinUntilCancelledAt: Int?
            /// If set, `readStream` throws this on the first pull (after
            /// `started`/`gate`) — simulates a mid-transfer failure (M5d/T3):
            /// `connectionFailed` exercises the `.interrupted` path, any other
            /// error the `.failed` path.
            var failWith: Error?
        }

        private var reads: [String: Read]
        /// Directory contents per path — the basis for tree expansion (M5b/T3).
        private var listings: [String: [RemoteFileItem]]
        private var written: [String: Data] = [:]
        private(set) var writeOrder: [String] = []
        /// Order of `createDirectory` calls — tests use this to verify the
        /// top-down creation of destination directories (M5b/T3).
        private(set) var createdDirectories: [String] = []
        /// Paths removed via `delete`, in call order (M5d/T1 groundwork).
        /// Recording only — no error simulation needed here yet, that lives
        /// in LocalFileSystemTests/MockRemoteFileSystem.
        private(set) var deletedPaths: [String] = []
        /// Write mode used by the most recent `write` per path (M5d/T3) — the
        /// resume tests assert `.append` was used, not `.overwrite`.
        private(set) var writeModes: [String: WriteMode] = [:]
        /// Offset requested by the most recent `readStream` per path (M5d/T3) —
        /// the resume tests assert the source was re-read from the partial size.
        private(set) var readOffsets: [String: UInt64] = [:]
        /// Signal gate for `stat`, isolated from the chunk gating (`Read.started/gate`
        /// above): lets tests hold open EXACTLY the stat await in `resolveConflictIfNeeded`
        /// (M5b/T2 review fix, no-decider variant). `statEntered`
        /// fires as soon as `stat` is entered — before that, `statGate` waits, if
        /// set.
        private var statEntered: TestSignal?
        private var statGate: TestSignal?
        /// Per-path stat gates (M6a/T3 review, I-2/finding d): lets a test
        /// hold open ONE specific stat call (e.g. a rename-candidate probe)
        /// while every other stat call on the same instance stays ungated —
        /// unlike `statGate` above, which gates every call indiscriminately.
        private var statGates: [String: TestSignal]
        /// Every path passed to `stat`, in call order — lets a test detect
        /// that a SPECIFIC stat call has been entered (and is possibly parked
        /// behind `statGate`/`statGates`) without needing a dedicated
        /// "entered" signal per path.
        private(set) var statedPaths: [String] = []
        /// Analogous for `list`: lets tests pin down tree expansion at a
        /// `list` await (cancelAll-during-expansion, M5b/T3).
        private var listEntered: TestSignal?
        private var listGate: TestSignal?
        /// Per-path list gates (M6a/T3 review, I-1): lets a test hold open
        /// ONE specific `list` call (e.g. a subdirectory expansion) while
        /// every other `list` call on the same instance stays ungated.
        private var listGates: [String: TestSignal]
        /// Every path passed to `list`, in call order — analogous to
        /// `statedPaths`.
        private(set) var listedPaths: [String] = []
        /// Tracks how many `write` calls are in flight at once (peak) — the
        /// parallel-slot tests assert the peak never exceeds `maxConcurrent`.
        private let concurrency: ConcurrencyTracker?

        init(
            reads: [String: Read],
            listings: [String: [RemoteFileItem]] = [:],
            statEntered: TestSignal? = nil, statGate: TestSignal? = nil,
            statGates: [String: TestSignal] = [:],
            listEntered: TestSignal? = nil, listGate: TestSignal? = nil,
            listGates: [String: TestSignal] = [:],
            concurrency: ConcurrencyTracker? = nil
        ) {
            self.reads = reads
            self.listings = listings
            self.statEntered = statEntered
            self.statGate = statGate
            self.statGates = statGates
            self.listEntered = listEntered
            self.listGate = listGate
            self.listGates = listGates
            self.concurrency = concurrency
        }

        func list(path: String) async throws -> [RemoteFileItem] {
            listedPaths.append(path)
            await listEntered?.fire()
            if let listGate { try await listGate.wait() }
            if let gate = listGates[path] { try await gate.wait() }
            if let entries = listings[path] { return entries }
            throw RemoteFSError.notFound(path: path)
        }

        func stat(path: String) async throws -> RemoteFileItem {
            statedPaths.append(path)
            await statEntered?.fire()
            if let statGate { try await statGate.wait() }
            if let gate = statGates[path] { try await gate.wait() }
            guard let read = reads[path] else { throw RemoteFSError.notFound(path: path) }
            let name = String(path.split(separator: "/").last ?? Substring(path))
            return RemoteFileItem(name: name, path: path, kind: .file, size: UInt64(read.content.count))
        }

        func readStream(
            path: String, fromOffset offset: UInt64
        ) async throws -> AsyncThrowingStream<Data, Error> {
            guard let read = reads[path] else { throw RemoteFSError.notFound(path: path) }
            readOffsets[path] = offset
            let start = min(Int(offset), read.content.count)
            let chunks = QueueTestFS.chunked(read.content.subdata(in: start..<read.content.count))
            let started = read.started
            let gate = read.gate
            let spinAt = read.spinUntilCancelledAt
            let failWith = read.failWith
            var index = 0
            var opened = false
            return AsyncThrowingStream<Data, Error>(unfolding: {
                if !opened {
                    opened = true
                    await started?.fire()
                    if let gate { try await gate.wait() }
                    if let failWith { throw failWith }
                }
                if let spinAt, index == spinAt {
                    // Park cancellation-UNAWARE: only the cancellation wakes the
                    // loop; the chunk is still delivered afterwards, the next
                    // pull is covered by the engine's `checkCancellation`.
                    while !Task.isCancelled { await Task.yield() }
                }
                guard index < chunks.count else { return nil }
                defer { index += 1 }
                return chunks[index]
            })
        }

        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
            await concurrency?.enter()
            var collected = Data()
            do {
                for try await chunk in contents { collected.append(chunk) }
            } catch {
                await concurrency?.leave()
                throw error
            }
            writeModes[path] = mode
            switch mode {
            case .overwrite:
                written[path] = collected
            case .append:
                written[path] = (written[path] ?? Data()) + collected
            }
            writeOrder.append(path)
            await concurrency?.leave()
        }

        func writtenData(at path: String) -> Data? { written[path] }

        func delete(path: String) async throws {
            deletedPaths.append(path)
        }

        /// Logs the call (for order checks of the top-down
        /// creation) and is otherwise an idempotent no-op — this double doesn't
        /// know any real collision cases.
        func createDirectory(at path: String) async throws {
            createdDirectories.append(path)
        }

        func rename(from: String, to: String) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }

        func setPermissions(path: String, permissions: UInt32) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }

        func deleteTree(at path: String) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }

        func disconnect() async {}

        private static func chunked(_ data: Data) -> [Data] {
            guard !data.isEmpty else { return [] }
            var chunks: [Data] = []
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                chunks.append(data.subdata(in: offset..<end))
                offset = end
            }
            return chunks
        }
    }

    // MARK: - Small helpers

    /// MainActor counter for `onCompleted` calls.
    @MainActor final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    /// Tracks the number of concurrently-active writes and the peak reached.
    /// Used by the parallel-slot tests to prove at most `maxConcurrent`
    /// transfers run at once.
    actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// Polls (with `Task.yield`) for a condition so tests don't depend on fixed
    /// sleeps. Only for states without their own signal.
    @MainActor func waitUntil(
        _ condition: @MainActor () -> Bool,
        limit: Int = 100_000
    ) async {
        var iterations = 0
        while !condition() && iterations < limit {
            await Task.yield()
            iterations += 1
        }
    }

    /// Runs `op` and reports whether it returned within `timeout`. Does NOT
    /// wait on `op` itself (no hang on a regression), but polls
    /// a done flag. For the cancellation-timeout race in test M5c/T2.
    @MainActor func completesWithin(
        _ timeout: Duration, _ op: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let done = Counter()
        Task { @MainActor in await op(); done.increment() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if done.value > 0 { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return done.value > 0
    }

    // MARK: - 1

    @Test func enqueueRunsTransferAndFinishes() async throws {
        let content = Data("hallo welt".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        // Right after enqueue (no await yet): deterministically queued.
        #expect(vm.items.count == 1)
        #expect(vm.items[0].status == .queued)

        try await started.wait()
        #expect(vm.items[0].status.isRunning)

        await gate.fire()
        try await done.wait()

        #expect(vm.items[0].status == .finished)
        #expect(counter.value == 1)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 2

    @Test func secondEnqueueDuringRunningIsQueuedNotDropped() async throws {
        let content = Data("x".utf8)
        let started1 = TestSignal()
        let gate1 = TestSignal()
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])
        let done1 = TestSignal()
        let done2 = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: item 2 must stay .queued while item 1 runs
        vm.enqueue(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done1.fire() })
        vm.enqueue(
            fileName: "2.txt", direction: .upload,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done2.fire() })

        try await started1.wait()
        // Item 1 is running, item 2 was NOT dropped, but is waiting.
        #expect(vm.items[0].status.isRunning)
        #expect(vm.items[1].status == .queued)

        await gate1.fire()
        try await done1.wait()
        try await done2.wait()

        #expect(vm.items[0].status == .finished)
        #expect(vm.items[1].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/1.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 3

    @Test func itemsRunInFIFOOrder() async throws {
        let content = Data("y".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
            "/3.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: serial completion order is asserted
        for name in ["1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }
        vm.enqueue(
            fileName: "3.txt", direction: .upload,
            source: source, sourcePath: "/3.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()

        #expect(await destination.writeOrder == ["/ziel/1.txt", "/ziel/2.txt", "/ziel/3.txt"])
    }

    // MARK: - 4

    @Test func failedItemDoesNotBlockQueue() async throws {
        let content = Data("z".utf8)
        // /1.txt is NOT registered → stat throws notFound.
        let source = QueueTestFS(reads: ["/2.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [:])
        let done2 = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "1.txt", direction: .download,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        vm.enqueue(
            fileName: "2.txt", direction: .download,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done2.fire() })

        try await done2.wait()

        #expect(vm.items[0].status == .failed(
            String(format: CoreL10n.string("core.transfer.notFound %@"), "/1.txt")))
        #expect(vm.items[1].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 5

    @Test func enqueueAndWaitReturnsAfterCompletion() async throws {
        let content = Data("w".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        let returned = Counter()
        let waitTask = Task { @MainActor in
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .download,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
            returned.increment()
        }

        try await started.wait()
        // Still running → enqueueAndWait has NOT returned.
        #expect(returned.value == 0)
        #expect(vm.items[0].status.isRunning)

        await gate.fire()
        try await waitTask.value

        #expect(returned.value == 1)
        #expect(vm.items[0].status == .finished)
    }

    // MARK: - 6

    @Test func enqueueAndWaitThrowsOnFailure() async throws {
        // /a.txt not registered → stat throws notFound → enqueueAndWait throws.
        let source = QueueTestFS(reads: [:])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        await #expect(throws: RemoteFSError.self) {
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .download,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
        }
        #expect(vm.items[0].status == .failed(
            String(format: CoreL10n.string("core.transfer.notFound %@"), "/a.txt")))
    }

    // MARK: - 7

    @Test func cancelAllCancelsQueuedAndRunning() async throws {
        let content = Data("c".utf8)
        let started1 = TestSignal()
        let gate1 = TestSignal()   // never fired; cancel must release it
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content),
            "/3.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: item 2 must stay .queued until cancelAll
        vm.enqueue(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        // Item 2 with a waiting enqueueAndWait — must throw on cancel.
        let waiterThrew = Counter()
        let waitTask = Task { @MainActor in
            do {
                try await vm.enqueueAndWait(
                    fileName: "2.txt", direction: .upload,
                    source: source, sourcePath: "/2.txt",
                    destination: destination, destinationDirectory: "/ziel")
            } catch {
                waiterThrew.increment()
            }
        }

        // Wait until item 1 is running AND item 2 is enqueued.
        try await started1.wait()
        await waitUntil { vm.items.count == 2 && vm.items[1].status == .queued }

        await vm.cancelAll()

        #expect(vm.items[1].status == .cancelled)          // queued → cancelled immediately
        #expect(vm.items[0].status == .cancelled)          // running → cancelled, NOT failed
        await waitTask.value
        #expect(waiterThrew.value == 1)                     // waiting enqueueAndWait threw
        #expect(vm.isActive == false)

        // Worker restart after cancelAll: a new enqueue starts running again.
        let done3 = TestSignal()
        vm.enqueue(
            fileName: "3.txt", direction: .upload,
            source: source, sourcePath: "/3.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done3.fire() })
        try await done3.wait()
        #expect(vm.items.last?.status == .finished)
        #expect(vm.isActive == false)
    }

    // MARK: - 8

    @Test func clearCompletedRemovesOnlyDone() async throws {
        let content = Data("d".utf8)
        let startedX = TestSignal()
        let gateX = TestSignal()
        let startedC = TestSignal()
        let gateC = TestSignal()
        let source = QueueTestFS(reads: [
            "/x.txt": .init(content: content, started: startedX, gate: gateX),   // will be cancelled
            "/a.txt": .init(content: content),                                    // finished
            // /b.txt is missing → failed
            "/c.txt": .init(content: content, started: startedC, gate: gateC),   // stays running
            "/d.txt": .init(content: content),                                    // stays queued
        ])
        let destination = QueueTestFS(reads: [:])
        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: item D must stay .queued behind running C

        // cancelled: start X, then cancelAll.
        vm.enqueue(
            fileName: "x.txt", direction: .upload,
            source: source, sourcePath: "/x.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedX.wait()
        await vm.cancelAll()
        #expect(vm.items[0].status == .cancelled)

        // finished: A via enqueueAndWait.
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        // failed: B via enqueueAndWait (throws), status failed.
        _ = try? await vm.enqueueAndWait(
            fileName: "b.txt", direction: .upload,
            source: source, sourcePath: "/b.txt",
            destination: destination, destinationDirectory: "/ziel")

        // running C + queued D.
        vm.enqueue(
            fileName: "c.txt", direction: .upload,
            source: source, sourcePath: "/c.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedC.wait()
        vm.enqueue(
            fileName: "d.txt", direction: .upload,
            source: source, sourcePath: "/d.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)

        // State before cleanup: cancelled, finished, failed, running, queued.
        #expect(vm.items.count == 5)
        #expect(vm.items[3].status.isRunning)
        #expect(vm.items[4].status == .queued)

        vm.clearCompleted()

        // Only running + queued remain.
        #expect(vm.items.count == 2)
        #expect(vm.items[0].fileName == "c.txt")
        #expect(vm.items[0].status.isRunning)
        #expect(vm.items[1].fileName == "d.txt")
        #expect(vm.items[1].status == .queued)

        // Cleanup: cancel C/D so no task is left hanging.
        await vm.cancelAll()
    }

    // MARK: - 9

    @Test func isActiveReflectsPendingWork() async throws {
        let content = Data("e".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        #expect(vm.isActive == false)

        vm.enqueue(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })
        #expect(vm.isActive == true)

        try await started.wait()
        #expect(vm.isActive == true)
        #expect(vm.pendingCount == 1)

        await gate.fire()
        try await done.wait()
        await waitUntil { vm.isActive == false }
        #expect(vm.isActive == false)
        #expect(vm.pendingCount == 0)
    }

    // MARK: - Conflict tests (M5b/T2)

    /// Actor counter for decider calls from a `@Sendable` closure.
    actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - 10

    /// Without a decider set, a conflict behaves like M5a: overwrite.
    @Test func conflictWithoutDeciderOverwrites() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        // Target already exists → conflict.
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    /// Editor write-backs (M5e/T3) skip the conflict check by design: even when
    /// the destination already exists, the decider is NOT consulted and the item
    /// finishes with an overwrite.
    @Test func editUploadBypassesConflictCheck() async throws {
        let content = Data("edited".utf8)
        let localURL = URL(fileURLWithPath: "/private/tmp/macscp-edit-test/a.txt")
        // Source = local stand-in reading the temp file at localURL.path.
        let source = QueueTestFS(reads: [
            localURL.path(percentEncoded: false): .init(content: content),
        ])
        // Destination already HAS the file — if the conflict check ran, the
        // decider would be consulted (and stat would find it).
        let destination = QueueTestFS(reads: ["/remote/a.txt": .init(content: Data("old".utf8))])
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, false) }
        let id = vm.enqueueEditUpload(
            fileName: "a.txt", localURL: localURL,
            source: source, destination: destination, remoteDirectory: "/remote")

        await waitUntil { vm.items.first(where: { $0.id == id })?.status == .finished }

        #expect(await calls.count == 0)                       // decider never called
        #expect(vm.items.first(where: { $0.id == id })?.status == .finished)
        #expect(vm.items.first(where: { $0.id == id })?.direction == .upload)
        #expect(await destination.writtenData(at: "/remote/a.txt") == content)
    }

    // MARK: - 11

    /// `.skip` marks the item `.skipped`, doesn't write, and doesn't call onCompleted.
    @Test func deciderSkipMarksSkippedAndSkipsWrite() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])
        let counter = Counter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.skip, false) }
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment() })

        await waitUntil { vm.items[0].status == .skipped }
        #expect(vm.items[0].status == .skipped)
        #expect(counter.value == 0)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // no write
    }

    // MARK: - 12

    /// `.overwrite` rewrites the target.
    @Test func deciderOverwriteWrites() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.overwrite, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 13

    /// `.rename` looks for the next free name: "(2)" taken → ends up at "(3)".
    @Test func deciderRenameWritesUnderFreeName() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [
            "/ziel/a.txt": .init(content: Data("alt".utf8)),        // conflict
            "/ziel/a (2).txt": .init(content: Data("belegt".utf8)), // (2) taken
        ])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.rename, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(vm.items[0].fileName == "a (3).txt")
        #expect(await destination.writtenData(at: "/ziel/a (3).txt") == content)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // original untouched
    }

    // MARK: - 14

    /// Decider returns nil (cancel) → item `.cancelled`, enqueueAndWait throws.
    @Test func deciderCancelCancelsItem() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in nil }
        await #expect(throws: CancellationError.self) {
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .upload,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
        }
        #expect(vm.items[0].status == .cancelled)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // no write
    }

    // MARK: - 15

    /// `applyToAll == true` sets a rule: the second conflict doesn't ask again.
    @Test func applyToAllAsksOnlyOnce() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [
            "/ziel/1.txt": .init(content: Data("alt".utf8)),
            "/ziel/2.txt": .init(content: Data("alt".utf8)),
        ])
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: the "apply to all" rule must be set before item 2 resolves
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, true) }
        for name in ["1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }

        await waitUntil { vm.items.count == 2 && vm.items.allSatisfy { $0.status == .finished } }
        #expect(await calls.count == 1)
        #expect(await destination.writtenData(at: "/ziel/1.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 16

    /// The rule only applies until drain: a later batch asks again.
    @Test func ruleResetsAfterDrain() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [
            "/ziel/1.txt": .init(content: Data("alt".utf8)),
            "/ziel/2.txt": .init(content: Data("alt".utf8)),
        ])
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, true) }

        // Batch 1 with applyToAll.
        try await vm.enqueueAndWait(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel")
        #expect(await calls.count == 1)
        await waitUntil { vm.isActive == false }   // worker drained → rule reset

        // Batch 2: decider is asked AGAIN.
        try await vm.enqueueAndWait(
            fileName: "2.txt", direction: .upload,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel")
        #expect(await calls.count == 2)
    }

    // MARK: - 17

    /// If the target doesn't exist, the decider isn't asked at all.
    @Test func noConflictDoesNotAskDecider() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [:])   // target does NOT exist
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await calls.count == 0)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 18

    /// Reviewer finding (M5b/T2): `cancelAll` while the decider prompt is open
    /// must NOT allow the transfer to proceed anymore, even though the item at
    /// this point is in neither `order` nor `runningTransferTask`.
    @Test func cancelAllDuringConflictPromptPreventsTransfer() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])
        let deciderEntered = TestSignal()
        let releaseDecider = TestSignal()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in
            await deciderEntered.fire()
            try? await releaseDecider.wait()
            return (.overwrite, false)
        }

        let waiterThrew = Counter()
        let waitTask = Task { @MainActor in
            do {
                try await vm.enqueueAndWait(
                    fileName: "a.txt", direction: .upload,
                    source: source, sourcePath: "/a.txt",
                    destination: destination, destinationDirectory: "/ziel")
            } catch {
                waiterThrew.increment()
            }
        }

        try await deciderEntered.wait()

        // cancelAll while the decider is open: the item is currently hanging in
        // resolveConflictIfNeeded — neither queued nor runningTransferTask.
        let cancelTask = Task { @MainActor in await vm.cancelAll() }
        await waitUntil { vm.items[0].status == .cancelled }
        #expect(vm.items[0].status == .cancelled)

        // cancelAll blocks until the decider returns (documented/accepted).
        await releaseDecider.fire()
        await cancelTask.value
        await waitTask.value

        #expect(vm.items[0].status == .cancelled)          // stays cancelled, NOT finished
        #expect(waiterThrew.value == 1)                     // enqueueAndWait threw
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // no write after cancel
    }

    // MARK: - 19

    /// Like above, but without a decider: the stat await itself is already the
    /// window (no conflict prompt needed, target doesn't exist).
    @Test func cancelAllDuringStatProbePreventsTransfer() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let statEntered = TestSignal()
        let statGate = TestSignal()
        let destination = QueueTestFS(reads: [:], statEntered: statEntered, statGate: statGate)

        let vm = TransferQueueViewModel()
        let waiterThrew = Counter()
        let waitTask = Task { @MainActor in
            do {
                try await vm.enqueueAndWait(
                    fileName: "a.txt", direction: .upload,
                    source: source, sourcePath: "/a.txt",
                    destination: destination, destinationDirectory: "/ziel")
            } catch {
                waiterThrew.increment()
            }
        }

        try await statEntered.wait()

        let cancelTask = Task { @MainActor in await vm.cancelAll() }
        await waitUntil { vm.items[0].status == .cancelled }
        #expect(vm.items[0].status == .cancelled)

        await statGate.fire()
        await cancelTask.value
        await waitTask.value

        #expect(vm.items[0].status == .cancelled)
        #expect(waiterThrew.value == 1)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)
    }

    // MARK: - Tree tests (M5b/T3)

    /// Standard fixture `dir/{a.txt, sub/{b.txt}, link→x, leer/}` as listings.
    func treeListings() -> [String: [RemoteFileItem]] {
        [
            "/dir": [
                RemoteFileItem(name: "a.txt", path: "/dir/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "sub", path: "/dir/sub", kind: .directory),
                RemoteFileItem(name: "link", path: "/dir/link", kind: .symlink),
                RemoteFileItem(name: "leer", path: "/dir/leer", kind: .directory),
            ],
            "/dir/sub": [
                RemoteFileItem(name: "b.txt", path: "/dir/sub/b.txt", kind: .file, size: 1),
            ],
            "/dir/leer": [],
        ]
    }

    /// Finds the status of the item with the given display name.
    @MainActor func status(_ vm: TransferQueueViewModel, _ name: String) -> TransferQueueViewModel.Item.Status? {
        vm.items.first(where: { $0.fileName == name })?.status
    }

    // MARK: - 20

    /// Destination directories are created top-down BEFORE the file writes.
    @Test func treeCreatesDirectoriesTopDown() async throws {
        let contentA = Data("aaa".utf8)
        let contentB = Data("bbb".utf8)
        let startedA = TestSignal(); let gateA = TestSignal()
        let startedB = TestSignal(); let gateB = TestSignal()
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: contentA, started: startedA, gate: gateA),
                "/dir/sub/b.txt": .init(content: contentB, started: startedB, gate: gateB),
            ],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: file write order is asserted
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        // Wait for full expansion (all three directories created),
        // without relying on onCompleted (writes are gated).
        while (await destination.createdDirectories).count < 3 { await Task.yield() }
        #expect(await destination.createdDirectories == ["/ziel/dir", "/ziel/dir/sub", "/ziel/dir/leer"])
        #expect(await destination.writeOrder.isEmpty)   // directories first, writes still gated

        await gateA.fire(); await gateB.fire()
        try await done.wait()
        #expect(await destination.writeOrder == ["/ziel/dir/a.txt", "/ziel/dir/sub/b.txt"])
    }

    // MARK: - 21

    /// All files are transferred, onCompleted fires exactly once.
    @Test func treeTransfersAllFilesAndFiresOnCompletedOnce() async throws {
        let contentA = Data("aaa".utf8)
        let contentB = Data("bbb".utf8)
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: contentA),
                "/dir/sub/b.txt": .init(content: contentB),
            ],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()
        await waitUntil { vm.isActive == false }
        // No second call — let it run a few more rounds.
        for _ in 0..<50 { await Task.yield() }

        #expect(counter.value == 1)
        #expect(status(vm, "a.txt") == .finished)
        #expect(status(vm, "b.txt") == .finished)
        #expect(await destination.writtenData(at: "/ziel/dir/a.txt") == contentA)
        #expect(await destination.writtenData(at: "/ziel/dir/sub/b.txt") == contentB)
    }

    // MARK: - 22

    /// Symlinks are skipped (item `.skipped`, name suffix " →", no write).
    @Test func treeSkipsSymlinks() async throws {
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: Data("a".utf8)),
                "/dir/sub/b.txt": .init(content: Data("b".utf8)),
            ],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()

        #expect(status(vm, "link →") == .skipped)
        #expect(await destination.writtenData(at: "/ziel/dir/link") == nil)
    }

    // MARK: - 23

    /// Empty directories are still created.
    @Test func treeCreatesEmptyDirectories() async throws {
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: Data("a".utf8)),
                "/dir/sub/b.txt": .init(content: Data("b".utf8)),
            ],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()
        #expect(await destination.createdDirectories.contains("/ziel/dir/leer"))
    }

    // MARK: - 24

    /// onCompleted only fires AFTER the last item finishes, not earlier.
    @Test func treeOnCompletedWaitsForLastItem() async throws {
        let contentA = Data("aaa".utf8)
        let contentB = Data("bbb".utf8)
        let startedB = TestSignal(); let gateB = TestSignal()
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: contentA),
                "/dir/sub/b.txt": .init(content: contentB, started: startedB, gate: gateB),
            ],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        // b.txt is running (gated), a.txt is already finished — still no onCompleted.
        try await startedB.wait()
        await waitUntil { status(vm, "a.txt") == .finished }
        #expect(counter.value == 0)

        await gateB.fire()
        try await done.wait()
        #expect(counter.value == 1)
        #expect(status(vm, "b.txt") == .finished)
    }

    // MARK: - 25

    /// Expansion error (list throws in a subfolder) → `.failed` item with
    /// a "/" suffix; the remaining branches keep running.
    @Test func treeExpansionErrorProducesFailedItemButOthersRun() async throws {
        // "/dir/sub" NOT registered → list throws notFound in this branch.
        var listings = treeListings()
        listings["/dir/sub"] = nil
        let contentA = Data("aaa".utf8)
        let source = QueueTestFS(
            reads: ["/dir/a.txt": .init(content: contentA)],
            listings: listings)
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()

        // Error item for the subfolder.
        let subStatus = status(vm, "sub/")
        if case .failed = subStatus {} else { Issue.record("sub/ should be .failed, was \(String(describing: subStatus))") }
        // a.txt went through anyway.
        #expect(status(vm, "a.txt") == .finished)
        #expect(status(vm, "link →") == .skipped)
        #expect(await destination.writtenData(at: "/ziel/dir/a.txt") == contentA)
        // b.txt was never enqueued.
        #expect(status(vm, "b.txt") == nil)
    }

    // MARK: - 26

    /// Even on partial failure (one file fails), onCompleted fires — exactly once.
    @Test func treePartialFailureStillFiresOnCompleted() async throws {
        // a.txt read is missing → copyFile throws → item .failed. b.txt goes through.
        let contentB = Data("bbb".utf8)
        let source = QueueTestFS(
            reads: ["/dir/sub/b.txt": .init(content: contentB)],
            listings: treeListings())
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()
        await waitUntil { vm.isActive == false }
        for _ in 0..<50 { await Task.yield() }

        #expect(counter.value == 1)
        if case .failed = status(vm, "a.txt") {} else { Issue.record("a.txt should be .failed") }
        #expect(status(vm, "b.txt") == .finished)
        #expect(await destination.writtenData(at: "/ziel/dir/sub/b.txt") == contentB)
    }

    // MARK: - 27

    /// cancelAll during expansion: no new items, group cleaned up,
    /// onCompleted does NOT fire, isActive false.
    @Test func cancelAllDuringExpansionStopsCleanly() async throws {
        let listEntered = TestSignal()
        let listGate = TestSignal()   // never fired; cancel must release it
        let source = QueueTestFS(
            reads: [
                "/dir/a.txt": .init(content: Data("a".utf8)),
                "/dir/sub/b.txt": .init(content: Data("b".utf8)),
            ],
            listings: treeListings(),
            listEntered: listEntered, listGate: listGate)
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment() })

        // Expansion hangs in the first list call.
        try await listEntered.wait()
        await vm.cancelAll()

        #expect(vm.isActive == false)
        #expect(vm.items.isEmpty)         // list never returned → no file items
        for _ in 0..<50 { await Task.yield() }
        #expect(counter.value == 0)        // no onCompleted on full cancellation

        // Worker restart stays intact: a new enqueue starts running.
        let done = TestSignal()
        let plain = QueueTestFS(reads: ["/x.txt": .init(content: Data("x".utf8))])
        vm.enqueue(
            fileName: "x.txt", direction: .upload,
            source: plain, sourcePath: "/x.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })
        try await done.wait()
        #expect(vm.items.last?.status == .finished)
    }

    // MARK: - 28

    /// Two independent `enqueueTree` calls (different folders) are enqueued
    /// one after another but run independently: each `onCompleted`
    /// fires exactly once, and item assignment stays cleanly separated —
    /// no mixing between the two groups (final review M5b,
    /// backlog e).
    @Test func twoConcurrentTreesKeepIndependentGroups() async throws {
        let contentA = Data("aaa".utf8)
        let contentB = Data("bbb".utf8)
        let listings: [String: [RemoteFileItem]] = [
            "/dirA": [RemoteFileItem(name: "a.txt", path: "/dirA/a.txt", kind: .file, size: 1)],
            "/dirB": [RemoteFileItem(name: "b.txt", path: "/dirB/b.txt", kind: .file, size: 1)],
        ]
        let source = QueueTestFS(
            reads: [
                "/dirA/a.txt": .init(content: contentA),
                "/dirB/b.txt": .init(content: contentB),
            ],
            listings: listings)
        let destination = QueueTestFS(reads: [:])
        let counterA = Counter()
        let counterB = Counter()
        let doneA = TestSignal()
        let doneB = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "dirA", direction: .download,
            source: source, sourceDirectory: "/dirA",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counterA.increment(); await doneA.fire() })
        vm.enqueueTree(
            directoryName: "dirB", direction: .download,
            source: source, sourceDirectory: "/dirB",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counterB.increment(); await doneB.fire() })

        try await doneA.wait()
        try await doneB.wait()
        await waitUntil { vm.isActive == false }
        for _ in 0..<50 { await Task.yield() }

        #expect(counterA.value == 1)
        #expect(counterB.value == 1)
        #expect(status(vm, "a.txt") == .finished)
        #expect(status(vm, "b.txt") == .finished)
        #expect(await destination.writtenData(at: "/ziel/dirA/a.txt") == contentA)
        #expect(await destination.writtenData(at: "/ziel/dirB/b.txt") == contentB)
        #expect(await destination.createdDirectories.contains("/ziel/dirA"))
        #expect(await destination.createdDirectories.contains("/ziel/dirB"))
    }

    // MARK: - 29

    /// Folder without files (only empty subfolders): onCompleted fires exactly
    /// once, `createdDirectories` contains both levels (final review M5b,
    /// backlog e).
    @Test func emptyTreeFiresOnCompleted() async throws {
        let listings: [String: [RemoteFileItem]] = [
            "/leerdir": [
                RemoteFileItem(name: "unter", path: "/leerdir/unter", kind: .directory),
            ],
            "/leerdir/unter": [],
        ]
        let source = QueueTestFS(reads: [:], listings: listings)
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueueTree(
            directoryName: "leerdir", direction: .download,
            source: source, sourceDirectory: "/leerdir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()
        for _ in 0..<50 { await Task.yield() }

        #expect(counter.value == 1)
        #expect(await destination.createdDirectories == ["/ziel/leerdir", "/ziel/leerdir/unter"])
        #expect(vm.items.isEmpty)   // no file items, only directories
    }

    // MARK: - 30 (M5c/T2: cooperative cancellation of a RUNNING transfer)

    /// A transfer that is already running (actively pushing chunks, with NO
    /// cancellation-aware gate) must end chunk-precisely via `cancelAll`:
    /// item `.cancelled` instead of `.finished`, `cancelAll` returns promptly.
    ///
    /// Without the `checkCancellation` in `TransferEngine.copyFile`, the
    /// transfer would run through to its natural end and the item would end up
    /// `.finished` (red starting state). The cancellation-UNAWARE parking loop
    /// in the source double ensures that the cancellation is caught
    /// exclusively via the engine check and not via a throwing wait.
    @Test func cancelAllStopsRunningTransferCooperatively() async throws {
        let content = Data(repeating: 0x5A, count: TransferChunk.size * 4)
        let started = TestSignal()
        let source = QueueTestFS(reads: [
            "/big.bin": .init(content: content, started: started, spinUntilCancelledAt: 1),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "big.bin", direction: .upload,
            source: source, sourcePath: "/big.bin",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)

        try await started.wait()
        await waitUntil { vm.items[0].status.isRunning }

        // Timeout race: with cooperative cancellation, cancelAll returns
        // promptly; without it, the transfer would hang/run until its natural end.
        let returnedInTime = await completesWithin(.seconds(2)) { await vm.cancelAll() }
        #expect(returnedInTime)
        #expect(vm.items[0].status == .cancelled)   // NOT .finished
        #expect(vm.isActive == false)
    }

    // MARK: - Parallel-slot tests (M5c/T4)

    // MARK: - 31

    /// With `maxConcurrent == 2` and three gated transfers, at most two run at
    /// once: the mock's peak concurrency never exceeds two, and the third item
    /// stays `.queued` until a slot frees.
    @Test func startsAtMostMaxConcurrent() async throws {
        let content = Data("x".utf8)
        let started0 = TestSignal(); let gate0 = TestSignal()
        let started1 = TestSignal(); let gate1 = TestSignal()
        let started2 = TestSignal(); let gate2 = TestSignal()
        let tracker = ConcurrencyTracker()
        let source = QueueTestFS(reads: [
            "/0.txt": .init(content: content, started: started0, gate: gate0),
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content, started: started2, gate: gate2),
        ])
        let destination = QueueTestFS(reads: [:], concurrency: tracker)

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2
        for name in ["0.txt", "1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }

        // The first two FIFO items start; the third must wait for a free slot.
        try await started0.wait()
        try await started1.wait()
        await waitUntil { vm.items[0].status.isRunning && vm.items[1].status.isRunning }
        #expect(vm.items[2].status == .queued)
        #expect(await tracker.peak == 2)

        // Free one slot → the third starts; still never three at once.
        await gate0.fire()
        try await started2.wait()
        await waitUntil { vm.items[2].status.isRunning }

        await gate1.fire(); await gate2.fire()
        await waitUntil { vm.items.allSatisfy { $0.status == .finished } }
        #expect(await tracker.peak == 2)   // never exceeded the limit
    }

    // MARK: - 32

    /// Slots are handed out in strict FIFO from the enqueue order, even under
    /// parallelism: with `maxConcurrent == 2`, the two running slots always
    /// hold the earliest still-unfinished items; a freed slot goes to the next
    /// in line, never to a later item.
    @Test func fifoStartOrderPreserved() async throws {
        let content = Data("x".utf8)
        let started0 = TestSignal(); let gate0 = TestSignal()
        let started1 = TestSignal(); let gate1 = TestSignal()
        let started2 = TestSignal(); let gate2 = TestSignal()
        let started3 = TestSignal(); let gate3 = TestSignal()
        let source = QueueTestFS(reads: [
            "/0.txt": .init(content: content, started: started0, gate: gate0),
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content, started: started2, gate: gate2),
            "/3.txt": .init(content: content, started: started3, gate: gate3),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2
        for name in ["0.txt", "1.txt", "2.txt", "3.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }

        // Items 0 and 1 (the first two enqueued) take the two slots.
        try await started0.wait()
        try await started1.wait()
        await waitUntil { vm.items[0].status.isRunning && vm.items[1].status.isRunning }
        #expect(vm.items[2].status == .queued)
        #expect(vm.items[3].status == .queued)

        // Free item 0's slot → it goes to item 2 (next in FIFO), NOT item 3.
        // `started2.wait()` only returns once item 2 actually starts; a FIFO
        // violation (item 3 first) would leave item 2 unstarted and hang here.
        await gate0.fire()
        try await started2.wait()
        await waitUntil { vm.items[0].status == .finished }
        #expect(vm.items[2].status.isRunning)
        #expect(vm.items[3].status == .queued)   // item 3 still waits behind item 2

        // Free item 1's slot → it goes to item 3.
        await gate1.fire()
        try await started3.wait()
        await waitUntil { vm.items[3].status.isRunning }

        await gate2.fire(); await gate3.fire()
        await waitUntil { vm.isActive == false }
    }

    // MARK: - 33

    /// `cancelAll` with two running transfers plus one queued: all three end
    /// `.cancelled`, each waiting `enqueueAndWait` throws exactly once, and the
    /// call returns promptly (cooperative cancellation, no natural-end wait).
    @Test func cancelAllWithParallelRunners() async throws {
        let content = Data("c".utf8)
        let started0 = TestSignal(); let gate0 = TestSignal()   // never fired
        let started1 = TestSignal(); let gate1 = TestSignal()   // never fired
        let source = QueueTestFS(reads: [
            "/0.txt": .init(content: content, started: started0, gate: gate0),
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2

        let throwCount = Counter()
        for name in ["0.txt", "1.txt", "2.txt"] {
            Task { @MainActor in
                do {
                    try await vm.enqueueAndWait(
                        fileName: name, direction: .upload,
                        source: source, sourcePath: "/\(name)",
                        destination: destination, destinationDirectory: "/ziel")
                } catch {
                    throwCount.increment()
                }
            }
        }

        // Two run, one is queued.
        try await started0.wait()
        try await started1.wait()
        await waitUntil {
            vm.items.count == 3
            && vm.items[0].status.isRunning && vm.items[1].status.isRunning
            && vm.items[2].status == .queued
        }

        let returnedInTime = await completesWithin(.seconds(2)) { await vm.cancelAll() }
        #expect(returnedInTime)
        #expect(vm.items[0].status == .cancelled)
        #expect(vm.items[1].status == .cancelled)
        #expect(vm.items[2].status == .cancelled)
        #expect(vm.isActive == false)
        await waitUntil { throwCount.value == 3 }
        #expect(throwCount.value == 3)   // each waiter threw exactly once
    }

    // MARK: - 34

    /// Two conflicts arriving in parallel slots serialize around the decider:
    /// the prompts never overlap (peak decider concurrency stays 1), yet both
    /// items are still asked (rule not applied to all) and both complete.
    @Test func conflictPromptsSerializeAcrossSlots() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
        ])
        // Both targets exist → both conflict.
        let destination = QueueTestFS(reads: [
            "/ziel/1.txt": .init(content: Data("alt".utf8)),
            "/ziel/2.txt": .init(content: Data("alt".utf8)),
        ])
        let deciderPeak = ConcurrencyTracker()
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2
        vm.conflictDecider = { _ in
            await calls.increment()
            await deciderPeak.enter()
            // Yield generously: without a FIFO gate the other slot's decider
            // would interleave here and push the peak to two.
            for _ in 0..<10 { await Task.yield() }
            await deciderPeak.leave()
            return (.overwrite, false)
        }
        for name in ["1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }

        await waitUntil { vm.items.count == 2 && vm.items.allSatisfy { $0.status == .finished } }
        #expect(await deciderPeak.peak == 1)   // prompts never overlapped
        #expect(await calls.count == 2)        // both conflicts were asked
        #expect(await destination.writtenData(at: "/ziel/1.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - Rate/ETA tests (M5c/T5)

    /// Controllable clock source for the VM's `now` hook (injectable,
    /// see `TransferQueueViewModel.init(now:)`): `advance` moves the clock
    /// forward by a fixed duration, `now()` reads the current value —
    /// deterministic instead of depending on real wall-clock timing.
    final class TickClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now
        func advance(by duration: Duration) {
            lock.lock(); current = current.advanced(by: duration); lock.unlock()
        }
        func now() -> ContinuousClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }

    /// Source with a MANUALLY driven chunk stream: the test holds the
    /// `AsyncThrowingStream` continuation and delivers chunks (and the
    /// clock advance) exactly when it wants to — no gate/signal detour
    /// needed, because `TransferEngine.copyFile`'s `iterator.next()` suspends
    /// until the next `yield` anyway.
    actor ManualByteSource: RemoteFileSystem {
        private let totalSize: UInt64?
        private let providedStream: AsyncThrowingStream<Data, Error>

        init(totalSize: UInt64?, stream: AsyncThrowingStream<Data, Error>) {
            self.totalSize = totalSize
            self.providedStream = stream
        }

        func list(path: String) async throws -> [RemoteFileItem] { [] }
        func stat(path: String) async throws -> RemoteFileItem {
            RemoteFileItem(name: "f.bin", path: path, kind: .file, size: totalSize)
        }
        func readStream(
            path: String, fromOffset offset: UInt64
        ) async throws -> AsyncThrowingStream<Data, Error> { providedStream }
        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
        func delete(path: String) async throws { throw RemoteFSError.notFound(path: path) }
        func createDirectory(at path: String) async throws {}
        func rename(from: String, to: String) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }
        func setPermissions(path: String, permissions: UInt32) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }
        func deleteTree(at path: String) async throws {
            throw RemoteFSError.protocolError(reason: "unsupported in this test double")
        }
        func disconnect() async {}
    }

    /// Reads the `TransferProgress` from the current status of the first
    /// item, if `.running` — otherwise `nil`. Small helper to avoid
    /// repetition in the following tests.
    @MainActor private func runningProgress(_ vm: TransferQueueViewModel) -> TransferProgress? {
        guard case .running(let progress) = vm.items.first?.status else { return nil }
        return progress
    }

    // MARK: - 35

    /// With a known `totalBytes` (300) and a clock set via `TickClock` to
    /// exactly 1s intervals: the first sample doesn't yield a rate yet
    /// (only one sample), the second (100 bytes / 1s window) yields exactly
    /// 100 B/s and a derived ETA of 1s (200 bytes remaining).
    @Test func rateAndETAPopulateOverSlidingWindow() async throws {
        let tick = TickClock()
        let vm = TransferQueueViewModel(now: { tick.now() })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let source = ManualByteSource(totalSize: 300, stream: stream)
        let destination = QueueTestFS(reads: [:])

        vm.enqueue(
            fileName: "f.bin", direction: .download,
            source: source, sourcePath: "/f.bin",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)

        continuation.yield(Data(repeating: 0, count: 100))
        await waitUntil { runningProgress(vm)?.bytesTransferred == 100 }
        let first = runningProgress(vm)
        #expect(first?.bytesPerSecond == nil)   // only one sample so far
        #expect(first?.etaSeconds == nil)

        tick.advance(by: .seconds(1))
        continuation.yield(Data(repeating: 0, count: 100))
        await waitUntil { runningProgress(vm)?.bytesTransferred == 200 }
        let second = runningProgress(vm)
        #expect(second?.bytesPerSecond == 100)   // 100 bytes over a 1s window
        #expect(second?.etaSeconds == 1.0)       // (300-200) / 100 B/s

        tick.advance(by: .seconds(1))
        continuation.yield(Data(repeating: 0, count: 100))
        continuation.finish()
        await waitUntil { vm.items.first?.status == .finished }
        #expect(await destination.writtenData(at: "/ziel/f.bin")?.count == 300)
    }

    // MARK: - 36

    /// Without a known `totalBytes`: the rate is still calculated (the
    /// window only needs timestamps + bytes), but the ETA stays `nil` —
    /// binding per the plan ("ETA only with known totalBytes").
    @Test func etaStaysNilWithoutKnownTotalBytes() async throws {
        let tick = TickClock()
        let vm = TransferQueueViewModel(now: { tick.now() })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let source = ManualByteSource(totalSize: nil, stream: stream)
        let destination = QueueTestFS(reads: [:])

        vm.enqueue(
            fileName: "f.bin", direction: .download,
            source: source, sourcePath: "/f.bin",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)

        continuation.yield(Data(repeating: 0, count: 100))
        await waitUntil { runningProgress(vm)?.bytesTransferred == 100 }

        tick.advance(by: .seconds(1))
        continuation.yield(Data(repeating: 0, count: 100))
        await waitUntil { runningProgress(vm)?.bytesTransferred == 200 }
        let progress = runningProgress(vm)
        #expect(progress?.bytesPerSecond == 100)   // rate doesn't need totalBytes
        #expect(progress?.etaSeconds == nil)        // ETA does

        continuation.finish()
        await waitUntil { vm.items.first?.status == .finished }
    }

    // MARK: - Interrupted / resume tests (M5d/T3)

    // MARK: - 37

    /// A `connectionFailed` mid-transfer marks the item `.interrupted` (and
    /// sets `hasInterrupted`); ANY OTHER error still marks it `.failed`.
    @Test func connectionLossMarksInterruptedOtherErrorFails() async throws {
        let content = Data(repeating: 0x41, count: TransferChunk.size)
        let startedA = TestSignal(); let gateA = TestSignal()
        let startedB = TestSignal(); let gateB = TestSignal()
        let source = QueueTestFS(reads: [
            "/a.txt": .init(content: content, started: startedA, gate: gateA,
                            failWith: RemoteFSError.connectionFailed(reason: "socket closed")),
            "/b.txt": .init(content: content, started: startedB, gate: gateB,
                            failWith: RemoteFSError.protocolError(reason: "boom")),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1

        // a.txt: connection lost → interrupted.
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedA.wait()
        await gateA.fire()
        await waitUntil { vm.items[0].status == .interrupted }
        #expect(vm.items[0].status == .interrupted)
        #expect(vm.hasInterrupted)
        #expect(vm.isActive == false)   // interrupted is not "pending" work

        // b.txt: a different error → failed (contrast).
        vm.enqueue(
            fileName: "b.txt", direction: .upload,
            source: source, sourcePath: "/b.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedB.wait()
        await gateB.fire()
        await waitUntil { if case .failed = vm.items[1].status { return true }; return false }
        if case .failed = vm.items[1].status {} else {
            Issue.record("b.txt should be .failed, was \(String(describing: vm.items[1].status))")
        }
    }

    // MARK: - 38

    /// `retryInterrupted` re-enqueues with resume semantics: the engine reads
    /// the source FROM THE PARTIAL OFFSET and APPENDS to the destination, and
    /// the item flips `.interrupted → .queued → .finished`.
    @Test func retryInterruptedResumesWithAppendAndOffset() async throws {
        let chunk = TransferChunk.size
        let full = Data(repeating: 0x5A, count: chunk * 2)
        let started1 = TestSignal(); let gate1 = TestSignal()
        let local1 = QueueTestFS(reads: [
            "/a.txt": .init(content: full, started: started1, gate: gate1,
                            failWith: RemoteFSError.connectionFailed(reason: "lost")),
        ])
        let remote1 = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: local1, sourcePath: "/a.txt",
            destination: remote1, destinationDirectory: "/ziel", onCompleted: nil)
        try await started1.wait()
        await gate1.fire()
        await waitUntil { vm.items[0].status == .interrupted }

        // New session refs: full source + a destination that already holds a
        // partial (one chunk), so resume continues from offset == chunk.
        let local2 = QueueTestFS(reads: ["/a.txt": .init(content: full)])
        let remote2 = QueueTestFS(reads: [
            "/ziel/a.txt": .init(content: Data(repeating: 0x5A, count: chunk)),
        ])
        vm.retryInterrupted(source: local2, destination: remote2)

        // Flipped back out of the terminal state immediately.
        #expect(vm.items[0].status == .queued || vm.items[0].status.isRunning)
        await waitUntil { vm.items[0].status == .finished }

        // Engine received resume:true → offset read on the source, append on
        // the destination, only the tail written.
        #expect(await local2.readOffsets["/a.txt"] == UInt64(chunk))
        #expect(await remote2.writeModes["/ziel/a.txt"] == .append)
        #expect(await remote2.writtenData(at: "/ziel/a.txt")?.count == chunk)
    }

    // MARK: - 39

    /// `cancelAll` cancels queued/running items but does NOT sweep `.interrupted`
    /// ones — they are already terminal and stay resumable across the teardown.
    @Test func cancelAllDoesNotSweepInterrupted() async throws {
        let chunk = TransferChunk.size
        let content = Data(repeating: 0x42, count: chunk)
        let startedA = TestSignal(); let gateA = TestSignal()
        let startedC = TestSignal(); let gateC = TestSignal()   // never fired
        let source = QueueTestFS(reads: [
            "/a.txt": .init(content: content, started: startedA, gate: gateA,
                            failWith: RemoteFSError.connectionFailed(reason: "lost")),
            "/c.txt": .init(content: content, started: startedC, gate: gateC),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1

        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedA.wait()
        await gateA.fire()
        await waitUntil { vm.items[0].status == .interrupted }

        // c.txt runs (gated), then cancelAll strikes.
        vm.enqueue(
            fileName: "c.txt", direction: .upload,
            source: source, sourcePath: "/c.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedC.wait()
        await vm.cancelAll()

        #expect(vm.items[0].status == .interrupted)   // untouched by cancelAll
        #expect(vm.items[1].status == .cancelled)      // running → cancelled
        #expect(vm.hasInterrupted)
    }

    // MARK: - 40

    /// The queue survives a session teardown (`cancelAll`): the interrupted
    /// item stays in the list, and `retryInterrupted` runs it against the NEW
    /// session's file systems (mock identity — the new destination is written,
    /// the old one is not).
    @Test func queueSurvivesTeardownAndRetryUsesNewFileSystems() async throws {
        let content = Data(repeating: 0x43, count: TransferChunk.size)
        let started1 = TestSignal(); let gate1 = TestSignal()
        let local1 = QueueTestFS(reads: [
            "/a.txt": .init(content: content, started: started1, gate: gate1,
                            failWith: RemoteFSError.connectionFailed(reason: "lost")),
        ])
        let remote1 = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: local1, sourcePath: "/a.txt",
            destination: remote1, destinationDirectory: "/ziel", onCompleted: nil)
        try await started1.wait()
        await gate1.fire()
        await waitUntil { vm.items[0].status == .interrupted }

        // Simulated teardown, exactly as ContentView does on disconnect.
        await vm.cancelAll()
        #expect(vm.items.count == 1)
        #expect(vm.items[0].status == .interrupted)

        // New session: fresh full source + empty destination.
        let local2 = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let remote2 = QueueTestFS(reads: [:])
        vm.retryInterrupted(source: local2, destination: remote2)
        await waitUntil { vm.items[0].status == .finished }

        #expect(await remote2.writtenData(at: "/ziel/a.txt") == content)   // new destination
        #expect(await remote1.writtenData(at: "/ziel/a.txt") == nil)        // old one untouched
    }

    // MARK: - 41

    /// `hasInterrupted` is false without any interrupted item (even after a
    /// clean finish) and true once one appears.
    @Test func hasInterruptedReflectsState() async throws {
        let content = Data(repeating: 0x44, count: TransferChunk.size)
        let source = QueueTestFS(reads: ["/ok.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        #expect(vm.hasInterrupted == false)

        try await vm.enqueueAndWait(
            fileName: "ok.txt", direction: .upload,
            source: source, sourcePath: "/ok.txt",
            destination: destination, destinationDirectory: "/ziel")
        #expect(vm.hasInterrupted == false)   // a finished transfer isn't interrupted

        let started = TestSignal(); let gate = TestSignal()
        let flaky = QueueTestFS(reads: [
            "/x.txt": .init(content: content, started: started, gate: gate,
                            failWith: RemoteFSError.connectionFailed(reason: "lost")),
        ])
        vm.enqueue(
            fileName: "x.txt", direction: .upload,
            source: flaky, sourcePath: "/x.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await started.wait()
        await gate.fire()
        await waitUntil { vm.hasInterrupted }
        #expect(vm.hasInterrupted)
    }

    // MARK: - 42

    /// A renamed item (conflict → "a (2).txt") that then gets interrupted is
    /// retried under its EFFECTIVE (post-rename) name, not the original.
    @Test func renamedItemRetriesUnderEffectiveName() async throws {
        let content = Data(repeating: 0x45, count: TransferChunk.size)
        let started = TestSignal(); let gate = TestSignal()
        let source = QueueTestFS(reads: [
            "/a.txt": .init(content: content, started: started, gate: gate,
                            failWith: RemoteFSError.connectionFailed(reason: "lost")),
        ])
        // Destination already holds a.txt → rename resolves to "a (2).txt".
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("old".utf8))])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.rename, false) }
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await started.wait()
        await gate.fire()
        await waitUntil { vm.items[0].status == .interrupted }
        #expect(vm.items[0].fileName == "a (2).txt")   // displayed under the renamed name

        // Retry resumes under the renamed name, writing to "/ziel/a (2).txt".
        let local2 = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let remote2 = QueueTestFS(reads: [:])
        vm.retryInterrupted(source: local2, destination: remote2)
        await waitUntil { vm.items[0].status == .finished }

        #expect(await remote2.writtenData(at: "/ziel/a (2).txt") == content)
        #expect(await remote2.writtenData(at: "/ziel/a.txt") == nil)
    }

    // MARK: - Shared bandwidth buckets (M6a/T2, migrated to BandwidthLimiter M8a/T2)

    @Test("direction limits build one shared bucket per direction")
    @MainActor
    func directionLimitsBuildBuckets() {
        let queue = TransferQueueViewModel()
        queue.limiter = BandwidthLimiter()
        #expect(queue.limiter?.uploadBucket == nil && queue.limiter?.downloadBucket == nil)
        queue.limiter?.uploadLimitBytesPerSec = 1024
        #expect(queue.limiter?.uploadBucket != nil && queue.limiter?.downloadBucket == nil)
        queue.limiter?.downloadLimitBytesPerSec = 2048
        #expect(queue.limiter?.downloadBucket != nil)
        // Changing a non-zero limit keeps the SAME bucket instance (running
        // transfers hold it — the change must reach them live).
        let bucketBefore = queue.limiter?.uploadBucket
        queue.limiter?.uploadLimitBytesPerSec = 4096
        #expect(queue.limiter?.uploadBucket === bucketBefore)
        queue.limiter?.uploadLimitBytesPerSec = 0
        #expect(queue.limiter?.uploadBucket == nil)
    }

    // MARK: - Group-cancel + conflict-gate hygiene (M6a/T3)

    // MARK: - 43

    /// A tree conflict cancel (decider returns nil) aborts the WHOLE folder
    /// transfer: the colliding item and every other still-queued item of the
    /// same group end `.cancelled`, an already-`.finished` item stays
    /// finished, and the group's `onCompleted` still fires exactly once
    /// (anyFinished).
    @Test func treeConflictCancelAbortsWholeGroup() async throws {
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "1.txt", path: "/dir/1.txt", kind: .file, size: 1),
                RemoteFileItem(name: "2.txt", path: "/dir/2.txt", kind: .file, size: 1),
                RemoteFileItem(name: "3.txt", path: "/dir/3.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/1.txt": .init(content: Data("aaa".utf8)),
                "/dir/2.txt": .init(content: Data("bbb".utf8)),
                "/dir/3.txt": .init(content: Data("ccc".utf8)),
            ],
            listings: listings)
        let destination = QueueTestFS(reads: [
            "/ziel/dir/2.txt": .init(content: Data("alt".utf8)),   // conflict on file 2
        ])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: file 1 finishes before file 2's conflict resolves
        vm.conflictDecider = { _ in nil }   // Cancel
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()

        #expect(status(vm, "1.txt") == .finished)     // already-finished item stays finished
        #expect(status(vm, "2.txt") == .cancelled)     // the conflicting item itself
        #expect(status(vm, "3.txt") == .cancelled)     // swept as still-queued group member
        #expect(counter.value == 1)                    // onCompleted fires exactly once
    }

    // MARK: - 44

    /// The same tree-conflict cancel leaves an UNGROUPED queued item and a
    /// SECOND, independent group completely untouched: both keep running to
    /// completion.
    @Test func treeConflictCancelLeavesOtherItemsAlone() async throws {
        let listingsA: [String: [RemoteFileItem]] = [
            "/dirA": [
                RemoteFileItem(name: "1.txt", path: "/dirA/1.txt", kind: .file, size: 1),
                RemoteFileItem(name: "2.txt", path: "/dirA/2.txt", kind: .file, size: 1),
                RemoteFileItem(name: "3.txt", path: "/dirA/3.txt", kind: .file, size: 1),
            ],
        ]
        let listingsB: [String: [RemoteFileItem]] = [
            "/dirB": [
                RemoteFileItem(name: "b1.txt", path: "/dirB/b1.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b2.txt", path: "/dirB/b2.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dirA/1.txt": .init(content: Data("a1".utf8)),
                "/dirA/2.txt": .init(content: Data("a2".utf8)),
                "/dirA/3.txt": .init(content: Data("a3".utf8)),
                "/dirB/b1.txt": .init(content: Data("b1".utf8)),
                "/dirB/b2.txt": .init(content: Data("b2".utf8)),
                "/solo.txt": .init(content: Data("solo".utf8)),
            ],
            listings: listingsA.merging(listingsB) { a, _ in a })
        let destination = QueueTestFS(reads: [
            "/ziel/dirA/2.txt": .init(content: Data("alt".utf8)),
        ])
        let counterA = Counter()
        let doneA = TestSignal()
        let counterB = Counter()
        let doneB = TestSignal()
        let soloDone = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: file 1 finishes before file 2's conflict resolves
        vm.conflictDecider = { _ in nil }
        vm.enqueueTree(
            directoryName: "dirA", direction: .download,
            source: source, sourceDirectory: "/dirA",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counterA.increment(); await doneA.fire() })
        vm.enqueue(
            fileName: "solo.txt", direction: .download,
            source: source, sourcePath: "/solo.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await soloDone.fire() })
        vm.enqueueTree(
            directoryName: "dirB", direction: .download,
            source: source, sourceDirectory: "/dirB",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counterB.increment(); await doneB.fire() })

        try await doneA.wait()
        try await soloDone.wait()
        try await doneB.wait()

        #expect(status(vm, "1.txt") == .finished)
        #expect(status(vm, "2.txt") == .cancelled)
        #expect(status(vm, "3.txt") == .cancelled)
        #expect(counterA.value == 1)
        // Untouched: the ungrouped item and the second group's items.
        #expect(status(vm, "solo.txt") == .finished)
        #expect(status(vm, "b1.txt") == .finished)
        #expect(status(vm, "b2.txt") == .finished)
        #expect(counterB.value == 1)
    }

    // MARK: - 45

    /// A conflict cancel on one group item ALSO cooperatively cancels the
    /// group's currently-RUNNING transfer (blocked mid-chunk, no cancellation-
    /// aware gate): it ends `.cancelled` instead of running to completion, and
    /// `onCompleted` still fires exactly once.
    @Test func treeConflictCancelCancelsRunningGroupTransfers() async throws {
        let content1 = Data(repeating: 0x5A, count: TransferChunk.size * 4)
        let started1 = TestSignal()
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "1.bin", path: "/dir/1.bin", kind: .file, size: UInt64(content1.count)),
                RemoteFileItem(name: "2.txt", path: "/dir/2.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/1.bin": .init(content: content1, started: started1, spinUntilCancelledAt: 1),
                "/dir/2.txt": .init(content: Data("x".utf8)),
            ],
            listings: listings)
        let destination = QueueTestFS(reads: [
            "/ziel/dir/2.txt": .init(content: Data("alt".utf8)),   // conflict on file 2
        ])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2   // both files occupy a slot at once
        vm.conflictDecider = { _ in
            // Only resolve file 2's conflict once file 1 is DEFINITELY running
            // (registered in runningTransferTasks) — proves the cancel below
            // hits a running transfer, not one still queued/resolving.
            try? await started1.wait()
            return nil   // Cancel
        }
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()

        #expect(status(vm, "1.bin") == .cancelled)   // running transfer, stopped cooperatively
        #expect(status(vm, "2.txt") == .cancelled)   // the conflicting item itself
        #expect(counter.value == 1)
    }

    // MARK: - 46

    /// Single-file (ungrouped) conflict cancel keeps the OLD behavior: only
    /// that item is cancelled, any other queued item is unaffected.
    @Test func singleFileConflictCancelKeepsOldBehavior() async throws {
        let source = QueueTestFS(reads: [
            "/a.txt": .init(content: Data("x".utf8)),
            "/b.txt": .init(content: Data("y".utf8)),
        ])
        let destination = QueueTestFS(reads: [
            "/ziel/a.txt": .init(content: Data("alt".utf8)),   // conflict
        ])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in nil }
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        let done = TestSignal()
        vm.enqueue(
            fileName: "b.txt", direction: .upload,
            source: source, sourcePath: "/b.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()

        #expect(vm.items[0].status == .cancelled)
        #expect(vm.items[1].status == .finished)
    }

    // MARK: - 47

    /// An "apply to all" rule set by one slot while a SECOND slot is waiting
    /// at the conflict gate is honored by that second slot as soon as it gets
    /// the gate — it must NOT prompt the decider a second time.
    @Test func queueRuleSetWhileWaitingAtGateIsApplied() async throws {
        let statEntered1 = TestSignal(); let statGate1 = TestSignal()
        let statEntered2 = TestSignal(); let statGate2 = TestSignal()
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: Data("neu1".utf8)),
            "/2.txt": .init(content: Data("neu2".utf8)),
        ])
        let destination1 = QueueTestFS(
            reads: ["/ziel/1.txt": .init(content: Data("alt1".utf8))],
            statEntered: statEntered1, statGate: statGate1)
        let destination2 = QueueTestFS(
            reads: ["/ziel/2.txt": .init(content: Data("alt2".utf8))],
            statEntered: statEntered2, statGate: statGate2)

        let calls = CallCounter()
        let slot1EnteredDecider = TestSignal()
        let letSlot1Proceed = TestSignal()
        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2
        vm.conflictDecider = { _ in
            await calls.increment()
            let n = await calls.count
            if n == 1 {
                // Slot 1: holds the gate. Signal that we're inside the
                // decider (i.e. the gate is held), then wait until the test
                // has confirmed slot 2 is queued behind it before answering
                // with an "apply to all" rule.
                await slot1EnteredDecider.fire()
                try? await letSlot1Proceed.wait()
                return (.overwrite, true)
            }
            // Reached only if the fix is missing: slot 2 asked the decider
            // again instead of following the freshly-set rule.
            return (.overwrite, false)
        }

        vm.enqueue(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination1, destinationDirectory: "/ziel",
            onCompleted: nil)
        vm.enqueue(
            fileName: "2.txt", direction: .upload,
            source: source, sourcePath: "/2.txt",
            destination: destination2, destinationDirectory: "/ziel",
            onCompleted: nil)

        try await statEntered1.wait()
        try await statEntered2.wait()

        // File 1's stat returns (conflict) → it acquires the gate and calls
        // the decider (call #1), which then blocks on `letSlot1Proceed`.
        await statGate1.fire()
        try await slot1EnteredDecider.wait()

        // File 2's stat now returns (conflict too). `queueRule` is still nil
        // (slot 1 hasn't answered yet) so it takes the decider branch and
        // suspends on `conflictGate.acquire()` — slot 1 already holds it.
        await statGate2.fire()
        await waitUntil { vm.conflictGateWaiterCount == 1 }

        // Let slot 1 answer: sets the rule, releases the gate straight to
        // slot 2 (FIFO hand-off). A correct implementation re-checks the rule
        // right there and does NOT call the decider again.
        await letSlot1Proceed.fire()

        await waitUntil { vm.items.allSatisfy { $0.status == .finished } }
        #expect(await calls.count == 1)   // decider asked exactly once overall
        #expect(await destination1.writtenData(at: "/ziel/1.txt") == Data("neu1".utf8))
        #expect(await destination2.writtenData(at: "/ziel/2.txt") == Data("neu2".utf8))
    }

    // MARK: - 48

    /// Cancelling a tree conflict WHILE the group's expansion is still
    /// RUNNING (parked mid-`list`, not yet cancelled) stops the expansion
    /// before it can enqueue anything from the still-unlisted subdirectory:
    /// `cancelGroup`'s `expansionTasks[groupID]?.cancel()` is otherwise dead
    /// code (I-1 review finding). Fixture: `/dir` has a clean file, a
    /// conflicting file, and a `sub` subdirectory; `/dir` lists freely,
    /// `/dir/sub`'s list is pinned by a dedicated per-path gate.
    @Test func treeConflictCancelDuringExpansionStopsNewItems() async throws {
        let subListGate = TestSignal()
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "clean.txt", path: "/dir/clean.txt", kind: .file, size: 1),
                RemoteFileItem(name: "conflict.txt", path: "/dir/conflict.txt", kind: .file, size: 1),
                RemoteFileItem(name: "sub", path: "/dir/sub", kind: .directory),
            ],
            "/dir/sub": [
                RemoteFileItem(name: "inner.txt", path: "/dir/sub/inner.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/clean.txt": .init(content: Data("clean".utf8)),
                "/dir/conflict.txt": .init(content: Data("new".utf8)),
                "/dir/sub/inner.txt": .init(content: Data("inner".utf8)),
            ],
            listings: listings,
            listGates: ["/dir/sub": subListGate])
        let destination = QueueTestFS(reads: [
            "/ziel/dir/conflict.txt": .init(content: Data("old".utf8)),   // conflict
        ])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1   // determinism: clean.txt finishes before conflict.txt resolves
        vm.conflictDecider = { _ in
            // Answer only once the expansion has genuinely entered the
            // `/dir/sub` list call (parked behind `subListGate`) — proves the
            // cancel below interrupts a RUNNING expansion, not one that
            // already stopped at an earlier checkpoint.
            while await source.listedPaths.contains("/dir/sub") == false {
                await Task.yield()
            }
            return nil   // Cancel
        }
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()

        #expect(status(vm, "clean.txt") == .finished)
        #expect(status(vm, "conflict.txt") == .cancelled)
        #expect(status(vm, "inner.txt") == nil)   // never enqueued — sub was never listed
        #expect(counter.value == 1)               // anyFinished (clean.txt)

        // Let the parked list call unwind — a no-op in fixed code (the
        // expansion task is already cancelled, so `list` throws regardless
        // of this fire; see `TestSignal.wait()`'s cancellation-awareness).
        // Guards against leaking a permanently-parked task past the test.
        await subListGate.fire()
        for _ in 0..<50 { await Task.yield() }
        #expect(status(vm, "inner.txt") == nil)
    }

    // MARK: - 49

    /// Same interruption as above, but nothing EVER reaches `.finished`: the
    /// conflict is the sole top-level file (`maxConcurrent = 1`), its only
    /// sibling is the file behind the pinned `/dir/sub` listing. `onCompleted`
    /// must NEVER fire (the `anyFinished || expansionSucceeded` guard in
    /// `maybeFireGroup`), even though every materialized item ends
    /// `.cancelled`.
    @Test func treeConflictCancelWithNothingFinishedNeverFires() async throws {
        let subListGate = TestSignal()
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "conflict.txt", path: "/dir/conflict.txt", kind: .file, size: 1),
                RemoteFileItem(name: "sub", path: "/dir/sub", kind: .directory),
            ],
            "/dir/sub": [
                RemoteFileItem(name: "inner.txt", path: "/dir/sub/inner.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/conflict.txt": .init(content: Data("new".utf8)),
                "/dir/sub/inner.txt": .init(content: Data("inner".utf8)),
            ],
            listings: listings,
            listGates: ["/dir/sub": subListGate])
        let destination = QueueTestFS(reads: [
            "/ziel/dir/conflict.txt": .init(content: Data("old".utf8)),   // conflict
        ])
        let counter = Counter()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1
        vm.conflictDecider = { _ in
            while await source.listedPaths.contains("/dir/sub") == false {
                await Task.yield()
            }
            return nil   // Cancel
        }
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment() })

        await waitUntil { status(vm, "conflict.txt") == .cancelled }
        for _ in 0..<50 { await Task.yield() }   // let the expansion's cancellation settle

        #expect(status(vm, "conflict.txt") == .cancelled)
        #expect(status(vm, "inner.txt") == nil)
        #expect(counter.value == 0)   // nothing ever finished — onCompleted must NOT fire

        await subListGate.fire()   // let the parked expansion task unwind
        for _ in 0..<50 { await Task.yield() }
        #expect(counter.value == 0)
        #expect(status(vm, "inner.txt") == nil)
    }

    // MARK: - 50

    /// A conflict-cancel decision must be asked of the decider EXACTLY once,
    /// even when a SECOND group sibling is already parked at the (FIFO)
    /// conflict gate behind the first one: cancelling the group must sweep
    /// that parked sibling via `resolvingJobIDs` WITHOUT ever prompting it
    /// (I-2, finding c).
    @Test func treeConflictCancelWhileSiblingWaitsAtGate() async throws {
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "1.txt", path: "/dir/1.txt", kind: .file, size: 1),
                RemoteFileItem(name: "2.txt", path: "/dir/2.txt", kind: .file, size: 1),
                RemoteFileItem(name: "3.txt", path: "/dir/3.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/1.txt": .init(content: Data("one".utf8)),
                "/dir/2.txt": .init(content: Data("two".utf8)),
                "/dir/3.txt": .init(content: Data("three".utf8)),
            ],
            listings: listings)
        let destination = QueueTestFS(reads: [
            "/ziel/dir/2.txt": .init(content: Data("old2".utf8)),   // conflict on 2 and 3
            "/ziel/dir/3.txt": .init(content: Data("old3".utf8)),
        ])
        let calls = CallCounter()
        let enteredDecider = TestSignal()
        let letProceed = TestSignal()
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2   // 1.txt and 2.txt occupy the two slots first
        vm.conflictDecider = { _ in
            await calls.increment()
            // Only the FIRST call (2.txt) parks here; a second call would
            // mean 3.txt got prompted despite already having been swept.
            await enteredDecider.fire()
            try? await letProceed.wait()
            return nil   // Cancel
        }
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        // 2.txt's slot reached the decider (call #1) and is parked there.
        try await enteredDecider.wait()

        // 1.txt (no conflict) finishes and frees its slot; 3.txt is dequeued
        // into it, finds its own conflict, and suspends at
        // `conflictGate.acquire()` — 2.txt still holds the gate inside the
        // decider. Wait for 1.txt to finish (that is what frees the slot
        // for 3.txt); a conflict-resolving item itself stays `.queued`, so
        // polling 3.txt's status here would spin to the limit every run.
        await waitUntil { status(vm, "1.txt") == .finished }
        // Deterministic gate arrival (M6a final-review hardening): wait until
        // 3.txt's conflict probe has entered `stat` — from its return the
        // slot reaches `conflictGate.acquire()` with no other suspension
        // point in between, so after the yields below it is genuinely parked
        // AT THE GATE (not still queued in `order`).
        while await destination.statedPaths.contains("/ziel/dir/3.txt") == false {
            await Task.yield()
        }
        for _ in 0..<50 { await Task.yield() }

        // Let 2.txt's decider answer nil: cancels the whole group. 3.txt
        // must be swept via `resolvingJobIDs` WITHOUT the decider ever being
        // asked about it — its own `jobs[id] != nil` guard, right after the
        // gate hand-off, must catch the cancellation instead.
        await letProceed.fire()
        try await done.wait()

        #expect(status(vm, "1.txt") == .finished)
        #expect(status(vm, "2.txt") == .cancelled)
        #expect(status(vm, "3.txt") == .cancelled)
        #expect(await calls.count == 1)   // decider asked exactly once overall
        #expect(counter.value == 1)       // onCompleted fires exactly once (1.txt finished)
    }

    // MARK: - 51

    /// Sibling B's conflict is answered `.rename` (applyToAll false) and its
    /// rename-candidate stat probe is held open via a per-path stat gate.
    /// While B probes, sibling C's conflict is answered `nil` → the whole
    /// group is cancelled. B must end `.cancelled` exactly once, AFTER its
    /// probe eventually returns — no double terminal transition (I-2,
    /// finding d).
    @Test func treeConflictCancelWhileSiblingProbesRename() async throws {
        let renameProbeGate = TestSignal()
        // C's OWN initial conflict-check stat is held open too — otherwise C
        // could race B for `conflictGate` and end up polling forever for B's
        // probe while itself holding the gate B needs (deadlock). Gating C's
        // stat instead fully decouples the two: B is guaranteed to acquire
        // and release the gate (a quick, non-blocking decision) before C's
        // own conflict is even detected.
        let cStatGate = TestSignal()
        let listings: [String: [RemoteFileItem]] = [
            "/dir": [
                RemoteFileItem(name: "B.txt", path: "/dir/B.txt", kind: .file, size: 1),
                RemoteFileItem(name: "C.txt", path: "/dir/C.txt", kind: .file, size: 1),
            ],
        ]
        let source = QueueTestFS(
            reads: [
                "/dir/B.txt": .init(content: Data("newB".utf8)),
                "/dir/C.txt": .init(content: Data("newC".utf8)),
            ],
            listings: listings)
        let renameCandidatePath = "/ziel/dir/B (2).txt"   // left unregistered: a "free" name
        let destination = QueueTestFS(
            reads: [
                "/ziel/dir/B.txt": .init(content: Data("oldB".utf8)),   // conflict on B
                "/ziel/dir/C.txt": .init(content: Data("oldC".utf8)),   // conflict on C
            ],
            statGates: [
                renameCandidatePath: renameProbeGate,
                "/ziel/dir/C.txt": cStatGate,
            ])
        let counter = Counter()
        let done = TestSignal()

        // Drives cStatGate open only once B's rename probe has genuinely
        // started (its stat call entered, whether or not it's still parked)
        // — this is what makes C's cancel-nil answer land WHILE B probes.
        let driver = Task {
            while await destination.statedPaths.contains(renameCandidatePath) == false {
                await Task.yield()
            }
            await cStatGate.fire()
        }

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 2   // B and C occupy both slots at once
        vm.conflictDecider = { conflict in
            if conflict.fileName == "B.txt" {
                return (.rename, false)   // triggers B's rename-candidate probe
            }
            return nil   // C: cancel (its own stat was gated until B probed)
        }
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        try await done.wait()

        #expect(status(vm, "B.txt") == .cancelled)
        #expect(status(vm, "C.txt") == .cancelled)
        // Neither B nor C ever finished, but the (flat, ungated) expansion
        // itself completed regularly before the cancel — `expansionSucceeded`
        // alone satisfies `maybeFireGroup`'s OR-guard, so onCompleted still
        // fires exactly once (already proven by `done.wait()` returning).
        #expect(counter.value == 1)

        // Let B's parked rename probe unwind — a no-op in fixed code (its
        // job was already cleared by `cancelGroup`, so `process` bails at
        // the `jobs[jobID] != nil` guard without touching status again).
        await renameProbeGate.fire()
        for _ in 0..<50 { await Task.yield() }

        // Stable after the probe resolves: no double terminal transition.
        #expect(status(vm, "B.txt") == .cancelled)
        #expect(status(vm, "C.txt") == .cancelled)
        await driver.value   // already finished long ago; just tidy up
    }

    // MARK: - Edit-upload / localization tests (M6a/T4)

    // MARK: - 41

    /// Edit-upload write-backs (`bypassConflictCheck == true`, made via
    /// `enqueueEditUpload`) are NOT resumable — their temp source is deleted
    /// by `EditSessionManager.stopAll` on disconnect. A `connectionFailed`
    /// mid-transfer must therefore mark them `.failed` with the localized
    /// "interrupted" catalog text, NOT `.interrupted`. Counter-probe in the
    /// same test: a NORMAL transfer hitting the SAME error still becomes
    /// `.interrupted` (resumable), unaffected by the edit-upload branch.
    @Test func editUploadConnectionFailureIsFailedNotInterrupted() async throws {
        let content = Data(repeating: 0x41, count: TransferChunk.size)
        let startedEdit = TestSignal(); let gateEdit = TestSignal()
        let startedNormal = TestSignal(); let gateNormal = TestSignal()
        let localURL = URL(fileURLWithPath: "/local/a.txt")
        let source = QueueTestFS(reads: [
            localURL.path(percentEncoded: false): .init(
                content: content, started: startedEdit, gate: gateEdit,
                failWith: RemoteFSError.connectionFailed(reason: "socket closed")),
            "/normal.txt": .init(
                content: content, started: startedNormal, gate: gateNormal,
                failWith: RemoteFSError.connectionFailed(reason: "socket closed")),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1

        // The edit-upload write-back: connection lost mid-transfer.
        vm.enqueueEditUpload(
            fileName: "a.txt", localURL: localURL,
            source: source, destination: destination, remoteDirectory: "/ziel")
        try await startedEdit.wait()
        await gateEdit.fire()
        await waitUntil {
            if case .failed = vm.items[0].status { return true }; return false
        }
        guard case .failed(let message) = vm.items[0].status else {
            Issue.record("edit-upload should be .failed, was \(String(describing: vm.items[0].status))")
            return
        }
        #expect(message == CoreL10n.string("core.transfer.interrupted"))
        #expect(vm.items[0].status != .interrupted)
        #expect(vm.hasInterrupted == false)

        // Counter-probe: a NORMAL transfer with the SAME error still becomes
        // `.interrupted` (resumable) — the edit-upload branch does not leak
        // into the ordinary path.
        vm.enqueue(
            fileName: "normal.txt", direction: .upload,
            source: source, sourcePath: "/normal.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedNormal.wait()
        await gateNormal.fire()
        await waitUntil { vm.items[1].status == .interrupted }
        #expect(vm.items[1].status == .interrupted)
        #expect(vm.hasInterrupted)
    }

    // MARK: - 42

    /// `message(for:)` is `public` (M6a/T4): the App layer reuses it for
    /// editor-open failures (`ContentView.openInEditor`). Direct
    /// catalog-lookup test — locale-fixed, same pattern as the existing
    /// `.failed(...)` message assertions above.
    @Test func messageForLooksUpCatalogText() {
        let message = TransferQueueViewModel.message(for: RemoteFSError.notFound(path: "/a.txt"))
        #expect(message == String(format: CoreL10n.string("core.transfer.notFound %@"), "/a.txt"))
    }

    // MARK: - 43 (M6b/T1)

    /// `TransferConflict.isPartOfFolderTransfer` distinguishes a lone-file
    /// conflict from one raised inside a recursive folder transfer, so the
    /// conflict sheet can label its Cancel button accordingly.
    @Test("decider learns whether a conflict belongs to a folder transfer")
    @MainActor
    func deciderSeesFolderTransferFlag() async throws {
        // One conflicting single file and one tree whose file conflicts too.
        let source = QueueTestFS(
            reads: [
                "/solo.txt": .init(content: Data("s".utf8)),
                "/dir/tree.txt": .init(content: Data("t".utf8)),
            ],
            listings: ["/dir": [
                RemoteFileItem(name: "tree.txt", path: "/dir/tree.txt", kind: .file, size: 1)
            ]])
        let destination = QueueTestFS(reads: [
            "/ziel/solo.txt": .init(content: Data("old".utf8)),
            "/ziel/dir/tree.txt": .init(content: Data("old".utf8)),
        ])
        let flags = Flags()   // actor collecting (fileName, isPartOfFolderTransfer)
        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 1
        vm.conflictDecider = { conflict in
            await flags.record(conflict.fileName, conflict.isPartOfFolderTransfer)
            return (resolution: .skip, applyToAll: false)
        }
        vm.enqueue(
            fileName: "solo.txt", direction: .download,
            source: source, sourcePath: "/solo.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        vm.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        await waitUntil { vm.items.count >= 2 && vm.items.allSatisfy { $0.status.isTerminal } }
        #expect(await flags.value("solo.txt") == false)
        #expect(await flags.value("tree.txt") == true)
    }
}

/// Collects (fileName, isPartOfFolderTransfer) pairs reported by a
/// `conflictDecider` closure — a plain `[String: Bool]` isn't `Sendable`
/// across the closure's actor hops, so this needs an actor (M6b/T1).
private actor Flags {
    private var byName: [String: Bool] = [:]
    func record(_ name: String, _ flag: Bool) { byName[name] = flag }
    func value(_ name: String) -> Bool? { byName[name] }
}
