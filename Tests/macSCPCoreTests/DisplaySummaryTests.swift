import Foundation
import Testing
@testable import macSCPCore

@Suite("displaySummary")
struct DisplaySummaryTests {
    /// Before M22 the audit trail recorded `host: "unused"` and a WebDAV tab
    /// was titled `tim@`, because both were built from SSH-shaped fields the
    /// other backends never fill.
    @Test func eachBackendSummarisesItselfWithoutEmptyParts() {
        var s3 = FieldValues()
        s3[S3Field.bucket] = "backups"
        s3[S3Field.endpoint] = "https://minio.local:9000"
        let s3Summary = BackendDescriptor.descriptor(for: .s3).displaySummary(s3)
        #expect(!s3Summary.hasSuffix("@"))
        #expect(s3Summary.contains("backups"))

        var dav = FieldValues()
        dav[WebDAVField.username] = "tim"
        dav[WebDAVField.baseURL] = "https://cloud.example.com"
        let davSummary = BackendDescriptor.descriptor(for: .webdav).displaySummary(dav)
        #expect(davSummary.contains("cloud.example.com"))
        #expect(!davSummary.hasSuffix("@"))
    }
}
