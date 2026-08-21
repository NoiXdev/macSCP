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

    @Test func aStatThatNeverRespondsStillReportsFailureWithinTheDeadline() async {
        let fs = NeverRespondingFileSystem()
        let start = ContinuousClock.now
        let alive = await LivenessProbeRace.run(timeoutSeconds: 1) {
            (try? await fs.stat(path: "/home")) != nil
        }
        let elapsed = start.duration(to: .now)
        #expect(alive == false)
        // Lower bound: an implementation that returned `false`
        // immediately (never actually waiting out `timeoutSeconds`) would
        // still pass `alive == false` and the upper bound alike — this is
        // what rules that out. A small margin under the 1s deadline itself
        // (rather than requiring the full 1s) tolerates the deadline
        // firing a hair early on a busy scheduler without weakening what
        // this checks: the race genuinely waited, it did not just answer
        // `false` on the spot.
        #expect(elapsed >= .milliseconds(900))
        // Upper bound, generous rather than exact — this suite runs
        // alongside the rest of the package's tests under Swift Testing's
        // default parallel execution, and MainActor scheduling under that
        // contention measured as high as 4.3s for this same 1s deadline in
        // one observed run. What this assertion actually separates is
        // "timed out as designed" from "hung on the abandoned operation
        // forever": manually swapping this file's implementation back to
        // the `withTaskGroup` shape it replaced never completed this same
        // test at all (60+ seconds, killed by hand) against the identical
        // never-responding fake, so 20s leaves generous headroom past
        // realistic scheduling noise while staying far short of that.
        #expect(elapsed < .seconds(20))
    }

    @Test func aStatThatSucceedsQuicklyReportsSuccess() async {
        let alive = await LivenessProbeRace.run(timeoutSeconds: 5) {
            true
        }
        #expect(alive == true)
    }
}
