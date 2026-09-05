import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the fix for the finding a review round caught in `LivenessProbeRace`
/// (connection-liveness plan, Task 4, fix round 1): the previous shape
/// (`withTaskGroup`) measured 3.00s against a 1s deadline when the racing
/// operation never returned at all — a task group implicitly awaits every
/// child before its own scope returns, even one abandoned via
/// `cancelAll()`, and that abandoned child cannot finish early once its
/// underlying call has actually hung (Citadel's own path into NIO ends in a
/// bare `EventLoopFuture.get()` with no cancellation handler). This is the
/// exact case the whole liveness probe exists to catch — a connection that
/// dies silently, where `stat` never returns — so a test that only ever
/// exercises a `stat` that succeeds or throws promptly would never have
/// caught the bug that shipped.
@Suite("Liveness probe race")
@MainActor
struct LivenessProbeRaceTests {
    /// A `RemoteFileSystem` whose `stat` never resumes — the same shape
    /// Citadel's own NIO bridge has today against a silently dead
    /// connection. Every other requirement is unreached by this test and
    /// traps if ever called, so a future change that routes through one of
    /// them fails loudly instead of silently passing.
    ///
    /// For `stat`, the continuation IS the API under test here: the liveness probe
    /// must detect a dead connection by RACING this call against a bound,
    /// not by relying on cancellation to unstick it — matching Citadel's
    /// real, uncancellable in-flight I/O (CLAUDE.md, architecture
    /// invariants) — so it stays a genuinely bare, never-resumed
    /// `withCheckedThrowingContinuation`.
    private struct NeverRespondingFileSystem: RemoteFileSystem {
        func list(path: String) async throws -> [RemoteFileItem] {
            fatalError("not exercised by this test")
        }

        func stat(path: String) async throws -> RemoteFileItem {
            try await withCheckedThrowingContinuation { (_: CheckedContinuation<RemoteFileItem, Error>) in
                // Deliberately never resumed.
            }
        }

        func readStream(
            path: String, fromOffset offset: UInt64
        ) async throws -> AsyncThrowingStream<Data, Error> {
            fatalError("not exercised by this test")
        }

        func write(
            path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
        ) async throws {
            fatalError("not exercised by this test")
        }

        func delete(path: String) async throws {
            fatalError("not exercised by this test")
        }

        func createDirectory(at path: String) async throws {
            fatalError("not exercised by this test")
        }

        func rename(from: String, to: String) async throws {
            fatalError("not exercised by this test")
        }

        func setPermissions(path: String, permissions: UInt32) async throws {
            fatalError("not exercised by this test")
        }

        func deleteTree(at path: String) async throws {
            fatalError("not exercised by this test")
        }

        func homeDirectoryPath() async throws -> String {
            fatalError("not exercised by this test")
        }

        func disconnect() async {}
    }

    // The deadline this test is about is enforced by the harness, not by a
    // wall-clock `#expect` below. An earlier version asserted a twenty-second
    // wall-clock ceiling on `elapsed` and CI failed it at 24.999s: both of
    // `LivenessProbeRace`'s tasks are `@MainActor`, and the main actor is
    // ONE serial executor shared by every other main-actor test running in
    // parallel. Elapsed time here therefore measures the queue depth of the
    // whole suite, not this race. Raising the number would only move the
    // hostage line; `.timeLimit` states the actual claim — this must not
    // hang — and lets the harness enforce it independently of contention.
    @Test(.timeLimit(.minutes(1)))
    func aStatThatNeverRespondsStillReportsFailureWithinTheDeadline() async {
        let fs = NeverRespondingFileSystem()
        let start = ContinuousClock.now
        let alive = await LivenessProbeRace.run(timeoutSeconds: 1) {
            (try? await fs.stat(path: "/home")) != nil
        }
        let elapsed = start.duration(to: .now)
        #expect(alive == false)
        // Lower bound: an implementation that returned `false`
        // immediately (never actually waiting out `timeoutSeconds`) would
        // still satisfy `alive == false` — this is what rules that out.
        // Contention cannot make this one fire falsely; it only ever pushes
        // elapsed time up. A small margin under the 1s deadline itself
        // (rather than requiring the full 1s) tolerates the deadline
        // firing a hair early on a busy scheduler without weakening what
        // this checks: the race genuinely waited, it did not just answer
        // `false` on the spot.
        #expect(elapsed >= .milliseconds(900))
    }

    @Test func aStatThatSucceedsQuicklyReportsSuccess() async {
        let alive = await LivenessProbeRace.run(timeoutSeconds: 5) {
            true
        }
        #expect(alive == true)
    }
}
