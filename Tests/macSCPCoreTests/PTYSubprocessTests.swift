import Foundation
import MacSCPTestSupport
import Testing

/// `PTYSubprocess` itself, ungated: nothing here needs the Docker rig or the
/// built `macscp-cli` binary, only Darwin's own `/usr/bin/tty` and `/bin/sh`.
///
/// The bound below is the harness's `.timeLimit`, never a ceiling on how
/// long a case takes (CLAUDE.md, "A wall-clock ceiling in a test measures
/// the runner") — every wait in here is an `await` on `PTYSubprocess.run`
/// or on its `Handle.output`, never a sleep guessed to be "long enough".
@Suite("PTYSubprocess", .timeLimit(.minutes(1)))
struct PTYSubprocessTests {
    /// The positive this whole file exists to establish: `/usr/bin/tty`
    /// prints a real `/dev/ttysNNN` path, which it does if and only if its
    /// stdin really is a terminal. Every other case in this file, and the
    /// gated pair in `CLIMatrixITests.swift`, leans on this one having
    /// measured that the PTY setup actually produces a controlling
    /// terminal — see `PTYSubprocess.swift`'s own doc comment for the
    /// `adddup2`-only shape that does NOT and printed nothing here instead.
    @Test func ttyReportsARealTerminalPath() async throws {
        let result = try await PTYSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/tty"),
            arguments: [],
            environment: [:])
        #expect(
            result.output.hasPrefix("/dev/ttys"),
            "tty printed \(result.output.debugDescription), not a /dev/ttys path")
        #expect(result.status == 0, "tty exited \(result.status)")
        #expect(result.signal == nil, "tty was ended by a signal: \(String(describing: result.signal))")
    }

    /// A round trip through the terminal: `sh` blocks on `read`, this writes
    /// an answer through the `Handle`, and the child's own echo of it comes
    /// back on the same stream it was written to.
    @Test func writingToTheHandleAnswersAWaitingRead() async throws {
        let result = try await PTYSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read x; echo got:$x"],
            environment: [:]
        ) { handle in
            handle.write("hello\n")
        }
        #expect(
            result.output.contains("got:hello"),
            "output \(result.output.debugDescription) did not contain the echoed answer")
        #expect(result.status == 0, "sh exited \(result.status)")
    }

    /// `terminate()` ends a child that never exits on its own, and the
    /// `Result` says which signal did it — the positive beside
    /// `ttyReportsARealTerminalPath`'s "a normal exit reports no signal":
    /// without this case, a `Result.signal` that always reported `nil` would
    /// satisfy every other assertion in this file.
    ///
    /// `terminate()` sends SIGKILL (`PTYSubprocess.Handle.terminate()`), so
    /// that is the signal this measures — not SIGTERM.
    @Test func terminateEndsAChildWithASignal() async throws {
        let result = try await PTYSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            environment: [:]
        ) { handle in
            // Long enough for the child to have reached `sleep`'s own wait,
            // short enough not to matter: this is not the bound the case is
            // measured against, `terminate()` ending the child is.
            try await Task.sleep(for: .milliseconds(100))
            handle.terminate()
        }
        #expect(result.signal == SIGKILL, "sleep was ended by \(String(describing: result.signal)), not SIGKILL")
    }

    /// A child that runs to completion on its own, with no `interact` at
    /// all — `PTYSubprocess.run`'s default argument — reports the plain exit
    /// code a normal run leaves behind.
    @Test func aNormalExitReportsItsStatusAndNoSignal() async throws {
        let result = try await PTYSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            environment: [:])
        #expect(result.status == 7, "sh -c 'exit 7' reported status \(result.status)")
        #expect(result.signal == nil, "a normal exit reported a signal: \(String(describing: result.signal))")
    }
}
