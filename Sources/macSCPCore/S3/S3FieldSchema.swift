import Foundation

/// S3's field identifiers — the single source for its two schemas, its config
/// factory and its persistence adapter (M22).
public enum S3Field: String, CaseIterable, BackendFieldID {
    case endpoint, region, bucket, accessKeyID, secretAccessKey, usePathStyle

    public static let namespace = "S3Field"
}

/// S3's data-driven registration (M22). Everything the generic layers need to
/// know about S3 lives here; nothing outside branches on `.s3`.
public enum S3FieldSchema {
    public static let connection = ConnectionFieldSchema(
        fields: [
            // Endpoint and bucket here, plus `accessKeyID` in the credential
            // schema, are what make an S3 connection distinct on import
            // (M23/P3). VERBATIM throughout: unlike a host name, a URL path
            // and a bucket name are case-sensitive.
            ConnectionField(id: S3Field.endpoint.rawValue,
                            labelKey: "connection.s3.endpoint", labelDefault: "Endpoint",
                            kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            identity: .verbatim),
            // NOT identifying, though it is required: the region is part of
            // the SigV4 credential scope, not of which bucket this is. Two
            // sessions naming the same bucket under different regions are one
            // connection, one of them misconfigured.
            ConnectionField(id: S3Field.region.rawValue,
                            labelKey: "connection.s3.region", labelDefault: "Region",
                            kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3RegionRequired"),
            ConnectionField(id: S3Field.bucket.rawValue,
                            labelKey: "connection.s3.bucket", labelDefault: "Bucket",
                            kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3BucketRequired",
                            identity: .verbatim),
            // NOT identifying: path-style versus virtual-host addressing is
            // how a client reaches the bucket, not which bucket it reaches.
            // Two sessions differing only here are the same connection, and
            // the user must be asked rather than handed a silent second copy.
            ConnectionField(id: S3Field.usePathStyle.rawValue,
                            labelKey: "connection.s3.pathStyle",
                            labelDefault: "Use path-style URLs", kind: .toggle),
        ],
        presets: [
            ConnectionPreset(id: "aws", nameKey: "connection.s3.preset.aws",
                             nameDefault: "Amazon S3",
                             values: [S3Field.endpoint.rawValue: "https://s3.amazonaws.com",
                                      S3Field.usePathStyle.rawValue: "false"]),
            ConnectionPreset(id: "hetzner", nameKey: "connection.s3.preset.hetzner",
                             nameDefault: "Hetzner Object Storage",
                             values: [S3Field.endpoint.rawValue: "https://fsn1.your-objectstorage.com",
                                      S3Field.usePathStyle.rawValue: "true"]),
            ConnectionPreset(id: "custom", nameKey: "connection.s3.preset.custom",
                             nameDefault: "Custom", values: [:]),
        ])

    /// What a brand-new S3 form starts with (M22/T8). The toggle is written
    /// out rather than left absent so the checkbox reads "off" from a real
    /// value instead of from `FieldValues`'s absent-means-false rule.
    public static let defaults: FieldValues = {
        var values = FieldValues()
        values[bool: S3Field.usePathStyle] = false
        // A new form starts with the region most S3-compatible providers accept
        // because they do not check it. That is an ASSUMPTION about third-party
        // servers, which is why it is a visible, editable default on a new form
        // and never written into an existing session. AWS itself does check —
        // the AWS preset's user still has to enter theirs. Measured against the
        // rig's MinIO (us-east-1 in the gated suite); not measured against
        // Servinga, the provider in the report.
        values[S3Field.region] = "us-east-1"
        return values
    }()

    /// What a login set carries: the credentials, not the endpoint. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            // Identifying, and legitimately so: two different keys against one
            // bucket are two connections with different rights. It is an
            // opaque credential but NOT a secret — the secret is
            // `secretAccessKey` below, which carries no identity and never
            // enters a key.
            ConnectionField(id: S3Field.accessKeyID.rawValue,
                            labelKey: "connection.s3.accessKey",
                            labelDefault: "Access Key ID", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            identity: .verbatim),
            ConnectionField(id: S3Field.secretAccessKey.rawValue,
                            labelKey: "connection.s3.secretKey",
                            labelDefault: "Secret Access Key", kind: .secret,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            secretRole: .credential),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // The switch is exhaustive, so a case added to `S3Field` cannot reach
        // this factory without an arm here. That buys ACKNOWLEDGMENT, not
        // correctness: appending the new case to the `break` arm below
        // satisfies the compiler while deciding nothing. Which is why that
        // arm says why each of its fields needs no check — a new case joining
        // it has to fit the stated reason or move out.
        for field in S3Field.allCases {
            switch field {
            case .bucket:
                guard !values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the bucket") }
            case .endpoint:
                guard !values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the endpoint") }
            case .region, .accessKeyID, .secretAccessKey, .usePathStyle:
                // `region` needs no check HERE, but it is not optional: the
                // schema marks it `isRequired: true` above, and
                // `BackendDescriptor.firstViolation` enforces that before this
                // factory ever runs. Some S3-compatible servers (MinIO, probed
                // against the Docker rig) never look at the value, which reads
                // as "blank is fine" -- it is not. `region` is part of the
                // SigV4 credential scope (`AK/date/REGION/s3/aws4_request`);
                // an empty segment there is a scope real AWS rejects with an
                // opaque `AuthorizationHeaderMalformed` OR `SignatureDoesNotMatch`
                // — which one depends on what else about the request is off,
                // but both mean AWS rejected it. A server that ignores the
                // field is not evidence the field is unneeded, only that
                // it isn't the one enforcing it. `usePathStyle` is a toggle
                // whose every value is valid. The two credential fields belong
                // to the LOGIN, not the bucket: both `connect()` and
                // `validateForEditSave()` check them against the schema's own
                // `isRequired` via `BackendDescriptor.firstViolation` (M23/T6)
                // -- the latter passes `requireSecrets: false`, which is what
                // owns the rule that an empty secret means "unchanged" during
                // an edit.
                break
            }
        }
        return .s3(S3ConnectionConfig(
            accessKeyID: values[S3Field.accessKeyID].trimmingCharacters(in: .whitespacesAndNewlines),
            // TRIMMED, unlike every other backend's secret (maintainer
            // decision, M23/T5 fix round 1). An SSH or WebDAV password is sent
            // verbatim because whitespace can be a legitimate part of it; an
            // AWS secret access key is a base64-ish token that never contains
            // any, so the only thing trimming can remove is what a paste
            // brought along. Leaving it in produces a SigV4 signature mismatch
            // that surfaces as a bare "access denied" with nothing pointing at
            // the stray space. Kept HERE, in S3's own factory, rather than in
            // the shared connect path, so the policy stays S3's.
            secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            region: values[S3Field.region].trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines),
            usePathStyle: values[bool: S3Field.usePathStyle],
            sessionToken: nil))
    }

    /// Bucket and endpoint host — what identifies an S3 connection to a human.
    public static func displaySummary(_ values: FieldValues) -> String {
        let host = URL(string: values[S3Field.endpoint])?.host() ?? values[S3Field.endpoint]
        return "\(values[S3Field.bucket]) @ \(host)"
    }

    // MARK: - Persistence adapter

    /// The on-disk format is unchanged; this translates in both directions.
    public static func values(from stored: StoredS3Config) -> FieldValues {
        var values = FieldValues()
        values[S3Field.endpoint] = stored.endpoint
        values[S3Field.region] = stored.region
        values[S3Field.bucket] = stored.bucket
        values[S3Field.accessKeyID] = stored.accessKeyID
        values[bool: S3Field.usePathStyle] = stored.usePathStyle
        // secretAccessKey deliberately absent: it lives in the Keychain.
        return values
    }

    /// A login set's credentials in schema shape (M22/T9) — see
    /// `SSHFieldSchema.values(from:)`. The secret access key is absent for the
    /// same reason an SSH password is: it lives in the Keychain under the
    /// set's id.
    public static func values(from set: LoginSet) -> FieldValues {
        var values = FieldValues()
        values[S3Field.accessKeyID] = set.accessKeyID ?? ""
        return values
    }

    /// The set a filled-in credential form describes. `username`/`authKind`/
    /// `keyPath` are SSH's columns and stay at their neutral values here.
    public static func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        LoginSet(
            id: id, name: name, username: "", authKind: .password, keyPath: nil, kind: .s3,
            accessKeyID: values[S3Field.accessKeyID]
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every text field is TRIMMED on the way in (M23/T7 fix round 1), for the
    /// same reason as `SSHFieldSchema.apply` and matching what `makeConfig`
    /// already does for the CONNECT direction: without it the same typed value
    /// connected fine and persisted with whitespace. The App's S3 save branch
    /// trimmed all four before building this config; collapsing it onto the
    /// descriptor moved the responsibility here. The secret access key is not
    /// among them because it is not stored here at all.
    public static func stored(from values: FieldValues) -> StoredS3Config {
        StoredS3Config(
            accessKeyID: values[S3Field.accessKeyID]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            region: values[S3Field.region].trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines),
            usePathStyle: values[bool: S3Field.usePathStyle])
    }

    /// Writes ONLY the fields `S3Field` covers, mirroring
    /// `SSHFieldSchema.apply(_:to:)`. `StoredSession` carries group, login-set
    /// binding and the other backends' blocks; rebuilding it from these values
    /// would silently drop them.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.s3 = stored(from: values)
    }
}
