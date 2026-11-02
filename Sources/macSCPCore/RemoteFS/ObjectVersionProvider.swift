import Foundation

/// One entry of an object's version history: either a stored version or a
/// delete marker.
public struct ObjectVersion: Sendable, Equatable, Identifiable {
    /// The store's identifier for this entry. `id` leans on it, which is
    /// right for one key's history (`versions(ofKey:inBucket:)`), where it is
    /// unique. It is NOT unique across keys: two keys can both carry a `null`
    /// version id, so a page that spans keys (`ObjectVersionPage`) must not
    /// be fed through `id`.
    public let versionId: String
    public let key: String
    /// Whether this entry is the key's current one.
    public let isLatest: Bool
    /// A delete marker stores no content: it hides the key from a plain
    /// listing, and removing it brings the previous version back.
    public let isDeleteMarker: Bool
    /// The content length in bytes. `nil` for a delete marker, which has none.
    public let size: UInt64?
    /// When the entry was written. `nil` when the store did not report a
    /// date it could be parsed from.
    public let modifiedAt: Date?
    /// The entity tag as the store reported it. `nil` for a delete marker.
    public let entityTag: String?

    public var id: String { versionId }

    public init(
        versionId: String, key: String, isLatest: Bool, isDeleteMarker: Bool,
        size: UInt64?, modifiedAt: Date?, entityTag: String?
    ) {
        self.versionId = versionId
        self.key = key
        self.isLatest = isLatest
        self.isDeleteMarker = isDeleteMarker
        self.size = size
        self.modifiedAt = modifiedAt
        self.entityTag = entityTag
    }
}

/// One page of a bucket's version listing, and where the next one starts.
public struct ObjectVersionPage: Sendable, Equatable {
    /// The entries as the page carries them, in the order they were handed
    /// to the initializer. Nothing here sorts or reverses them.
    public let versions: [ObjectVersion]
    /// The continuation marker for the next page, or `nil` when there is
    /// none. An opaque token: it is sent back to the store percent-encoded
    /// and never parsed, because its shape is the store's business and is not
    /// necessarily a plain key.
    public let nextKeyMarker: String?
    /// The continuation marker's version half, handed back to the store
    /// alongside `nextKeyMarker` and equally opaque: sent percent-encoded,
    /// never parsed. This layer makes no claim about when it is `nil`.
    public let nextVersionIdMarker: String?
    /// Whether another page follows, derived from the presence of
    /// `nextKeyMarker` alone.
    public var isTruncated: Bool { nextKeyMarker != nil }

    public init(versions: [ObjectVersion], nextKeyMarker: String?, nextVersionIdMarker: String?) {
        self.versions = versions
        self.nextKeyMarker = nextKeyMarker
        self.nextVersionIdMarker = nextVersionIdMarker
    }
}

/// A key whose latest entry is a delete marker: gone from a plain listing,
/// still recoverable.
public struct DeletedEntry: Sendable, Equatable {
    public let key: String
    /// The version id of the delete marker that hides the key. Removing that
    /// marker (`liftDeleteMarker`) is what brings the key back.
    public let markerVersionId: String
    /// When the marker was written, i.e. when the key was deleted. `nil` when
    /// the store did not report a date it could be parsed from.
    public let modifiedAt: Date?

    public init(key: String, markerVersionId: String, modifiedAt: Date?) {
        self.key = key
        self.markerVersionId = markerVersionId
        self.modifiedAt = modifiedAt
    }
}

/// An OPTIONAL backend capability (queried via `as?`, like
/// `PresignedURLProvider` and `S3BucketSettings`): the version history of one
/// object, as opposed to the object's current content.
///
/// **It is not named for S3.** What it describes is an object that has
/// versions, delete markers that hide it, and a way to read, restore or
/// remove one of them; S3 is the backend that has those today, not the
/// definition of them. A caller asking `as? ObjectVersionProvider` is asking
/// whether the backend keeps history, not which vendor it is.
///
/// **`RemoteFileSystem` is deliberately untouched.** History is a property of
/// some backends only, so it is a capability beside the protocol rather than
/// a requirement on every conformer, the same decision as
/// `PresignedURLProvider`.
///
/// Every method names its bucket: the connection's own bucket is a property
/// of how it was opened, and a connection that starts at the account's bucket
/// list has none.
public protocol ObjectVersionProvider: Sendable {
    /// The history of `key`: its versions and delete markers. Empty when the
    /// key has no history at all.
    ///
    /// The order is whatever the store returns. Nothing here sorts or
    /// reverses it, and no order is measured or relied on at this layer; a
    /// caller that needs a defined order sorts explicitly.
    func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion]

    /// The keys directly under `prefix` (one level, as a folder view shows
    /// them; keys in a sub-prefix are not reported) whose latest entry is a
    /// delete marker.
    func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry]

    /// Streams the content of one specific version of `key`, from its first
    /// byte.
    func readStream(
        ofKey key: String, inBucket bucket: String, versionId: String
    ) async throws -> AsyncThrowingStream<Data, Error>

    /// Makes `versionId`'s content the current content of `key`, by writing
    /// it as a NEW version. The history keeps every entry it had.
    ///
    /// **Returns only when the history confirms it**: a new current version
    /// that is not a delete marker (and, where the backend can tell, carries
    /// the restored content). A write the history does not show throws
    /// `.protocolError`, so a caller that sees no error may rely on it.
    /// Throws, with nothing written, `.notFound` when the history holds no
    /// such version and `.protocolError` when `versionId` names a delete
    /// marker (it has no content) or `key` is empty. Costs a history read
    /// before the write and one after.
    func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws

    /// Permanently removes one version of `key`. Unlike deleting the key, it
    /// leaves no marker and cannot be undone.
    ///
    /// **Returns only when the history no longer lists it**; a version that is
    /// still listed throws `.protocolError`. Throws, with nothing removed,
    /// `.notFound` when the history holds no such version and `.protocolError`
    /// when `versionId` names a delete marker (that is `liftDeleteMarker`,
    /// which has the opposite effect) or `key` is empty. A version the store
    /// refuses to remove because of a retention or a legal hold is
    /// `.finding(.objectUnderRetention)` or `.finding(.objectUnderLegalHold)`.
    /// Costs a history read before the delete and one after.
    func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws

    /// Removes the delete marker `markerVersionId`, so the version beneath it
    /// is the key's current content again.
    ///
    /// The same request as `deleteVersion` on the wire, so the history is read
    /// first and the id must name a delete marker: `.notFound` when it names
    /// nothing, `.protocolError` when it names a version with content (lifting
    /// that would delete data for good) or `key` is empty, in both cases with
    /// nothing sent. **Returns only when the history no longer lists the
    /// marker**; otherwise `.protocolError`. Costs a history read before the
    /// delete and one after.
    func liftDeleteMarker(ofKey key: String, inBucket bucket: String, markerVersionId: String) async throws
}
