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
        // The whole error, not just the field: it names each reader's drained
        // state and how long every escalation phase took, which is what CI run
        // 33693297919 could not say when this line failed on an empty stderr.
        let pid = try #require(pid_t(announced), "the child announced no pid. \(error)")

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

    /// `stderrSoFar` means what it says: what the child wrote before the
    /// bound, whether or not the pipe ever reaches EOF.
    ///
    /// `readDataToEndOfFile()` returns ONLY at EOF, so a box filled that way
    /// holds everything or nothing — and "nothing" is what a caller gets
    /// exactly when the child is stuck, which is the only time this field is
    /// read. The child here backgrounds a second `sleep` that inherits the
    /// stderr write end, so killing the direct child does not close the pipe
    /// and EOF never arrives inside the escalation at all.
    ///
    /// CI run 33693297919 failed on the empty half of this: a timeout whose
    /// `stderrSoFar` was `""` could not say whether the child had written
    /// nothing or the reader had not got there, which is also why the error
    /// now reports each reader's drained state.
    @Test func aTimeoutReportsWhatTheChildWroteBeforeTheBound() async throws {
        let marker = "wrote-before-the-bound-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; sleep 60 & exec sleep 60"],
                timeout: .seconds(2))
            Issue.record("a child sleeping for 60 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        let text = String(decoding: error.stderrSoFar, as: UTF8.self)
        #expect(
            text.contains(marker),
            "stderr written before the bound was lost; the error said: \(error)")
        // The grandchild still holds the write end, so this is the case the
        // description has to be able to explain rather than merely survive.
        #expect(error.reap.stderrDrained == false)
        #expect("\(error)".contains("stderr reader"))
    }

    /// No argument VALUE reaches the failure message.
    ///
    /// Since the short waits were converted, `ssh-keygen -N <passphrase>` runs
    /// through this runner (`ConnectFailureSecrecyTests`,
    /// `Support/InstalledKey.swift`), so an argument is a secret's value and a
    /// rendered argument list is that secret sitting in a public CI log.
    ///
    /// The test itself is the second exit, and it is shut here too: `#expect`
    /// reports the SOURCE TEXT of the expression it checks, so a secret named
    /// inside an expectation leaks through the failure it is meant to prevent
    /// (CLAUDE.md, "A value a test must not leak has two exits, not one").
    /// Every `Bool` below is therefore computed first, and no message
    /// interpolates the rendered error.
    @Test func aTimeoutNamesNoArgumentValue() async throws {
        let secret = "passphrase-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "exec sleep 60", secret],
                timeout: .seconds(1))
            Issue.record("a child sleeping for 60 s returned inside a 1 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        let rendered = "\(error)"
        let rendersTheValue = rendered.contains(secret)
        #expect(rendersTheValue == false, "an argument value reached the failure message")

        // The positive half: the message still says enough to identify the
        // invocation. Without it, a `description` that rendered nothing at all
        // would satisfy the check above.
        let namesTheExecutable = rendered.contains("sh")
        let namesTheCount = rendered.contains("\(error.arguments.count) arguments")
        #expect(namesTheExecutable)
        #expect(namesTheCount)
        #expect(error.arguments.count == 3)
    }

    /// Cancellation is an outcome of its own, not a quiet "it settled".
    ///
    /// An `AsyncStream` finishes when its awaiting task is cancelled just as
    /// it does when someone finishes it, so a wait that cannot tell the two
    /// apart reports the child as settled the moment an enclosing
    /// `.timeLimit` or task group fires — and then reads `terminationStatus`
    /// off a child that is still running and walks away leaving it there.
    ///
    /// Both halves are checked here: the error that comes back out is a
    /// `CancellationError`, and the child is gone. The child announces its
    /// own pid into a file and then `exec`s `sleep`, so the pid on disk IS
    /// the process the runner owns.
    @Test func aCancelledRunKillsItsChildAndReportsCancellation() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-runner-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let pidPath = pidFile.path(percentEncoded: false)

        let task = Task { () -> SubprocessResult in
            try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo $$ > '\(pidPath)'; exec sleep 30"],
                timeout: .seconds(120))
        }

        // Cancel a RUNNING child, not the spawn: without this the test could
        // pass against a runner that only ever refuses to start.
        var announced: pid_t?
        for _ in 0..<200 where announced == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               text.hasSuffix("\n"),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                announced = value
            } else {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        let childPID = try #require(announced, "the child never announced its pid")

        let started = ContinuousClock.now
        task.cancel()
        var thrown: (any Error)?
        do {
            _ = try await task.value
            Issue.record("a cancelled run returned a result instead of reporting cancellation")
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started
        #expect(thrown is CancellationError, "cancellation surfaced as \(String(describing: thrown))")
        #expect(elapsed < .seconds(20), "the cancelled run took \(elapsed) to come back")

        var stillThere = true
        for _ in 0..<50 where stillThere {
            stillThere = kill(childPID, 0) == 0
            if stillThere { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(stillThere == false, "pid \(childPID) outlived the cancelled run")
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
