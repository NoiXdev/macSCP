// `@preconcurrency` because `SSHClient` and `TTYStdinWriter` are Citadel
// types with no `Sendable` conformance, and the layer below is no better:
// the SSH transport reaches this app through a third-party fork of Apple's
// swift-nio-ssh that branched in 2022 and never took Apple's `Sendable`
// adoption (measured in
// docs/superpowers/specs/2026-08-20-backlog-dependencies.md). Neither
// package is ours, so there is nothing to conform here.
//
// What the suppression costs: the compiler stops diagnosing
// `Sendable`-related crossings involving Citadel's types in this file.
// Moving an `SSHClient` or a `TTYStdinWriter` across an isolation boundary
// now compiles in silence, whether or not it is safe. There are two such
// crossings and each carries its own argument where it happens: the pump
// task capturing `client`, and the `Handshake` handing the writer out of
// the `withPTY` closure. `@preconcurrency` does not reach the second one's
// `sending` position, which is why that one needs a second annotation on
// top of this import.
@preconcurrency import Citadel
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

        // The pump captures `client`, a non-`Sendable` Citadel value — the
        // crossing this file's `@preconcurrency import` no longer flags. Why
        // there is no race: `withPTY` opens a CHILD channel on the
        // connection and every byte this task reads or writes belongs to
        // that child, never to the connection's own state; Citadel drives
        // both from the client's single NIO event loop, so the calls made
        // here are serialized against every other user of the same client
        // whether or not this task is the one making them.
        //
        // What would break it: code here that reached into `client` to alter
        // the connection itself — its authentication, its host-key state,
        // its lifetime — rather than to open a child channel on it. Opening
        // a second shell over the same client is fine and is what the child
        // channel is for; tearing the client down from in here is not, and
        // is why `close()` cancels only the pump and leaves the connection
        // to the window that owns it.
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
            DiagnosticLog.shared.log(.debug, "shell", "shell open")
            return CitadelShell(output: output, writer: writer, pump: pump)
        } catch {
            pump.cancel()
            // The ORIGINAL `error` (fix round 1, Structural): the previous
            // `reason=\(error)` interpolated the raw handshake error
            // directly.
            DiagnosticLog.shared.log(.debug, "shell", "shell open failed", reason: error)
            // The thrown reason follows the same rule as the log line:
            // `localizedDescription`, never the bare value — describing an
            // arbitrary error prints its stored properties
            // (`DialSupport.reason(for:)`'s rule; `CitadelFileSystem
            // .connectFailureText(for:)` is the connect-time twin). The
            // browser banner and the diagnostic log drop a `.protocolError`'s
            // text; the CLI and the transfer queue still render it, and
            // this keeps the construction site honest for either.
            throw RemoteFSError.protocolError(
                reason: "failed to open shell: \(error.localizedDescription)")
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
        DiagnosticLog.shared.log(.debug, "shell", "shell close")
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
        // `resume(with:)` takes its result as `sending`, and `new` was just
        // stored in `result` — so as far as region analysis is concerned the
        // value is shared with `self` and may not be handed on. That is a
        // statement about `TTYStdinWriter`, a Citadel type with no
        // `Sendable` conformance; `@preconcurrency` does not reach a
        // `sending` position, so the check is switched off for this one
        // value instead.
        //
        // Why there is no race: exactly one consumer ever receives the
        // writer. The lock makes the first resolution the only one — every
        // later call returns at the guard — and `writer()` has a single call
        // site, in `open`, which awaits it once for a `Handshake` that is
        // created there and never escapes. The copy left behind in `result`
        // exists only so a resolution that arrives BEFORE that await is not
        // lost; nothing reads it afterwards. From there the writer belongs
        // to the one `CitadelShell` `open` returns.
        //
        // What would break it: a second `writer()` call, or handing a
        // `Handshake` to anyone but the `open` that made it — then two
        // holders of the same writer would exist and the argument above is
        // gone.
        nonisolated(unsafe) let resolved = new
        pending?.resume(with: resolved)
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
