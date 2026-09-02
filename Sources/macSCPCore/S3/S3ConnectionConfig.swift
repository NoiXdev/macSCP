import Foundation

/// The persisted, SECRET-FREE S3 parameters (M12) — stored in
/// `StoredSession.s3`/exports. The secret access key is never here; it lives
/// only in the Keychain (`SecretStore`), like the SSH password.
public struct StoredS3Config: Equatable, Codable, Sendable {
    public var accessKeyID: String
    public var region: String
    /// Full origin so S3-compatible providers (MinIO, Hetzner, R2, …) work.
    public var endpoint: String
    public var bucket: String
    /// Path-style (`endpoint/bucket/key`) vs. virtual-hosted. Many
    /// S3-compatible providers require path-style.
    public var usePathStyle: Bool
    /// The persisted half of `S3ConnectionConfig.startsAtBucketList` below:
    /// this connection's root is the ACCOUNT's bucket list rather than the
    /// one bucket named above (2026-09-02).
    ///
    /// LAST, with a default, and decoded with `decodeIfPresent ?? false` —
    /// every `sessions.json` and every export file already on disk was
    /// written before this key existed, and `false` is what they all meant.
    /// A synthesized `Codable` would throw `keyNotFound` on each of them
    /// and take the whole session file down with it, which is why the two
    /// halves are written out below rather than left to the compiler.
    public var startsAtBucketList: Bool

    public init(accessKeyID: String, region: String, endpoint: String,
                bucket: String, usePathStyle: Bool, startsAtBucketList: Bool = false) {
        self.accessKeyID = accessKeyID; self.region = region
        self.endpoint = endpoint; self.bucket = bucket; self.usePathStyle = usePathStyle
        self.startsAtBucketList = startsAtBucketList
    }

    private enum CodingKeys: String, CodingKey {
        case accessKeyID, region, endpoint, bucket, usePathStyle, startsAtBucketList
    }

    // `encode(to:)` stays SYNTHESIZED from the keys above, so a field added
    // later cannot be left out of it — only the reading half needs a hand,
    // and only for the one absent-key default. The consequence is that a
    // re-encode is NOT byte-identical to what an older macSCP wrote: the
    // `false` that file left absent is written out. That is the intended
    // direction — every writer here rewrites the whole block anyway, and an
    // omitted `false` would make "never had the toggle" and "toggle turned
    // off" indistinguishable on disk.

    /// Hand-written for the one absent-key default above. Every other field
    /// is decoded exactly as the synthesized initializer would, so a block
    /// missing any of THEM still fails loudly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessKeyID = try container.decode(String.self, forKey: .accessKeyID)
        region = try container.decode(String.self, forKey: .region)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        bucket = try container.decode(String.self, forKey: .bucket)
        usePathStyle = try container.decode(Bool.self, forKey: .usePathStyle)
        startsAtBucketList =
            try container.decodeIfPresent(Bool.self, forKey: .startsAtBucketList) ?? false
    }

}

/// The RUNTIME S3 connect config (M12): the persisted fields PLUS the transient
/// secret. NOT Codable — never persisted (mirrors `SSHConnectionConfig`, which
/// carries the plaintext password only at connect time). Built by the App from
/// a `StoredS3Config` + the Keychain secret.
public struct S3ConnectionConfig: Equatable, Sendable {
    public var accessKeyID: String
    /// Warning: plaintext secret — never log/interpolate/persist it.
    public var secretAccessKey: String
    public var region: String
    public var endpoint: String
    public var bucket: String
    public var usePathStyle: Bool
    /// Temporary-credentials session token (STS); nil for long-lived keys.
    public var sessionToken: String?
    /// The connection's ROOT is the account's bucket list rather than one
    /// bucket: `S3FileSystem` asks `ListBuckets` on connect, `/` lists the
    /// buckets, and the first component of every deeper path names the
    /// bucket it routes into (`S3FileSystem.RootMode`). `bucket` above is
    /// then unused — the form hides it when this is on.
    ///
    /// LAST, with a default, so every existing call site keeps compiling
    /// and keeps meaning what it meant: `false` is today's behaviour, byte
    /// for byte.
    public var startsAtBucketList: Bool

    public init(accessKeyID: String, secretAccessKey: String, region: String,
                endpoint: String, bucket: String, usePathStyle: Bool, sessionToken: String?,
                startsAtBucketList: Bool = false) {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey
        self.region = region; self.endpoint = endpoint; self.bucket = bucket
        self.usePathStyle = usePathStyle; self.sessionToken = sessionToken
        self.startsAtBucketList = startsAtBucketList
    }
}
