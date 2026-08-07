import Foundation

/// The pre-M23 on-disk shape of a session: SSH's fields flat at the top level,
/// meaningless on S3 and WebDAV sessions, where they held `"unused"`.
///
/// DECODE ONLY. Nothing writes this shape any more — `SessionStore` reads it
/// once from `sessions.json` and writes the result to `sessions-v2.json`,
/// leaving the old file untouched as the migration-moment backup.
struct LegacyStoredSession: Decodable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authKind: StoredSession.AuthKind
    let keyPath: String?
    let groupID: UUID?
    let loginSetID: UUID?
    let jump: StoredSession.JumpSpec?
    let kind: ConnectionKind?
    let s3: StoredS3Config?
    let webdav: StoredWebDAVConfig?

    /// A session's `kind` decides whether the flat fields meant anything. For
    /// S3 and WebDAV they were placeholders, and carrying them into an `ssh`
    /// block would preserve exactly the defect this milestone removes.
    func upgraded() -> StoredSession {
        let resolvedKind = kind ?? .ssh
        var session = StoredSession(
            id: id, name: name, groupID: groupID,
            loginSetID: loginSetID, kind: resolvedKind,
            s3: s3, webdav: webdav)
        if resolvedKind == .ssh {
            session.ssh = StoredSSHConfig(
                host: host, port: port, username: username,
                authKind: authKind, keyPath: keyPath, jump: jump)
        }
        return session
    }
}
