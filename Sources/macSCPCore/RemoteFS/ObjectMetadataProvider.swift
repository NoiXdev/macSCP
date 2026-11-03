import Foundation

/// One object's metadata as the store reports it, and as a caller may ask it
/// to become: the three standard headers a person edits plus the custom
/// ones.
public struct ObjectMetadata: Sendable, Equatable {
    public var contentType: String?
    public var cacheControl: String?
    public var contentDisposition: String?
    /// Keys WITHOUT the `x-amz-meta-` prefix, which is transport. The prefix
    /// is added when a request is built and stripped when an answer is read,
    /// so a value of this type never carries it and a caller never has to
    /// know it exists.
    public var custom: [String: String]
    /// The object's entity tag as read, kept as received. A read-only
    /// witness, not an input: nothing writes it, which is why it is `let`
    /// where every field above it is `var`.
    public let entityTag: String?

    public init(
        contentType: String?,
        cacheControl: String?,
        contentDisposition: String?,
        custom: [String: String],
        entityTag: String?
    ) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.contentDisposition = contentDisposition
        self.custom = custom
        self.entityTag = entityTag
    }
}

/// One grant of an object's ACL: who holds which permission.
public struct ACLGrant: Sendable, Equatable {
    public let granteeID: String?
    public let granteeDisplayName: String?
    /// The permission as the store spells it (`FULL_CONTROL`, `READ`, ...),
    /// not mapped to an enum: a store may report one this project has not
    /// seen, and a closed set would have to drop it or lie about it.
    public let permission: String
    /// True when the store named a grant but no holder (measured on the rig,
    /// spec section 4.6: the one `FULL_CONTROL` grant's `Grantee` element
    /// is empty, with neither `ID` nor `DisplayName`). A UI must say so
    /// rather than draw a blank row.
    public var holderIsUnnamed: Bool { granteeID == nil && granteeDisplayName == nil }

    public init(granteeID: String?, granteeDisplayName: String?, permission: String) {
        self.granteeID = granteeID
        self.granteeDisplayName = granteeDisplayName
        self.permission = permission
    }
}

/// An object's ACL as read: the owner, named separately, and the grants.
public struct ObjectACL: Sendable, Equatable {
    public let ownerID: String?
    public let ownerDisplayName: String?
    public let grants: [ACLGrant]

    public init(ownerID: String?, ownerDisplayName: String?, grants: [ACLGrant]) {
        self.ownerID = ownerID
        self.ownerDisplayName = ownerDisplayName
        self.grants = grants
    }
}

/// An OPTIONAL backend capability (queried via `as?`, like
/// `PresignedURLProvider` and `S3BucketSettings`): one object's metadata,
/// which can be read and replaced, and its ACL, which can only be read.
///
/// **There is no `setACL`, and that is a decision, not an omission.** The
/// rig's store answers `PUT ?acl` with `200` and does not keep the grant:
/// spec section 4.6 measured `s3 PUT "/$B/doc.txt?acl" -H 'x-amz-acl:
/// public-read'` -> `200`, and the following `s3 GET "/$B/doc.txt?acl"` ->
/// `200` with the policy "unchanged: the same single owner grant. The public
/// grant was accepted and not kept." Under the read-back rule every write
/// here obeys (a write is read back, and a change the read does not show is
/// not reported as made), a control for that write could only ever report
/// "not confirmed", and no store available to this project would let a test
/// prove otherwise. The maintainer removed it from this half on 2026-10-23
/// (spec section 3). The same section records what the measurement does NOT
/// establish: "that AWS refuses `PutObjectAcl` outright on a bucket with
/// Object Ownership set to `BucketOwnerEnforced`, and that Hetzner's object
/// storage honours ACLs. Both are reasons the feature was wanted; neither is
/// evidence this project holds." A guard test holds this protocol to having
/// no ACL write, so one cannot arrive here unnoticed.
///
/// **Reading the ACL lives here rather than in a third protocol** because it
/// is the same subject as the metadata (one object's attributes) reached
/// from the same sheet (spec section 5). A backend that can answer one of
/// these questions about an object can answer the other, and a caller asking
/// `as? ObjectMetadataProvider` is asking exactly that.
///
/// Every method names its bucket, for the reason `S3BucketSettings` gives:
/// the connection's own bucket is a property of how it was opened, and a
/// connection that starts at the account's bucket list has no single bucket
/// at all.
public protocol ObjectMetadataProvider: Sendable {
    func metadata(ofKey key: String, inBucket bucket: String) async throws -> ObjectMetadata

    /// Replaces `key`'s metadata and reads it back; throws rather than
    /// reporting success it could not confirm.
    ///
    /// S3 has no in-place metadata write: the mechanism is a copy of the
    /// object onto itself (spec section 4.5), so on a versioned bucket this
    /// writes a NEW version. A caller that edits metadata says so to the
    /// person editing it.
    func setMetadata(_ metadata: ObjectMetadata, ofKey key: String, inBucket bucket: String) async throws

    /// `nil` when the store does not offer ACLs at all (`501`).
    func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL?
}
