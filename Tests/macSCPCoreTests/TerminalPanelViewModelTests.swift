import Foundation
import MacSCPTestSupport
import Synchronization
import Testing
@testable import macSCPCore

/// Controllable mock shell: output is fed in from outside; send/resize/close
/// are recorded.
final class MockShell: RemoteShell, Sendable {
    private struct State {
        var sent: [[UInt8]] = []
        var resizes: [(cols: Int, rows: Int)] = []
        var closed = false
    }

    let output: AsyncThrowingStream<[UInt8], Error>
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let state = Mutex(State())
    var sent: [[UInt8]] { state.withLock { $0.sent } }
    var resizes: [(cols: Int, rows: Int)] { state.withLock { $0.resizes } }
    var closed: Bool { state.withLock { $0.closed } }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }
    func send(_ bytes: [UInt8]) async throws { state.withLock { $0.sent.append(bytes) } }
    func resize(cols: Int, rows: Int) async throws { state.withLock { $0.resizes.append((cols, rows)) } }
    func close() async { state.withLock { $0.closed = true }; continuation.finish() }
}

@Suite("TerminalPanelViewModel", .timeLimit(.minutes(1)))
@MainActor
struct TerminalPanelViewModelTests {
    @Test func toggleOpensShellAndForwardsOutput() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        var received: [[UInt8]] = []
        vm.onOutput = { received.append($0) }

        vm.toggle()
        #expect(vm.isVisible)
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)

        shell.continuation.yield(Array("hallo".utf8))
        try await pollUntil("a chunk reached the consumer") { !received.isEmpty }
        #expect(!received.isEmpty)
        #expect(received.first.map { String(decoding: $0, as: UTF8.self) } == "hallo")
    }

    @Test func toggleTwiceDoesNotOpenTwice() async throws {
        let counter = Counter()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            await counter.increment()
            return MockShell()
        })
        vm.toggle()   // visible + opens
        vm.toggle()   // hidden
        vm.toggle()   // visible — shell is already running, do NOT reopen
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        #expect(await counter.value == 1)
    }

    @Test func streamEndSetsEnded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        shell.continuation.finish()
        try await pollUntil("the panel ended") { vm.state == .ended(nil) }
        #expect(vm.state == .ended(nil))
    }

    @Test func streamErrorSetsEndedWithMessage() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        shell.continuation.finish(throwing: RemoteFSError.protocolError(reason: "kaputt"))
        try await pollUntil("the panel ended with a message") {
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }
        var endedWithMessage = false
        if case .ended(let msg) = vm.state { endedWithMessage = msg != nil }
        #expect(endedWithMessage)
    }

    @Test func openFailureSetsEnded() async throws {
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            throw RemoteFSError.connectionFailed(reason: "nein")
        })
        vm.toggle()
        try await pollUntil("the panel ended with a message") {
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }
        var endedWithMessage = false
        if case .ended(let msg) = vm.state { endedWithMessage = msg != nil }
        #expect(endedWithMessage)
    }

    @Test func reopenAfterEndedWorks() async throws {
        let shells = ShellFactory()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in await shells.next() })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        await shells.current.close()
        try await pollUntil("the panel ended") { vm.state == .ended(nil) }
        #expect(vm.state == .ended(nil))
        vm.openIfNeeded()  // "Reopen" button
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        #expect(await shells.count == 2)
    }

    @Test func sendForwardsToShell() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        vm.send(Array("ls\n".utf8))
        try await pollUntil("bytes reached the shell") { !shell.sent.isEmpty }
        #expect(!shell.sent.isEmpty)
        #expect(shell.sent.first == Array("ls\n".utf8))
    }

    /// Regression: independent, unstructured `Task`s per `send()` call
    /// give no FIFO guarantee — with fast keystrokes (or paste), a later,
    /// shorter-delayed input can overtake an earlier one. `InvertedDelayShell`
    /// deliberately delays chunk i of N by `(N - i) * 2ms`, so that
    /// independent tasks are guaranteed to record out of order, while a
    /// FIFO chain records in exactly the send order.
    @Test func sendPreservesFIFOOrderUnderVaryingLatency() async throws {
        let totalChunks = 20
        let shell = InvertedDelayShell(totalChunks: totalChunks)
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)

        for i in 0..<totalChunks {
            vm.send([UInt8(i)])
        }
        try await pollUntil("every chunk was recorded") { shell.recorded.count == totalChunks }
        #expect(shell.recorded.count == totalChunks)
        #expect(shell.recorded == Array(0..<totalChunks))
    }

    /// Regression (final review M4, minor 1): hiding with ⌘T unmounts the
    /// TerminalView, `onOutput` becomes nil, the read loop discards chunks —
    /// showing it again starts an empty console. The VM must buffer the
    /// chunks while no consumer is attached.
    @Test func outputIsBufferedForReplayWhileHidden() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        // No onOutput set (panel hidden) — chunks must not be lost
        shell.continuation.yield(Array("verborgen".utf8))
        try await pollUntil("the replay buffer holds a chunk") { !vm.replayBuffer.isEmpty }
        #expect(!vm.replayBuffer.isEmpty)
        #expect(vm.replayBuffer.flatMap { $0 } == Array("verborgen".utf8))
        // New consumer (re-mount) sees buffer + live data
        var received: [[UInt8]] = []
        vm.onOutput = { received.append($0) }
        shell.continuation.yield(Array("live".utf8))
        try await pollUntil("a chunk reached the consumer") { !received.isEmpty }
        #expect(!received.isEmpty)
    }

    /// Regression: the replay buffer must not grow unbounded — it is
    /// capped at `maxReplayBytes` (256 KiB); the oldest chunks are evicted.
    @Test func replayBufferIsBounded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        shell.continuation.yield([UInt8](repeating: 1, count: 200_000))
        shell.continuation.yield([UInt8](repeating: 2, count: 200_000))
        // Waits for the SECOND chunk to arrive (not just "buffer satisfies
        // the bound", since a still-empty buffer trivially satisfies the
        // bound and would end the poll immediately — before the actual
        // processing happens).
        try await pollUntil("the second chunk reached the replay buffer") { vm.replayBuffer.last?.last == 2 }
        #expect(vm.replayBuffer.last?.last == 2)
        #expect(vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024)
        #expect(vm.replayBuffer.last?.last == 2)  // Newest is kept
    }

    @Test func shutdownClosesShellAndHides() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        await vm.shutdown()
        #expect(shell.closed)
        #expect(vm.state == .closed)
        #expect(!vm.isVisible)
    }

    /// Regression: shutdown() during `.opening` must not ignore the in-flight
    /// `openShell` call — otherwise the late-resolving open overwrites the
    /// `.closed` state and the shell it creates stays open as an orphan.
    @Test func shutdownWhileOpeningLeavesClosedAndClosesOrphan() async throws {
        let shell = MockShell()
        let openerReturned = Flag()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            await openerReturned.set()
            return shell
        })

        vm.toggle()
        #expect(vm.state == .opening)

        await vm.shutdown()
        #expect(!vm.isVisible)

        // Enough time for the delayed opener to resolve.
        try await Task.sleep(for: .milliseconds(300))

        #expect(vm.state == .closed)
        if await openerReturned.value {
            #expect(shell.closed)
        }
    }

    /// Regression: a read loop that ends only after shutdown() (a late
    /// `continuation.finish()`, after `close()` has already returned)
    /// must not retroactively overwrite `.closed` with `.ended`.
    @Test func staleReadLoopCannotOverwriteState() async throws {
        let shell = LateFinishShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)

        Task {
            try await Task.sleep(for: .milliseconds(50))
            shell.finish()
        }

        await vm.shutdown()
        #expect(vm.state == .closed)

        try await Task.sleep(for: .milliseconds(150))
        #expect(vm.state == .closed)
    }

    /// Terminal-Snippets milestone: a menu-triggered snippet has to open the
    /// panel and send in the same step — it cannot wait for the shell. Bytes
    /// handed to `send(_:)` during `.opening` must therefore survive and
    /// arrive once the shell runs, instead of hitting `guard let shell` and
    /// vanishing.
    @Test func sendDuringOpeningIsDeliveredOnceRunning() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return shell
        })

        vm.openIfNeeded()
        #expect(vm.state == .opening)
        vm.send(Array("uptime\r".utf8))
        #expect(shell.sent.isEmpty)  // Nothing to send to yet.

        try await pollUntil("the shell is running") { vm.state == .running }

        #expect(vm.state == .running)
        try await pollUntil("bytes reached the shell") { !shell.sent.isEmpty }
        #expect(!shell.sent.isEmpty)
        #expect(shell.sent.flatMap { $0 } == Array("uptime\r".utf8))
    }

    /// The held bytes keep their order, and keep it against sends issued
    /// after the shell is up: the flush runs in the same step that sets
    /// `.running`, so nothing sent later can overtake it.
    @Test func bytesHeldWhileOpeningKeepTheirOrder() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return shell
        })

        vm.openIfNeeded()
        vm.send([1, 2])
        vm.send([3])
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        vm.send([4])
        try await pollUntil("four bytes reached the shell") { shell.sent.flatMap { $0 }.count == 4 }
        #expect(shell.sent.flatMap { $0 }.count == 4)
        #expect(shell.sent.flatMap { $0 } == [1, 2, 3, 4])
    }

    /// A failed open must not leave the held bytes lying around for a LATER
    /// shell to receive out of nowhere — the user gets the `.ended` message
    /// the panel renders, not a command that runs on the next reopen.
    @Test func bytesHeldWhileOpeningAreDroppedWhenTheOpenFails() async throws {
        let shells = ShellFactory()
        let attempts = Counter()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(50))
            await attempts.increment()
            // First attempt fails, every later one succeeds.
            if await attempts.value == 1 {
                throw RemoteFSError.connectionFailed(reason: "nein")
            }
            return await shells.next()
        })

        vm.openIfNeeded()
        vm.send(Array("rm -rf /\r".utf8))
        try await pollUntil("the panel ended with a message") {
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }
        var endedWithMessage = false
        if case .ended(let msg) = vm.state { endedWithMessage = msg != nil }
        #expect(endedWithMessage)

        vm.openIfNeeded()  // "Reopen"
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        // Give a mistaken replay time to show up before asserting it didn't.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await shells.current.sent.isEmpty)
    }

    /// Regression: the `send()` chain belongs to ONE shell. A send that is
    /// still running when the shell ends must not make the first send to the
    /// NEXT shell wait behind it — the queued call carries its own shell
    /// reference, so waiting buys nothing and only delays delivery.
    ///
    /// `HangingSendShell.send` never returns on its own, so without the reset
    /// the chained send below waits for it forever and `[7]` never reaches
    /// the second shell.
    @Test func aSendToAnEndedShellDoesNotDelayTheNextOne() async throws {
        let first = HangingSendShell()
        let second = MockShell()
        let attempts = Counter()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            await attempts.increment()
            return await attempts.value == 1 ? first : second
        })

        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        vm.send([1])                  // Enters the chain and never finishes.
        try await pollUntil("the first shell's send was entered") { first.sendCalls == 1 }
        #expect(first.sendCalls == 1)

        first.finish()                // Shell ends -> `.ended`.
        try await pollUntil("the panel ended") { vm.state == .ended(nil) }
        #expect(vm.state == .ended(nil))

        vm.openIfNeeded()             // "Reopen" -> second shell.
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        vm.send([7])

        try await pollUntil("bytes reached the second shell") { !second.sent.isEmpty }

        #expect(!second.sent.isEmpty)
        #expect(second.sent.flatMap { $0 } == [7])
    }

    /// The app's order is open-then-layout: `toggle()` sets `.opening` in the
    /// same synchronous step that shows the panel, so the surface reports the
    /// geometry it was laid out at while `shell` is still `nil`. That report
    /// used to be dropped, and the shell kept `openIfNeeded()`'s hardcoded
    /// 80x24 for the rest of its life.
    @Test func aSizeReportedWhileOpeningReachesTheShellOnceItRuns() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return shell
        })

        vm.openIfNeeded()
        #expect(vm.state == .opening)
        vm.resize(cols: 132, rows: 43)
        #expect(shell.resizes.isEmpty)  // Nothing to resize yet.

        try await pollUntil("the shell is running") { vm.state == .running }

        #expect(vm.state == .running)
        try await pollUntil("a window-change reached the shell") { !shell.resizes.isEmpty }
        #expect(!shell.resizes.isEmpty)
        #expect(shell.resizes.map { [$0.cols, $0.rows] } == [[132, 43]])
    }

    /// The ORDER, which is the half a separate `Task` cannot give: the
    /// window-change has to be at the shell before the bytes that were
    /// buffered beside it. `ContentView.sendSnippet` is the path that makes
    /// this concrete — it opens the panel and buffers the snippet in one
    /// step, so a flush that runs first starts a full-screen program at
    /// 80x24 and leaves it to take SIGWINCH afterwards.
    ///
    /// The bytes are handed over BEFORE the size here, deliberately: what is
    /// pinned is "the window-change precedes the flush", not "the calls keep
    /// the order they were issued in". Issuing them the other way round would
    /// let a fix that merely preserves issue order pass.
    ///
    /// `OrderedShell` rather than `MockShell` for the other half of the
    /// property — that the two go through ONE FIFO instead of racing in
    /// parallel tasks. See that class's doc comment for the measurement that
    /// made the difference visible.
    @Test func aWindowChangeRecordedWhileOpeningArrivesBeforeTheFlushedBytes() async throws {
        let shell = OrderedShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return shell
        })
        let snippet = Array("vim notes.txt\r".utf8)

        vm.openIfNeeded()
        vm.send(snippet)
        vm.resize(cols: 132, rows: 43)
        #expect(shell.events.isEmpty)

        try await pollUntil("the shell is running") { vm.state == .running }

        #expect(vm.state == .running)
        try await pollUntil("the shell recorded both events") { shell.events.count == 2 }
        #expect(shell.events.count == 2)
        #expect(
            shell.events == [.resized(cols: 132, rows: 43), .sent(snippet)],
            "the shell saw \(shell.events)")
    }

    /// A geometry the shell has already been told is not sent again, and a
    /// different one is — the comparison is against the last size SENT, so a
    /// window that is genuinely 80x24 still gets its window-change (comparing
    /// against `openIfNeeded()`'s open-time 80x24 would swallow exactly that
    /// one).
    @Test func anUnchangedSizeIsNotSentTwiceAndAChangedOneIs() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.openIfNeeded()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)

        vm.resize(cols: 80, rows: 24)  // The shell's own open-time geometry.
        // Barrier, not a settle: `send` chains behind the window-change and
        // awaits its task's VALUE, so bytes at the shell prove the resize
        // task ran to the end -- including the `lastSentSize` write that
        // happens after `shell.resize` returns. Waiting only for the resize
        // to be RECORDED would race that write, and the duplicates below
        // would sometimes be issued before the shell was known to have
        // acknowledged the first one.
        vm.send([0x61])
        try await pollUntil("bytes reached the shell") { !shell.sent.isEmpty }
        #expect(!shell.sent.isEmpty)
        #expect(shell.resizes.count == 1)

        vm.resize(cols: 80, rows: 24)
        vm.resize(cols: 80, rows: 24)
        // Give a duplicate time to show up before asserting it didn't.
        try await Task.sleep(for: .milliseconds(100))
        #expect(shell.resizes.count == 1)

        vm.resize(cols: 132, rows: 43)
        try await pollUntil("the shell recorded a second window-change") { shell.resizes.count == 2 }
        #expect(shell.resizes.count == 2)
        #expect(shell.resizes.map { [$0.cols, $0.rows] } == [[80, 24], [132, 43]])
    }

    /// A window-change that FAILED on the wire must not be remembered as
    /// delivered — otherwise the dedup above swallows the next report of that
    /// same geometry, and the remote is left at a size nobody can correct:
    /// `sizeChanged` fires only on a CHANGE, so it will not report it again.
    ///
    /// The barrier is the same one the dedup test uses (a `send` chained
    /// behind the window-change), which is what makes the first half a fact
    /// rather than a wait: the bytes arrive only after the failing resize
    /// task has finished.
    @Test func aFailedWindowChangeIsNotRememberedAsSent() async throws {
        let shell = FailFirstResizeShell(failures: 1)
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.openIfNeeded()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)

        vm.resize(cols: 132, rows: 43)  // Throws on the wire.
        vm.send([0x61])
        try await pollUntil("bytes reached the shell") { !shell.sent.isEmpty }
        #expect(!shell.sent.isEmpty)
        #expect(shell.attempts == 1)
        #expect(shell.accepted.isEmpty, "the failing resize must not be recorded as accepted")

        // The SAME geometry again: it has to go out a second time.
        vm.resize(cols: 132, rows: 43)
        try await pollUntil("the shell saw a second resize attempt") { shell.attempts == 2 }
        #expect(shell.attempts == 2)
        #expect(
            shell.accepted.map { [$0.cols, $0.rows] } == [[132, 43]],
            "attempts \(shell.attempts), accepted \(shell.accepted)")
    }

    /// A window-change that returns AFTER its own shell is gone must not be
    /// remembered for the next one.
    ///
    /// `lastSentSize` is written after the `await`, so the write no longer
    /// sits in the synchronous step that owns the shell — and
    /// `cancelPendingSends()` cannot prevent it: it names only the tail of the
    /// chain, and cancellation is a flag that a NIO future ignores. So a
    /// stalled window-change returns whenever it returns, and without an
    /// identity check it writes onto whatever the view model has become.
    ///
    /// The sequence below is the whole failure, and every step is forced
    /// rather than waited for:
    ///
    /// 1. shell A is running; a 100x30 window-change stalls on the link;
    /// 2. shell A ends — `forgetGeometry()` clears `lastSentSize`;
    /// 3. Reopen: `openIfNeeded()` clears it again and parks on the channel
    ///    open, so the view model sits in `.opening` with `shell == nil`;
    /// 4. INSIDE that window the stalled window-change returns;
    /// 5. the remounted surface reports the same 100x30 — the window has not
    ///    moved — and it is held in `pendingSize`;
    /// 6. shell B opens.
    ///
    /// Unguarded, step 4 writes `lastSentSize = 100x30` while `shell` is
    /// `nil`, step 6's `flushPendingSize` dedups against it, and shell B keeps
    /// its open-time 80x24 for its whole life. That is not a degraded value —
    /// it is the exact defect this task exists to fix, reached through the new
    /// write path.
    @Test func aWindowChangeReturningAfterItsShellEndedIsNotRememberedForTheNext() async throws {
        let first = ParkedResizeShell()
        let second = MockShell()
        let secondOpen = ParkGate()
        let attempts = Counter()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            await attempts.increment()
            if await attempts.value == 1 { return first }
            await secondOpen.wait()  // Hold shell B's channel open.
            return second
        })

        // 1. Shell A, and a window-change that stalls inside it.
        vm.openIfNeeded()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        vm.resize(cols: 100, rows: 30)
        try await pollUntil("the window-change reached the gate") { first.resizeGate.entered == 1 }
        #expect(first.resizeGate.entered == 1)
        #expect(first.acceptedResizes.isEmpty)

        // 2. Shell A ends with the window-change still in flight.
        first.endOutput()
        try await pollUntil("the panel ended") { vm.state == .ended(nil) }
        #expect(vm.state == .ended(nil))

        // 3. Reopen, parked on the channel open.
        vm.openIfNeeded()
        #expect(vm.state == .opening)
        try await pollUntil("shell B's open reached the gate") { secondOpen.entered == 1 }
        #expect(secondOpen.entered == 1)

        // 4. The stalled window-change returns, inside that window.
        first.resizeGate.release()
        try await pollUntil("the stalled window-change was accepted") { first.acceptedResizes.count == 1 }
        #expect(first.acceptedResizes.count == 1)
        // The view model's own write happens when `shell.resize` RETURNS,
        // i.e. in a MainActor continuation that is runnable the moment the
        // line above observes the record. Yielding lets it run, so the rest
        // of the test measures a view model that has already been written to
        // rather than racing that write. If this yield were too short the
        // test would go GREEN against the defect, which is why it is measured
        // against the unguarded write rather than assumed (red 5 of 5).
        try await Task.sleep(for: .milliseconds(100))

        // 5. The remounted surface reports the unchanged geometry.
        vm.resize(cols: 100, rows: 30)

        // 6. Shell B opens.
        secondOpen.release()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        try await pollUntil("a window-change reached shell B") { !second.resizes.isEmpty }
        #expect(!second.resizes.isEmpty)
        #expect(
            second.resizes.map { [$0.cols, $0.rows] } == [[100, 30]],
            """
            shell B saw \(second.resizes) — a window-change belonging to \
            shell A was remembered across the reopen, so B keeps the 80x24 it \
            was opened with.
            """)
        await vm.shutdown()
    }

    /// A size reported while nothing is opening belongs to no shell: it must
    /// not be kept and replayed into one opened much later, the same rule
    /// `send(_:)`'s buffer follows. Otherwise a panel that was closed at one
    /// window size would open its next shell at that stale geometry.
    @Test func aSizeReportedWhileClosedIsNotReplayedIntoALaterShell() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })

        #expect(vm.state == .closed)
        vm.resize(cols: 200, rows: 60)

        vm.openIfNeeded()
        try await pollUntil("the shell is running") { vm.state == .running }
        #expect(vm.state == .running)
        // Give a mistaken replay time to show up before asserting it didn't.
        try await Task.sleep(for: .milliseconds(100))
        #expect(shell.resizes.isEmpty)
    }

    /// The hold is bounded (64 KiB), so an open that never completes cannot
    /// let it grow without limit — same discipline as `replayBuffer`.
    @Test func bytesHeldWhileOpeningAreBounded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return shell
        })

        vm.openIfNeeded()
        vm.send([UInt8](repeating: 1, count: 50_000))
        vm.send([UInt8](repeating: 2, count: 50_000))

        try await pollUntil("the shell is running") { vm.state == .running }

        #expect(vm.state == .running)
        try await pollUntil("bytes reached the shell") { !shell.sent.isEmpty }
        #expect(!shell.sent.isEmpty)
        let delivered = shell.sent.flatMap { $0 }
        #expect(delivered.count == 64 * 1024)
        // The cap truncates the tail, it does not evict the head: what
        // arrives is the START of the input, so a command is cut short
        // rather than silently rewritten into a different one.
        #expect(delivered.first == 1)
        #expect(delivered.last == 2)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// Shell whose `close()` returns immediately without ending the output
/// stream. `output` deliberately ignores task cancellation (busy-polls a
/// manual flag) — real `AsyncThrowingStream` continuations already end
/// iteration on `Task.cancel()`, which would mask the actual race. Here the
/// read loop ends only via the explicit, delayed `finish()`, to test that a
/// late-ending read loop does not overwrite a state that has already been
/// set.
final class LateFinishShell: RemoteShell, Sendable {
    private struct State {
        var closed = false
        var finished = false
    }

    private let state = Mutex(State())
    var closed: Bool { state.withLock { $0.closed } }

    var output: AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream<[UInt8], Error> { [weak self] in
            while true {
                guard let self else { return nil }
                if self.state.withLock({ $0.finished }) { return nil }
                // Deliberately swallows CancellationError — simulates a
                // data stream that does not observe task cancellation
                // itself (e.g. a real network connection).
                _ = try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {
        state.withLock { $0.closed = true }
    }
    func finish() {
        state.withLock { $0.finished = true }
    }
}

/// A gate that parks its caller until the test releases it, readable
/// synchronously so a test can wait for "the call has arrived" without an
/// `await` inside a poll's condition closure.
///
/// `NSLock` rather than an actor for exactly that reason: `entered` has to be
/// readable from a non-async expression. Every WAIT is still an `await`.
///
/// Deliberately NOT cancellation-aware, unlike the gates in the AppKit sizing
/// suite. This one stands in for `CitadelShell.resize` -> `TTYStdinWriter
/// .changeSize` awaiting a NIO future, which does not observe cancellation
/// either — a window-change that `cancelPendingSends()` has flagged still
/// goes out and still returns. Making it cancellable would model away the
/// very thing under test.
final class ParkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var enteredCount = 0

    /// How many callers have reached the gate, released or not.
    var entered: Int { lock.lock(); defer { lock.unlock() }; return enteredCount }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            enteredCount += 1
            if isReleased {
                lock.unlock()
                c.resume()
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    /// Lets the parked caller through, and every later one. Takes the
    /// continuation under the lock before resuming, so a second `release()`
    /// cannot resume it twice.
    func release() {
        lock.lock()
        isReleased = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Shell whose `resize` parks on a `ParkGate` until the test releases it, so
/// a window-change can be left IN FLIGHT across the end of its own shell and
/// the opening of the next one. That is the shape of a real `resize` on a
/// half-dead link: it is awaiting a NIO future, `cancelPendingSends()` can
/// only flag it, and it returns whenever the future finally completes —
/// possibly long after the shell it belongs to is gone.
final class ParkedResizeShell: RemoteShell, Sendable {
    let resizeGate = ParkGate()
    private let accepted = Mutex<[(cols: Int, rows: Int)]>([])
    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    /// The window-changes that got all the way through.
    var acceptedResizes: [(cols: Int, rows: Int)] { accepted.withLock { $0 } }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {}

    func resize(cols: Int, rows: Int) async throws {
        await resizeGate.wait()
        accepted.withLock { $0.append((cols, rows)) }
    }

    /// Ends the output stream the way a remote `exit` does, which is what
    /// drives the panel to `.ended`.
    func endOutput() { continuation.finish() }
    func close() async { continuation.finish() }
}

/// Shell whose first `failures` window-changes throw before recording
/// anything, and whose later ones are accepted. `attempts` counts every call
/// including the failed ones, `accepted` only the ones that got through — the
/// two together are what separates "sent again" from "deduped away".
///
/// `output` stays open, so the read loop keeps running and a resize failure
/// does not end the panel: what is under test is the view model's memory of
/// what the shell acknowledged, not its error handling.
final class FailFirstResizeShell: RemoteShell, Sendable {
    struct ResizeFailure: Error {}

    private struct State {
        var attempts = 0
        var accepted: [(cols: Int, rows: Int)] = []
        var sent: [[UInt8]] = []
    }

    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let state = Mutex(State())
    private let failures: Int

    var attempts: Int { state.withLock { $0.attempts } }
    var accepted: [(cols: Int, rows: Int)] { state.withLock { $0.accepted } }
    var sent: [[UInt8]] { state.withLock { $0.sent } }

    init(failures: Int) {
        self.failures = failures
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws { state.withLock { $0.sent.append(bytes) } }

    func resize(cols: Int, rows: Int) async throws {
        let failing = state.withLock { state -> Bool in
            state.attempts += 1
            return state.attempts <= failures
        }
        if failing { throw ResizeFailure() }
        state.withLock { $0.accepted.append((cols, rows)) }
    }

    func close() async { continuation.finish() }
}

/// Shell that records sends and window-changes in ONE list, so a test can ask
/// which reached it first — and whose `resize` SUSPENDS before recording,
/// while `send` records at once.
///
/// That asymmetry is the whole fixture, and it was measured into existence:
/// with a shell that records both immediately, the ordering test could not
/// tell the shipped chain from a free `Task { shell.resize(…) }` — the free
/// task is created first and wins on scheduling alone, so the mutation passed
/// 5 of 5 runs. With `resize` sleeping first, the two implementations are
/// distinguishable by construction rather than by timing:
///
/// - chained through `sendTask` (shipped): the flush's `send` waits for the
///   resize task to COMPLETE, sleep included -> `[.resized, .sent]`, and no
///   amount of load can reorder it;
/// - a free `Task`: the send has nothing to wait for and records while the
///   resize is still asleep -> `[.sent, .resized]`.
///
/// The delay is therefore not a race the test hopes to win. It is what makes
/// the correct answer independent of scheduling.
final class OrderedShell: RemoteShell, Sendable {
    enum Event: Equatable, Sendable {
        case sent([UInt8])
        case resized(cols: Int, rows: Int)
    }

    private let recorded = Mutex<[Event]>([])
    private let resizeDelay: Duration
    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    var events: [Event] { recorded.withLock { $0 } }

    init(resizeDelay: Duration = .milliseconds(50)) {
        self.resizeDelay = resizeDelay
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {
        recorded.withLock { $0.append(.sent(bytes)) }
    }

    func resize(cols: Int, rows: Int) async throws {
        try await Task.sleep(for: resizeDelay)
        recorded.withLock { $0.append(.resized(cols: cols, rows: rows)) }
    }

    func close() async { continuation.finish() }
}

/// Shell whose `send(_:)` never returns on its own — it sleeps until the
/// surrounding task is cancelled. Stands in for a send that is still in
/// flight when the shell ends (a stalled connection); `finish()` ends the
/// output stream the way a closing shell does.
final class HangingSendShell: RemoteShell, Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let sendCallCount = Mutex(0)
    var sendCalls: Int { sendCallCount.withLock { $0 } }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {
        sendCallCount.withLock { $0 += 1 }
        // Long enough to outlast the whole test; cancellation ends it.
        try await Task.sleep(for: .seconds(600))
    }
    func resize(cols: Int, rows: Int) async throws {}
    func close() async { continuation.finish() }
    func finish() { continuation.finish() }
}

/// Shell whose `send(_:)` delays the i-th of N calls by `(N - i) * 2ms`
/// before recording it — the earlier a chunk was sent, the longer it
/// waits. With independent tasks per `send()` call (the bug), later,
/// short-delayed chunks catch up with earlier, long-delayed ones and the
/// recording gets scrambled; a FIFO chain, by contrast, records in exactly
/// the send order, because each call only starts after the previous one
/// (including its delay) has finished.
final class InvertedDelayShell: RemoteShell, Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let totalChunks: Int
    private let recordedIndices = Mutex<[Int]>([])
    var recorded: [Int] { recordedIndices.withLock { $0 } }

    init(totalChunks: Int) {
        self.totalChunks = totalChunks
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {
        let i = Int(bytes[0])
        let delayMs = (totalChunks - i) * 2
        try await Task.sleep(for: .milliseconds(delayMs))
        recordedIndices.withLock { $0.append(i) }
    }
    func resize(cols: Int, rows: Int) async throws {}
    func close() async { continuation.finish() }
}

actor ShellFactory {
    private var shells: [MockShell] = []
    var count: Int { shells.count }
    var current: MockShell { shells.last! }
    func next() -> MockShell {
        let shell = MockShell()
        shells.append(shell)
        return shell
    }
}

/// `send(_:onDelivered:)` exists so a caller can record what actually went
/// out. The audit log's snippet entry hangs on it: before P5 the entry was
/// written right after the send CALL, so a shell that failed to open left an
/// entry claiming a snippet ran when its bytes were buffered and discarded.
@Suite("TerminalPanelViewModel delivery callback", .timeLimit(.minutes(1)))
@MainActor
struct TerminalPanelViewModelDeliveryTests {
    /// Lets the test decide WHEN the shell finishes opening, instead of
    /// racing a fixed sleep against however loaded the machine is. The
    /// previous version of this suite slept 80 ms inside `openShell` and
    /// waited for the flush afterwards; that passed alone and failed inside
    /// the full suite, which is the worst way for a test to be wrong.
    private final class OpenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func waitUntilOpened() async {
            await withCheckedContinuation { c in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    c.resume()
                    return
                }
                continuation = c
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Counts delivery callbacks AND lets a test wait for the first one
    /// without inventing a deadline for it.
    ///
    /// The wait used to be a 5 ms poll against a 5 s deadline, and that
    /// deadline was the whole flakiness: measured under CPU starvation
    /// (twelve spinners on this machine) the test went red roughly one run
    /// in three, and its own failure message said which half was missing --
    /// "callback 0, shell received 1 chunk(s), state .running". The bytes
    /// had reached the shell; only the hop back onto the main actor to call
    /// `onDelivered` had not been scheduled yet, because every main-actor
    /// test in the suite was queued in front of it. Nothing was lost; the
    /// test simply stopped waiting.
    ///
    /// So the wait is event-driven now: the callback resumes it, and a
    /// starved machine makes it slower rather than red. Raising the number
    /// would have hidden the same race one load level further out. The same
    /// shape as `OpenGate` above, for the same reason -- if the delivery
    /// already happened, the wait returns at once instead of parking on a
    /// continuation nobody will resume.
    ///
    /// It is event-driven AND it ends, and the two are no longer the same
    /// mechanism. The first version of this had no ending at all, and a
    /// review measured what that costs: mutate `onDelivered?()` in
    /// `TerminalPanelViewModel.send` to never fire, and this suite ran past
    /// ninety seconds instead of failing in five with a diagnosis. That
    /// trades a flaky test for a hung suite, in a repository whose backlog
    /// already carries a suite-hang incident. The ending that measurement
    /// bought was a private ceiling task of thirty seconds; it is now the
    /// suite's `.timeLimit(.minutes(1))`, which cancels the test — and
    /// `waitForFirstDelivery` resumes its parked waiter from the
    /// cancellation handler, so the caller's assertion and its message still
    /// run. A callback that will NEVER fire is still a red test with a
    /// diagnosis rather than a runner that never returns; what is gone is
    /// the second clock, which could only measure how loaded the machine was
    /// (CLAUDE.md, "A wall-clock ceiling in a test measures the runner").
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var wasReleased = false

        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

        func bump() {
            lock.lock()
            _count += 1
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }

        /// Waits for the first delivery, or for this test to be cancelled —
        /// which is what the suite's `.timeLimit` does — and reports which
        /// happened. The caller asserts on the count either way, so a
        /// give-up lands on the diagnostic rather than on a bare timeout
        /// message.
        @discardableResult
        func waitForFirstDelivery() async -> Bool {
            await withTaskCancellationHandler {
                await self.parkUntilDelivered()
            } onCancel: {
                // The waiter is parked on the continuation and nothing else
                // will touch it if the callback never comes; releasing it
                // here is what lets the caller reach its assertion.
                self.resumePendingWaiter()
            }
            return count > 0
        }

        private func parkUntilDelivered() async {
            await withCheckedContinuation { c in
                lock.lock()
                // `wasReleased` and not just the count: the handler above can
                // run BEFORE this parks (a task already cancelled runs it
                // immediately), and a resume that arrives then has nothing to
                // resume. Recording it under the same lock is what keeps that
                // race from parking forever.
                if _count > 0 || wasReleased {
                    lock.unlock()
                    c.resume()
                    return
                }
                continuation = c
                lock.unlock()
            }
        }

        private func resumePendingWaiter() {
            lock.lock()
            wasReleased = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    @Test func firesOnceWhenTheShellIsRunning() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.openIfNeeded()
        try await pollUntil("the shell is running") {
            if case .running = vm.state { return true } else { return false }
        }

        let delivered = Box()
        vm.send([0x61]) { delivered.bump() }
        await delivered.waitForFirstDelivery()

        #expect(
            delivered.count == 1,
            "callback \(delivered.count), shell received \(shell.sent.count) chunk(s)")
    }

    @Test func waitsForTheFlushWhenTheShellIsStillOpening() async throws {
        let shell = MockShell()
        let gate = OpenGate()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            await gate.waitUntilOpened()
            return shell
        })
        vm.openIfNeeded()

        let delivered = Box()
        vm.send([0x61]) { delivered.bump() }
        // Still buffered: the shell cannot have opened, because only the
        // line below lets it. Checked synchronously, before any suspension.
        #expect(delivered.count == 0)

        gate.open()
        await delivered.waitForFirstDelivery()
        // Reachable even when the callback never fires, and that is the
        // point: the suite's `.timeLimit` cancels the wait above rather than
        // leaving it parked forever with the line below as dead code. It
        // reports which half is missing -- bytes at the shell but no callback
        // is a callback bug; neither is a flush bug. That message is what
        // diagnosed the flake this suite was rebuilt around.
        #expect(
            delivered.count == 1,
            "callback \(delivered.count), shell received \(shell.sent.count) chunk(s), state \(vm.state)")
    }

    @Test func neverFiresWhenTheOpenFails() async throws {
        struct OpenFailure: Error {}
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in throw OpenFailure() })
        vm.openIfNeeded()

        let delivered = Box()
        vm.send([0x61]) { delivered.bump() }
        try await pollUntil("the panel ended") {
            if case .ended = vm.state { return true } else { return false }
        }

        #expect(delivered.count == 0)
        if case .ended = vm.state {} else {
            Issue.record("expected the panel to end after a failed open, got \(vm.state)")
        }
    }

    // MARK: - Finding 3: remoteWantsBracketedPaste

    /// `remoteWantsBracketedPaste` must answer exactly what `bracketedPasteQuery`
    /// returns -- both `true` and `false`, so a stuck-`true` regression (which
    /// would send bracket sequences to a shell that shows them literally
    /// instead of running the pasted text as intended) is caught the same as a
    /// stuck-`false` one.
    @Test func remoteWantsBracketedPasteAnswersWhatTheClosureReturns() {
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in MockShell() })
        vm.bracketedPasteQuery = { true }
        #expect(vm.remoteWantsBracketedPaste == true)
        vm.bracketedPasteQuery = { false }
        #expect(vm.remoteWantsBracketedPaste == false)
    }

    /// The load-bearing case: with no view attached, `bracketedPasteQuery` is
    /// `nil`, and `remoteWantsBracketedPaste` must read that as `false` -- the
    /// conservative answer, per its own doc comment. Guessing "on" here would
    /// make `SnippetSendPlanner` bracket-wrap a multi-line snippet for a shell
    /// that never negotiated mode 2004, which shows the escape sequences as
    /// literal text instead of pasting.
    @Test func remoteWantsBracketedPasteIsFalseWithNoQuerySet() {
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in MockShell() })
        #expect(vm.bracketedPasteQuery == nil)
        #expect(vm.remoteWantsBracketedPaste == false)
    }
}
