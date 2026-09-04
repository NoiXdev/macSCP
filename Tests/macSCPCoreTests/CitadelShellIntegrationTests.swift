import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// Only runs with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d — from the MAIN checkout).
///
/// `.timeLimit(.minutes(2))`, not the project default of one: six `@Test`s,
/// each opening through `connectWithRetry()`, whose own budget is
/// `connectTimeout: .seconds(30)` twice (first attempt plus one retry)
/// separated by a 500 ms sleep — 60.5 s worst case, already past a
/// one-minute limit before a single command reaches the remote.
/// `windowChangeReachesTheRemotePTY` adds an 800 ms local sleep and a
/// remote `sleep 3` on top of that. Two minutes is that connect budget
/// plus headroom for the remote round trip, not a duration this file
/// measures anything against.
@Suite("CitadelShell against Docker SSH server",
       .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
       .serialized,
       .timeLimit(.minutes(2)))
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

    /// Collects output chunks until the marker shows up.
    ///
    /// No timeout of its own. This used to race the read against a
    /// `Task.sleep` child, which is a wall-clock ceiling under another
    /// spelling — on a loaded runner the sleeper could win while the marker
    /// was on its way (CLAUDE.md, "A wall-clock ceiling in a test measures
    /// the runner"). The read now ends when the marker arrives, when the
    /// stream ends without it, or when the suite's `.timeLimit` cancels the
    /// test.
    ///
    /// That third ending still reaches the diagnostic below rather than
    /// parking the run: measured 2026-09-04, cancelling a task iterating an
    /// `AsyncThrowingStream` FINISHES the stream — `next()` returns nil and
    /// the loop returns normally, it does not throw `CancellationError`. So
    /// a marker that never comes falls out of the loop and throws with the
    /// partial text, which is the whole point of reporting it.
    private func collectUntil(_ shell: any RemoteShell, marker: String) async throws -> String {
        // A plain `var`: there is one reader and no second task to race it.
        var collected = ""
        for try await chunk in shell.output {
            collected += String(decoding: chunk, as: UTF8.self)
            if collected.contains(marker) { return collected }
        }
        throw RemoteFSError.protocolError(reason: "marker not found in: \(collected)")
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
        // Stream must end cleanly (no error) — an `exit` is not an error
        // case, even though Citadel's withPTY internally throws a
        // ChannelError.alreadyClosed when closing the already-dead channel.
        //
        // Awaited directly, where this used to race a ten-second sleeper for
        // the same reason `collectUntil` above no longer does. `ended` still
        // means "the stream ended, rather than the wait running out"; only
        // what runs the wait out has changed, from that sleeper to the
        // suite's `.timeLimit`. It is read off `Task.isCancelled` because
        // the loop cannot report the difference: cancelling a task iterating
        // an `AsyncThrowingStream` finishes the stream normally (measured
        // 2026-09-04), so a cancelled read and a real end return by the same
        // path and only the flag tells them apart.
        var thrown: Error?
        do { for try await _ in shell.output {} } catch { thrown = error }
        let ended = !Task.isCancelled
        #expect(ended, "output stream must end after exit")
        #expect(
            thrown == nil,
            "a clean exit must not produce an error: \(String(describing: thrown))")
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

        let out = try await collectUntil(shell, marker: "AFTER:")
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
