import Foundation
import Testing

@testable import macSCPCore

/// `S3FieldSchema.makeConfig`'s two backstop refusals say what the form
/// already says, in the user's language.
///
/// They are a backstop: `BackendDescriptor.firstViolation` refuses a blank
/// bucket or endpoint before this factory runs, from the SAME
/// `invalidMessageKey` the schema declares on the field. The factory used
/// to answer with a hardcoded English "Enter the bucket" / "Enter the
/// endpoint" instead, which is a second copy of a message the schema
/// already owns — and an English one, in a `connectionFailed(reason:)`
/// that `TransferFailureLabel` would show as a "technical detail from the
/// server" if it ever reached a transfer row.
///
/// So the factory now DERIVES the key from the field, as
/// `BucketLevelOperation.refusalMessageKey` derives its own: a reworded
/// message moves in one place, and a renamed key cannot leave a second
/// copy behind.
@Suite struct S3ConfigFactoryMessageTests {
    private static func values(bucket: String, endpoint: String) -> FieldValues {
        var values = S3FieldSchema.defaults
        values[S3Field.endpoint] = endpoint
        values[S3Field.bucket] = bucket
        values[S3Field.region] = "us-east-1"
        values[S3Field.accessKeyID] = "AKIAEXAMPLE"
        values[S3Field.startsAtBucketList] = "false"
        return values
    }

    /// The key the schema declares for a field, read the way the factory
    /// has to read it — from the schema, never spelled here.
    private static func invalidMessageKey(of field: S3Field) throws -> String {
        let declared = try #require(
            S3FieldSchema.connection.fields.first { $0.id == field.rawValue })
        return try #require(declared.invalidMessageKey)
    }

    @Test(arguments: [S3Field.bucket, S3Field.endpoint])
    func aBlankRequiredFieldIsRefusedInTheSchemasOwnWords(_ field: S3Field) throws {
        let values = Self.values(
            bucket: field == .bucket ? "   " : "bucket",
            endpoint: field == .endpoint ? "  " : "https://s3.example.com")
        let key = try Self.invalidMessageKey(of: field)
        let expected = CoreL10n.string(key)
        // The catalogue really answers — `CoreL10n.string` falls back to the
        // key text, which is never empty and would satisfy a weaker check.
        #expect(expected != key, "no catalogue entry for \(key)")

        #expect(throws: RemoteFSError.connectionFailed(reason: expected)) {
            _ = try S3FieldSchema.makeConfig(values, "secret")
        }
    }
}
