import Foundation

/// Process-wide serialization for tests that mutate the `SSH_AUTH_SOCK`
/// environment variable (M11e/T2).
///
/// `@Suite(.serialized)` only serializes tests WITHIN one suite —
/// `AgentAuthTests`, the gated agent tests in
/// `CitadelFileSystemIntegrationTests`, and the gated agent test in
/// `GoServerRSAIntegrationTests` are three DIFFERENT suites (counted
/// 2026-09-02), and Swift Testing is free to run different suites
/// concurrently. All of them
/// temporarily overwrite the same process-global `SSH_AUTH_SOCK` variable
/// (set it to a test-owned socket, run a connect, restore the original), so
/// without a lock that spans suites, one suite's mutation could interleave
/// with the other's and leave a test authenticating against the wrong agent.
///
/// This actor is that cross-suite lock. Every env-mutation site wraps its
/// set/restore critical section in `AgentEnvLock.shared.run { ... }` — an
/// actor (rather than a plain `NSLock`) so the critical section can safely
/// span `await` points (the connect calls inside it) without blocking a
/// cooperative-pool thread while holding a lock.
actor AgentEnvLock {
    static let shared = AgentEnvLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with exclusive ownership of the lock, for the whole
    /// duration `SSH_AUTH_SOCK` is set to a test-owned value.
    ///
    /// `nonisolated` so `body` and its result never cross this actor's
    /// boundary — the callers hand in closures that capture test-local,
    /// non-`Sendable` state, and there is no reason for that state to visit
    /// the lock. Only `acquire`/`release` are isolated, and neither carries
    /// a value. The release is spelled out on both paths rather than left to
    /// `defer`, because it now has to be awaited: the ordering is unchanged
    /// — the lock is still given up before `run` returns or rethrows.
    nonisolated func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}
