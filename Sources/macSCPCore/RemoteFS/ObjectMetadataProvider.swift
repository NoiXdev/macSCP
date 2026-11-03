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
    /// Who holds the grant, when the store named one. Usually a canonical
    /// user id, but it MAY hold a group URI instead: `ACLGrant` has no field
    /// of its own for one, and a group grant read as "unnamed" would present
    /// a public grant as a holder the store did not say. **That group shape
    /// is unmeasured on this store.** Spec section 4.6.1 measured only the
    /// empty `Grantee`; mapping a group's URI into this field is an
    /// inference from the documented policy format, not an observation. A UI
    /// that shows this value must not assume it is an id.
    public let granteeID: String?
    public let granteeDisplayName: String?
    /// The permission as the store spells it (`FULL_CONTROL`, `READ`, ...),
    /// not mapped to an enum: a store may report one this project has not
    /// seen, and a closed set would have to drop it or lie about it.
    public let permission: String
    /// True when the store named a grant but no holder. Spec section 4.6
    /// measured that on a bucket's ACL (the one `FULL_CONTROL` grant's
    /// `Grantee` element is empty, with neither `ID` nor `DisplayName`);
    /// section 4.6.1 measured it on an object's, which 4.6 had left open.
    /// A UI must say so rather than draw a blank row.
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
/// grant was accepted and not kept." (All of that is section 4.6.)
///
/// Spec section 3 draws the consequence, and says that the maintainer removed
/// the control on 2026-10-23: "Under the first half's read-back rule the
/// control could only ever report "not confirmed", and no store available to
/// this project would let a test prove otherwise." Section 4.6 also records
/// what its measurement does NOT establish: "that AWS refuses `PutObjectAcl`
/// outright on a bucket with Object Ownership set to `BucketOwnerEnforced`,
/// and that Hetzner's object storage honours ACLs. Both are reasons the
/// feature was wanted; neither is evidence this project holds." Task 3's
/// guard test is where this protocol gets held to having no ACL write, so
/// one cannot arrive here unnoticed.
///
/// **Reading the ACL lives here rather than in a third protocol** because it
/// is the same subject as the metadata (one object's attributes) reached
/// from the same sheet (spec section 5).
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

    /// `nil` means the store does not offer object ACLs at all. The `501`
    /// shape this is meant for is what the rig's store returns for the
    /// neighbouring `GET ?ownershipControls` call (spec section 4.6:
    /// `501 NotImplemented`); for `?acl` itself that store answers `200` with
    /// a policy. So the `501` here is generalised from a sibling call and has
    /// NOT been measured for `?acl`.
    func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL?
}
