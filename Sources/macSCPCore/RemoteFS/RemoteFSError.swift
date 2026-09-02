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
    /// The operations `S3FileSystem` refuses when their target IS a bucket
    /// rather than something inside one — the mutating ones, the seam that
    /// hands write capability out of the process, and (since 2026-09-02)
    /// the byte read.
    ///
    /// An enum and not a `String` (Task 3 review, I-2). The first version
    /// carried the method name as text, which the CLI then interpolated
    /// into an English sentence — printing "macSCP does not createDirectory
    /// buckets" for four of the six. A closed set makes every renderer's
    /// `switch` exhaustive, so a case added here cannot reach a user
    /// without someone writing its sentence, and it removes the hand-spelled
    /// copies of method names from the call sites.
    ///
    /// SEVEN cases across EIGHT call sites in `S3FileSystem` — counted in
    /// the tree in the pass that added `readStream`: `rename` guards both of
    /// its ends (source and destination) and reports the same operation for
    /// either, naming in `path` whichever end was the bucket.
    public enum BucketLevelOperation: String, CaseIterable, Sendable, Equatable {
        case write, delete, createDirectory, deleteTree, rename, presignedURL
        /// Reading a bucket's BYTES. A ranged `GET` on a path-style bucket
        /// root is answered with a `ListObjectsV2` XML body, so without this
        /// the caller gets a "file" whose contents are the bucket listing.
        case readStream

        /// This refusal's catalogue key, DERIVED from the case rather than
        /// spelled at each of the three UI mappers that render it. A case
        /// added without its four catalog entries is caught by
        /// `everyBucketLevelOperationHasItsOwnSentence`, which iterates
        /// `allCases` — the lookup itself cannot fail loudly, since
        /// `CoreL10n.string` falls back to the key text.
        public var refusalMessageKey: String {
            "core.connect.s3BucketLevelRefused.\(rawValue)"
        }
    }

    /// An operation whose target IS a bucket rather than something inside
    /// one, refused by `S3FileSystem` (2026-09-02). `path` is the browser
    /// path that resolved to a bucket root.
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
    case bucketLevelRefused(operation: BucketLevelOperation, path: String)

    /// A rename whose two ends live in DIFFERENT buckets, refused by
    /// `S3FileSystem` (2026-09-02, Task 4). Only reachable in bucket-list
    /// mode, where a path's first component names the bucket.
    ///
    /// Not a `bucketLevelRefused`: neither end IS a bucket, so that case's
    /// whole vocabulary — including the CLI's "<path> is a bucket" frame —
    /// would say something false. The refusal has a different reason, so it
    /// gets a different case and its own sentence.
    ///
    /// Why refuse at all: `rename` is a per-object copy+delete with no
    /// rollback. Inside one bucket a half-failure leaves every object in one
    /// place the user can still see and finish by hand. Across buckets the
    /// same half-failure splits them over a permission boundary, and
    /// possibly two regions — a behaviour nobody has designed. Refused until
    /// someone does.
    case crossBucketRenameRefused(from: String, to: String)

    /// True only for `.connectionFailed`. The transfer queue (M5d/T3) uses
    /// this — and ONLY this — to classify a mid-transfer error as
    /// `.interrupted` (resumable) rather than `.failed`.
    public var isConnectionFailure: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
