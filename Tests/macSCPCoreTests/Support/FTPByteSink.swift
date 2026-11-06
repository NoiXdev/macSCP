import Foundation
import Synchronization

/// Where a test's transfer drain puts the bytes it read.
///
/// It exists because `FTPDataConnection.transfer`'s drain is `@Sendable` —
/// the closure is handed to an actor, and the 522 retry may hand it over
/// twice, which rules out `sending` — so a drain cannot accumulate into a
/// mutable local. A `Mutex` is noncopyable and cannot itself be captured by
/// such a closure, which is why this is a class and not a `Mutex` at the
/// call site.
///
/// `count` and `matches(_:)` are what the expectations read: a test that
/// compared the `Data` itself would print a file's contents into a failure
/// message.
final class FTPByteSink: Sendable {
    private let box = Mutex(Data())

    init() {}

    func append(_ chunk: Data) {
        box.withLock { $0.append(chunk) }
    }

    var count: Int { box.withLock { $0.count } }

    /// Whether what was read is exactly `expected`. A `Bool`, computed
    /// before any expectation touches it.
    func matches(_ expected: Data) -> Bool {
        box.withLock { $0 == expected }
    }
}
