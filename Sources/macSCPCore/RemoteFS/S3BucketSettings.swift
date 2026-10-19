import Foundation

/// A bucket's versioning state, as the store reports it and as a caller may
/// ask it to become.
///
/// Three states, and the third is not writable. `.never` is what an ABSENT
/// `<Status>` element means: a bucket versioning has never been switched on
/// for. S3 has no request that returns a bucket to that state — once
/// versioning has been enabled the most a caller can do is `.suspended` — so
/// `.never` exists only as a READ result, and writing it is refused
/// (`S3SettingsXML.versioningBody`).
public enum BucketVersioning: String, Sendable, CaseIterable {
    case never, enabled, suspended
}

/// An OPTIONAL backend capability (queried via `as?`, like
/// `PresignedURLProvider` and `RemoteShellProvider`): the settings of a
/// bucket, as opposed to the objects in it.
///
/// Every method names its bucket. The connection's own bucket is a property
/// of how it was opened (`RootMode`), and a connection that starts at the
/// account's bucket list has no single bucket at all, so nothing here reads
/// one from the connection.
///
/// One protocol for all of a bucket's settings rather than one per setting:
/// a backend either speaks bucket-level S3 or it does not, and a caller
/// asking `as? S3BucketSettings` is asking exactly that. Each setting adds
/// its methods here and its conformance in the extension at the bottom of
/// `S3FileSystem.swift`.
public protocol S3BucketSettings: Sendable {
    /// The versioning state of `bucket`. `.never` when the store reports no
    /// status at all.
    func versioning(ofBucket bucket: String) async throws -> BucketVersioning

    /// Switches versioning of `bucket` to `.enabled` or `.suspended`.
    /// `.never` is unrepresentable at the store and throws
    /// `RemoteFSError.finding(.operationNotSupported)` before any request.
    func setVersioning(_ state: BucketVersioning, ofBucket bucket: String) async throws
}
