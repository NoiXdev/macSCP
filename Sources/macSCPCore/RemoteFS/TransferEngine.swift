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
    ///   - resume: if `true` and the destination already exists SMALLER than
    ///     the source, continue from its current size (offset read + append
    ///     write) instead of starting over (M5d/T2). Destination size >=
    ///     source size is treated as "already complete" (a size-based
    ///     heuristic — no content hashing) and the call returns immediately
    ///     after reporting one final progress event at full size, WITHOUT
    ///     reading or writing anything. Destination absent (`notFound`)
    ///     behaves exactly like a fresh transfer. `false` (default) leaves
    ///     behavior byte-for-byte identical to pre-M5d: unconditional
    ///     `.overwrite` from offset 0.
    ///   - throttle: Shared bandwidth bucket (M6a); `nil` (default) means
    ///     unlimited — no throttling at all. Callers that want to pace a
    ///     direction pass ONE `BandwidthBucket` shared across all of that
    ///     direction's concurrent transfers, so the limit applies in
    ///     aggregate rather than per-transfer. See `BandwidthBucket`'s doc
    ///     comment for the pacing/debt model.
    ///   - secondaryThrottle: Second bucket for cross-remote transfers (M8b):
    ///     a remote→remote stream is real download AND upload on this
    ///     machine's link, so every chunk pays both buckets; the pace follows
    ///     the tighter one.
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        resume: Bool = false,
        throttle: BandwidthBucket? = nil,
        secondaryThrottle: BandwidthBucket? = nil,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let total = try await source.stat(path: sourcePath).size
        let destinationPath = RemotePath.join(destinationDirectory, fileName)

        // Resume (M5d/T2): decide the starting offset BEFORE touching the
        // source stream. `resume == false` takes none of this — offset stays
        // 0 and the write mode stays `.overwrite`, identical to pre-M5d.
        // S3-like destinations cannot append (no partial object survives a
        // failed multipart, and a re-PUT replaces the whole object) — force a
        // full overwrite regardless of the caller's `resume` (M13).
        let effectiveResume = resume && destination.supportsAppendResume
        var resumeOffset: UInt64 = 0
        if effectiveResume {
            do {
                let destinationSize = try await destination.stat(path: destinationPath).size ?? 0
                if let total, destinationSize >= total {
                    // Already complete by the size heuristic: one final
                    // progress event at full size, no read/write at all.
                    onProgress(TransferProgress(bytesTransferred: total, totalBytes: total))
                    return
                }
                resumeOffset = destinationSize
            } catch RemoteFSError.notFound {
                // No destination yet — behaves like a fresh transfer (offset 0).
                resumeOffset = 0
            }
        }

        let input = try await source.readStream(path: sourcePath, fromOffset: resumeOffset)

        // Counting intermediary, pull-based: the destination pulls chunk by
        // chunk, nothing is buffered beyond a single chunk.
        var iterator = input.makeAsyncIterator()
        // Progress starts at the resume offset (0 when not resuming) and
        // `totalBytes` always stays the FULL source size, not the remaining
        // amount — the caller sees genuine "bytes of the whole file" progress
        // across a resume, not a restart from 0.
        var transferred: UInt64 = resumeOffset
        let counted = AsyncThrowingStream<Data, Error>(unfolding: {
            // Cooperative cancellation BEFORE every chunk: applies chunk-precisely.
            try Task.checkCancellation()
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))

            // Shared throttle (M6a): every chunk asks the direction's bucket
            // before being handed to the destination. `consume` also throws
            // on task cancellation — in addition to the check above, not in
            // place of it.
            if let throttle {
                try await throttle.consume(chunk.count)
            }
            // Second bucket (M8b): a cross-remote stream is upload AND
            // download at once, so it pays both — sequentially, no lock held
            // across either await, so this can never deadlock against the
            // other direction's transfers sharing the same buckets.
            if let secondaryThrottle {
                try await secondaryThrottle.consume(chunk.count)
            }
            return chunk
        })

        // Write mode follows the ACTUAL resume offset, not the `resume` flag
        // itself: `resume: true` against an absent destination behaves like a
        // fresh transfer end to end, including the write mode (`.overwrite`),
        // not just the read offset.
        try await destination.write(
            path: destinationPath, mode: resumeOffset > 0 ? .append : .overwrite, contents: counted)

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
