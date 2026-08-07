import Foundation
import Testing
@testable import macSCPCore

/// The write counterpart to M22's read-only `sessionValues(_:)`.
///
/// Every test here is the same shape on purpose: populate the parts of a
/// `StoredSession` the adapter has NO business touching, apply, and assert
/// they survived. An adapter that rebuilds instead of mutating passes a
/// round-trip test and silently drops a group assignment, a login-set binding
/// or a jump host.
@Suite struct BackendApplyTests {
    private func jumpSpec() -> StoredSession.JumpSpec {
        StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2022, username: "hop",
            authKind: .privateKey, keyPath: "/keys/hop")
    }

    @Test func sshApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID(), jump = jumpSpec()
        var session = sshSession(
            name: "prod", groupID: group, loginSetID: set, jump: jump)

        var values = FieldValues()
        values[SSHField.host] = "new.example.com"
        values[SSHField.port] = "2222"
        values[SSHField.username] = "deploy"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        BackendDescriptor.descriptor(for: .ssh).apply(values, &session)

        #expect(session.host == "new.example.com")
        #expect(session.port == 2222)
        #expect(session.username == "deploy")
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.jump == jump)
        #expect(session.name == "prod")
    }

    @Test func s3ApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID()
        var session = s3Session(name: "bucket", groupID: group, loginSetID: set)

        var values = FieldValues()
        values[S3Field.endpoint] = "https://minio.example.com"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "archive"
        values[S3Field.accessKeyID] = "AKIANEW"
        values[bool: S3Field.usePathStyle] = true
        BackendDescriptor.descriptor(for: .s3).apply(values, &session)

        #expect(session.s3?.bucket == "archive")
        #expect(session.s3?.region == "us-east-1")
        #expect(session.s3?.endpoint == "https://minio.example.com")
        #expect(session.s3?.accessKeyID == "AKIANEW")
        #expect(session.s3?.usePathStyle == true)
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.name == "bucket")
    }

    @Test func webdavApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID()
        var session = webdavSession(name: "cloud", groupID: group, loginSetID: set)

        var values = FieldValues()
        values[WebDAVField.baseURL] = "https://nas.example.com/dav"
        // Deliberately NOT the fixture's default username ("tim") -- an
        // assertion against the same value the fixture already carries would
        // pass even if `apply` silently dropped the field.
        values[WebDAVField.username] = "alice"
        values[bool: WebDAVField.useNextcloudPath] = true
        BackendDescriptor.descriptor(for: .webdav).apply(values, &session)

        #expect(session.webdav?.baseURL == "https://nas.example.com/dav")
        #expect(session.webdav?.username == "alice")
        #expect(session.webdav?.useNextcloudPath == true)
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.name == "cloud")
    }

    /// `sessionValues` and `apply` are inverses. Proving it for all three
    /// backends at once is what keeps a field added to one side and forgotten
    /// on the other from shipping.
    ///
    /// `groupID`/`loginSetID` are populated (M23/T9 fix round 2), not left
    /// `nil`: `sessionValues` never reads either one (they are not backend
    /// fields), so a `nil == nil` comparison would carry this assertion even
    /// for a REBUILDING adapter that drops them both -- exactly the defect
    /// this suite exists to catch, per its own header comment.
    @Test(arguments: ConnectionKind.allCases)
    func applyIsTheInverseOfSessionValues(kind: ConnectionKind) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let group = UUID(), set = UUID()
        let original: StoredSession
        switch kind {
        case .ssh: original = sshSession(
            name: "s", host: "h.example.com", port: 2222, username: "u",
            authKind: .privateKey, keyPath: "/k", groupID: group, loginSetID: set)
        case .s3: original = s3Session(name: "s", groupID: group, loginSetID: set)
        case .webdav: original = webdavSession(name: "s", groupID: group, loginSetID: set)
        }

        var rebuilt = original
        descriptor.apply(descriptor.sessionValues(original), &rebuilt)
        #expect(rebuilt == original)
    }
}
