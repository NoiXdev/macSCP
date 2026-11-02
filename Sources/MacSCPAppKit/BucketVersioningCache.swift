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
/// **A write elsewhere does not update it.** The Versioning sheet changes a
/// bucket's state through `S3BucketSettings.setVersioning`, not through this
/// type, so a state read before that write is what the next ask returns. Nothing
/// here invalidates; whoever writes a state and then relies on this cache for
/// the same bucket owns that gap.
///
/// Owned by the session (`BrowserSession.bucketVersioning`), so it dies with
/// the connection whose answers it holds.
@MainActor
final class BucketVersioningCache {
    private let settings: any S3BucketSettings
    private var answers: [String: BucketVersioning] = [:]
    private var inFlight: [String: Task<BucketVersioning, any Error>] = [:]

    init(settings: any S3BucketSettings) {
        self.settings = settings
    }

    /// The versioning state of `bucket`, from the cache if it was asked
    /// before. Throws what Core throws; nothing is kept on a throw.
    func versioning(_ bucket: String) async throws -> BucketVersioning {
        if let known = answers[bucket] { return known }
        if let running = inFlight[bucket] { return try await running.value }
        let settings = self.settings
        // The read is its own task so that a caller that goes away (a sheet
        // dismissed mid-read) does not cancel the read another caller is
        // waiting on. It records its own outcome: whoever is still waiting
        // gets the answer, and the cache is right whether anyone is.
        let read = Task { @MainActor [weak self] () throws -> BucketVersioning in
            do {
                let answer = try await settings.versioning(ofBucket: bucket)
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

/// Whether the "Show Versions…" row is offered for a bucket in a given
/// versioning state, and if not, the catalogue key of the sentence that says
/// why.
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
    case unavailable(reasonKey: String)

    /// The descriptor's id for the row (`BackendDescriptor.s3Descriptor`).
    static let actionID = "s3.versions"

    /// The catalogue key of the sentence a declined row shows as its tooltip.
    static let neverVersionedReasonKey = "browser.action.versions.neverVersioned"

    init(versioning: BucketVersioning) {
        switch versioning {
        case .enabled, .suspended:
            self = .available
        case .never:
            self = .unavailable(reasonKey: Self.neverVersionedReasonKey)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .available: true
        case .unavailable: false
        }
    }

    /// The key of the reason, or `nil` for a row that is offered.
    var reasonKey: String? {
        switch self {
        case .available: nil
        case .unavailable(let reasonKey): reasonKey
        }
    }
}
