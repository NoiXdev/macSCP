import Synchronization

/// A value per key, computed and then remembered, with no reader ever
/// waiting for another reader's computation.
///
/// A reader that misses computes the value itself, OUTSIDE the lock, then
/// publishes it in a short critical section; if another reader published
/// first, that value wins. The lock is only ever held for a dictionary
/// lookup or update, so no cooperative-pool thread (or the main thread, in a
/// `@MainActor` suite) parks behind someone else's work.
///
/// That is the rule `SourceCorpus` lives by since fix round 1 of the
/// 2026-09-19 CI-starvation plan. Its first form kept whole-root tables in
/// `static let`s: the first reader built a whole root's blanked views on its
/// own thread while every other reader parked in Swift's one-time
/// initialisation. Measured locally over three full runs: 0.7 / 18.7 /
/// 5.6 s of Core pool thread-time and 14.9 / 16.7 / 6.8 s of AppKit pool
/// thread-time parked there — on a three-core runner, one builder and two
/// waiters are the whole pool.
///
/// Readers that want many keys at once (`values(for:compute:)`) also share
/// the work instead of duplicating it: a key another reader is computing
/// right now is skipped and come back to at the end, by which time it is
/// usually done; if it is not, the reader computes it too rather than wait.
/// Without that, a dozen tests walking the same tree at the same moment
/// each blanked every file — measured in the same fix round, the Core
/// guard suites' pool thread-time went back up to 33.0 / 39.6 / 36.4 s.
///
/// A computation that throws is the caller's to cache or not: store a
/// `Result` as the value to remember a failure, or let `compute` throw to
/// retry it on the next read.
public final class PerKeyCache<Value: Sendable>: Sendable {
    private enum Entry: Sendable {
        /// A reader has claimed the key and is computing it. Never waited
        /// on: another reader that wants it now computes it too.
        case running
        case done(Value)
    }

    private enum Claim {
        case done(Value)
        case mine
        case taken
    }

    private let store = Mutex<[String: Entry]>([:])

    public init() {}

    /// The value for `key`: remembered, or computed here.
    public func value(for key: String, compute: () throws -> Value) rethrows -> Value {
        switch claim(key) {
        case .done(let value):
            return value
        case .mine, .taken:
            return try computeAndPublish(key, compute: compute)
        }
    }

    /// The values for `keys`, in order. Keys nobody has claimed are claimed
    /// and computed in order; keys another reader is computing are left for
    /// a second pass, where each is taken if it has been published by then
    /// and computed here if it has not.
    public func values(for keys: [String], compute: (Int) throws -> Value) rethrows -> [Value] {
        var results = [Value?](repeating: nil, count: keys.count)
        var deferred: [Int] = []
        for index in keys.indices {
            switch claim(keys[index]) {
            case .done(let value): results[index] = value
            case .taken: deferred.append(index)
            case .mine: results[index] = try computeAndPublish(keys[index]) { try compute(index) }
            }
        }
        for index in deferred {
            results[index] = try value(for: keys[index]) { try compute(index) }
        }
        return results.map { $0! }
    }

    private func claim(_ key: String) -> Claim {
        store.withLock { entries in
            switch entries[key] {
            case .done(let value)?: return .done(value)
            case .running?: return .taken
            case nil:
                entries[key] = .running
                return .mine
            }
        }
    }

    private func computeAndPublish(_ key: String, compute: () throws -> Value) rethrows -> Value {
        let computed: Value
        do {
            computed = try compute()
        } catch {
            // Give the claim back, so the key is not left looking busy.
            store.withLock { entries in
                if case .running? = entries[key] { entries[key] = nil }
            }
            throw error
        }
        return store.withLock { entries in
            if case .done(let first)? = entries[key] { return first }
            entries[key] = .done(computed)
            return computed
        }
    }
}
