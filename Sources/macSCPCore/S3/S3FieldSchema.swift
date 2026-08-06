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
            ConnectionField(id: S3Field.endpoint.rawValue,
                            labelKey: "connection.s3.endpoint", labelDefault: "Endpoint",
                            kind: .text),
            ConnectionField(id: S3Field.region.rawValue,
                            labelKey: "connection.s3.region", labelDefault: "Region",
                            kind: .text),
            ConnectionField(id: S3Field.bucket.rawValue,
                            labelKey: "connection.s3.bucket", labelDefault: "Bucket",
                            kind: .text),
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
        return values
    }()

    /// What a login set carries: the credentials, not the endpoint. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: S3Field.accessKeyID.rawValue,
                            labelKey: "connection.s3.accessKey",
                            labelDefault: "Access Key ID", kind: .text),
            ConnectionField(id: S3Field.secretAccessKey.rawValue,
                            labelKey: "connection.s3.secretKey",
                            labelDefault: "Secret Access Key", kind: .secret),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // Switching over the field enum is what makes the compiler check that
        // a newly added field was considered here.
        for field in S3Field.allCases {
            switch field {
            case .bucket:
                guard !values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the bucket") }
            case .endpoint:
                guard !values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the endpoint") }
            case .region, .accessKeyID, .secretAccessKey, .usePathStyle:
                break
            }
        }
        return .s3(S3ConnectionConfig(
            accessKeyID: values[S3Field.accessKeyID].trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secret,
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

    public static func stored(from values: FieldValues) -> StoredS3Config {
        StoredS3Config(
            accessKeyID: values[S3Field.accessKeyID], region: values[S3Field.region],
            endpoint: values[S3Field.endpoint], bucket: values[S3Field.bucket],
            usePathStyle: values[bool: S3Field.usePathStyle])
    }
}
