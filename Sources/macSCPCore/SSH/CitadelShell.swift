import Citadel
import Foundation
import NIOCore
import NIOSSH

/// RemoteShell auf Basis von Citadels `withPTY`.
///
/// Citadels API ist closure-gescoped: der Shell-Kanal lebt genau so lange wie
/// die an `withPTY` übergebene Closure. Diese Klasse invertiert das — eine
/// Pump-Task hält die Closure im Lese-Loop offen, bis `close()` sie cancelt.
/// Die Cancellation beendet die for-await-Schleife, die Closure kehrt zurück,
/// `withPTY` schließt den Kanal (nur den Child-Channel, nie die Verbindung).
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

    /// Öffnet die PTY-Shell; kehrt erst zurück, wenn pty-req + shell bestätigt
    /// sind (Writer verfügbar) oder der Aufbau fehlgeschlagen ist.
    static func open(
        client: SSHClient, terminal: String, cols: Int, rows: Int
    ) async throws -> CitadelShell {
        let (output, outCont) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        let handshake = Handshake()

        let pump = Task {
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
                }
                outCont.finish()
            } catch is CancellationError {
                // close() — bewusst kein Fehler für den Konsumenten
                outCont.finish()
            } catch {
                // Aufbau- ODER Laufzeitfehler: Handshake ggf. lösen (no-op,
                // falls schon succeeded) und den Stream fehlerhaft beenden.
                handshake.fail(error)
                outCont.finish(throwing: error)
            }
        }

        do {
            let writer = try await handshake.writer()
            return CitadelShell(output: output, writer: writer, pump: pump)
        } catch {
            pump.cancel()
            throw RemoteFSError.protocolError(
                reason: "Shell konnte nicht geöffnet werden: \(error)")
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

/// Exactly-once-Übergabe des TTYStdinWriter aus der withPTY-Closure nach außen.
/// Thread-sicher: succeed/fail können von der Pump-Task kommen, writer() vom
/// Aufrufer — wer zuerst ein Ergebnis setzt, gewinnt; Rest ist no-op.
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
