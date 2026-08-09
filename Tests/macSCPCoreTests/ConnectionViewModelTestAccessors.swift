import Foundation
@testable import macSCPCore

// S3 and WebDAV pass-through accessors `ConnectionViewModel` carried in
// production before M22 made the connection form data-driven. Production
// code now reads and writes `values` directly and has no caller left for
// any of these eight (verified by deleting them from `ConnectionViewModel`
// and rebuilding `MacSCPApp`/`MacSCPCLI` clean — only test files failed to
// compile). They stay here as test-only convenience so the ~69 existing call
// sites across the test target keep reading `vm.s3Bucket`/`vm.webdavBaseURL`/
// etc. instead of the raw namespaced `values` subscript.

extension ConnectionViewModel {
    var s3Endpoint: String {
        get { values[S3Field.endpoint] }
        set { values[S3Field.endpoint] = newValue }
    }

    var s3Region: String {
        get { values[S3Field.region] }
        set { values[S3Field.region] = newValue }
    }

    var s3Bucket: String {
        get { values[S3Field.bucket] }
        set { values[S3Field.bucket] = newValue }
    }

    var s3AccessKeyID: String {
        get { values[S3Field.accessKeyID] }
        set { values[S3Field.accessKeyID] = newValue }
    }

    /// Never persisted — same "leave unchanged in edit mode" rule as the
    /// SSH `password`/jump `jumpPassword` above; the App layer resolves the
    /// actual secret from the Keychain at connect time.
    var s3SecretAccessKey: String {
        get { values[S3Field.secretAccessKey] }
        set { values[S3Field.secretAccessKey] = newValue }
    }

    var s3UsePathStyle: Bool {
        get { values[bool: S3Field.usePathStyle] }
        set { values[bool: S3Field.usePathStyle] = newValue }
    }

    var webdavBaseURL: String {
        get { values[WebDAVField.baseURL] }
        set { values[WebDAVField.baseURL] = newValue }
    }

    var webdavUseNextcloudPath: Bool {
        get { values[bool: WebDAVField.useNextcloudPath] }
        set { values[bool: WebDAVField.useNextcloudPath] = newValue }
    }
}
