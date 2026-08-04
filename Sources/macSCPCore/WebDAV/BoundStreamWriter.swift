import Foundation

/// Feeds the `OutputStream` half of a `Stream.getBoundStreams` pair from
/// Swift concurrency, without ever parking a thread inside
/// `OutputStream.write` and without polling for space.
///
/// Two properties of bound streams shape this type.
///
/// **`OutputStream.write` blocks, and nothing can interrupt it.** A thread
/// parked inside it on a full, unread buffer stays parked: `Task.cancel()`
/// only sets a flag, and closing either end of the pair does not release the
/// blocked writer (verified empirically). So a write is only ever issued
/// while `hasSpaceAvailable` is true, which makes every call return promptly
/// — possibly a partial write, never a block.
///
/// **Waiting for space has to be event-driven.** The pair holds a single
/// `TransferChunk.size` buffer, so any wait interval is a hard ceiling on
/// upload throughput: one buffer per wake. Polling with a 5 ms sleep caps a
/// 64 KiB buffer at roughly 12.5 MiB/s — below a gigabit LAN, let alone a
/// local server. Instead the stream is scheduled on a run loop owned by one
/// dedicated thread, and that run loop's `hasSpaceAvailable` event drives the
/// next write directly, so the writer resumes the instant the reader drains.
///
/// Every call on the stream happens on that one thread. Callers hand chunks
/// over with `perform(_:on:with:waitUntilDone:)` and await a continuation the
/// thread resumes once the chunk has been written in full.
///
/// The thread holds a strong reference to the writer for as long as it runs,
/// so `close()` is mandatory — a `defer` at the caller's top level, not a
/// happy-path call.
final class BoundStreamWriter: NSObject, StreamDelegate, @unchecked Sendable {
    /// Why an outstanding write was abandoned.
    enum Failure: Error {
        /// The caller tore the writer down itself (`close()`, or task
        /// cancellation). Carries no information worth reporting: the
        /// caller already knows why.
        case tornDown
        /// The stream's peer went away — `.errorOccurred` or
        /// `.endEncountered` fired on the underlying `OutputStream` while a
        /// write was outstanding. This is exactly what a failing
        /// `URLSessionTask` does to its body stream when it tears itself
        /// down, so on its own this case carries no more information than
        /// `tornDown` does: `WebDAVFileSystem.pumpFailure` treats it the
        /// same way, letting the transport's own error win. The one place
        /// that is NOT true is a 2xx exit, where there is no transport
        /// error to fall back to — there, this case IS the only
        /// information available and must be allowed to propagate.
        case readerGone
    }

    /// `perform(_:on:with:waitUntilDone:)` can only carry an object.
    private final class Chunk: NSObject {
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
    }

    private let stream: OutputStream
    private var thread: Thread!

    private let lock = NSLock()
    /// Guarded by `lock`. Under a lock rather than confined to the run-loop
    /// thread because teardown can come from anywhere — and because a `write`
    /// that registers its waiter *after* the thread has gone must still be
    /// resumed, or it suspends forever.
    private var terminal: Error?
    private var waiter: CheckedContinuation<Void, Error>?

    /// Touched only on `thread`.
    private var pending: [UInt8] = []
    private var position = 0
    private var stopped = false

    init(stream: OutputStream) {
        self.stream = stream
        super.init()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = RunLoop.current
            self.stream.delegate = self
            self.stream.schedule(in: runLoop, forMode: .default)
            self.stream.open()
            ready.signal()
            // `run(mode:before:)` blocks until an input source fires; the
            // scheduled stream and the queued `perform`s are those sources.
            // It returns false when no source is left at all, which would
            // otherwise strand a waiter — hence the `settle` below.
            while !stopped && runLoop.run(mode: .default, before: .distantFuture) {}
            self.stream.close()
            // Last word before the thread dies: nothing can be delivered here
            // any more, so anyone still suspended has to be released now.
            settle(Failure.tornDown)
        }
        thread.name = "dev.noix.macscp.bound-stream-writer"
        thread.start()
        self.thread = thread
        ready.wait()
    }

    /// Writes `data` in full, suspending — never blocking a thread — whenever
    /// the pair's buffer is full. Cancelling the calling task releases it
    /// immediately with a `CancellationError`.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let terminal {
                    lock.unlock()
                    continuation.resume(throwing: terminal)
                    return
                }
                // Checking `terminal` and registering the waiter under one
                // lock acquisition is what closes the race with a concurrent
                // teardown: either we see the terminal state and throw, or
                // teardown finds our waiter and resumes it.
                waiter = continuation
                lock.unlock()
                perform(#selector(enqueue(_:)), on: thread,
                        with: Chunk([UInt8](data)), waitUntilDone: false)
            }
        } onCancel: {
            terminate(with: CancellationError())
        }
    }

    /// Ends the body and tears the writer down: closes the write half so the
    /// reader sees EOF, stops the thread, and releases anyone still waiting.
    /// Idempotent, callable from any thread, safe in a `defer`.
    func close() {
        terminate(with: Failure.tornDown)
    }

    // MARK: - Teardown

    private func terminate(with error: Error) {
        settle(error)
        perform(#selector(stop(_:)), on: thread, with: nil, waitUntilDone: false)
    }

    /// Records the terminal state and releases the outstanding waiter, if any.
    /// The first error recorded wins, so a genuine stream failure is not
    /// overwritten by the teardown that follows it.
    private func settle(_ error: Error) {
        lock.lock()
        if terminal == nil { terminal = error }
        let reported = terminal!
        let outstanding = waiter
        waiter = nil
        lock.unlock()
        outstanding?.resume(throwing: reported)
    }

    // MARK: - Run-loop thread

    @objc private func enqueue(_ chunk: Chunk) {
        lock.lock()
        let terminal = self.terminal
        lock.unlock()
        if let terminal {
            complete(with: terminal)
            return
        }
        pending = chunk.bytes
        position = 0
        pumpOut()
    }

    @objc private func stop(_ unused: Any?) {
        guard !stopped else { return }
        stopped = true
        stream.close()
    }

    /// Writes as much of the outstanding chunk as the pair has room for. A
    /// write is never issued without space, so no call here can block; when
    /// the buffer fills, this simply returns and the next
    /// `hasSpaceAvailable` event resumes it.
    private func pumpOut() {
        guard !pending.isEmpty else { return }
        while position < pending.count, stream.hasSpaceAvailable {
            let written = pending.withUnsafeBufferPointer { buffer -> Int in
                stream.write(buffer.baseAddress! + position,
                             maxLength: pending.count - position)
            }
            guard written > 0 else {
                complete(with: Failure.readerGone)
                return
            }
            position += written
        }
        if position >= pending.count { complete(with: nil) }
    }

    private func complete(with error: Error?) {
        pending = []
        position = 0
        lock.lock()
        if let error, terminal == nil { terminal = error }
        let outstanding = waiter
        waiter = nil
        lock.unlock()
        guard let outstanding else { return }
        if let error {
            outstanding.resume(throwing: error)
        } else {
            outstanding.resume()
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable:
            pumpOut()
        case .errorOccurred, .endEncountered:
            // The reader went away. Release the writer instead of leaving it
            // waiting for space that will never come.
            complete(with: Failure.readerGone)
        default:
            break
        }
    }
}
