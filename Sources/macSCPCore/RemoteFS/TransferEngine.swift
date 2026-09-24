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

extension TransferDirection {
    /// `direction=up|down` — the two words the diagnostic-log design's
    /// "transfer start" line names.
    fileprivate var logText: String {
        switch self {
        case .upload: return "up"
        case .download: return "down"
        }
    }
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
    ///   - expectedSourceValidator: The source validator (an opaque entity
    ///     tag from `RemoteFileSystem.entityTag(path:)`) that the partial file
    ///     at the destination was produced from — the resume-identity plan's
    ///     whole point. It is sent to the source ONLY when this call actually
    ///     resumes (`resumeOffset > 0`); a fresh transfer has no partial file
    ///     to be wrong about and sends nothing. A source that holds a
    ///     different object refuses the read rather than appending a second
    ///     object's tail onto the first object's head. `nil` (default) is the
    ///     pre-plan behaviour exactly: no precondition, whatever the offset.
    ///   - onSourceValidator: Called at most ONCE, before the source stream is
    ///     opened, with the validator THIS attempt is tied to — so a caller
    ///     that has to retry later can hand the same value back as
    ///     `expectedSourceValidator`. "At most once": a call that returns
    ///     early because the destination is already complete opens no stream
    ///     and reports nothing. The value reported is
    ///     `expectedSourceValidator` when the caller supplied one (a resume
    ///     carries its original validator forward; re-reading would tie a
    ///     second interruption to whatever the source holds NOW, which is the
    ///     object swap this mechanism exists to catch), and otherwise
    ///     whatever `source.entityTag(path:)` answers. A caller that passes
    ///     nothing here is charged no round trip for it — which is every call
    ///     site that predates this plan.
    ///
    ///     A callback rather than a return value or an `inout` box because
    ///     the value is needed on the path where this call THROWS: a
    ///     transfer that is interrupted mid-stream never returns, and an
    ///     `inout` cannot cross into the unstructured task the queue runs
    ///     this in. `onProgress`'s shape, for the same reason.
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
    ///   - direction: For the diagnostic log's `transfer start
    ///     direction=up|down` line only — `nil` (default) logs `unknown`
    ///     rather than guessing. `TransferQueueViewModel`'s one production
    ///     call site always knows its job's own `direction` and passes it;
    ///     the CLI and this file's own tests do not, and stay source-
    ///     compatible without it since `DiagnosticLog` is `.off` (a no-op)
    ///     everywhere neither of them configures it.
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        resume: Bool = false,
        expectedSourceValidator: String? = nil,
        direction: TransferDirection? = nil,
        throttle: BandwidthBucket? = nil,
        secondaryThrottle: BandwidthBucket? = nil,
        onSourceValidator: (@Sendable (String?) -> Void)? = nil,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let destinationPath = RemotePath.join(destinationDirectory, fileName)
        let clock = ContinuousClock()
        let transferStart = clock.now
        do {
            // One metadata read of the source, not two (fix round 1,
            // Important 2): where a validator is wanted, it comes out of the
            // SAME read that answers the size — for S3 that is one listing of
            // the parent rather than two, for WebDAV one PROPFIND rather than
            // two. A caller that wants no validator, or that already carries
            // one, takes the plain `stat` this line has always made.
            let sourceEntry: RemoteFileItem
            var attemptValidator = expectedSourceValidator
            if onSourceValidator != nil, attemptValidator == nil {
                let probed = try await source.statWithEntityTag(path: sourcePath)
                sourceEntry = probed.item
                attemptValidator = probed.entityTag
            } else {
                sourceEntry = try await source.stat(path: sourcePath)
            }
            let total = sourceEntry.size
            DiagnosticLog.shared.log(
                .info, "transfer",
                "transfer start direction=\(direction?.logText ?? "unknown") "
                    + "path=\(destinationPath) bytes=\(total.map(String.init) ?? "unknown")")

            // Resume (M5d/T2): decide the starting offset BEFORE touching the
            // source stream. `resume == false` takes none of this — offset
            // stays 0 and the write mode stays `.overwrite`, identical to
            // pre-M5d. S3-like destinations cannot append (no partial object
            // survives a failed multipart, and a re-PUT replaces the whole
            // object) — force a full overwrite regardless of the caller's
            // `resume` (M13).
            let effectiveResume = resume && destination.supportsAppendResume
            var resumeOffset: UInt64 = 0
            if effectiveResume {
                do {
                    let destinationSize =
                        try await destination.stat(path: destinationPath).size ?? 0
                    if let total, destinationSize >= total {
                        // Already complete by the size heuristic: one final
                        // progress event at full size, no read/write at all.
                        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total))
                        let ms = Int(transferStart.duration(to: clock.now).milliseconds.rounded())
                        DiagnosticLog.shared.log(
                            .info, "transfer", "transfer done path=\(destinationPath) ms=\(ms)")
                        return
                    }
                    resumeOffset = destinationSize
                } catch RemoteFSError.notFound {
                    // No destination yet — behaves like a fresh transfer (offset 0).
                    resumeOffset = 0
                }
            }

            // A carried validator describes the PARTIAL FILE, so it stops
            // being true the moment there is no partial file (fix round 2,
            // Minor 1). `resumeOffset == 0` — the destination was absent, or
            // the caller asked for no resume — means this attempt reads the
            // object as it is NOW, from zero, and sends no precondition
            // either way. Reporting the old validator would have the attempt
            // AFTER this one send a precondition for an object that may no
            // longer exist, against a partial built from the current one:
            // refused as "the file changed" where resuming was exactly right.
            //
            // Only reached when a validator was carried in; the fresh-probe
            // branch above already answered for the current object.
            //
            // A re-read that THROWS leaves `attemptValidator` alone, and that
            // is a deliberate choice between two wrong answers, because a
            // failed read says nothing about the object: on both HTTP
            // backends the validator is a request of its own, so it is lost
            // to exactly the dropped connection that is about to interrupt
            // this attempt. Reporting `nil` would replace a validator the
            // queue had earned — `TransferQueueViewModel` seeds its box with
            // the job's carried value precisely so silence cannot do that —
            // and the attempt after this one would then resume at a non-zero
            // offset with no precondition: a splice, silently. Carrying the
            // stale value forward is the other wrong answer, and it is the
            // one to prefer: its worst case is the refusal the fix above
            // exists to avoid ("the file changed" where resuming was right),
            // which costs a transfer and corrupts nothing.
            //
            // A re-read that SUCCEEDS with `nil` is not that case: the object
            // really has no validator now, and `nil` is the true answer.
            //
            // This is the one place `statWithEntityTag` is deliberately NOT
            // used, although it would fold this request into the `stat` above
            // and halve the metadata cost of this branch. Its extension
            // default composes the two requirements under a `try?`, so a
            // throw and a genuine `nil` arrive here as the same answer — and
            // telling those two apart is the whole of the decision below.
            // The doubling is paid only on this branch (a carried validator
            // whose partial file has vanished), never per file of a queued
            // directory.
            if onSourceValidator != nil, resumeOffset == 0, expectedSourceValidator != nil {
                do {
                    attemptValidator = try await source.entityTag(path: sourcePath)
                } catch {
                    DiagnosticLog.shared.log(
                        .info, "transfer",
                        "validator re-read failed path=\(destinationPath) "
                            + "keeping the carried one",
                        reason: error)
                }
            }

            // Resume identity (resume-identity plan, Task 2): the validator
            // this attempt is tied to, read with the size above (or re-read
            // just now) and reported here — BEFORE the stream is opened, so a
            // later retry can hand it back. A caller that is not told has
            // nothing to retry with, which is why the queue reads its own
            // carried value as the floor rather than treating silence as "no
            // validator".
            onSourceValidator?(attemptValidator)

            // The three-argument read ONLY where a precondition means
            // something: an actual resume, with a validator to hold the source
            // to. Every other case takes the two-argument call this has always
            // made, so no conformer's behaviour changes unless a validator is
            // really being carried.
            let input: AsyncThrowingStream<Data, Error>
            if resumeOffset > 0, let expectedSourceValidator {
                input = try await source.readStream(
                    path: sourcePath, fromOffset: resumeOffset,
                    ifMatching: expectedSourceValidator)
            } else {
                input = try await source.readStream(path: sourcePath, fromOffset: resumeOffset)
            }

        // Counting intermediary, pull-based: the destination pulls chunk by
        // chunk, nothing is buffered beyond a single chunk.
        //
        // `nonisolated(unsafe)`: an `AsyncThrowingStream.Iterator` is stateful
        // and not `Sendable`, and the `unfolding:` closure that advances it is
        // `@Sendable`, so the compiler has to assume several tasks might call
        // `next()` at once. Why that cannot happen here: this iterator is
        // created by this call, is never stored or handed to anyone, and the
        // `unfolding:` closure is the only code that touches it. That closure
        // is the producer of `counted`, and `counted` goes to exactly one
        // place — `destination.write` — where every backend in this package
        // drains it with a single sequential loop over a single iterator. The
        // WebDAV backend moves that loop into a detached pump task, which is a
        // different task than this one but still only ever one at a time. So
        // the iterator is confined to one reader for its whole life, and each
        // `copyFile` call has its own.
        //
        // What would break it: a `write` implementation that split `contents`
        // across concurrent readers. That would already violate the
        // `AsyncSequence` single-consumer contract, and would corrupt the byte
        // stream long before the annotation became the problem.
        nonisolated(unsafe) var iterator = input.makeAsyncIterator()
        // Progress starts at the resume offset (0 when not resuming) and
        // `totalBytes` always stays the FULL source size, not the remaining
        // amount — the caller sees genuine "bytes of the whole file" progress
        // across a resume, not a restart from 0.
        //
        // `nonisolated(unsafe)` for the same reason, and on the strength of
        // the same argument, as the iterator above: this counter is read and
        // written only by the `unfolding:` closure, which is the single
        // sequential reader of that iterator. It advances in lockstep with
        // it — one chunk pulled, one addition — so if the iterator is
        // confined to one reader then so is the counter.
        nonisolated(unsafe) var transferred: UInt64 = resumeOffset
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
            let ms = Int(transferStart.duration(to: clock.now).milliseconds.rounded())
            DiagnosticLog.shared.log(
                .info, "transfer", "transfer done path=\(destinationPath) ms=\(ms)")
        } catch {
            let ms = Int(transferStart.duration(to: clock.now).milliseconds.rounded())
            // The ORIGINAL `error` (fix round 1, Structural): the previous
            // hand-written `reason=\(reasonText)` fell back to `String(
            // describing: error)` for anything but `CancellationError` —
            // exactly the raw-error shape the new overload exists to
            // replace with `DialSupport.reason(for:)`.
            DiagnosticLog.shared.log(
                .info, "transfer", "transfer failed path=\(destinationPath) ms=\(ms)", reason: error)
            throw error
        }
    }
}
