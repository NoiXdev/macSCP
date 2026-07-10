import Foundation
import Testing
@testable import macSCPCore

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
        let store = KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)"))
        do {
            return try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        }
    }

    /// Collects output chunks until the marker shows up or the timeout hits.
    private func collectUntil(
        _ shell: any RemoteShell, marker: String, timeout: Duration = .seconds(10)
    ) async throws -> String {
        var collected = ""
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await chunk in shell.output {
                    collected += String(decoding: chunk, as: UTF8.self)
                    if collected.contains(marker) { return collected }
                }
                return nil
            }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let first = try await group.next()!
            group.cancelAll()
            guard let result = first, result.contains(marker) else {
                throw RemoteFSError.protocolError(reason: "marker not found in: \(collected)")
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
        var thrown: Error?
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { for try await _ in shell.output {} } catch { thrown = error }
                return true
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(ended, "output stream must end after exit")
        #expect(thrown == nil, "a clean exit must not produce an error: \(String(describing: thrown))")
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
