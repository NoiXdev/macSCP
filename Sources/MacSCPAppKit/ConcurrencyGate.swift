import Foundation

/// At most `limit` bodies run at once; the rest wait their turn.
///
/// The lock read is two signed requests per version with no batch form, so a
/// long history must not turn into hundreds of requests in flight. A waiter
/// whose task was cancelled still waits for a slot and then returns without
/// running its body: the wait is bounded by the reads in front of it, which
/// are themselves cancelled, and not tracking a continuation per waiter keeps
/// there nothing to strand.
@MainActor
final class ConcurrencyGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit >= 1, "a gate that admits nobody would park every caller forever")
        self.limit = limit
    }

    /// Runs `body` when a slot is free. `nil` when the calling task was
    /// cancelled by the time the slot came.
    func run<T>(_ body: () async -> T) async -> T? {
        if running >= limit {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running += 1
        }
        // A slot is held here in both branches: the waiter was handed one.
        defer {
            if waiters.isEmpty {
                running -= 1
            } else {
                waiters.removeFirst().resume()
            }
        }
        if Task.isCancelled { return nil }
        return await body()
    }
}
