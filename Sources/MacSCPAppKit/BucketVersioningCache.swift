import Foundation
import macSCPCore

/// What a bucket's versioning state is, read once per bucket and kept for the
/// session. The version history's menu row asks it before it decides whether
/// to be offered (`VersionsRowAvailability`), and the sheet behind that row
/// asks it again when it opens; the second asker does not read again.
///
/// It is `ObjectLockStateCache`'s sibling and takes its shape from it: lazily
/// per bucket, because a connection that starts at the account's bucket list
/// has no single bucket to read on connect, and cached, because the state
/// does not change under a session that is not the one changing it.
///
/// **An answer is cached and a failure is not.** All three states are
/// answers, `.never` included: it is what the store said, and asking again
/// gives it again. Anything Core throws is a failure to find out, not a state,
/// and the next ask reads again; a cache that stored a failure as `.never`
/// would call a bucket with a history one that has none.
///
/// Two asks for one bucket at the same time share one read.
///
/// **A write elsewhere does not update it by itself, so the writer tells it.**
/// The Versioning sheet changes a bucket's state through
/// `S3BucketSettings.setVersioning`, not through this type, and calls
/// `invalidate(_:)` once that write has returned (`BucketVersioningModel.apply`).
/// (Withdrawn wording, verbatim: "Nothing here invalidates; whoever writes a
/// state and then relies on this cache for the same bucket owns that gap."
/// Task 7 closed the gap: with the "Show Versions" row wired, a bucket read as
/// never versioned and then enabled would otherwise have kept a disabled row,
/// saying it was never versioned, for the rest of the session.) Versioning is
/// a three-state toggle the app writes; Object Lock on a bucket is effectively
/// one-way and has no such writer, which is why `ObjectLockStateCache` has no
/// `invalidate`.
///
/// **The menu cannot await, so it reads `knownVersioning(_:)`.** It answers
/// only from what was already read, and `nil` means "not asked yet" -- a
/// different fact from every state, `.never` included.
///
/// Owned by the session (`BrowserSession.bucketVersioning`), so it dies with
/// the connection whose answers it holds.
@MainActor
final class BucketVersioningCache {
    private let settings: any S3BucketSettings
    private var answers: [String: BucketVersioning] = [:]
    private var inFlight: [String: Task<BucketVersioning, any Error>] = [:]
    /// Bumped by `invalidate(_:)`. A read records its answer only if the
    /// number it started under is still current, so a read that was already
    /// on the wire when a write landed cannot put the state from BEFORE the
    /// write back into the cache.
    private var generations: [String: Int] = [:]

    init(settings: any S3BucketSettings) {
        self.settings = settings
    }

    /// The versioning state of `bucket` if it has already been read, and
    /// `nil` if it has not. Never reads, never waits, and never answers for a
    /// read that is still running.
    func knownVersioning(_ bucket: String) -> BucketVersioning? {
        answers[bucket]
    }

    /// Forgets what is known about `bucket`, including a read that is running
    /// now: the next ask reads again. Other buckets keep their answers.
    ///
    /// Called by whoever has just changed the bucket's state, **after the
    /// write succeeded and not when it threw**: a write that failed changed
    /// nothing, and dropping a good answer because a request failed throws
    /// away what was true.
    func invalidate(_ bucket: String) {
        answers[bucket] = nil
        inFlight[bucket] = nil
        generations[bucket, default: 0] += 1
    }

    /// The versioning state of `bucket`, from the cache if it was asked
    /// before. Throws what Core throws; nothing is kept on a throw.
    func versioning(_ bucket: String) async throws -> BucketVersioning {
        if let known = answers[bucket] { return known }
        if let running = inFlight[bucket] { return try await running.value }
        let settings = self.settings
        let generation = generations[bucket, default: 0]
        // The read is its own task so that a caller that goes away (a sheet
        // dismissed mid-read) does not cancel the read another caller is
        // waiting on. It records its own outcome: whoever is still waiting
        // gets the answer, and the cache is right whether anyone is.
        let read = Task { @MainActor [weak self] () throws -> BucketVersioning in
            do {
                let answer = try await settings.versioning(ofBucket: bucket)
                // Only the read the cache still considers current may record
                // or clear: after `invalidate` a newer read may own the slot.
                if let self, self.generations[bucket, default: 0] == generation {
                    self.answers[bucket] = answer
                    self.inFlight[bucket] = nil
                }
                return answer
            } catch {
                if let self, self.generations[bucket, default: 0] == generation {
                    self.inFlight[bucket] = nil
                }
                throw error
            }
        }
        inFlight[bucket] = read
        return try await read.value
    }
}

/// Whether the "Show Versions…" row is offered for a bucket in a given
/// versioning state, and if not, the sentence that says why.
///
/// **The three states are spelled out, deliberately.** A suspended bucket
/// still HAS a version history -- suspending stops new versions being made, it
/// does not delete the old ones -- so the sheet opens on `.enabled` and on
/// `.suspended`, and refusing it there would hide data the user has.
/// `.never` is the one state with nothing to show. The switch has no
/// `default:`, so a fourth `BucketVersioning` case is a compile error here
/// instead of silently joining whichever set a boolean reduction would have
/// put it in.
///
/// This is the row's availability only. Whether a version can be RESTORED is
/// a different question with a different answer (`.enabled` alone) and is
/// decided where the restore is.
enum VersionsRowAvailability: Equatable {
    case available
    case unavailable(reason: CatalogueLine)

    /// The descriptor's id for the row (`BackendDescriptor.s3Descriptor`).
    static let actionID = "s3.versions"

    /// The sentence a declined row shows as its tooltip.
    static let neverVersionedReason = CatalogueLine(
        key: "browser.action.versions.neverVersioned",
        english: "This bucket has never had versioning turned on, so there is no history to show.")

    /// The catalogue key of that sentence, read off the line and not spelled a
    /// second time.
    static let neverVersionedReasonKey = neverVersionedReason.key

    init(versioning: BucketVersioning) {
        switch versioning {
        case .enabled, .suspended:
            self = .available
        case .never:
            self = .unavailable(reason: Self.neverVersionedReason)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .available: true
        case .unavailable: false
        }
    }

    /// The sentence that says why the row is declined, or `nil` for a row
    /// that is offered.
    var reason: CatalogueLine? {
        switch self {
        case .available: nil
        case .unavailable(let reason): reason
        }
    }

    /// The key of that sentence, or `nil` for a row that is offered.
    var reasonKey: String? { reason?.key }
}
