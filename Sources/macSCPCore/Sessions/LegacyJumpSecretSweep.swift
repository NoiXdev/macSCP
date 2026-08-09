import Foundation

/// Removes the Keychain entries the M23 migration left behind.
///
/// M23 dropped a non-SSH session's `jump` when it upgraded the store and said
/// so in `LegacyStoredSession`: the jump's `secretID` named a Keychain entry
/// that nothing referenced afterwards, and the cleanup was deferred to "a
/// separate pass that owns a `SecretStore`". This is that pass.
///
/// **Candidates come from the preserved legacy file, never from the Keychain.**
/// That is what makes the sweep safe rather than merely careful: an entry a
/// future macSCP wrote cannot appear in a file written before M23, so it can
/// never become a candidate. Enumerating the Keychain would have no such
/// guarantee -- everything under the service shares one flat UUID namespace
/// (`KeychainSecretStore` addresses every item by `kSecAttrAccount` =
/// `id.uuidString` under one `kSecAttrService`), so session secrets,
/// login-set secrets and key passphrases are indistinguishable from each
/// other and from anything a newer build stores.
///
/// **Every read error aborts before anything is deleted.** A store that reads
/// as empty when it merely failed would leave no id claimed, and every live
/// jump secret would look like an orphan. For the same reason the sweep talks
/// to the stores rather than to a view model: `reload()` turns a failure into
/// empty lists.
///
/// The sweep never calls `password(for:)`. Nothing is read, only deleted, so
/// there are no access prompts and no decision rests on a failing read.
public struct LegacyJumpSecretSweep {
    /// What the run did.
    ///
    /// `removed` counts DELETES THAT SUCCEEDED, not entries that were known
    /// to be there. The sweep never reads, so it cannot tell the two apart,
    /// and two ordinary situations make the difference real:
    ///
    /// - A slot that is already gone still deletes successfully
    ///   (`KeychainSecretStore` maps `errSecItemNotFound` to success). The
    ///   legacy file stays on disk as M23's downgrade snapshot, so a repeat
    ///   run sees the same candidates; a run in which every delete succeeded
    ///   therefore reports the same `removed` again while changing nothing.
    ///   After a run with `failed > 0` that is not true: a repeat that now
    ///   gets past whatever blocked those slots reports MORE, and does remove
    ///   something.
    /// - A legacy jump backed by a LOGIN SET had a `secretID` that never held
    ///   a secret -- `JumpSpec.secretID` is present in set mode too, unused.
    ///   `legacyJumpSecretIDs()` yields it like any other, so the very first
    ///   run counts a slot that was empty from the start.
    ///
    /// So `removed` is an upper bound on entries that actually went away, and
    /// is not fit to be shown as one.
    public struct Result: Equatable, Sendable {
        public var removed: Int
        public var failed: Int
        public init(removed: Int, failed: Int) {
            self.removed = removed
            self.failed = failed
        }
    }

    private let sessions: SessionStore
    private let loginSets: LoginSetStore
    private let keys: ManagedKeyStore
    private let secrets: any SecretStore

    public init(
        sessions: SessionStore, loginSets: LoginSetStore,
        keys: ManagedKeyStore, secrets: any SecretStore
    ) {
        self.sessions = sessions
        self.loginSets = loginSets
        self.keys = keys
        self.secrets = secrets
    }

    public func run() throws -> Result {
        // Order matters: every read happens before the first delete, so a
        // failure anywhere leaves the Keychain untouched.
        let candidates = try sessions.legacyJumpSecretIDs()
        guard !candidates.isEmpty else { return Result(removed: 0, failed: 0) }
        let claimed = try claimedIDs()

        var removed = 0, failed = 0
        for id in candidates where !claimed.contains(id) {
            do {
                try secrets.deletePassword(for: id)
                removed += 1
            } catch {
                // One failure does not stop the rest -- same rule as removing
                // several known hosts. The count is reported; the error is not
                // carried further, because in production it can only be an
                // OSStatus and the user's next step is the same either way.
                failed += 1
            }
        }
        return Result(removed: removed, failed: failed)
    }

    /// The ids of every session, login set and managed key the stores SURFACE,
    /// plus the jump `secretID` of every surfaced session.
    ///
    /// Deliberately wider than strictly necessary -- a pre-M23 jump `secretID`
    /// cannot also be a login-set or managed-key id, since the only place a
    /// `JumpSpec.secretID` is created is `ConnectionViewModel.buildJumpSpec`,
    /// which reuses the jump's own previous id or mints a fresh UUID. Asking
    /// all three costs one pass each and makes the rule "delete only what
    /// appears NOWHERE" true without case analysis.
    ///
    /// "Surfaced" is not "stored": `SessionStore.load()` drops an `.ssh`
    /// record with no SSH block, and `LoginSetStore.all()` hides a record
    /// whose `authKind` it does not recognise, so both can withhold an id
    /// that is on disk. Neither can matter for THIS candidate set. A dropped
    /// session record has no `ssh` block and therefore no `jump` at all, so it
    /// could never have contributed a candidate; and a hidden login set could
    /// only matter through its own `id`, which by the paragraph above is never
    /// a jump `secretID`.
    private func claimedIDs() throws -> Set<UUID> {
        var claimed = Set<UUID>()
        for session in try sessions.all() {
            claimed.insert(session.id)
            if let secretID = session.jump?.secretID { claimed.insert(secretID) }
        }
        for set in try loginSets.all() { claimed.insert(set.id) }
        for key in try keys.all() { claimed.insert(key.id) }
        return claimed
    }
}
