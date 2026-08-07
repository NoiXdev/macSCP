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
    /// S3 and WebDAV, `host`/`port`/`username`/`authKind`/`keyPath` were
    /// placeholders — usually the literal `"unused"` — and carrying them into
    /// an `ssh` block would preserve exactly the defect this milestone removes.
    ///
    /// `jump` IS DIFFERENT, and dropping it here is a deliberate, lossy choice
    /// rather than the same placeholder argument. A jump was never a
    /// placeholder: it was a real stored object, and the pre-M23 save path
    /// passed `jump:` for every kind, so an S3 or WebDAV session carrying one
    /// can genuinely exist on a user's disk. A hop is an SSH concept, so the
    /// new shape has nowhere to put it and this migration discards it.
    ///
    /// What that costs, stated plainly: the jump's `secretID` names a Keychain
    /// entry holding that bastion's password, and after this migration nothing
    /// references it. The entry is orphaned, not deleted — it stays in the
    /// Keychain forever. Nothing breaks at connect time, because such a hop was
    /// never dialled for a non-SSH session in the first place.
    ///
    /// The cleanup is deliberately NOT done here: this runs from
    /// `SessionStore.load()`, a read path, and a read must not acquire Keychain
    /// write side effects — the same reason `migrateFromLegacy` persists with
    /// `try?`. Reaping orphaned jump slots belongs in a separate pass that owns
    /// a `SecretStore` and can report its failures.
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
