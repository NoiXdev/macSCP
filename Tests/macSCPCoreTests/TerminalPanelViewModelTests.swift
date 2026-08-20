import Foundation
import Testing
@testable import macSCPCore

/// Controllable mock shell: output is fed in from outside; send/resize/close
/// are recorded.
final class MockShell: RemoteShell, @unchecked Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let lock = NSLock()
    private var _sent: [[UInt8]] = []
    private var _resizes: [(cols: Int, rows: Int)] = []
    private var _closed = false
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }
    var resizes: [(cols: Int, rows: Int)] { lock.lock(); defer { lock.unlock() }; return _resizes }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }
    func send(_ bytes: [UInt8]) async throws { lock.lock(); _sent.append(bytes); lock.unlock() }
    func resize(cols: Int, rows: Int) async throws { lock.lock(); _resizes.append((cols, rows)); lock.unlock() }
    func close() async { lock.lock(); _closed = true; lock.unlock(); continuation.finish() }
}

/// Polls until `condition` is true (max ~2 s) — same pattern as in the other VM tests.
@MainActor
private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

@Suite("TerminalPanelViewModel")
@MainActor
struct TerminalPanelViewModelTests {
    @Test func toggleOpensShellAndForwardsOutput() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        var received: [[UInt8]] = []
        vm.onOutput = { received.append($0) }

        vm.toggle()
        #expect(vm.isVisible)
        try await waitUntil(vm.state == .running)

        shell.continuation.yield(Array("hallo".utf8))
        try await waitUntil(!received.isEmpty)
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
        try await waitUntil(vm.state == .running)
        #expect(await counter.value == 1)
    }

    @Test func streamEndSetsEnded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        shell.continuation.finish()
        try await waitUntil(vm.state == .ended(nil))
    }

    @Test func streamErrorSetsEndedWithMessage() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        shell.continuation.finish(throwing: RemoteFSError.protocolError(reason: "kaputt"))
        try await waitUntil({
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }())
    }

    @Test func openFailureSetsEnded() async throws {
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            throw RemoteFSError.connectionFailed(reason: "nein")
        })
        vm.toggle()
        try await waitUntil({
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }())
    }

    @Test func reopenAfterEndedWorks() async throws {
        let shells = ShellFactory()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in await shells.next() })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        await shells.current.close()
        try await waitUntil(vm.state == .ended(nil))
        vm.openIfNeeded()  // "Reopen" button
        try await waitUntil(vm.state == .running)
        #expect(await shells.count == 2)
    }

    @Test func sendForwardsToShell() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        vm.send(Array("ls\n".utf8))
        try await waitUntil(!shell.sent.isEmpty)
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
        try await waitUntil(vm.state == .running)

        for i in 0..<totalChunks {
            vm.send([UInt8(i)])
        }
        try await waitUntil(shell.recorded.count == totalChunks)
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
        try await waitUntil(vm.state == .running)
        // No onOutput set (panel hidden) — chunks must not be lost
        shell.continuation.yield(Array("verborgen".utf8))
        try await waitUntil(!vm.replayBuffer.isEmpty)
        #expect(vm.replayBuffer.flatMap { $0 } == Array("verborgen".utf8))
        // New consumer (re-mount) sees buffer + live data
        var received: [[UInt8]] = []
        vm.onOutput = { received.append($0) }
        shell.continuation.yield(Array("live".utf8))
        try await waitUntil(!received.isEmpty)
    }

    /// Regression: the replay buffer must not grow unbounded — it is
    /// capped at `maxReplayBytes` (256 KiB); the oldest chunks are evicted.
    @Test func replayBufferIsBounded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        shell.continuation.yield([UInt8](repeating: 1, count: 200_000))
        shell.continuation.yield([UInt8](repeating: 2, count: 200_000))
        // Waits for the SECOND chunk to arrive (not just "buffer satisfies
        // the bound", since a still-empty buffer trivially satisfies the
        // bound and would end the poll immediately — before the actual
        // processing happens).
        try await waitUntil(vm.replayBuffer.last?.last == 2)
        #expect(vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024)
        #expect(vm.replayBuffer.last?.last == 2)  // Newest is kept
    }

    @Test func shutdownClosesShellAndHides() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
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
        try await waitUntil(vm.state == .running)

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

        try await waitUntil(vm.state == .running)
        try await waitUntil(!shell.sent.isEmpty)
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
        try await waitUntil(vm.state == .running)
        vm.send([4])
        try await waitUntil(shell.sent.flatMap { $0 }.count == 4)
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
        try await waitUntil({
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }())

        vm.openIfNeeded()  // "Reopen"
        try await waitUntil(vm.state == .running)
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
        try await waitUntil(vm.state == .running)
        vm.send([1])                  // Enters the chain and never finishes.
        try await waitUntil(first.sendCalls == 1)

        first.finish()                // Shell ends -> `.ended`.
        try await waitUntil(vm.state == .ended(nil))

        vm.openIfNeeded()             // "Reopen" -> second shell.
        try await waitUntil(vm.state == .running)
        vm.send([7])

        try await waitUntil(!second.sent.isEmpty)
        #expect(second.sent.flatMap { $0 } == [7])
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

        try await waitUntil(vm.state == .running)
        try await waitUntil(!shell.sent.isEmpty)
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
final class LateFinishShell: RemoteShell, @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    private var _finished = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    var output: AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream<[UInt8], Error> { [weak self] in
            while true {
                guard let self else { return nil }
                self.lock.lock()
                let finished = self._finished
                self.lock.unlock()
                if finished { return nil }
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
        lock.lock(); _closed = true; lock.unlock()
    }
    func finish() {
        lock.lock(); _finished = true; lock.unlock()
    }
}

/// Shell whose `send(_:)` never returns on its own — it sleeps until the
/// surrounding task is cancelled. Stands in for a send that is still in
/// flight when the shell ends (a stalled connection); `finish()` ends the
/// output stream the way a closing shell does.
final class HangingSendShell: RemoteShell, @unchecked Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let lock = NSLock()
    private var _sendCalls = 0
    var sendCalls: Int { lock.lock(); defer { lock.unlock() }; return _sendCalls }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {
        lock.lock(); _sendCalls += 1; lock.unlock()
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
final class InvertedDelayShell: RemoteShell, @unchecked Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let totalChunks: Int
    private let lock = NSLock()
    private var _recorded: [Int] = []
    var recorded: [Int] { lock.lock(); defer { lock.unlock() }; return _recorded }

    init(totalChunks: Int) {
        self.totalChunks = totalChunks
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }

    func send(_ bytes: [UInt8]) async throws {
        let i = Int(bytes[0])
        let delayMs = (totalChunks - i) * 2
        try await Task.sleep(for: .milliseconds(delayMs))
        lock.lock(); _recorded.append(i); lock.unlock()
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
@Suite("TerminalPanelViewModel delivery callback")
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
    /// It is event-driven WITH A CEILING, and the ceiling is not the timing
    /// budget the old poll's deadline was. The first version of this had no
    /// bound at all, and a review measured what that costs: mutate
    /// `onDelivered?()` in `TerminalPanelViewModel.send` to never fire, and
    /// this suite ran past ninety seconds instead of failing in five with a
    /// diagnosis. That trades a flaky test for a hung suite, in a repository
    /// whose backlog already carries a suite-hang incident. The bound is
    /// deliberately far outside any scheduling delay -- it is not there to
    /// decide the race, it is there so a callback that will NEVER fire ends
    /// as a red test with a message instead of as a runner that never
    /// returns.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var continuation: CheckedContinuation<Void, Never>?

        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

        func bump() {
            lock.lock()
            _count += 1
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }

        /// Waits for the first delivery, or gives up after `timeout` and
        /// reports which happened. The caller asserts on the count either
        /// way, so a give-up lands on the diagnostic rather than on a
        /// bare timeout message.
        @discardableResult
        func waitForFirstDelivery(timeout: Duration = .seconds(30)) async -> Bool {
            let waiter = Task { await self.parkUntilDelivered() }
            let ceiling = Task {
                try? await Task.sleep(for: timeout)
                // Resuming the continuation from here is what makes the
                // ceiling real: the waiter is parked on it and nothing else
                // will touch it if the callback never comes.
                self.resumePendingWaiter()
            }
            await waiter.value
            ceiling.cancel()
            return count > 0
        }

        private func parkUntilDelivered() async {
            await withCheckedContinuation { c in
                lock.lock()
                if _count > 0 {
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
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Polls instead of sleeping a fixed span: the same fixed wait that is
    /// ample when this suite runs alone is not when the whole suite runs in
    /// parallel, and a timing-dependent test that only fails under load is
    /// worse than no test.
    private func waitUntil(
        _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @Test func firesOnceWhenTheShellIsRunning() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.openIfNeeded()
        _ = await waitUntil { if case .running = vm.state { return true } else { return false } }

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
        // Reachable again, and that is the point of the ceiling: without one
        // a callback that never fires parked this wait forever and the line
        // below was dead code. It reports which half is missing -- bytes at
        // the shell but no callback is a callback bug; neither is a flush
        // bug. That message is what diagnosed the flake this suite was
        // rebuilt around.
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
        _ = await waitUntil { if case .ended = vm.state { return true } else { return false } }

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
