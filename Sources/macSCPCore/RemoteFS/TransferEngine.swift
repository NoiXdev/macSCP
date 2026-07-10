import Foundation

public struct TransferProgress: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64?
    /// Smoothed transfer rate in bytes/second (M5c/T5). Always `nil` coming
    /// directly from `TransferEngine` — it is computed downstream, in
    /// `TransferQueueViewModel`'s progress consumer, over a sliding window of
    /// samples. Default-`nil` param keeps every existing call site (engine,
    /// tests) source-compatible.
    public let bytesPerSecond: Double?
    /// Estimated seconds remaining (M5c/T5). `nil` until both `totalBytes`
    /// and `bytesPerSecond` are known — same provenance as `bytesPerSecond`
    /// (computed by the queue, never by the engine).
    public let etaSeconds: Double?

    public init(
        bytesTransferred: UInt64, totalBytes: UInt64?,
        bytesPerSecond: Double? = nil, etaSeconds: Double? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
    }

    /// Fraction 0…1; nil if the total size is unknown or 0.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

/// Small `Duration` <-> `Double`-seconds conversions shared by the throttle
/// below and `TransferQueueViewModel`'s rate window (M5c/T5). Internal only —
/// no public API surface needed outside the module.
extension Duration {
    var secondsAsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Named distinctly from the stdlib's integer-based `Duration.seconds(_:)`
    /// to avoid overload ambiguity.
    static func seconds(fromDouble seconds: Double) -> Duration {
        let secondsComponent = Int64(seconds)
        let attosecondsComponent = Int64(
            (seconds - Double(secondsComponent)) * 1_000_000_000_000_000_000)
        return Duration(secondsComponent: secondsComponent, attosecondsComponent: attosecondsComponent)
    }
}

public enum TransferDirection: Equatable, Sendable {
    case upload
    case download
}

/// Copies individual files between two file systems (M2c: one at a time,
/// destination gets overwritten; conflict rules and the queue arrive in M5).
public enum TransferEngine {
    /// Copies ONE file from source to destinationDirectory/fileName.
    /// Direction-agnostic (local→remote, remote→local, remote→remote).
    ///
    /// If the source stream throws mid-transfer, already-written destination
    /// data is left in place (no rollback) — retry/cleanup is M5's job.
    ///
    /// Cooperative cancellation (M5c/T2): `Task.checkCancellation()` is
    /// checked BEFORE every chunk write. If the surrounding task is cancelled
    /// (e.g. via `TransferQueueViewModel.cancelAll`), the transfer stops
    /// chunk-precisely (64 KiB) with `CancellationError`. The cancellation may
    /// leave a PARTIAL file at the destination; it is NOT rolled back —
    /// cleanup (or a resume) is the caller's job (M5d).
    /// - Parameters:
    ///   - bytesPerSecondLimit: Bandwidth throttle in bytes/s (M5c/T5); `0`
    ///     (default) turns it off — no behavior change from before T5.
    ///   - sleep: Injectable sleep hook for the throttle, default a real
    ///     `Task.sleep`. Tests replace it with a counting stub that does
    ///     NOT actually sleep (no flaky timing).
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        bytesPerSecondLimit: Int = 0,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let total = try await source.stat(path: sourcePath).size
        let input = try await source.readStream(path: sourcePath)
        let destinationPath = RemotePath.join(destinationDirectory, fileName)

        // Counting intermediary, pull-based: the destination pulls chunk by
        // chunk, nothing is buffered beyond a single chunk.
        var iterator = input.makeAsyncIterator()
        var transferred: UInt64 = 0
        // Throttle accounting (M5c/T5): a purely VIRTUAL clock that only
        // advances by the durations we hand to `sleep` — not measured by wall
        // clock. That makes the throttle deterministically testable
        // (injected `sleep` that just counts instead of sleeping), but costs
        // accuracy under real chunk latency: an already-slow connection gets
        // throttled ADDITIONALLY (never faster than the limit, possibly
        // slower). Simple sliding approach, no burst bucket (see plan).
        var throttledElapsed = Duration.zero
        let counted = AsyncThrowingStream<Data, Error>(unfolding: {
            // Cooperative cancellation BEFORE every chunk: applies chunk-precisely.
            try Task.checkCancellation()
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))

            if bytesPerSecondLimit > 0 {
                let targetElapsed = Duration.seconds(
                    fromDouble: Double(transferred) / Double(bytesPerSecondLimit))
                if throttledElapsed < targetElapsed {
                    // IMPORTANT: the `checkCancellation` above already covers
                    // chunk-precise cancellation (M5c/T2). `sleep` itself ALSO
                    // throws on task cancellation (`Task.sleep`'s default
                    // behavior) — a cancel during it discards this chunk (it's
                    // never returned/written), in addition to the check
                    // above, not in place of it.
                    try await sleep(targetElapsed - throttledElapsed)
                    throttledElapsed = targetElapsed
                }
            }
            return chunk
        })

        try await destination.write(path: destinationPath, contents: counted)

        // IMPORTANT: `AsyncThrowingStream(unfolding:)` ENDS SILENTLY when the
        // consuming task is cancelled (the next `next()` returns `nil` without
        // calling the closure again) — the `checkCancellation` above does NOT
        // catch that. The destination's consume loop therefore runs out
        // chunk-precisely (no further chunk gets written) but returns
        // regularly. Only this post-check makes the cancellation visible to
        // the caller: it throws `CancellationError`, which the queue maps to
        // `.cancelled`. The already-written PARTIAL file is left in place (no
        // rollback, see above).
        //
        // Benign edge case: if cancellation lands exactly after the LAST chunk
        // has already been written and `destination.write` has returned
        // normally, this check still observes the task as cancelled and still
        // throws `CancellationError` — the queue then reports `.cancelled`
        // even though the destination file is actually complete. That's a
        // false-negative on completeness, not a correctness bug: no data is
        // lost or corrupted, and treating a last-instant cancel as
        // `.cancelled` rather than `.finished` is the conservative, expected
        // read of "the task was cancelled" (M5c-final-review note).
        try Task.checkCancellation()
    }
}
