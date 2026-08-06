import Foundation
import Testing
@testable import macSCPCore

@Suite("S3FieldSchema")
struct S3FieldSchemaTests {
    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[S3Field.endpoint] = "https://minio.local:9000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "backups"
        values[S3Field.accessKeyID] = "AKIA"
        values[bool: S3Field.usePathStyle] = true
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .s3), fields: S3Field.self).isEmpty)
    }

    /// The credential schema is what the login-set editor renders. Access key
    /// and secret belong to the login; endpoint and bucket belong to the
    /// connection.
    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .s3).credentialSchema.fields.map(\.id))
        #expect(ids == [S3Field.accessKeyID.rawValue, S3Field.secretAccessKey.rawValue])
    }

    @Test func makeConfigBuildsAnS3Config() throws {
        let config = try S3FieldSchema.makeConfig(filledValues(), "topsecret")
        guard case .s3(let s3) = config else {
            Issue.record("expected .s3, got \(config)")
            return
        }
        #expect(s3.endpoint == "https://minio.local:9000")
        #expect(s3.bucket == "backups")
        #expect(s3.usePathStyle == true)
        #expect(s3.secretAccessKey == "topsecret")
    }

    @Test func makeConfigRejectsAnEmptyBucket() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        #expect(throws: (any Error).self) { _ = try S3FieldSchema.makeConfig(values, "s") }
    }

    /// The round trip the persistence adapter must satisfy: what the form
    /// collected survives being written to disk and read back.
    @Test func valuesRoundTripThroughTheStoredConfig() {
        let stored = S3FieldSchema.stored(from: filledValues())
        let back = S3FieldSchema.values(from: stored)
        #expect(back[S3Field.endpoint] == "https://minio.local:9000")
        #expect(back[S3Field.region] == "us-east-1")
        #expect(back[S3Field.bucket] == "backups")
        #expect(back[S3Field.accessKeyID] == "AKIA")
        #expect(back[bool: S3Field.usePathStyle] == true)
    }

    /// The stored config has no secret field at all, so the round trip must
    /// not carry one either.
    @Test func theRoundTripDropsTheSecret() {
        var values = filledValues()
        values[S3Field.secretAccessKey] = "topsecret"
        let back = S3FieldSchema.values(from: S3FieldSchema.stored(from: values))
        #expect(back[S3Field.secretAccessKey] == "")
    }

    @Test func displaySummaryNamesTheBucketAndEndpointHost() {
        #expect(S3FieldSchema.displaySummary(filledValues()) == "backups @ minio.local")
    }
}
