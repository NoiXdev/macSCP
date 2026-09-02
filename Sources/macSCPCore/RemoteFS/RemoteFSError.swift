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

    /// True only for `.connectionFailed`. The transfer queue (M5d/T3) uses
    /// this — and ONLY this — to classify a mid-transfer error as
    /// `.interrupted` (resumable) rather than `.failed`.
    public var isConnectionFailure: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
