import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(5)))
struct ArchiveRunnerTests {
    /// A real `zip` over a real directory. No network, no rig: the local
    /// runner's whole job is argv plus bytes, and this is the cheapest place
    /// to prove a hostile name survives it.
    @Test func thelocalRunnerCompressesAnApostropheAndADollarSign() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let awkward = "it's $(not) run"
        try Data("payload\n".utf8).write(to: dir.appendingPathComponent(awkward))

        let plan = try ArchivePlan.compress(
            .zip,
            selection: [RemoteFileItem(
                name: awkward, path: dir.appendingPathComponent(awkward).path, kind: .file)],
            workingDirectory: dir.path, archiveName: "out.zip")
        let outcome = try await LocalArchiveRunner().run(plan)

        #expect(outcome == .finished)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("out.zip").path))
        // Still there: the name was data, not code.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(awkward).path))
    }

    @Test func thelocalRunnerReportsAMissingToolApart() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: dir.path,
            tool: "macscp-no-such-archiver", words: [.operand("x")], stdin: nil)
        await #expect(throws: ArchiveFailure.toolMissing(tool: "macscp-no-such-archiver")) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    @Test func theremoteRunnerHandsThePlanToItsChannel() async throws {
        let channel = RecordingArchiveChannel()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        let outcome = try await RemoteArchiveRunner(channel: channel).run(plan)
        #expect(outcome == .finished)
        #expect(await channel.lines.count == 1)
    }

    /// The positive half and the negative half sit together: a backend that
    /// answers the capability yields a runner, one that does not yields none.
    @Test func aBackendIsAskedForTheCapabilityInsideTheModule() async throws {
        #expect(RemoteArchiveRunner(backend: RecordingArchiveChannel()) != nil)
        #expect(RemoteArchiveRunner(backend: "not a channel") == nil)
    }

    @Test func theremoteRunnerTurns127IntoAMissingTool() async throws {
        let channel = FailingArchiveChannel(exitCode: 127)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.toolMissing(tool: "zip")) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    @Test func theremoteRunnerKeepsAnyOtherExitStatusAsItIs() async throws {
        let channel = FailingArchiveChannel(exitCode: 12)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.exited(status: 12)) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    /// A FLOOR, not a ceiling: the runner must not return before the tool
    /// has finished. A ceiling here would measure the machine, which this
    /// project has three CI reds on record for.
    @Test func thelocalRunnerDoesNotReturnBeforeTheArchiveExists() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<200 {
            try Data(repeating: 0x41, count: 4096)
                .write(to: dir.appendingPathComponent("f\(index)"))
        }
        let selection = (0..<200).map { index in
            RemoteFileItem(
                name: "f\(index)", path: dir.appendingPathComponent("f\(index)").path,
                kind: .file)
        }
        let plan = try ArchivePlan.compress(
            .zip, selection: selection, workingDirectory: dir.path,
            archiveName: "many.zip")
        _ = try await LocalArchiveRunner().run(plan)

        // The floor, stated as a COUNT rather than as an outcome: if `run`
        // returned before `zip` had finished, the archive would hold fewer
        // than the 200 entries that went in. An earlier version of this case
        // asserted only `== .finished` on a second run, which every
        // implementation passes including one that returns immediately --
        // a test that could not fail is worse than no test, so it was
        // replaced rather than kept.
        let listed = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", "./many.zip"],
            currentDirectory: dir,
            timeout: ArchiveBudget.run)
        let entryCount = listed.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true).count
        #expect(entryCount == 200)
    }
}
