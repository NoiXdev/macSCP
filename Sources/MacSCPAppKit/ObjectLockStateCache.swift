import Foundation
import macSCPCore

/// Whether a bucket has Object Lock at all, read once per bucket and kept for
/// the session (S3 bucket settings design, section 8).
///
/// **Why per bucket, lazily, and cached.** Object Lock is the one call with a
/// hard "not configured" answer, and on a connection that starts at the
/// account's bucket list every bucket differs, so there is no one answer to
/// read on connect. A surface that needs it asks when it opens; the second
/// surface on the same bucket does not read again.
///
/// **The question it asks is `hasObjectLock(ofBucket:)`, and no other.**
/// `objectLockDefault(ofBucket:)` is `nil` for two different bucket states --
/// no Object Lock at all, and Object Lock with no default retention yet -- and
/// a cache built on it would report "not enabled" for exactly the bucket where
/// a first retention is about to be set (`S3BucketSettings.hasObjectLock`
/// says so, and the brief of this task was corrected on 2026-10-21 for having
/// first asked for the other call).
///
/// **An answer is cached, a failure is not.** The store's `404`
/// (`ObjectLockConfigurationNotFoundError`) arrives from Core as `false` and
/// is kept as "no lock": it is what the bucket is, and asking again would give
/// it again. Anything else Core throws is a failure to find out, not an
/// answer, and the next ask reads again; a cache that stored it as "no lock"
/// would hide a lock-enabled bucket behind one bad request.
///
/// Two asks for one bucket at the same time share one read.
///
/// Owned by the session (`BrowserSession.objectLockStates`), so it dies with
/// the connection whose answers it holds.
@MainActor
final class ObjectLockStateCache {
    private let settings: any S3BucketSettings
    private var answers: [String: Bool] = [:]
    private var inFlight: [String: Task<Bool, any Error>] = [:]

    init(settings: any S3BucketSettings) {
        self.settings = settings
    }

    /// Whether `bucket` has Object Lock, from the cache if it was asked
    /// before. Throws what Core throws; nothing is kept on a throw.
    func hasObjectLock(_ bucket: String) async throws -> Bool {
        if let known = answers[bucket] { return known }
        if let running = inFlight[bucket] { return try await running.value }
        let settings = self.settings
        // The read is its own task so that a caller that goes away (a sheet
        // dismissed mid-read) does not cancel the read another caller is
        // waiting on. It records its own outcome: whoever is still waiting
        // gets the answer, and the cache is right whether anyone is.
        let read = Task { @MainActor [weak self] () throws -> Bool in
            do {
                let answer = try await settings.hasObjectLock(ofBucket: bucket)
                self?.answers[bucket] = answer
                self?.inFlight[bucket] = nil
                return answer
            } catch {
                self?.inFlight[bucket] = nil
                throw error
            }
        }
        inFlight[bucket] = read
        return try await read.value
    }
}
