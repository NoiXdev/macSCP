import Foundation
import Observation

/// `applyMerge` refusing a group whose members hold different secrets (M28/T2).
/// Thrown rather than branched so it lands in the rollback the carry failures
/// already use -- one place that deletes the set, rewires nothing and deletes
/// nothing. `description` is what that branch interpolates into
/// `core.login.mergeFailed %@`, which is why this is a localized sentence
/// instead of a type name; it states THAT the credentials differ and never
/// quotes either of them.
private struct LoginMergeSecretConflict: Error, CustomStringConvertible {
    var description: String { CoreL10n.string("core.login.mergeConflictingSecrets") }
}

/// State of the sessions sidebar: list, save, delete, password access.
/// Secrets go exclusively through the SecretStore.
@Observable
@MainActor
public final class SessionListViewModel {
    public private(set) var sessions: [StoredSession] = []
    /// Flat groups shown as collapsible sidebar sections, in creation order
    /// (not sorted).
    public private(set) var groups: [StoredGroup] = []
    /// Reusable logins (M10b), loaded name-sorted by the store.
    public private(set) var loginSets: [LoginSet] = []
    public private(set) var errorMessage: String?

    private let store: SessionStore
    private let secrets: any SecretStore
    /// Per-session audit log persistence (M9b) — only consumed here to clean
    /// up a session's log file on `delete(_:)`. Defaulted so existing call
    /// sites (and most tests) don't need to know about it.
    private let auditStore: AuditLogStore
    /// Login-set persistence (M10b). Defaulted so existing call sites don't
    /// need to know about it.
    private let loginSetStore: LoginSetStore

    public init(
        store: SessionStore, secrets: any SecretStore,
        auditStore: AuditLogStore = AuditLogStore(directory: AuditLogStore.defaultDirectory),
        loginSetStore: LoginSetStore = LoginSetStore(directory: SessionStore.defaultDirectory)
    ) {
        self.store = store
        self.secrets = secrets
        self.auditStore = auditStore
        self.loginSetStore = loginSetStore
        reload()
    }

    public func reload() {
        do {
            sessions = try store.all().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            groups = try store.allGroups()
            errorMessage = nil
        } catch {
            sessions = []
            groups = []
            errorMessage = String(
                format: CoreL10n.string("core.session.loadFailed %@"), String(describing: error))
        }
        loginSets = (try? loginSetStore.all()) ?? []
    }

    /// Sessions belonging to the given group, or ungrouped sessions when
    /// `groupID` is `nil`.
    public func sessions(inGroup groupID: UUID?) -> [StoredSession] {
        sessions.filter { $0.groupID == groupID }
    }

    /// `loginSetID`, when non-nil, makes the session reference a login set
    /// (M10b): `password` is then ignored and no session-level keychain
    /// entry is written, since the set owns the secret instead.
    /// `jump` (M10c) attaches a jump host hop; `jumpSecret` of `nil` or empty
    /// leaves an existing MANUAL jump's keychain slot untouched, a non-empty
    /// value overwrites it. Slot hygiene: an old manual jump whose slot is no
    /// longer referenced by the new state — jump removed, switched to set
    /// mode, or replaced with a freshly-generated manual `JumpSpec` (a
    /// changed `secretID`) — has its keychain entry cleaned up (see
    /// `cleanOrphanedJumpSlot`'s own doc comment below for the exact rule).
    /// `kind` (M12/T7b): defaulted so every existing SSH call site is
    /// untouched. For an `.s3` session, `password` carries the secret access
    /// key — it rides the SAME keychain slot (`secrets.savePassword(_:for:
    /// session.id)` below) as the SSH password; there is no separate S3
    /// secret path, and the same holds for a `.webdav` session's password
    /// (M21, bug-fix round after Task 9).
    ///
    /// `values` (M23/T7) replaces the flat host/port/username triple plus the
    /// per-protocol `s3:`/`webdav:` parameters: the backend's own adapter
    /// writes its own fields, so this method no longer needs to know that S3
    /// has a bucket and SSH has a port — nor to park the literal `"unused"` in
    /// fields a backend does not have, which is what the three call sites in
    /// `ContentView` used to do.
    @discardableResult
    public func save(
        name: String, values: FieldValues, password: String,
        kind: ConnectionKind = .ssh,
        groupID: UUID? = nil, loginSetID: UUID? = nil,
        jump: StoredSession.JumpSpec? = nil, jumpSecret: String? = nil
    ) -> StoredSession? {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        var previousJump: StoredSession.JumpSpec?
        var session: StoredSession
        if let existing = sessions.first(where: { $0.name == name }) {
            previousJump = existing.jump
            session = existing
        } else {
            session = StoredSession(id: UUID(), name: name, kind: kind)
        }
        session.name = name
        // A name collision across KINDS is the one way this method changes an
        // existing session's protocol (M23/T7 fix round 1) — "Save & connect"
        // matches by name, so saving an SSH connection under a name an S3
        // session already holds converts it. Mutating rather than rebuilding is
        // what carries group and login-set binding forward, but the PREVIOUS
        // backend's own storage must not come along: `apply` writes only the
        // fields its own backend owns, so without this an `.ssh` session keeps
        // a populated `s3` block (endpoint, bucket, access key id) and a `.s3`
        // session keeps SSH's key path, auth kind and port. All of that reaches
        // the store, the export codec and `SessionImportPlanner.duplicateKey`.
        //
        // Since M23/T8 that is one line per backend block, and the separate
        // `host`/`username` reset this used to need before `apply` is gone with
        // it: SSH's fields live in `ssh`, so clearing the block clears them.
        //
        // Guarded on an actual kind CHANGE so the ordinary same-kind re-save
        // stays byte-identical. `validateForEditSave` needs no counterpart: the
        // type picker is disabled in edit mode (`ConnectionFormView`,
        // "connection type is fixed after creation"), so an edit cannot reach
        // this case.
        if session.kind != kind {
            session.ssh = nil
            session.s3 = nil
            session.webdav = nil
        }
        session.kind = kind
        session.groupID = groupID
        session.loginSetID = loginSetID
        descriptor.apply(values, &session)
        // AFTER `apply`, which is what creates the SSH block for an `.ssh`
        // session (M23/T8). A jump is an SSH concept and now lives inside that
        // block, so a non-SSH session has nowhere to put one — and this line
        // is correctly a no-op there rather than storing a hop nothing dials.
        session.ssh?.jump = jump

        do {
            try store.upsert(session)
            if loginSetID == nil {
                // The auth kind lives in the values now, and
                // `requiresSecret` is the descriptor's own answer to "does this
                // backend need a secret at all" — false ONLY for an SSH agent
                // login (S3 and WebDAV always answer true), which is exactly
                // what the `authKind == .agent` check here used to mean. An
                // agent login stores no secret and has its leftover manual slot
                // cleaned up (M10d).
                if descriptor.requiresSecret(values) {
                    try secrets.savePassword(password, for: session.id)
                } else {
                    try? secrets.deletePassword(for: session.id)
                }
            }
            // `sessionID == nil` is load-bearing (M11a/T3 review): a jump that
            // borrows a saved connection has no secret of its own — the
            // referenced session owns it. Enforcing that HERE, not only at the
            // call sites, keeps a future caller from silently copying the
            // resolved secret into this jump's otherwise unused slot.
            if let jump, jump.loginSetID == nil, jump.sessionID == nil,
               jump.authKind != .agent, let jumpSecret, !jumpSecret.isEmpty {
                try secrets.savePassword(jumpSecret, for: jump.secretID)
            }
            cleanOrphanedJumpSlot(previous: previousJump, new: jump)
            reload()
            return session
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.saveFailed %@"), String(describing: error))
            return nil
        }
    }

    /// Slot hygiene (M10c, extended M10d, extended M11a): an old MANUAL jump
    /// (`secretID` slot, `loginSetID == nil`) becomes orphaned when the new
    /// state no longer references that exact slot — the jump was removed,
    /// switched to set mode, replaced with a freshly generated `JumpSpec`,
    /// switched to agent mode (M10d, no secret needed even when `secretID`
    /// itself didn't change), or switched to session mode (M11a, `sessionID`
    /// non-nil — the referenced session's own login is used instead, same
    /// "no secret needed here" reasoning as agent mode). The session-mode
    /// case matters even though `buildJumpSpec` happens to carry the SAME
    /// `secretID` forward when switching from an existing manual jump
    /// (`existingJumpSecretID` reused as a data carrier, spec §1) — without
    /// the `new.sessionID == nil` check below, that unchanged id would look
    /// "still referenced" and the stale manual secret would survive
    /// alongside a jump that no longer reads it. Throw-free by design
    /// (M9b/M10b pattern): a stray keychain entry is a harmless residual,
    /// never a reason to fail the save/update itself.
    ///
    /// SET mode is the one case that asks before it deletes (M28/T3). It used
    /// to drop the old slot on the strength of the new MODE alone, without
    /// asking whether the set holds anything — and nothing carries that value
    /// (`save` and `updateSession` both write `jumpSecret` only for a jump
    /// with `loginSetID == nil`), so the slot is the only copy. A set holding
    /// no secret then leaves the jump unable to authenticate with nothing to
    /// go back to, and secretless sets are ordinary: `LoginSetExportSheet`
    /// starts its `includeSecrets` switch off. The old slot now goes only when
    /// `jumpSetDemonstrablyCoversItsLogin` below says so; "the set holds
    /// nothing", "the Keychain would not answer" and "the set is not for SSH
    /// at all" (M28/T6) each keep it.
    ///
    /// Keeping on an unanswerable read is chosen deliberately, not inherited:
    /// this function stays throw-free, so the alternative would be to abort
    /// the save — but the BINDING is fine, only the cleanup cannot be
    /// justified, and a stray entry is the residual this function's own
    /// contract already tolerates. Losing the only copy of a credential is
    /// not.
    ///
    /// The question is asked only for a genuinely set-bound jump
    /// (`sessionID == nil`): once `sessionID` is set, `loginSetID` survives as
    /// an inert data carrier that nothing reads — the same F-1 rule
    /// `sessionsUsing(setID:)` applies — so a session-mode jump keeps
    /// deleting, as it did before.
    private func cleanOrphanedJumpSlot(
        previous: StoredSession.JumpSpec?, new: StoredSession.JumpSpec?
    ) {
        guard let previous, previous.loginSetID == nil else { return }
        if let new, new.loginSetID == nil, new.authKind != .agent, new.sessionID == nil,
           new.secretID == previous.secretID {
            return // Still referenced by the new manual jump -- keep it.
        }
        if let new, let setID = new.loginSetID, new.sessionID == nil,
           !jumpSetDemonstrablyCoversItsLogin(setID) {
            return // The new set cannot be shown to serve this jump -- keep it.
        }
        try? secrets.deletePassword(for: previous.secretID)
    }

    /// Whether the login set a jump has just been bound to is a set a jump can
    /// use at all, and demonstrably holds what that jump will need (M28/T3,
    /// applicability added M28/T6). `false` for every case this site cannot
    /// establish — an unreadable set store, an id matching no set, a Keychain
    /// that will not answer — because the only caller deletes a credential
    /// from a `true` and there is no second copy of it.
    ///
    /// APPLICABILITY comes first, and asks `kind`, because coverage is only
    /// meaningful once the set is one this jump could resolve through. A jump
    /// is an SSH hop: `LoginResolver.resolveJump` hands a set-bound spec to
    /// its private `sshLogin(from:)`, which reads the set's `username`,
    /// `authKind` and `keyPath` and the Keychain slot under the set's id, and
    /// `ConnectionViewModel.buildJumpConfig` puts those into an
    /// `SSHConnectionConfig.Jump` — a type with a host, a port, a username and
    /// an `AuthMethod`, and no notion of any other backend. Without this arm a
    /// WebDAV set (whose password field is declared without `isRequired`, so
    /// `setCoversItsLogin` answers `true` while it holds nothing) or an S3 set
    /// holding its secret access key would count as covering an SSH bastion,
    /// and the only copy of the bastion password would go.
    ///
    /// `resolveJump` refuses such a binding itself since M28/T7
    /// (`.jumpSetNotSSH`), which is what keeps the wrong credentials off the
    /// wire — but that answer comes at CONNECT time and this runs at SAVE
    /// time, from `cleanOrphanedJumpSlot` inside the two store-writing paths.
    /// A deletion decided here cannot be taken back by a later refusal, so
    /// this arm still has to ask.
    ///
    /// Asking it BEFORE `setCoversItsLogin` also means no Keychain read
    /// happens for a set that could never have justified the deletion.
    ///
    /// The sets come from `loginSetStore` rather than from `loginSets`:
    /// `reload()` fills that array through a `try?`, so a store that cannot be
    /// read is indistinguishable there from a store holding no sets. Both mean
    /// "keep" here, but only a real read can say which one it is — and
    /// `reload()` runs AFTER this in both callers, so the array would also be
    /// one save behind.
    ///
    /// The private-key arm is the one place this asks more than
    /// `setCoversItsLogin`. That member answers `true` for a private-key set
    /// without reading anything, because the schema shows the passphrase field
    /// as visible but not required — right, since an unencrypted key needs
    /// none. For a DELETION it is not enough: an encrypted key whose
    /// passphrase is stored nowhere leaves the jump unable to authenticate.
    ///
    /// `ManagedKeyPassphrase.hasStoredPassphrase` is deliberately NOT the
    /// question here, and not because the case is unreachable — a jump bound
    /// to a private-key set is ordinary. It is that a managed key's own slot
    /// is never consulted on the jump path: a set-bound jump's secret comes
    /// from `LoginResolver.resolveJump`, which for a non-agent SSH set reads
    /// `secrets.password(for: set.id)` and nothing else, while the two callers
    /// of `ManagedKeyPassphrase.resolve` (`ConnectionFormView`'s Connect
    /// button and `ContentView`'s fill path) both write the connection form's
    /// OWN password from the form's own key path. A key's slot could not
    /// rescue this jump even holding the passphrase. The set's own slot is
    /// therefore the only evidence that exists at this site, and an empty one
    /// means "cannot tell" — which keeps the old slot.
    ///
    /// A stored secret is judged verbatim, untrimmed, for the same reason
    /// `setCoversItsLogin` gives.
    private func jumpSetDemonstrablyCoversItsLogin(_ setID: UUID) -> Bool {
        do {
            guard let set = try loginSetStore.all().first(where: { $0.id == setID }) else {
                return false
            }
            guard set.kind == .ssh else { return false }
            guard try setCoversItsLogin(set) else { return false }
            guard set.authKind == .privateKey else { return true }
            return !((try secrets.password(for: set.id)) ?? "").isEmpty
        } catch {
            return false
        }
    }

    /// The outcome of `delete(_:)`'s jump-restoration pass (M11a Task 2).
    public struct JumpRestoreResult: Equatable {
        /// The number of sessions REFERENCING the deleted one as a jump host
        /// -- not the number actually restored. `delete(_:)` only performs a
        /// restoration when the deleted session still carries its SSH block;
        /// a session that references it can be counted here while none of
        /// that copying runs, so this field can overstate how many
        /// restorations actually happened. That gap is currently
        /// unreachable in practice: `SessionStore.load()` drops any `.ssh`
        /// record with no stored SSH block before it ever reaches a caller,
        /// so no session lacking that block -- and therefore no session that
        /// could trigger the gap -- can be in the list `delete(_:)` operates
        /// on.
        public var restored: Int
        public var secretFailures: Int

        public init(restored: Int, secretFailures: Int) {
            self.restored = restored
            self.secretFailures = secretFailures
        }
    }

    /// Deletes a session. Spec §5 "delete = restoration" for a session used
    /// as someone else's jump host (M11a): every session whose `jump.
    /// sessionID` points at the one being deleted gets the deleted session's
    /// EFFECTIVE login (its own data, or its login set's, exactly like
    /// `resolvedSSHLogin(for:)` reports it) copied into concrete `JumpSpec`
    /// fields, its resolved secret copied into the jump's OWN `secretID`
    /// slot, and both `sessionID` and `loginSetID` nilled -- the restored
    /// jump carries no reference of any kind, only values. A keychain
    /// failure while copying one session's secret is counted, never fatal;
    /// the session is still restored (values + nil reference), only its
    /// secret slot stays empty (M10b/B2 pattern: nothing is deleted here,
    /// only copied, so there is no risk of losing a secret to a failed
    /// write).
    ///
    /// Ordering is deliberate: every restoration is persisted BEFORE the
    /// session itself is deleted, so a failure in the deletion step can
    /// never leave a half-restored world -- referencing sessions are always
    /// either fully restored or (if nothing referenced this session)
    /// untouched, regardless of what happens to the deletion itself.
    @discardableResult
    public func delete(_ session: StoredSession) -> JumpRestoreResult {
        // Restoration copies the deleted session's host, port and login into
        // every jump that referenced it. Only an SSH session HAS those, which
        // is why `affected` below is computed only for `.ssh` -- copying a
        // non-SSH session's (nonexistent) host/port would write a bastion
        // nobody can dial into someone else's configuration, looking
        // configured.
        //
        // Leaving the reference dangling instead is the honest outcome: the
        // next connect reports `.missingJumpSession` -- "the connection used
        // as jump host no longer exists" -- which is true and actionable.
        // Such a reference can only exist in data written before M24; the
        // picker no longer offers one and `LoginResolver.resolveJump` now
        // refuses one.
        let affected = session.kind == .ssh ? sessionsUsingAsJump(session.id) : []
        var secretFailures = 0
        // Nothing below is needed unless something actually references this
        // session as its bastion, and since M24 `affected` is empty for every
        // non-SSH session. Computing it anyway was not merely wasted work: the
        // `secrets.password(for:)` call reaches into the Keychain, and for an
        // `.s3` session the slot it reads holds that session's SECRET ACCESS
        // KEY -- fetched only to be discarded. A read of a secret nobody needs
        // is one read too many.
        if !affected.isEmpty {
            // Defensive, and unreachable in practice for the same reason as
            // above: `affected` is non-empty only for `.ssh`, and a blockless
            // `.ssh` record is dropped when the store loads (M26). Wrapping
            // the computation and the loop in `if let` (rather than an early
            // `return`) is deliberate: an early return here would skip the
            // deletion below, which is the whole point of this function.
            if let ssh = session.ssh {
                // The deleted session's effective login, via `resolvedSSHLogin(for:)`:
                // nil for a manual session (use its own fields + own keychain secret
                // below), a set's values otherwise. An
                // agent session/set reads no keychain at all (M10d rule).
                let resolvedBastionLogin = resolvedSSHLogin(for: session)
                let bastionUsername = resolvedBastionLogin?.username ?? ssh.username
                let bastionAuthKind = resolvedBastionLogin?.authKind ?? ssh.authKind
                let bastionKeyPath = resolvedBastionLogin?.keyPath ?? session.keyPath
                var bastionSecret: String?
                if let resolvedBastionLogin {
                    bastionSecret = resolvedBastionLogin.secret
                } else if ssh.authKind != .agent {
                    bastionSecret = (try? secrets.password(for: session.id)) ?? nil
                }

                for referencing in affected {
                    guard var jump = referencing.jump else { continue }
                    jump.host = ssh.host
                    jump.port = ssh.port
                    jump.username = bastionUsername
                    jump.authKind = bastionAuthKind
                    jump.keyPath = bastionKeyPath
                    jump.loginSetID = nil
                    jump.sessionID = nil

                    var hadSecretFailure = false
                    if let bastionSecret {
                        do {
                            try secrets.savePassword(bastionSecret, for: jump.secretID)
                        } catch {
                            hadSecretFailure = true
                        }
                    }

                    var updated = referencing
                    // `referencing.jump` was non-nil above, so the SSH block exists:
                    // only an SSH session can carry a jump at all since M23/T8.
                    updated.ssh?.jump = jump
                    // Throw-free by design (M10b pattern): a store-write failure for
                    // one referencing session must not abort restoring the others,
                    // nor the deletion that follows.
                    try? store.upsert(updated)
                    if hadSecretFailure {
                        secretFailures += 1
                    }
                }
            }
        }

        do {
            try store.delete(id: session.id)
            try secrets.deletePassword(for: session.id)
            if let jump = session.jump {
                // Throw-free: a stray jump secret is a harmless residual,
                // never a reason to fail the session deletion itself.
                try? secrets.deletePassword(for: jump.secretID)
            }
            // Throw-free by design (M9b) — an orphaned log file is a minor
            // leak, never a reason to fail the session deletion itself.
            auditStore.deleteLog(for: session.id)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.deleteFailed %@"), String(describing: error))
        }

        return JumpRestoreResult(restored: affected.count, secretFailures: secretFailures)
    }

    public func password(for session: StoredSession) -> String? {
        (try? secrets.password(for: session.id)) ?? nil
    }

    /// Renames a session in place (trims whitespace; an empty result is a
    /// no-op). Does not touch the Keychain secret.
    public func renameSession(_ session: StoredSession, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = session
        updated.name = trimmed
        updateSession(updated, newSecret: nil)
    }

    /// Persists an updated session. `newSecret` of `nil` or empty leaves the
    /// existing Keychain secret untouched; a non-empty value overwrites it.
    /// `jumpSecret` (M10c) is the same "unchanged when nil/empty" semantics
    /// for a MANUAL `updated.jump`'s own slot; slot hygiene for an orphaned
    /// old jump secret runs the same as in `save`.
    public func updateSession(_ updated: StoredSession, newSecret: String?, jumpSecret: String? = nil) {
        let previousJump = sessions.first(where: { $0.id == updated.id })?.jump
        do {
            try store.upsert(updated)
            // No secret field on screen means this login needs none, which
            // today is ssh-agent and nothing else (M10d) -- clean up a
            // leftover manual slot from before the switch. Asking the
            // schema rather than `updated.ssh?.authKind` keeps a
            // `.s3`/`.webdav` session out of this branch by its own
            // declaration instead of by the accident that its SSH auth kind
            // (were it read at all) is not `.agent`.
            if BackendDescriptor.descriptor(for: updated.kind)
                .visibleSecretField(for: updated) == nil {
                try? secrets.deletePassword(for: updated.id)
            } else if let newSecret, !newSecret.isEmpty {
                try secrets.savePassword(newSecret, for: updated.id)
            }
            // Same invariant as `save` above: a session-referencing jump never
            // owns a secret, regardless of what the caller passes.
            if let jump = updated.jump, jump.loginSetID == nil, jump.sessionID == nil,
               jump.authKind != .agent, let jumpSecret, !jumpSecret.isEmpty {
                try secrets.savePassword(jumpSecret, for: jump.secretID)
            }
            cleanOrphanedJumpSlot(previous: previousJump, new: updated.jump)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.saveFailed %@"), String(describing: error))
        }
    }

    /// Moves a session into a group, or ungroups it when `groupID` is `nil`.
    public func moveSession(_ session: StoredSession, toGroup groupID: UUID?) {
        var updated = session
        updated.groupID = groupID
        updateSession(updated, newSecret: nil)
    }

    /// Persists which window halves were last shown for a session (P2
    /// terminal-chrome milestone, Task 4), so a session that is reopened
    /// later comes up the way it was left. Looked up by id rather than
    /// taking a `StoredSession` directly, so the caller (a toolbar/menu
    /// toggle handler) does not need to keep its own copy of the session
    /// around just to write one field into it — a no-op if `sessionID` no
    /// longer names a stored session (e.g. it was deleted while its tab
    /// stayed connected).
    public func updatePaneVisibility(for sessionID: UUID, to visibility: PaneVisibility) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        var updated = session
        updated.paneVisibility = visibility
        updateSession(updated, newSecret: nil)
    }

    /// Creates a new group (trims whitespace; an empty result creates
    /// nothing and returns `nil`).
    @discardableResult
    public func createGroup(named name: String) -> StoredGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = StoredGroup(name: trimmed)
        do {
            try store.upsertGroup(group)
            reload()
            return group
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.groupSaveFailed %@"),
                String(describing: error))
            return nil
        }
    }

    /// Renames a group in place (trims whitespace; an empty result is a
    /// no-op).
    public func renameGroup(_ group: StoredGroup, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = group
        updated.name = trimmed
        do {
            try store.upsertGroup(updated)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.groupSaveFailed %@"),
                String(describing: error))
        }
    }

    /// Dissolves a group: member sessions become ungrouped, never deleted.
    public func dissolveGroup(_ group: StoredGroup) {
        do {
            try store.dissolveGroup(id: group.id)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.groupSaveFailed %@"),
                String(describing: error))
        }
    }

    // MARK: - Login sets (M10b)

    /// Sessions currently referencing the given set, either as their target
    /// login or their jump's login (M10c) — a session referencing the set on
    /// both counts once, since this filters sessions, not references.
    /// `jump?.sessionID == nil` (F-1 fix, final review): a session-mode jump
    /// (spec §1) never actually uses its `loginSetID` -- it's left over as an
    /// inert data carrier once `sessionID` is non-nil (see
    /// `ConnectionViewModel.buildJumpSpec`'s doc comment) -- so a stale
    /// leftover value there must not inflate this usage count.
    public func sessionsUsing(setID: UUID) -> [StoredSession] {
        sessions.filter {
            $0.loginSetID == setID || ($0.jump?.loginSetID == setID && $0.jump?.sessionID == nil)
        }
    }

    /// How many sessions currently reference the given set.
    public func usageCount(of setID: UUID) -> Int {
        sessionsUsing(setID: setID).count
    }

    /// Sessions whose jump host references the given session (M11a) --
    /// used for the "N sessions use this as their jump host" delete
    /// confirmation.
    public func sessionsUsingAsJump(_ id: UUID) -> [StoredSession] {
        sessions.filter { $0.jump?.sessionID == id }
    }

    /// Whether `set` holds what a login bound to it will need (M28).
    ///
    /// Two arms, and the order matters: a set whose visible secret field is
    /// absent or optional needs nothing, and answering that FIRST is what
    /// keeps the Keychain from being read for an agent or key login that has
    /// no slot (the M10d rule). Only a set that declares a REQUIRED secret is
    /// asked whether it actually holds one.
    ///
    /// The question goes to the schema, via
    /// `BackendDescriptor.visibleSecretField(for set:)` — see that member's
    /// own doc comment for why `LoginSet.authKind` is the wrong thing to ask.
    ///
    /// THROWS rather than answering false when the Keychain will not respond.
    /// A failed read is not proof of an empty slot, and the callers of this
    /// decide whether to delete a credential from its answer -- reading "not
    /// covered" out of a locked Keychain would destroy an intact secret.
    ///
    /// A stored secret is judged VERBATIM, untrimmed, the same rule
    /// `ConnectionFieldSchema.missingRequiredFields` applies to a secret
    /// field: whitespace can be a legitimate part of a password, so a slot
    /// holding one covers its login.
    func setCoversItsLogin(_ set: LoginSet) throws -> Bool {
        let descriptor = BackendDescriptor.descriptor(for: set.kind)
        guard descriptor.visibleSecretField(for: set)?.isRequired == true else { return true }
        return !((try secrets.password(for: set.id)) ?? "").isEmpty
    }

    /// Saves a set; a non-nil, non-empty secret overwrites the keychain
    /// entry stored under the SET id (nil/empty keeps it — the editor's
    /// "unchanged" prompt semantics, same as `updateSession`). Agent sets
    /// (M10d) never write a secret at all, regardless of what's passed —
    /// the invariant "no keychain data for agent" holds even if a caller
    /// passes one by mistake.
    public func saveLoginSet(_ set: LoginSet, secret: String?) {
        do {
            try loginSetStore.upsert(set)
            if set.authKind == .agent {
                // C-1: an agent set never keeps a secret -- clean up a
                // leftover slot from before a switch to agent mode, mirroring
                // the session-level hygiene in `save`/`updateSession`.
                try? secrets.deletePassword(for: set.id)
            } else if let secret, !secret.isEmpty {
                try secrets.savePassword(secret, for: set.id)
            }
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.login.saveFailed %@"), String(describing: error))
        }
    }

    /// The outcome of `deleteLoginSet`.
    public struct LoginSetDeleteResult: Equatable {
        public var restored: Int
        public var secretFailures: Int

        public init(restored: Int, secretFailures: Int) {
            self.restored = restored
            self.secretFailures = secretFailures
        }
    }

    /// Spec §3 "delete = restoration": every referencing session gets the
    /// set's username/authKind/keyPath copied back, the set's secret copied
    /// into ITS OWN keychain slot, `loginSetID` nilled. A keychain failure
    /// for one session is counted, never aborts — the session is still
    /// restored (values + nil reference), only its secret is missing.
    /// Afterwards the set and its secret are removed.
    ///
    /// M10c: a session's JUMP can independently reference the same set —
    /// that reference is restored the same way (set's values copied into the
    /// `JumpSpec`, set's secret copied into the jump's OWN `secretID` slot,
    /// `jump.loginSetID` nilled). A session referencing the set on BOTH the
    /// target and the jump has both restored but is counted only ONCE in
    /// `restored`/`secretFailures` — `sessionsUsing` already de-duplicates
    /// per session, and any secret-copy failure on either reference marks
    /// that one session as a failure, not two.
    ///
    /// A failure to READ the set's own secret is the one case that aborts:
    /// nothing is restored, nothing is deleted, the result is zeroed and the
    /// failure goes to `errorMessage` — see the read site's own comment.
    public func deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult {
        let affected = sessionsUsing(setID: set.id)
        // C-1: an agent set carries no secret to restore, even if a stale
        // slot survives from before an edit switched the set to agent mode
        // (`saveLoginSet` scrubs new switches, but an already-agent set must
        // never read/transfer a leftover secret either).
        //
        // The read THROWS rather than swallowing (M28 final review, I-1),
        // and a failure changes nothing at all -- the same rule `applyMerge`
        // follows for its own carry, for the same reason. A locked Keychain
        // or a refused prompt is indistinguishable from a set with nothing to
        // hand back: every referencing session would be restored without its
        // secret, `secretFailures` would stay 0 (it counts WRITE failures),
        // and the set's own slot would then be deleted -- for a session bound
        // by `applyMerge` that slot is the only copy. Reported through the
        // same `errorMessage` the store-failure path below uses; nothing was
        // restored and nothing was deleted, which is what the zeroed result
        // says.
        let setSecret: String?
        do {
            setSecret = set.authKind == .agent ? nil : try secrets.password(for: set.id)
        } catch {
            errorMessage = String(
                format: CoreL10n.string("core.login.deleteFailed %@"), String(describing: error))
            return LoginSetDeleteResult(restored: 0, secretFailures: 0)
        }
        var secretFailures = 0

        for session in affected {
            var restored = session
            var sessionHadSecretFailure = false

            if restored.loginSetID == set.id {
                // Only an SSH session actually gets its login restored here:
                // `restored.ssh?.username = …` is a silent no-op for an S3
                // session (`restored.ssh` is nil), and nothing below restores
                // `restored.s3?.accessKeyID` either — the set's own values
                // never make it back into the session's `s3` block, only
                // `loginSetID` is cleared. This matches pre-M23 behaviour (no
                // regression here), but it is a real gap, not a "handled
                // elsewhere": an S3 session that had its login set deleted
                // ends up with the SET's secret copied into its own keychain
                // slot below, yet no access key ID of its own to pair it
                // with. `beginEditing`/`SessionImportPlanner` are the later
                // phases that would need to close this.
                restored.ssh?.username = set.username
                restored.ssh?.authKind = set.authKind
                restored.ssh?.keyPath = set.keyPath
                restored.loginSetID = nil
                if let setSecret {
                    do {
                        try secrets.savePassword(setSecret, for: session.id)
                    } catch {
                        sessionHadSecretFailure = true
                    }
                }
            }

            // `jump.sessionID == nil` (F-1 fix, final review): a session-mode
            // jump's `loginSetID` is an inert leftover, never the set this
            // jump actually uses (spec §1) -- without this guard a dangling
            // `loginSetID` would write the set's secret into a session-mode
            // jump's otherwise-unused `secretID` slot.
            if var jump = restored.jump, jump.loginSetID == set.id, jump.sessionID == nil {
                jump.username = set.username
                jump.authKind = set.authKind
                jump.keyPath = set.keyPath
                jump.loginSetID = nil
                if let setSecret {
                    do {
                        try secrets.savePassword(setSecret, for: jump.secretID)
                    } catch {
                        sessionHadSecretFailure = true
                    }
                }
                restored.ssh?.jump = jump
            }

            // Throw-free by design: a session's own store write failing here
            // is not distinguished from a keychain failure by the spec, and
            // must not abort restoring the remaining sessions.
            try? store.upsert(restored)
            if sessionHadSecretFailure {
                secretFailures += 1
            }
        }

        do {
            try loginSetStore.delete(id: set.id)
            // Only wipe the set's own keychain secret once the store record
            // is actually gone -- a throwing `delete` must leave the set (and
            // its secret) intact rather than orphaning a set with no secret.
            try? secrets.deletePassword(for: set.id)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.login.deleteFailed %@"), String(describing: error))
        }

        return LoginSetDeleteResult(restored: affected.count, secretFailures: secretFailures)
    }

    /// Suggests merging manual sessions that share the same effective login
    /// (spec §4). Merge-ignored groups are read fresh from the store each
    /// call, so a change to `ignoreMerge` is reflected immediately.
    public func mergeCandidates() -> [LoginMergeCandidate] {
        LoginMergePlanner.candidates(
            sessions: sessions,
            ignoredGroups: (try? loginSetStore.ignoredMergeGroups()) ?? [],
            secrets: secrets)
    }

    /// Persists "don't suggest merging these sessions again" (spec §4).
    /// Throw-free: a failure to persist the ignore is a harmless miss (the
    /// banner may reappear), never a reason to interrupt the user.
    public func ignoreMerge(_ candidate: LoginMergeCandidate) {
        try? loginSetStore.addIgnoredMergeGroup(Set(candidate.sessionIDs))
    }

    /// Creates a set from a merge candidate and rewires every session in the
    /// group onto it. The source secret is the first group session that
    /// actually HAS one (not blindly `sessionIDs.first` — a `.privateKey`
    /// group can have an earlier member with no stored passphrase while a
    /// later one does; a slot holding the empty string counts as having none,
    /// M28/T2) and is copied under the new set id; every group
    /// session's own secret is then removed (throw-free — a leftover
    /// keychain entry is a harmless residual, never a reason to abort).
    /// Members that hold DIFFERENT non-empty secrets are not merged on the
    /// first of them: that is refused outright, because one set has one
    /// credential slot and could serve at most one of them (M28/T2). A
    /// store failure while creating the set aborts before anything is
    /// rewired. Deletion is gated on the secret carry, not on rewiring order
    /// (spec §4): if any part of the carry fails — a keychain READ, members
    /// disagreeing, or the write onto the set — the just-created set is
    /// rolled back, no session is rewired, and every session keeps its own
    /// secret. A failing read is a failed carry and not an empty one, which
    /// is what keeps a locked keychain from looking like a group with
    /// nothing to carry (M28/T2). Once the carry succeeds, each session
    /// is rewired and has its own secret deleted in the same iteration —
    /// both are `try?`, so a store-write failure for one session does not
    /// stop that session's secret from being deleted.
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet? {
        let groupSessions = candidate.sessionIDs.compactMap { id in
            sessions.first { $0.id == id }
        }
        guard !groupSessions.isEmpty else { return nil }
        // Defense in depth (M24). Field keys are namespaced (`SSHField.*`
        // vs. `S3Field.*` vs. `WebDAVField.*`), so two backends can never
        // produce equal `fields` dictionaries -- `kind`'s presence in
        // `LoginMergePlanner`'s grouping key is structurally untestable, not
        // what keeps a group from mixing kinds. This guard is the actual
        // mixed-group defense, and it has to hold here because this function
        // DELETES Keychain entries, and a candidate reaches it as a plain
        // value that anything could have built. Refusing here costs nothing:
        // no set, no rewiring, no deletion, so the banner simply stays.
        guard groupSessions.allSatisfy({ $0.kind == candidate.kind }) else { return nil }

        let descriptor = BackendDescriptor.descriptor(for: candidate.kind)
        // Same defense, one step further: `kind` matching is not enough --
        // `LoginMergePlanner.candidates` also filters out any session whose
        // kind claims a block it does not carry (`hasStoredConfiguration`),
        // so a hand-built candidate over BLOCKLESS sessions of the right kind
        // is exactly as unreachable through the planner as a mixed-kind one,
        // and exactly as capable of deleting a live Keychain entry underneath
        // an empty stored config if it reached here anyway.
        guard groupSessions.allSatisfy({ descriptor.hasStoredConfiguration($0) }) else { return nil }
        let set = descriptor.loginSet(id: UUID(), name: name, from: candidate.values)
        do {
            try loginSetStore.upsert(set)
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.login.mergeFailed %@"), String(describing: error))
            return nil
        }

        var carryError: (any Error)?
        do {
            // The read throws rather than swallowing (M28/T2): a Keychain that
            // will not answer looks exactly like a group of empty slots, and
            // the loop below deletes one slot per member. Reading "nothing to
            // carry" out of a failure would take the only copy each member has.
            // A group that really has nothing to carry is a different case and
            // still merges: those deletes remove slots, but nothing is LOST by
            // them, because a member holding no secret -- or holding only ""
            // -- has nothing to lose when its slot goes.
            //
            // An EMPTY secret counts as no secret (M28/T2 fix round 1), or the
            // same loss happens without any keychain failure: `save` stores the
            // password it is given for every manual non-agent session
            // (`requiresSecret`), empty string included, so an unencrypted
            // private key leaves a slot holding "". A passphrase never enters
            // `LoginMergePlanner`'s grouping key -- the planner skips the read
            // for a `.passphrase`-role field -- so that member can group with,
            // and be ordered before, one holding a real passphrase. Taking it
            // as the source would carry "" onto the set and then delete that
            // real passphrase, the group's only copy.
            //
            // One read per member, none repeated (fix round 2): the value found
            // here IS the value carried. Choosing a source and then re-reading
            // its slot would open a window between the two reads -- the Keychain
            // can lock in it, and the slot can change in it -- and the second
            // read's answer would be the one that counts. There is no such
            // window with one read.
            //
            // Members that hold DIFFERENT non-empty secrets abort the merge
            // (M28/T2 fix round 3, maintainer decision). A login set is one
            // credential: `LoginResolver.credentials(of:secrets:)` reads the
            // set's single slot and every bound session resolves through it, so
            // a set built from disagreeing members could have served at most
            // one of them -- and the way there was to
            // write one onto the set and delete the other, whose slot was the
            // only place it existed. Refusing is not a new restriction; it
            // declines a merge that could not have worked.
            //
            // Which groups can reach it: `LoginMergePlanner.candidates` puts a
            // member's secret in its grouping key only when the schema shows a
            // visible secret field AND that field's role is not `.passphrase`,
            // so disagreeing members are kept apart for a `.credential` secret
            // and only for that. The two that get here are a `.passphrase`
            // group, and a group whose schema shows NO secret field at all --
            // an ssh-agent login, whose members should have no slot, since
            // `save` deletes it for them, but does so with `try?`, so a refused
            // delete leaves one behind. Two agent sessions with leftover slots
            // of differing content would be refused here for a login that has
            // no credential to disagree about. Nothing is lost by that refusal,
            // but it is not a case this check was written for -- see the M28/T2
            // report. And a candidate arrives here as a plain value that
            // anything could have built, planner or not.
            var carried: String?
            for session in groupSessions {
                guard let secret = try secrets.password(for: session.id), !secret.isEmpty
                else { continue }
                if let carried {
                    guard secret == carried else { throw LoginMergeSecretConflict() }
                } else {
                    carried = secret
                }
            }
            if let carried {
                try secrets.savePassword(carried, for: set.id)
            }
        } catch {
            carryError = error
        }
        if let carryError {
            // The secret never made it onto the set -- roll the set back and
            // leave every session exactly as it was (still un-rewired, still
            // holding its own secret).
            try? loginSetStore.delete(id: set.id)
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.login.mergeFailed %@"),
                String(describing: carryError))
            return nil
        }

        for session in groupSessions {
            var updated = session
            updated.loginSetID = set.id
            try? store.upsert(updated)
            try? secrets.deletePassword(for: session.id)
        }

        reload()
        return set
    }

    /// A conflict-free name for a new set (pattern of the file-conflict
    /// names used elsewhere): the label itself, or `"<label> (2)"`,
    /// `"(3)"`, … the first one not colliding case-insensitively with an
    /// existing set's name. `label` is whichever identifying credential value
    /// names the login on screen — a user name for SSH and WebDAV, an access
    /// key ID for S3. (M24/T3 rename: the parameter used to say
    /// `forUsername:`, which was already inaccurate for its S3 callers before
    /// this — this merely gives the long-standing behavior an honest label.)
    public func suggestedSetName(forLabel label: String) -> String {
        let existingNames = Set(loginSets.map { $0.name.lowercased() })
        guard existingNames.contains(label.lowercased()) else { return label }
        var counter = 2
        while existingNames.contains("\(label) (\(counter))".lowercased()) {
            counter += 1
        }
        return "\(label) (\(counter))"
    }

    /// Resolves what a session should actually connect with: its own data
    /// for a manual session, or its set's credentials in the backend's own
    /// field vocabulary. A dangling `loginSetID` throws rather than silently
    /// falling back (spec §2).
    ///
    /// One method for every protocol since M22/T9 — it replaced the SSH-only
    /// `resolvedLogin(for:)` and the S3-only `resolvedS3Login(for:)`, which
    /// is why a WebDAV session can be bound to a login set at all.
    public func resolvedCredentials(for session: StoredSession) throws -> FieldValues? {
        try LoginResolver.resolve(session: session, sets: loginSets, secrets: secrets)
    }

    /// The credential values a login set supplies, secret included (M22/T9) —
    /// the same shape `resolvedCredentials(for:)` returns, for the form's
    /// fill-before-submit path, where the user picked the set directly and
    /// there is no session to resolve THROUGH yet.
    public func credentials(of set: LoginSet) -> FieldValues {
        LoginResolver.credentials(of: set, secrets: secrets)
    }

    /// The SSH-shaped login of a session's set, for the two internal paths
    /// that speak username/authKind/keyPath/secret and nothing else (jump
    /// restoration on delete, and the session export format). `nil` for a
    /// manual session AND for a dangling or kind-mismatched reference —
    /// neither path may abort, they fall back to the session's own values.
    private func resolvedSSHLogin(for session: StoredSession) -> ResolvedLogin? {
        (try? LoginResolver.sshLogin(
            session: session, sets: loginSets, secrets: secrets)) ?? nil
    }

    /// Resolves what a session's jump host should actually connect with
    /// (M10c). `nil` when the session has no jump; a dangling `loginSetID`
    /// on the jump throws, same as `resolvedCredentials(for:)` (spec §2), and
    /// so does one bound to a set that is not an SSH set
    /// (`.jumpSetNotSSH`, M28/T7 — a jump is an SSH bastion).
    public func resolvedJumpLogin(for session: StoredSession) throws -> ResolvedLogin? {
        guard let jump = session.jump else { return nil }
        return try LoginResolver.resolveJump(spec: jump, sets: loginSets, secrets: secrets)
    }

    /// Resolves a session's jump host fully (M11a), including host/port:
    /// `nil` when the session has no jump. Unlike `resolvedJumpLogin`, this
    /// also covers "session" mode (`jump.sessionID` non-nil) -- the
    /// referenced session's own host/port and login. Throws the same
    /// typed errors as `LoginResolver.resolveJump(...sessions:
    /// referencingSessionID:)`: `.missingJumpSession` for a dangling
    /// reference, `.jumpSessionNotSSH` for a reference to a non-`.ssh`
    /// session, `.jumpChainNotSupported` for a chain or self-reference, and
    /// -- on the `sessionID == nil` half it delegates -- `.missingSet` and
    /// `.jumpSetNotSSH` for the jump's own `loginSetID`.
    public func resolvedJump(for session: StoredSession) throws -> ResolvedJump? {
        guard let jump = session.jump else { return nil }
        return try LoginResolver.resolveJump(
            spec: jump, sets: loginSets, secrets: secrets, sessions: sessions,
            referencingSessionID: session.id)
    }

    /// What subset of the sidebar an export covers.
    public enum ExportScope {
        case single(StoredSession)
        case group(StoredGroup)
        case all
    }

    /// Builds an export payload for the given scope (spec M9a §2.2). Groups
    /// are only included when `includeGroups`, and only those referenced by
    /// an exported session. Passwords are only looked up when
    /// `includePasswords`; a missing keychain entry is omitted from the
    /// payload and counted in `missingPasswordCount` rather than aborting
    /// the export.
    public func exportPayload(
        for scope: ExportScope, includeGroups: Bool, includePasswords: Bool
    ) -> (payload: SessionExportPayload, missingPasswordCount: Int) {
        let scopedSessions: [StoredSession]
        switch scope {
        case .single(let session):
            scopedSessions = [session]
        case .group(let group):
            scopedSessions = sessions(inGroup: group.id)
        case .all:
            scopedSessions = sessions
        }

        var missingPasswordCount = 0
        let exportedSessions: [ExportedSession] = scopedSessions.map { session in
            // A set-backed session exports the SET's credentials (and, with
            // includePasswords, the SET's secret) instead of its own — a
            // missing/dangling set just falls back to the session's own
            // (possibly empty) values; export never aborts. The credential
            // values land in `fields` below; here it decides only whether a
            // secret has to be fetched at all.
            let resolved = resolvedSSHLogin(for: session)
            // Built once and reused below (for `needsSecret` and for the
            // field bag) -- both ask the same backend's descriptor for the
            // same session's kind.
            let descriptor = BackendDescriptor.descriptor(for: session.kind)

            // Whether a secret can be fetched at all. The two branches are NOT
            // interchangeable: for a set-bound session the agent-ness belongs
            // to the SET, so asking the schema about the SESSION's own values
            // would make a session behind an agent set start looking for a
            // secret and count itself in the user-visible "N passwords
            // missing". Only the fallback -- the manual session, which is where
            // `StoredSession.authKind` used to be read -- becomes a schema
            // question. The `.agent` comparison on `ResolvedLogin` stays: that
            // type is SSH-shaped on purpose since M22/T9, and is not one of
            // the placeholder accessors.
            let needsSecret = resolved.map { $0.authKind != .agent }
                ?? (descriptor.visibleSecretField(for: session) != nil)

            var password: String?
            // Agent entries (M10d) never carry a secret and are never
            // counted as missing one -- there is nothing to be missing.
            // An `.s3` session's secret travels via `s3SecretAccessKey`
            // below instead (same keychain slot, different export field) --
            // skip here so it isn't fetched/counted twice.
            // `session.kind != .s3` and `session.kind != .webdav ||
            // session.webdav != nil` guard the same hazard from two sides:
            // an `.s3` session's secret is fetched below instead (never
            // here), and a BLOCKLESS `.webdav` session names no server, so
            // fetching a secret for it would count it in the user-visible
            // "N passwords missing" total and, on import, leave an orphan
            // Keychain slot for a session with no WebDAV block at all --
            // exactly the hazard the `.s3` guard below was restored to
            // prevent (M23/P3 fix round 1). An `.ssh`/set-bound session with
            // no resolved login still falls through to a real lookup, same
            // as before.
            if includePasswords, needsSecret, session.kind != .s3,
                session.kind != .webdav || session.webdav != nil {
                password = resolved != nil ? resolved?.secret : self.password(for: session)
                if password == nil {
                    missingPasswordCount += 1
                }
            }

            // The S3 secret access key mirrors `password` above -- prefer the
            // RESOLVED login set's secret (a set-bound S3 session stores
            // its secret under the SET's id, not the session's own id),
            // falling back to the session's own keychain slot; same
            // missing-password accounting, same "only with includePasswords"
            // gate. It is a SECRET, so it never travels in `fields`.
            var s3SecretAccessKey: String?
            // `session.s3 != nil` is load-bearing, not leftover shape from the
            // block this replaced (M23/P3 fix round 1). An `.s3` session with
            // NO stored block names no server: fetching a secret for it would
            // count it in the user-visible "N passwords missing" total, and on
            // import the empty bag yields no S3 block while the carried secret
            // still claims a Keychain slot — an orphan of exactly the kind the
            // jump-password rule below avoids. Dropping this guard was an
            // unreported side effect of collapsing the columns; it is restored
            // deliberately.
            //
            // The `password` branch above carries the matching
            // `session.webdav != nil` guard for the same reason, so a
            // blockless `.webdav` session is no longer fetched or counted
            // either -- the two backends are symmetric here.
            if session.kind == .s3, session.s3 != nil, includePasswords {
                s3SecretAccessKey = resolved != nil ? resolved?.secret : self.password(for: session)
                if s3SecretAccessKey == nil {
                    missingPasswordCount += 1
                }
            }

            // Every backend field in one bag (M23/P3), from the backend's own
            // read adapter -- which is why there is no per-protocol block
            // here any more, and why a fourth backend costs zero columns. An
            // `.s3`/`.webdav` session with no stored block yields the EMPTY
            // bag, and the import side reads that back as "no block".
            var fields = descriptor.sessionValues(session)
            // A set-bound SSH session exports the SET's credentials, not its
            // own -- login sets are never exported, so the reference has to
            // become values here or be lost. `sessionValues` cannot do this:
            // it reads a `StoredSession`, which holds the binding, not the
            // set. Deliberately SSH-only, matching what the columns did
            // before the bag: an S3 session's access key ID stays its own
            // (resolving a set's is deferred to M13, `ResolvedLogin` has no
            // such field), and a WebDAV set supplies the user name at CONNECT
            // time -- baking it in would silently rewrite the stored config.
            if session.kind == .ssh, let resolved {
                fields[SSHField.username] = resolved.username
                fields[SSHField.authKind] = resolved.authKind.rawValue
                fields[SSHField.keyPath] = resolved.keyPath ?? ""
            }

            // Jump fields (M10c, extended M11a): always the RESOLVED values
            // -- a set reference becomes the set's own values, a session
            // reference becomes the REFERENCED session's host/port/login; a
            // dangling set or session reference falls back to the spec's
            // own values (export never aborts). The reference itself
            // (loginSetID / sessionID) never travels with the export --
            // only resolved values do.
            var jumpHost: String?
            var jumpPort: Int?
            var jumpUsername: String?
            var jumpAuthKind: StoredSession.AuthKind?
            var jumpKeyPath: String?
            var jumpPassword: String?
            if let jump = session.jump {
                let resolvedJump = try? LoginResolver.resolveJump(
                    spec: jump, sets: loginSets, secrets: secrets, sessions: sessions,
                    referencingSessionID: session.id)
                jumpHost = resolvedJump?.host ?? jump.host
                jumpPort = resolvedJump?.port ?? jump.port
                jumpUsername = resolvedJump?.login.username ?? jump.username
                jumpAuthKind = resolvedJump?.login.authKind ?? jump.authKind
                jumpKeyPath = resolvedJump?.login.keyPath ?? jump.keyPath
                if includePasswords, jumpAuthKind != .agent {
                    jumpPassword = resolvedJump?.login.secret
                    if jumpPassword == nil {
                        missingPasswordCount += 1
                    }
                }
            }

            return ExportedSession(
                id: session.id, name: session.name, kind: session.kind, fields: fields.raw,
                groupID: includeGroups ? session.groupID : nil,
                // Unconditional, unlike `groupID` above: `includeGroups`
                // gates GROUP membership specifically, and pane visibility
                // is not a group reference -- it travels with the session
                // the same way `kind` or `fields` do.
                paneVisibility: session.paneVisibility, password: password,
                jumpHost: jumpHost, jumpPort: jumpPort, jumpUsername: jumpUsername,
                jumpAuthKind: jumpAuthKind, jumpKeyPath: jumpKeyPath, jumpPassword: jumpPassword,
                s3SecretAccessKey: s3SecretAccessKey)
        }

        var exportedGroups: [ExportedGroup] = []
        if includeGroups {
            let referencedGroupIDs = Set(scopedSessions.compactMap(\.groupID))
            exportedGroups = groups
                .filter { referencedGroupIDs.contains($0.id) }
                .map { ExportedGroup(id: $0.id, name: $0.name) }
        }

        let payload = SessionExportPayload(
            includesSecrets: includePasswords, groups: exportedGroups, sessions: exportedSessions)
        return (payload, missingPasswordCount)
    }

    /// The outcome of applying a `SessionImportPlan`.
    public struct SessionImportResult: Equatable {
        public var imported: Int
        public var skipped: Int
        public var passwordsImported: Int
        public var passwordFailures: Int
        /// Sessions whose `store.upsert` write failed (e.g. an unwritable
        /// store directory). These are excluded from `imported` and never
        /// get a password save, so no orphaned keychain entry is created.
        public var storeFailures: Int
        /// Replaced sessions whose previously stored password was DELETED
        /// because the import file carried none (M19) — see `applyImport`.
        /// Reported to the user: those sessions now have no saved password.
        public var secretsRemoved: Int
        /// Replaced sessions whose stale password could NOT be deleted (the
        /// Keychain refused). The old credential may still be bound to the
        /// reused id — the one outcome of the removal rule the user has to
        /// hear about, since it is the one that leaves a hidden credential
        /// live.
        public var secretRemovalFailures: Int

        public init(
            imported: Int, skipped: Int, passwordsImported: Int, passwordFailures: Int,
            storeFailures: Int, secretsRemoved: Int = 0, secretRemovalFailures: Int = 0
        ) {
            self.imported = imported
            self.skipped = skipped
            self.passwordsImported = passwordsImported
            self.passwordFailures = passwordFailures
            self.storeFailures = storeFailures
            self.secretsRemoved = secretsRemoved
            self.secretRemovalFailures = secretRemovalFailures
        }
    }

    /// Applies a previously computed `SessionImportPlan` (spec M9a §2.3).
    /// A cancelled plan (`plan.cancelled`) applies and reports NOTHING — an
    /// all-zero result, no store or keychain writes, `reload()` not even
    /// called — checked directly rather than inferred from every array
    /// happening to be empty.
    ///
    /// Existing GROUPS are never mutated. Existing SESSIONS can be: a
    /// `PlannedSession` whose `replacesExisting` is true (M19) carries an
    /// EXISTING record's id, and `store.upsert` overwrites that record in
    /// place.
    ///
    /// A replace is a replace of the SECRET too (M19). The import file
    /// decides which secret the replaced session ends up with:
    /// - it carries one (a non-empty string) → that one is saved under the
    ///   (reused) id;
    /// - it carries none — either `nil`, or an empty string, which counts as
    ///   "none" the same way the login-set twin (`applyLoginSetImport`)
    ///   treats it — (`includesSecrets == false`, the default export) →
    ///   the OLD secret is DELETED rather than left silently bound to the new
    ///   record. Keeping it would mean a session the user just replaced
    ///   connects with a password that is nowhere in the file they imported
    ///   and nowhere on screen — the worst of both readings. Deleting it is
    ///   reported (`secretsRemoved`), so the user knows to re-enter it, and
    ///   is counted only when a non-empty secret was actually there.
    /// The old record's JUMP slot is cleaned up on the same principle: the
    /// planner mints a FRESH `secretID` for every imported jump, so whatever
    /// the replaced record referenced is unreachable afterwards and would
    /// linger in the Keychain forever.
    ///
    /// A keychain failure for one session's password does not abort the
    /// import; the session is still created/overwritten and the failure is
    /// counted. A store-write failure for one session does not abort the
    /// import either, but that session is skipped entirely — including its
    /// password save, so no keychain entry is orphaned for a session that
    /// never landed in the store — and it is counted in `storeFailures`
    /// rather than `imported`.
    public func applyImport(_ plan: SessionImportPlan) -> SessionImportResult {
        guard !plan.cancelled else {
            return SessionImportResult(
                imported: 0, skipped: 0, passwordsImported: 0, passwordFailures: 0, storeFailures: 0)
        }
        var imported = 0
        var passwordsImported = 0
        var passwordFailures = 0
        var storeFailures = 0
        var secretsRemoved = 0
        var secretRemovalFailures = 0
        // Snapshot BEFORE any write: `store.upsert` overwrites a replaced
        // record, so its previous jump binding is only readable now.
        let previousByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for group in plan.groupsToCreate {
            // A failed group write is not fatal: sessions still import
            // (possibly without their groupID association). SessionStore's
            // load() already nils out any dangling groupID defensively, so
            // no session ends up referencing a group that doesn't exist.
            try? store.upsertGroup(group)
        }
        for planned in plan.sessionsToImport {
            let previous = planned.replacesExisting ? previousByID[planned.session.id] : nil
            do {
                try store.upsert(planned.session)
                imported += 1
            } catch {
                storeFailures += 1
                continue
            }
            // `!password.isEmpty`, matching the login-set twin
            // (`applyLoginSetImport`'s `secretForSet` check): without it, a
            // file carrying `"password": ""` on a replace took THIS branch
            // instead of the removal one below, writing an empty Keychain
            // entry and counting a `passwordsImported` for a "password" that
            // is not one.
            if let password = planned.password, !password.isEmpty {
                do {
                    try secrets.savePassword(password, for: planned.session.id)
                    passwordsImported += 1
                } catch {
                    passwordFailures += 1
                }
            } else if planned.replacesExisting {
                // No secret came with the replacement: the old one must not
                // survive under the reused id.
                //
                // The delete runs REGARDLESS of what the probe below could
                // establish, because it is idempotent and because "there is no
                // secret" and "I could not find out" are different answers
                // (the same distinction `ManagedKeyPassphrase.hasStoredPass-
                // phrase` throws to preserve). Gating the delete on a `try?`
                // read meant a Keychain that is there but not answering —
                // locked, prompt denied — left the OLD password bound to the
                // reused id, silently: exactly the state this rule exists to
                // prevent.
                //
                // The probe now only decides what may be CLAIMED. A read that
                // failed proves nothing, so nothing is reported; a delete that
                // failed is the one case where the stale credential really can
                // still be live, and that is reported.
                let stale = (try? secrets.password(for: planned.session.id)) ?? nil
                do {
                    try secrets.deletePassword(for: planned.session.id)
                    if !(stale ?? "").isEmpty { secretsRemoved += 1 }
                } catch {
                    secretRemovalFailures += 1
                }
            }
            // Orphan hygiene for a replaced record's jump secret: the planner
            // always mints a fresh `secretID`, so the old slot is unreachable
            // from here on. Best-effort and never counted — nothing the user
            // could act on, unlike the target secret above.
            if let previousJumpID = previous?.jump?.secretID,
               previousJumpID != planned.session.jump?.secretID
            {
                try? secrets.deletePassword(for: previousJumpID)
            }
            // Jump secret (M10c): stored under the FRESH secretID the
            // planner generated for `planned.session.jump`. Counted the same
            // way as the target's password -- a keychain failure here is one
            // more `passwordFailures`, never fatal to the import.
            if let jump = planned.session.jump, let jumpPassword = planned.jumpPassword {
                do {
                    try secrets.savePassword(jumpPassword, for: jump.secretID)
                    passwordsImported += 1
                } catch {
                    passwordFailures += 1
                }
            }
        }

        reload()
        return SessionImportResult(
            imported: imported, skipped: plan.skipped.count,
            passwordsImported: passwordsImported, passwordFailures: passwordFailures,
            storeFailures: storeFailures, secretsRemoved: secretsRemoved,
            secretRemovalFailures: secretRemovalFailures)
    }

    // MARK: - Login-set export/import (M19)

    /// A built `.macscplogins` payload plus everything the export sheet has to
    /// tell the user about what did NOT make it into the file.
    public struct LoginSetExportResult: Equatable {
        public var payload: LoginSetExportPayload
        /// Password/S3 sets that have no stored secret while secrets were
        /// requested. Key sets are excluded: an unencrypted key legitimately
        /// has no passphrase, so counting them would cry wolf on every export.
        public var missingSecretCount: Int
        /// Names of the sets whose MANAGED key could not be read (the key file
        /// vanished, or is unreadable). Those sets export without their key
        /// file — everything else about them still travels.
        public var keyErrors: [String]
        /// Embedded key files that travel WITHOUT their passphrase: encrypted
        /// key material the receiving side cannot unlock until the user types
        /// the passphrase there. Never silent — the sheet says so.
        public var keysWithoutPassphrase: Int
        /// Key sets whose `keyPath` is not a macSCP-managed key. Their file is
        /// deliberately never read (`EmbeddedKeyPorter.embed`), so the export
        /// carries the path string only.
        public var externalKeyCount: Int

        public init(
            payload: LoginSetExportPayload, missingSecretCount: Int, keyErrors: [String],
            keysWithoutPassphrase: Int, externalKeyCount: Int
        ) {
            self.payload = payload
            self.missingSecretCount = missingSecretCount
            self.keyErrors = keyErrors
            self.keysWithoutPassphrase = keysWithoutPassphrase
            self.externalKeyCount = externalKeyCount
        }
    }

    /// Builds the export payload for the given sets (spec M19 "Payload").
    ///
    /// `includesSecrets`/`includesKeyFiles` on the returned payload describe
    /// what is ACTUALLY in it, not what was asked for: both planners gate on
    /// those flags, so a flag that overstates makes the import promise
    /// material that is not there, and one that understates makes it drop
    /// material that is. Asking for secrets when no set has one therefore
    /// yields `includesSecrets == false`.
    ///
    /// Key files are embedded only for macSCP-MANAGED keys — an external
    /// `keyPath` (`~/.ssh/...`) is never opened, only its path travels.
    ///
    /// Passphrase sourcing (M19 finding 3): `EmbeddedKeyPorter.embed` can only
    /// look in the key's OWN Keychain slot. A key that arrived from an earlier
    /// import WITHOUT its passphrase has no such slot, and the passphrase the
    /// user has typed since lives in the LOGIN SET's slot instead (that is
    /// where `ManagedKeyPassphrase`/`LoginResolver` put it and read it from).
    /// The porter cannot see that slot; this caller can, and fills it in — so
    /// "export with secrets" does not silently ship a locked key whose
    /// passphrase the exporting machine had all along.
    public func loginSetExportPayload(
        for sets: [LoginSet], includeSecrets: Bool, includeKeyFiles: Bool,
        keyStore: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory)
    ) -> LoginSetExportResult {
        var missingSecretCount = 0
        var keyErrors: [String] = []
        var keysWithoutPassphrase = 0
        var externalKeyCount = 0

        let exported: [ExportedLoginSet] = sets.map { set in
            // Agent sets (M10d) never have a secret — nothing to read, nothing
            // to report as missing.
            var secret: String?
            if includeSecrets, set.authKind != .agent {
                secret = (try? secrets.password(for: set.id)) ?? nil
                if (secret ?? "").isEmpty, set.authKind == .password {
                    missingSecretCount += 1
                }
            }

            var embeddedKey: EmbeddedKey?
            if includeKeyFiles, set.authKind == .privateKey {
                do {
                    embeddedKey = try EmbeddedKeyPorter.embed(
                        keyPath: set.keyPath, includePassphrase: includeSecrets,
                        store: keyStore, secrets: secrets)
                    if embeddedKey == nil, !(set.keyPath ?? "").isEmpty {
                        externalKeyCount += 1
                    }
                } catch {
                    // One broken key never aborts the export of the other
                    // sets; the set travels without its key file and is named
                    // in the summary.
                    keyErrors.append(set.name)
                }
                if var key = embeddedKey, key.hasPassphrase, (key.passphrase ?? "").isEmpty {
                    if includeSecrets, let setSecret = secret, !setSecret.isEmpty {
                        key.passphrase = setSecret
                        embeddedKey = key
                    } else {
                        keysWithoutPassphrase += 1
                    }
                }
            }

            return ExportedLoginSet(
                id: set.id, name: set.name, kind: set.kind, username: set.username,
                authKind: set.authKind, keyPath: set.keyPath, accessKeyID: set.accessKeyID,
                secret: (secret ?? "").isEmpty ? nil : secret, embeddedKey: embeddedKey)
        }

        let payload = LoginSetExportPayload(
            includesSecrets: exported.contains {
                $0.secret != nil || !($0.embeddedKey?.passphrase ?? "").isEmpty
            },
            includesKeyFiles: exported.contains { $0.embeddedKey != nil },
            sets: exported)
        return LoginSetExportResult(
            payload: payload, missingSecretCount: missingSecretCount, keyErrors: keyErrors,
            keysWithoutPassphrase: keysWithoutPassphrase, externalKeyCount: externalKeyCount)
    }

    /// The outcome of applying a `LoginSetImportPlan`.
    public struct LoginSetImportResult: Equatable {
        /// Sets that are NEW to this machine — disjoint from `replaced`, since
        /// the summary shows both in one line. A renamed set counts here (it
        /// is a new record); `renamed` says how many of them had to take a
        /// different name.
        public var imported: Int
        public var replaced: Int
        public var skipped: Int
        public var renamed: Int
        public var secretsImported: Int
        /// `.password`-authKind sets (which includes S3 — see
        /// `S3FieldSchema.loginSet`) whose secret slot ends up EMPTY after this
        /// import: the file carried none, or a replace's incoming secret was
        /// empty. A count only — the planned secret decides it, never a
        /// Keychain read. Same authKind-only scope as
        /// `LoginSetExportResult.missingSecretCount`, so a private-key set's
        /// legitimately unencrypted (passphrase-less) state and an agent set's
        /// permanent absence never count here.
        public var secretsMissing: Int
        /// Replaced sets whose previously stored secret was deleted because
        /// the file carried none — same rule as `SessionImportResult`.
        public var secretsRemoved: Int
        /// Replaced sets whose stale secret could NOT be deleted — same
        /// meaning as `SessionImportResult.secretRemovalFailures`.
        public var secretRemovalFailures: Int
        public var secretFailures: Int
        public var storeFailures: Int
        public var keysImported: Int
        /// Names of the sets whose embedded key could not be materialized
        /// (fingerprint mismatch, unverifiable material, unwritable key
        /// store). The set itself is still imported — with the `keyPath` the
        /// file carried, which usually points nowhere on this machine and is
        /// then flagged in `missingKeyPaths`.
        public var keyFailures: [String]
        /// Names of the imported key sets whose `keyPath` does not exist on
        /// THIS machine. Not an error — the list says so, and the user can
        /// point the set at a local key.
        public var missingKeyPaths: [String]

        public init(
            imported: Int = 0, replaced: Int = 0, skipped: Int = 0, renamed: Int = 0,
            secretsImported: Int = 0, secretsMissing: Int = 0, secretsRemoved: Int = 0,
            secretRemovalFailures: Int = 0, secretFailures: Int = 0, storeFailures: Int = 0,
            keysImported: Int = 0, keyFailures: [String] = [], missingKeyPaths: [String] = []
        ) {
            self.imported = imported
            self.replaced = replaced
            self.skipped = skipped
            self.renamed = renamed
            self.secretsImported = secretsImported
            self.secretsMissing = secretsMissing
            self.secretsRemoved = secretsRemoved
            self.secretRemovalFailures = secretRemovalFailures
            self.secretFailures = secretFailures
            self.storeFailures = storeFailures
            self.keysImported = keysImported
            self.keyFailures = keyFailures
            self.missingKeyPaths = missingKeyPaths
        }
    }

    /// Applies a `LoginSetImportPlan`: materializes embedded keys, writes the
    /// sets, and stores their secrets (spec M19).
    ///
    /// A cancelled plan applies and reports NOTHING — checked directly, like
    /// `applyImport`, rather than inferred from empty arrays.
    ///
    /// Order per set: materialize the key first (it decides the final
    /// `keyPath`), then the store record, then the Keychain. A key that lands
    /// while the store write then fails is rolled back out of the key store
    /// again, so a failed import leaves no key behind that belongs to no set.
    ///
    /// Replace and secrets follow the session importer exactly: a replacement
    /// that carries a secret overwrites the old one, and a replacement that
    /// carries none DELETES it (counted in `secretsRemoved`) instead of
    /// leaving the previous credential bound to the set the user just
    /// replaced.
    public func applyLoginSetImport(
        _ plan: LoginSetImportPlan,
        keyStore: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory)
    ) -> LoginSetImportResult {
        guard !plan.cancelled else { return LoginSetImportResult() }

        var result = LoginSetImportResult(
            skipped: plan.skipped.count, renamed: plan.renamed.count)

        for planned in plan.setsToImport {
            var set = planned.set
            var materializedKeyID: UUID?
            // What this set's own Keychain slot should end up holding. Starts
            // as whatever the file carried and is cleared below when the KEY
            // took the same value — see `EmbeddedKeyPorter.MaterializedKey`.
            //
            // An AGENT set never holds a secret (M10d), the invariant
            // `saveLoginSet` enforces for every set the UI writes. Our own
            // exporter cannot produce `authKind: agent` WITH a secret, but a
            // hand-written file can — and the applier must uphold the rule
            // itself rather than trust the file, or the import creates a
            // Keychain entry no screen in the app can ever show, change or
            // clean up. Falling through to the removal branch below also
            // clears the slot a replaced password set used to have.
            var secretForSet = planned.set.authKind == .agent ? nil : planned.secret
            // True once the file DID carry a secret that this applier
            // deliberately declined to write under the set id — because the
            // key took it, or because an agent set may not hold one. It gates
            // only what may be CLAIMED below: the stale slot is still cleared,
            // but "removed because the file had none" would be a plain untruth
            // about a file that had one.
            var secretWithheld = planned.set.authKind == .agent && !(planned.secret ?? "").isEmpty

            if let embedded = planned.embeddedKey {
                do {
                    let materialized = try EmbeddedKeyPorter.materialize(
                        embedded, store: keyStore, secrets: secrets)
                    set.keyPath = materialized.path
                    materializedKeyID = (try? keyStore.key(forPath: materialized.path))??.id
                    result.keysImported += 1
                    if materialized.storedPassphrase, set.authKind == .privateKey {
                        // For a `.privateKey` set the set's secret IS the key
                        // passphrase (that is how `LoginResolver` and
                        // `ManagedKeyPassphrase` read it), so writing it again
                        // under the set id would put ONE secret in TWO slots —
                        // the duplication `hasStoredPassphrase` exists to
                        // prevent. And since the set's slot wins at connect
                        // time, the copy would go on shadowing the key's own
                        // value after the user changes it in the SSH keys
                        // sheet. The key owns it; the set stays out of it.
                        secretForSet = nil
                        secretWithheld = !(planned.secret ?? "").isEmpty
                    }
                } catch {
                    // The set still imports — without a usable key path, which
                    // `missingKeyPaths` below then surfaces.
                    result.keyFailures.append(set.name)
                }
            }

            do {
                try loginSetStore.upsert(set)
            } catch {
                result.storeFailures += 1
                // Undo the key that was just written for a set that never
                // landed: it would otherwise sit in the key list owned by
                // nothing. The count is only walked back when the removal
                // actually happened — `remove` refuses to unlist a key whose
                // Keychain slot it could not delete (see its doc), and a key
                // still in the list is still imported.
                if let materializedKeyID {
                    do {
                        try keyStore.remove(id: materializedKeyID, secrets: secrets)
                        result.keysImported -= 1
                    } catch {}
                }
                continue
            }
            // `imported` and `replaced` are DISJOINT: they sit in one summary
            // line ("N imported, N replaced, N skipped"), so counting a
            // replaced set in both made a single replacing set report itself
            // twice. `imported` means "new to this machine" — which includes a
            // renamed set (it IS a new record; `renamed` details how it got
            // its name) but never one that overwrote an existing record.
            if planned.replacesExisting {
                result.replaced += 1
            } else {
                result.imported += 1
            }

            // Same authKind-only scope as `loginSetExportPayload`'s
            // `missingSecretCount`: a `.privateKey` set legitimately has no
            // passphrase and an `.agent` set never holds one, so only
            // `.password` (which is also what an S3 set's secret access key
            // uses — see `S3FieldSchema.loginSet`) is worth flagging. Reads
            // `secretForSet`, the planned value, never the Keychain.
            if set.authKind == .password, (secretForSet ?? "").isEmpty {
                result.secretsMissing += 1
            }

            if let secret = secretForSet, !secret.isEmpty {
                do {
                    try secrets.savePassword(secret, for: set.id)
                    result.secretsImported += 1
                } catch {
                    result.secretFailures += 1
                }
            } else if planned.replacesExisting {
                // Identical rule and identical reasoning to `applyImport`'s
                // stale-secret branch: delete unconditionally (idempotent, and
                // an unreadable Keychain is not evidence of an empty slot),
                // probe only to decide what may be claimed.
                //
                // The removal runs for a WITHHELD secret too, and must: a stale
                // set slot would otherwise keep winning at connect time over
                // the key's own, correct passphrase, and an agent set would go
                // on owning a Keychain entry no screen can reach. Only the
                // CLAIM is suppressed then — see `secretWithheld`.
                let stale = (try? secrets.password(for: set.id)) ?? nil
                do {
                    try secrets.deletePassword(for: set.id)
                    if !secretWithheld, !(stale ?? "").isEmpty {
                        result.secretsRemoved += 1
                    }
                } catch {
                    result.secretRemovalFailures += 1
                }
            }

            if set.keyFileIsMissing { result.missingKeyPaths.append(set.name) }
        }

        reload()
        return result
    }
}
