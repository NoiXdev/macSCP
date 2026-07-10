import Citadel
import Foundation
import NIOCore
import NIOSSH

/// RemoteShell based on Citadel's `withPTY`.
///
/// Citadel's API is closure-scoped: the shell channel lives exactly as long
/// as the closure passed to `withPTY`. This class inverts that — a pump task
/// keeps the closure open in the read loop until `close()` cancels it.
/// Cancellation ends the for-await loop, the closure returns, `withPTY`
/// closes the channel (only the child channel, never the connection).
public final class CitadelShell: RemoteShell, @unchecked Sendable {
    public let output: AsyncThrowingStream<[UInt8], Error>
    private let writer: TTYStdinWriter
    private let pump: Task<Void, Never>

    private init(
        output: AsyncThrowingStream<[UInt8], Error>,
        writer: TTYStdinWriter,
        pump: Task<Void, Never>
    ) {
        self.output = output
        self.writer = writer
        self.pump = pump
    }

    /// Opens the PTY shell; returns only once pty-req + shell are confirmed
    /// (writer available) or setup has failed.
    static func open(
        client: SSHClient, terminal: String, cols: Int, rows: Int
    ) async throws -> CitadelShell {
        let (output, outCont) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        let handshake = Handshake()

        let pump = Task {
            var loopCompleted = false
            do {
                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: terminal,
                        terminalCharacterWidth: cols,
                        terminalRowHeight: rows,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: SSHTerminalModes([:]))
                ) { inbound, outbound in
                    handshake.succeed(outbound)
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            outCont.yield(Array(buffer: buffer))
                        }
                    }
                    loopCompleted = true
                }
                outCont.finish()
            } catch is CancellationError {
                // close() — deliberately not an error for the consumer
                outCont.finish()
            } catch {
                // If the read loop already ran to completion normally (remote
                // closed, e.g. via `exit`), `withPTY` often internally throws
                // ChannelError.alreadyClosed while closing the already-dead
                // channel — that's not a real error for the consumer, just
                // cleanup of an already-dead channel. Only an error BEFORE the
                // loop ends (a setup or runtime error) is reported to the
                // handshake/stream as an error.
                if loopCompleted {
                    outCont.finish()
                } else {
                    handshake.fail(error)
                    outCont.finish(throwing: error)
                }
            }
        }

        do {
            let writer = try await handshake.writer()
            return CitadelShell(output: output, writer: writer, pump: pump)
        } catch {
            pump.cancel()
            throw RemoteFSError.protocolError(
                reason: "failed to open shell: \(error)")
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await writer.write(ByteBuffer(bytes: bytes))
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await writer.changeSize(
            cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    public func close() async {
        pump.cancel()
        await pump.value
    }
}

/// Exactly-once hand-off of the TTYStdinWriter out of the withPTY closure.
/// Thread-safe: succeed/fail can come from the pump task, writer() from the
/// caller — whoever sets a result first wins; the rest is a no-op.
private final class Handshake: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TTYStdinWriter, Error>?
    private var continuation: CheckedContinuation<TTYStdinWriter, Error>?

    func succeed(_ writer: TTYStdinWriter) { resolve(.success(writer)) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    private func resolve(_ new: Result<TTYStdinWriter, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = new
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: new)
    }

    func writer() async throws -> TTYStdinWriter {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}
