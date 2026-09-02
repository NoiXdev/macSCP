import Foundation
import Testing

/// What `SubprocessRunner` has to get right for the suites that replaced
/// their blocking child waits with it: the exit status and both streams of a
/// normal child, an output volume no pipe buffer holds, a child that outlives
/// its bound, and the three inputs a caller can hand it.
@Suite("SubprocessRunner")
struct SubprocessRunnerTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func aNormalChildReportsItsStatusAndBothStreams() async throws {
        let result = try await SubprocessRunner.run(
            Self.shell,
            arguments: ["-c", "printf 'on stdout'; printf 'on stderr' >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdoutText == "on stdout")
        #expect(result.stderrText == "on stderr")
    }

    /// 256 KB down each stream, both written at once by backgrounded
    /// commands. A pipe's kernel buffer is a few tens of kilobytes, so a
    /// runner that drained one stream to EOF before starting on the other
    /// would deadlock here: the child would block writing to the stream
    /// nobody is reading, and so never reach EOF on the one that is.
    @Test func aChildFillingBothPipesIsDrainedWithoutDeadlock() async throws {
        let block = 256 * 1024
        let result = try await SubprocessRunner.run(
            Self.shell,
            arguments: [
                "-c",
                """
                dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'a' &
                dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'b' >&2 &
                wait
                """,
            ],
            timeout: .seconds(30))
        #expect(result.status == 0)
        #expect(result.stdout.count == block)
        #expect(result.stderr.count == block)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "b") })
    }

    /// The child announces its own pid and then `exec`s `sleep`, so the pid
    /// on stderr IS the process this runner owns — not a shell that would
    /// leave an orphan behind when it dies.
    ///
    /// Two things are checked, and the second is the one that matters: the
    /// throw arrives near the bound rather than at the child's own 30 s, and
    /// the pid is gone afterwards. A runner that gave up without killing
    /// would satisfy the first and fail the second.
    @Test func aChildThatOutlivesItsBoundThrowsAndIsKilled() async throws {
        let started = ContinuousClock.now
        var timeout: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo $$ >&2; exec sleep 30"],
                timeout: .seconds(2))
            Issue.record("a child that sleeps for 30 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            timeout = error
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(20), "the bound did not end the wait: \(elapsed)")

        let error = try #require(timeout)
        let announced = String(decoding: error.stderrSoFar, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(announced), "the child did not announce a pid: '\(announced)'")

        // Foundation reaps the child on its own thread once it dies, and
        // `kill(pid, 0)` still succeeds against a zombie — so this allows a
        // moment for the reap rather than reading once and hoping.
        var stillThere = true
        for _ in 0..<50 where stillThere {
            stillThere = kill(pid, 0) == 0
            if stillThere { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(stillThere == false, "pid \(pid) survived the timeout")
    }

    /// 128 KB in, so the writer proves it does not deadlock either: a runner
    /// that wrote stdin before starting to read would stall the moment the
    /// child's output filled a pipe nobody was draining.
    @Test func stdinIsWrittenAndClosedSoTheChildSeesEOF() async throws {
        let payload = Data(repeating: UInt8(ascii: "z"), count: 128 * 1024)
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: payload)
        #expect(result.status == 0)
        #expect(result.stdout == payload)
    }

    @Test func theEnvironmentAndWorkingDirectoryReachTheChild() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-subprocess-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("marker").path(percentEncoded: false),
            contents: Data())

        let listed = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/ls"), arguments: [], currentDirectory: directory)
        #expect(listed.status == 0)
        #expect(listed.stdoutText.contains("marker"))

        let probed = try await SubprocessRunner.run(
            Self.shell,
            arguments: ["-c", "printf '%s' \"$MACSCP_RUNNER_PROBE\""],
            environment: ["MACSCP_RUNNER_PROBE": "reached"])
        #expect(probed.stdoutText == "reached")
    }
}
