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

    public init(accessKeyID: String, region: String, endpoint: String,
                bucket: String, usePathStyle: Bool) {
        self.accessKeyID = accessKeyID; self.region = region
        self.endpoint = endpoint; self.bucket = bucket; self.usePathStyle = usePathStyle
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
