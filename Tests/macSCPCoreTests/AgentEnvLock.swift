import Foundation

/// Process-wide serialization for tests that mutate the `SSH_AUTH_SOCK`
/// environment variable (M11e/T2).
///
/// `@Suite(.serialized)` only serializes tests WITHIN one suite —
/// `AgentAuthTests` and the gated agent tests in
/// `CitadelFileSystemIntegrationTests` are two DIFFERENT suites, and Swift
/// Testing is free to run different suites concurrently. Both suites
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
    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
