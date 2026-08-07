import Foundation
@testable import macSCPCore

// Test fixtures for `StoredSession`. The ONE place the test target builds one.
//
// Not convenience: insulation. `StoredSession`'s shape changes in this
// milestone, and without this file that change would mean 136 hand edits
// across 21 files — where a mistyped port produces a test that still passes
// while asserting the wrong thing. With it, the change is three bodies.
//
// Defaults are deliberately recognisable rather than realistic: a test that
// depends on a value should name it.

func sshSession(
    id: UUID = UUID(),
    name: String,
    host: String = "example.com",
    port: Int = 22,
    username: String = "tim",
    authKind: StoredSession.AuthKind = .password,
    keyPath: String? = nil,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    jump: StoredSession.JumpSpec? = nil
) -> StoredSession {
    var session = StoredSession(id: id, name: name, groupID: groupID,
                                loginSetID: loginSetID, kind: .ssh)
    session.ssh = StoredSSHConfig(
        host: host, port: port, username: username,
        authKind: authKind, keyPath: keyPath, jump: jump)
    return session
}

func s3Session(
    id: UUID = UUID(),
    name: String,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    config: StoredS3Config = StoredS3Config(
        accessKeyID: "AKIA", region: "eu-central-1",
        endpoint: "https://s3.example.com", bucket: "bucket", usePathStyle: false)
) -> StoredSession {
    StoredSession(id: id, name: name, groupID: groupID,
                  loginSetID: loginSetID, kind: .s3, s3: config)
}

/// SSH form values for `SessionListViewModel.save(name:values:…)` — the flat
/// host/port/username triple that signature took before M23/T7, in SSH's own
/// field vocabulary. The ONE place the test target builds an SSH form bag, for
/// the same reason the session fixtures above exist.
func sshValues(
    host: String,
    port: Int = 22,
    username: String,
    authKind: StoredSession.AuthKind = .password,
    keyPath: String? = nil
) -> FieldValues {
    var values = BackendDescriptor.descriptor(for: .ssh).defaultValues
    values[SSHField.host] = host
    values[SSHField.port] = String(port)
    values[SSHField.username] = username
    values[SSHField.authKind] = authKind.rawValue
    values[SSHField.keyPath] = keyPath ?? ""
    return values
}

func webdavSession(
    id: UUID = UUID(),
    name: String,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    config: StoredWebDAVConfig = StoredWebDAVConfig(
        baseURL: "https://cloud.example.com/remote.php/dav",
        username: "tim", useNextcloudPath: false)
) -> StoredSession {
    StoredSession(id: id, name: name, groupID: groupID,
                  loginSetID: loginSetID, kind: .webdav, webdav: config)
}

// MARK: - Export field bags (M23/P3)
//
// What `SessionListViewModel.exportPayload` writes into
// `ExportedSession.fields` for a session of each kind — the same keys
// `BackendDescriptor.sessionValues` produces, written through the typed
// subscripts so a renamed field id cannot leave a test asserting a key
// nothing writes any more. The ONE place the test target builds an export
// bag, for the same reason the session fixtures above exist.

func sshExportFields(
    host: String = "example.com",
    port: Int = 22,
    username: String = "tim",
    authKind: StoredSession.AuthKind = .password,
    keyPath: String? = nil
) -> [String: String] {
    var values = FieldValues()
    values[SSHField.host] = host
    values[SSHField.port] = String(port)
    values[SSHField.username] = username
    values[SSHField.authKind] = authKind.rawValue
    values[SSHField.keyPath] = keyPath ?? ""
    return values.raw
}

func s3ExportFields(
    accessKeyID: String = "AKIA",
    region: String = "eu-central-1",
    endpoint: String = "https://s3.example.com",
    bucket: String = "bucket",
    usePathStyle: Bool = false
) -> [String: String] {
    var values = FieldValues()
    values[S3Field.accessKeyID] = accessKeyID
    values[S3Field.region] = region
    values[S3Field.endpoint] = endpoint
    values[S3Field.bucket] = bucket
    values[bool: S3Field.usePathStyle] = usePathStyle
    return values.raw
}

func webdavExportFields(
    baseURL: String = "https://cloud.example.com/remote.php/dav",
    username: String = "tim",
    useNextcloudPath: Bool = false
) -> [String: String] {
    var values = FieldValues()
    values[WebDAVField.baseURL] = baseURL
    values[WebDAVField.username] = username
    values[bool: WebDAVField.useNextcloudPath] = useNextcloudPath
    return values.raw
}
