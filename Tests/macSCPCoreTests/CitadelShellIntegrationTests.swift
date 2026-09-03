import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// State two task-group children share for the length of one test.
///
/// A reference rather than a captured `var`: a task-group child closure is
/// escaping and concurrent, so a `var` of the enclosing function would be
/// mutated from one task while another reads it. `NSLock` rather than
/// `Mutex` because the boxed value may be an `Error?`, which is not
/// `Sendable` — the same reason `FirstResult` in `WebDAVFileSystemWriteTests`
/// is built this way.
///
/// `@unchecked` because that non-`Sendable` payload is what the box exists to
/// carry. There is no unsynchronized state to race on: `value` is private and
/// every read and write goes through `withLock`. That argument breaks the
/// moment anything reaches the storage without taking the lock.
private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Only runs with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d — from the MAIN checkout).
@Suite("CitadelShell against Docker SSH server",
       .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
       .serialized)
struct CitadelShellIntegrationTests {
    /// Standard password connect against the Docker test server (127.0.0.1:2222,
    /// testuser/testpass) with a retry against the container's reconnect
    /// throttling. Matches the pattern from CitadelFileSystemIntegrationTests.
    private func connectWithRetry() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))
        let knownHostsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        // The store is only consulted DURING the connect (TOFU upsert); once
        // this function returns, the directory is dead weight — remove it so
        // repeated gated runs stop littering the temp directory (M11e/T3,
        // same sweep the other two integration suites already had).
        defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
        let store = KnownHostsStore(directory: knownHostsDirectory)
        do {
            return try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
    }

    /// Collects output chunks until the marker shows up or the timeout hits.
    private func collectUntil(
        _ shell: any RemoteShell, marker: String, timeout: Duration = .seconds(10)
    ) async throws -> String {
        // The reader child appends here while the timeout child may finish
        // and the failure message may read it — a plain captured `var` is a
        // genuine race between the two, not just a diagnostic. The box keeps
        // the partial text available to the message, which is the whole
        // point of reporting it.
        let collected = Shared("")
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await chunk in shell.output {
                    let text = collected.withLock { value -> String in
                        value += String(decoding: chunk, as: UTF8.self)
                        return value
                    }
                    if text.contains(marker) { return text }
                }
                return nil
            }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let first = try await group.next()!
            group.cancelAll()
            guard let result = first, result.contains(marker) else {
                throw RemoteFSError.protocolError(
                    reason: "marker not found in: \(collected.withLock { $0 })")
            }
            return result
        }
    }

    @Test func echoRoundtrip() async throws {
        let fs = try await connectWithRetry()
        let shell = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await shell.send(Array("echo MACSCP_M4_$((6*7))\n".utf8))
        let out = try await collectUntil(shell, marker: "MACSCP_M4_42")
        #expect(out.contains("MACSCP_M4_42"))
        await shell.close()
        await fs.disconnect()
    }

    @Test func sftpStillWorksAfterShellClose() async throws {
        let fs = try await connectWithRetry()
        let shell = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await shell.send(Array("echo ready\n".utf8))
        _ = try await collectUntil(shell, marker: "ready")
        await shell.close()
        // The SFTP channel must survive the shell close (same connection!)
        let items = try await fs.list(path: "/")
        #expect(!items.isEmpty)
        await fs.disconnect()
    }

    @Test func shellExitEndsOutputStream() async throws {
        let fs = try await connectWithRetry()
        let shell = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await shell.send(Array("exit\n".utf8))
        // Stream must end cleanly (no timeout, no error) — an `exit` is not
        // an error case, even though Citadel's withPTY internally throws a
        // ChannelError.alreadyClosed when closing the already-dead channel.
        // Written by the reader child, read by the expectation after the
        // group returns — the same cross-task hand-off as `collectUntil`.
        let thrown = Shared<Error?>(nil)
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { for try await _ in shell.output {} } catch {
                    thrown.withLock { $0 = error }
                }
                return true
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        let thrownError = thrown.withLock { $0 }
        #expect(ended, "output stream must end after exit")
        #expect(
            thrownError == nil,
            "a clean exit must not produce an error: \(String(describing: thrownError))")
        await shell.close() // idempotent after self-exit
        await fs.disconnect()
    }

    @Test func resizeDoesNotThrow() async throws {
        let fs = try await connectWithRetry()
        let shell = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await shell.resize(cols: 120, rows: 40)
        await shell.close()
        await fs.disconnect()
    }

    /// The last hop of the terminal-resize chain, measured rather than
    /// assumed (Polish milestone, Task 1): `resize` -> `changeSize` -> SSH
    /// `WindowChangeRequest` -> the remote PTY's own geometry. `resizeDoesNotThrow`
    /// above only proves the request left the client; `stty size` is the
    /// remote side answering what it actually has.
    ///
    /// One command line, one consumer of `shell.output`: the remote sleeps
    /// between the two `stty size` calls and the resize is sent during that
    /// sleep, so the second reading is necessarily taken after the window
    /// change. The two markers are written split (`"B""EFORE:"`) because the
    /// PTY echoes the command line back — a marker spelled whole would match
    /// its own echo instead of the output.
    @Test func windowChangeReachesTheRemotePTY() async throws {
        let fs = try await connectWithRetry()
        let shell = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await shell.send(Array(
            "echo \"B\"\"EFORE:$(stty size)\"; sleep 3; echo \"A\"\"FTER:$(stty size)\"\n".utf8))
        try await Task.sleep(for: .milliseconds(800))
        try await shell.resize(cols: 120, rows: 40)

        let out = try await collectUntil(shell, marker: "AFTER:", timeout: .seconds(20))
        let before = Self.value(after: "BEFORE:", in: out)
        let after = Self.value(after: "AFTER:", in: out)
        #expect(before == "24 80", "remote PTY started at \(String(describing: before))")
        #expect(
            after == "40 120",
            """
            The remote PTY reports \(String(describing: after)) after a \
            resize(cols: 120, rows: 40) — it was \(String(describing: before)).
            """)
        await shell.close()
        await fs.disconnect()
    }

    /// `stty size`'s answer ("<rows> <cols>") on the first line that carries
    /// `marker`, trimmed. `nil` when the marker never showed up.
    private static func value(after marker: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            guard let range = line.range(of: marker) else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    @Test func reopenAfterCloseWorks() async throws {
        let fs = try await connectWithRetry()
        let first = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        await first.close()
        let second = try await fs.openShell(terminal: "xterm-256color", cols: 80, rows: 24)
        try await second.send(Array("echo again\n".utf8))
        _ = try await collectUntil(second, marker: "again")
        await second.close()
        await fs.disconnect()
    }
}
