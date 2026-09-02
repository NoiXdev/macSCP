public enum RemoteFSError: Error, Equatable, Sendable {
    case connectionFailed(reason: String)
    case authenticationFailed
    /// Stage-1 (jump host) authentication failure (M10c). Kept distinct from
    /// `.authenticationFailed` so the connect form can highlight the jump
    /// credentials instead of the target's. `isConnectionFailure` deliberately
    /// stays false so a mid-transfer classification can never mark it
    /// resumable.
    case jumpAuthenticationFailed
    case notFound(path: String)
    case permissionDenied(path: String)
    case protocolError(reason: String)
    /// `ListBuckets` was refused with HTTP 403 `AccessDenied`: the key may
    /// not list the account's buckets (it lacks `s3:ListAllMyBuckets`).
    /// Only reachable from an S3 connection whose
    /// `startsAtBucketList` is on, and only at connect time.
    ///
    /// Distinct from `.authenticationFailed` on purpose: the credentials
    /// are good, one permission is missing, and the answer is "turn the
    /// toggle off and name the bucket" rather than "check your key".
    /// Measured 2026-09-02: AWS answers this way; the rig's MinIO does not
    /// — it returns the filtered list instead (docker/test-server/README.md).
    case bucketListForbidden
    /// `ListBuckets` succeeded and the account has no buckets at all. Its
    /// own case rather than an empty listing, because a connect that opens
    /// on an empty browser explains nothing at the form, which is where the
    /// user is looking.
    case bucketListEmpty
    /// An operation whose target IS a bucket rather than something inside
    /// one, refused by `S3FileSystem` (2026-09-02). `operation` names the
    /// `RemoteFileSystem` call that was refused; `path` is the browser path
    /// that resolved to a bucket root.
    ///
    /// Its own case rather than a `.protocolError` with a sentence in it,
    /// for two reasons. The refusal is a RULE, so a test can assert the
    /// rule was what refused — a `.protocolError` check is satisfied by any
    /// transport hiccup that happens to carry the same case (Task 2 review,
    /// I-2). And it gives the UI something to map to a written message
    /// instead of rendering a raw `reason` at the user.
    ///
    /// Only reachable in bucket-list mode: with the toggle off the same
    /// path is the bucket ROOT, which has always been the caller's business.
    case bucketLevelRefused(operation: String, path: String)

    /// True only for `.connectionFailed`. The transfer queue (M5d/T3) uses
    /// this — and ONLY this — to classify a mid-transfer error as
    /// `.interrupted` (resumable) rather than `.failed`.
    public var isConnectionFailure: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
