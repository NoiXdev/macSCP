import Foundation
import Testing

@testable import macSCPCore

/// What a scripted far side did with one line it was handed.
private struct ScriptedFailure: Error {}

/// A `ChecksumCommandChannel` that records every line it is asked to run and
/// answers from a closure.
///
/// `@unchecked Sendable` for the reason `Shared` in
/// `CitadelShellIntegrationTests` is: the recorded lines are mutated from
/// whatever task `BoundedClose` runs the operation on and read from the test
/// body, and `lock` is what serializes the two. Every access to `recorded`
/// below sits inside a `withLock`; that argument breaks the moment one does
/// not.
private final class ScriptedChannel: ChecksumCommandChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let answer: @Sendable (ChecksumCommandLine, Int) async throws -> String

    /// `answer` receives the line and how many lines have been asked for
    /// before it, so a script can make the first attempt behave differently
    /// from the ones after it.
    init(answer: @escaping @Sendable (ChecksumCommandLine, Int) async throws -> String) {
        self.answer = answer
    }

    var lines: [String] { lock.withLock { recorded } }

    func standardOutput(of line: ChecksumCommandLine) async throws -> String {
        let earlier = lock.withLock { () -> Int in
            let count = recorded.count
            recorded.append(line.text)
            return count
        }
        return try await answer(line, earlier)
    }
}

/// The bounds the unit cases run under: short enough that the two cases about
/// a silent far side cost about a second each, instead of the minutes
/// `ChecksumBounds.standard` is sized for.
private let quickBounds = ChecksumBounds(probeSeconds: 1, runSeconds: 1)

/// A GNU-shaped answer for `algorithm` over `path`, as a checksum tool writes
/// it: the digest, two spaces, the path echoed back.
private func gnuShapedAnswer(_ digest: String, path: String) -> String {
    "\(digest)  \(path)\n"
}

private let sha256OfNothingMuch =
    "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

@Suite("A file's checksum, computed on the far side")
struct RemoteChecksumTests {
    /// The whole interpolation surface of the capability, exercised with a
    /// path that tries to end the shell word and start a command of its own.
    ///
    /// The equality is the positive half of this check and pins the two
    /// negative ones beside it: the line is exactly what
    /// `ChecksumCommandForm` builds, so the assertions that no `&&` and no
    /// `||` appear in it cannot quietly start scanning a line that is no
    /// longer there.
    @Test("the path reaches the far side as one quoted word, in a single line")
    func pathIsQuotedIntoOneWord() async throws {
        let path = "/srv/x'; id; '"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        let outcome = try await RemoteChecksumRun.checksum(
            forFileAt: path, algorithm: .sha256,
            over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)

        #expect(outcome == .checksum(FileChecksum.computedOnRemote(.sha256, hex: sha256OfNothingMuch)!))
        let run = try #require(channel.lines.last)
        #expect(run == ChecksumCommandForm.gnu.command(for: .sha256, path: path))
        #expect(run.contains(PosixQuoting.singleQuoted(path)))
        #expect(!run.contains("&&"))
        #expect(!run.contains("||"))
    }

    @Test("the form used is the one the connection answered to, not a guess")
    func formFollowsTheProbe() async throws {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { throw ScriptedFailure() }
            if line == ChecksumCommandForm.bsd.presenceProbeLine() { return "/usr/bin/shasum\n" }
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        _ = try await RemoteChecksumRun.checksum(
            forFileAt: path, algorithm: .sha256,
            over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)

        #expect(channel.lines.last == ChecksumCommandForm.bsd.command(for: .sha256, path: path))
    }

    /// Two requests, one probe each way — the second request asks the far
    /// side for nothing but its own digest.
    @Test("the form is asked once per connection and then remembered")
    func theFormIsRememberedAcrossRequests() async throws {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        let memory = ChecksumFormMemory()
        for _ in 0..<2 {
            _ = try await RemoteChecksumRun.checksum(
                forFileAt: path, algorithm: .sha256,
                over: channel, rememberedIn: memory, bounds: quickBounds)
        }

        let probes = channel.lines.filter { $0 == ChecksumCommandForm.gnu.presenceProbeLine().text }
        let runs = channel.lines.filter { $0 == ChecksumCommandForm.gnu.command(for: .sha256, path: path) }
        #expect(probes.count == 1)
        #expect(runs.count == 2)
        #expect(channel.lines.count == probes.count + runs.count)
    }

    @Test("a far side with no checksum tool is an answer, not a failure")
    func noToolIsAnAnswer() async throws {
        let channel = ScriptedChannel { _, _ in throw ScriptedFailure() }
        let memory = ChecksumFormMemory()
        let outcome = try await RemoteChecksumRun.checksum(
            forFileAt: "/srv/data.bin", algorithm: .sha256,
            over: channel, rememberedIn: memory, bounds: quickBounds)

        #expect(outcome == .unavailableOnThisConnection)
        #expect(channel.lines.count == ChecksumCommandForm.allCases.count)

        let again = try await RemoteChecksumRun.checksum(
            forFileAt: "/srv/data.bin", algorithm: .sha256,
            over: channel, rememberedIn: memory, bounds: quickBounds)
        #expect(again == .unavailableOnThisConnection)
        // Remembered: the second request asked the far side nothing at all.
        #expect(channel.lines.count == ChecksumCommandForm.allCases.count)
    }

    @Test("output that cannot be read is an error, never a value")
    func unreadableOutputThrows() async {
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return "sha256sum: /srv/data.bin: No such file or directory\n"
        }
        await #expect(throws: RemoteFSError.self) {
            _ = try await RemoteChecksumRun.checksum(
                forFileAt: "/srv/data.bin", algorithm: .sha256,
                over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)
        }
    }

    /// The case that decides why standard error may never be merged in: a far
    /// side that prints a line of its own alongside the digest produces
    /// output the reader refuses, and so no checksum at all.
    @Test("a second line beside the digest is refused")
    func aSecondLineIsRefused() async {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return "Welcome to the far side.\n" + gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        await #expect(throws: RemoteFSError.self) {
            _ = try await RemoteChecksumRun.checksum(
                forFileAt: path, algorithm: .sha256,
                over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)
        }
    }

    /// Deliberately NO wall-clock ceiling on the call.
    ///
    /// The property is "the caller is not held", and the OUTCOME carries it:
    /// a `RemoteFSError` can only have come from the bound firing, since the
    /// scripted far side answers nothing else for an hour. An elapsed-time
    /// expectation beside it would measure the runner rather than the code —
    /// a bound is when a sleeping task becomes RUNNABLE, not when it runs,
    /// and this suite was one of the four that lost its verdict in CI run
    /// 33741778350, where three cores were shared between 3800 tests started
    /// in one burst. Slow there is not wrong; only a different answer is.
    @Test("a far side that never answers the command does not hold the caller")
    func theRunIsBounded() async {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            try await Task.sleep(for: .seconds(3600))
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        await #expect(throws: RemoteFSError.self) {
            _ = try await RemoteChecksumRun.checksum(
                forFileAt: path, algorithm: .sha256,
                over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)
        }
    }

    /// A probe the bound had to abandon says nothing about the far side, so
    /// it is the one answer that is NOT kept: the next request asks again.
    @Test("a probe that ran out of time is not remembered")
    func anAbandonedProbeIsNotRemembered() async throws {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, earlier in
            if earlier == 0 { try await Task.sleep(for: .seconds(3600)) }
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        let memory = ChecksumFormMemory()
        let first = try await RemoteChecksumRun.checksum(
            forFileAt: path, algorithm: .sha256,
            over: channel, rememberedIn: memory, bounds: quickBounds)
        #expect(first == .unavailableOnThisConnection)

        let second = try await RemoteChecksumRun.checksum(
            forFileAt: path, algorithm: .sha256,
            over: channel, rememberedIn: memory, bounds: quickBounds)
        #expect(second == .checksum(FileChecksum.computedOnRemote(.sha256, hex: sha256OfNothingMuch)!))
    }

    @Test("the value says the far side computed it, over the file's content")
    func theValueCarriesItsProvenance() async throws {
        let path = "/srv/data.bin"
        let channel = ScriptedChannel { line, _ in
            if line == ChecksumCommandForm.gnu.presenceProbeLine() { return "/usr/bin/sha256sum\n" }
            return gnuShapedAnswer(sha256OfNothingMuch, path: path)
        }
        let outcome = try await RemoteChecksumRun.checksum(
            forFileAt: path, algorithm: .sha256,
            over: channel, rememberedIn: ChecksumFormMemory(), bounds: quickBounds)

        guard case .checksum(let checksum) = outcome else {
            Issue.record("expected a checksum, got \(outcome)")
            return
        }
        #expect(checksum.provenance == .computedOnRemote)
        #expect(checksum.describesFileContent)
    }

    /// The probe names the tool by asking the form for it, so a renamed
    /// executable moves in one place.
    @Test("the probe asks for the form's own tool and runs nothing")
    func theProbeNamesTheFormsTool() {
        #expect(
            ChecksumCommandForm.gnu.presenceProbeLine().text
                == "command -v "
                    + PosixQuoting.singleQuoted(
                        ChecksumCommandForm.gnu.executable(for: ChecksumAlgorithm.preferred)))
        #expect(
            ChecksumCommandForm.bsd.presenceProbeLine().text
                == "command -v "
                    + PosixQuoting.singleQuoted(
                        ChecksumCommandForm.bsd.executable(for: ChecksumAlgorithm.preferred)))
    }
}
