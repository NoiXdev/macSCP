import Foundation
import MacSCPTestSupport

/// Process-wide serialization for tests that mutate the `SSH_AUTH_SOCK`
/// environment variable (M11e/T2).
///
/// `@Suite(.serialized)` only serializes tests WITHIN one suite —
/// `AgentAuthTests` and `ConnectFailureSecrecyTests` (which take this lock
/// directly), and the gated agent tests in
/// `CitadelFileSystemIntegrationTests` and `GoServerRSAIntegrationTests`
/// (which reach it through `withAgentEnv`) are four DIFFERENT suites
/// (counted 2026-09-02, after a review found the first count one short),
/// and Swift Testing is free to run different suites
/// concurrently. All of them
/// temporarily overwrite the same process-global `SSH_AUTH_SOCK` variable
/// (set it to a test-owned socket, run a connect, restore the original), so
/// without a lock that spans suites, one suite's mutation could interleave
/// with the other's and leave a test authenticating against the wrong agent.
///
/// This is that cross-suite lock. Every env-mutation site wraps its
/// set/restore critical section in `AgentEnvLock.shared.run { ... }`.
///
/// `@unchecked Sendable` behind an `NSLock` rather than an `actor`: `acquire()`
/// routes through `awaitResumption`
/// (`Tests/MacSCPTestSupport/AwaitResumption.swift`), whose body closure
/// must be `@Sendable` to run on the unstructured task that watches for
/// cancellation — an actor's isolated state cannot be touched from a
/// `@Sendable` closure that way, so the lock takes over the isolation an
/// actor used to provide. Every critical section this lock guards is a
/// short synchronous mutation (append/remove-first on `waiters`), so an
/// `NSLock` is exactly as safe here as the actor was — the actor was chosen
/// for idiom, not because a plain lock could not do this job.
final class AgentEnvLock: @unchecked Sendable {
    static let shared = AgentEnvLock()

    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func acquire() async throws {
        try await awaitResumption { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeNow = self.lock.withLock { () -> Bool in
                if !self.isLocked {
                    self.isLocked = true
                    return true
                }
                self.waiters.append(continuation)
                return false
            }
            if shouldResumeNow { continuation.resume() }
        }
    }

    private func release() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isLocked = false
                return nil
            } else {
                return waiters.removeFirst()
            }
        }
        pending?.resume()
    }

    /// Runs `body` with exclusive ownership of the lock, for the whole
    /// duration `SSH_AUTH_SOCK` is set to a test-owned value.
    ///
    /// `throws` rather than `rethrows`: `acquire()` can itself throw
    /// `CancellationError` (if the calling task is cancelled while
    /// waiting), independently of whether `body` ever throws, which
    /// `rethrows` cannot express. The release is spelled out on both paths
    /// rather than left to `defer`, because it now has to run after an
    /// `await` — the ordering is unchanged: the lock is still given up
    /// before `run` returns or rethrows, and never given up if `acquire()`
    /// itself never completed.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
