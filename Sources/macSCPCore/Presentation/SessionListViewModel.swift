import Foundation
import Observation

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
    @discardableResult
    public func save(
        name: String, host: String, port: Int, username: String, password: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil,
        groupID: UUID? = nil, loginSetID: UUID? = nil,
        jump: StoredSession.JumpSpec? = nil, jumpSecret: String? = nil
    ) -> StoredSession? {
        let session: StoredSession
        var previousJump: StoredSession.JumpSpec?
        if let existing = sessions.first(where: { $0.name == name }) {
            previousJump = existing.jump
            var updated = existing
            updated.host = host
            updated.port = port
            updated.username = username
            updated.authKind = authKind
            updated.keyPath = keyPath
            updated.groupID = groupID
            updated.loginSetID = loginSetID
            updated.jump = jump
            session = updated
        } else {
            session = StoredSession(name: name, host: host, port: port,
                                    username: username, authKind: authKind, keyPath: keyPath,
                                    groupID: groupID, loginSetID: loginSetID, jump: jump)
        }
        do {
            try store.upsert(session)
            if loginSetID == nil {
                if authKind == .agent {
                    // Agent mode needs no secret (M10d) -- clean up a
                    // leftover manual slot from before the switch, mirroring
                    // the "no session-level secret needed" set-mode branch.
                    try? secrets.deletePassword(for: session.id)
                } else {
                    try secrets.savePassword(password, for: session.id)
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
    private func cleanOrphanedJumpSlot(
        previous: StoredSession.JumpSpec?, new: StoredSession.JumpSpec?
    ) {
        guard let previous, previous.loginSetID == nil else { return }
        if let new, new.loginSetID == nil, new.authKind != .agent, new.sessionID == nil,
           new.secretID == previous.secretID {
            return // Still referenced by the new manual jump -- keep it.
        }
        try? secrets.deletePassword(for: previous.secretID)
    }

    /// The outcome of `delete(_:)`'s jump-restoration pass (M11a Task 2).
    public struct JumpRestoreResult: Equatable {
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
    /// `resolvedLogin` would report it) copied into concrete `JumpSpec`
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
        let affected = sessionsUsingAsJump(session.id)
        // The deleted session's effective login, resolved exactly like
        // `resolvedLogin(for:)` would: nil for a manual session (use its own
        // fields + own keychain secret below), a set's values otherwise. An
        // agent session/set reads no keychain at all (M10d rule).
        let resolvedBastionLogin = (try? LoginResolver.resolve(
            session: session, sets: loginSets, secrets: secrets)) ?? nil
        let bastionUsername = resolvedBastionLogin?.username ?? session.username
        let bastionAuthKind = resolvedBastionLogin?.authKind ?? session.authKind
        let bastionKeyPath = resolvedBastionLogin?.keyPath ?? session.keyPath
        var bastionSecret: String?
        if let resolvedBastionLogin {
            bastionSecret = resolvedBastionLogin.secret
        } else if session.authKind != .agent {
            bastionSecret = (try? secrets.password(for: session.id)) ?? nil
        }

        var secretFailures = 0
        for referencing in affected {
            guard var jump = referencing.jump else { continue }
            jump.host = session.host
            jump.port = session.port
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
            updated.jump = jump
            // Throw-free by design (M10b pattern): a store-write failure for
            // one referencing session must not abort restoring the others,
            // nor the deletion that follows.
            try? store.upsert(updated)
            if hadSecretFailure {
                secretFailures += 1
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
            if updated.authKind == .agent {
                // Agent mode needs no secret (M10d) -- clean up a leftover
                // manual slot from before the switch.
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
    public func deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult {
        let affected = sessionsUsing(setID: set.id)
        // C-1: an agent set carries no secret to restore, even if a stale
        // slot survives from before an edit switched the set to agent mode
        // (`saveLoginSet` scrubs new switches, but an already-agent set must
        // never read/transfer a leftover secret either).
        let setSecret: String? = set.authKind == .agent
            ? nil : ((try? secrets.password(for: set.id)) ?? nil)
        var secretFailures = 0

        for session in affected {
            var restored = session
            var sessionHadSecretFailure = false

            if restored.loginSetID == set.id {
                restored.username = set.username
                restored.authKind = set.authKind
                restored.keyPath = set.keyPath
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
                restored.jump = jump
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
    /// later one does) and is copied under the new set id; every group
    /// session's own secret is then removed (throw-free — a leftover
    /// keychain entry is a harmless residual, never a reason to abort). A
    /// store failure while creating the set aborts before anything is
    /// rewired. Session secrets are deleted only "nach erfolgreicher
    /// Umstellung" (spec §4): if carrying the secret onto the new set fails,
    /// the just-created set is rolled back, no session is rewired, and every
    /// session keeps its own secret.
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet? {
        let groupSessions = candidate.sessionIDs.compactMap { id in
            sessions.first { $0.id == id }
        }
        guard let first = groupSessions.first else { return nil }

        let set = LoginSet(
            name: name, username: candidate.username, authKind: candidate.authKind,
            keyPath: candidate.keyPath)
        do {
            try loginSetStore.upsert(set)
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.login.mergeFailed %@"), String(describing: error))
            return nil
        }

        let source = groupSessions.first { (try? secrets.password(for: $0.id)) ?? nil != nil } ?? first
        var carryError: (any Error)?
        if let secret = (try? secrets.password(for: source.id)) ?? nil {
            do {
                try secrets.savePassword(secret, for: set.id)
            } catch {
                carryError = error
            }
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
    /// names used elsewhere): the username itself, or `"<username> (2)"`,
    /// `"(3)"`, … the first one not colliding case-insensitively with an
    /// existing set's name.
    public func suggestedSetName(forUsername username: String) -> String {
        let existingNames = Set(loginSets.map { $0.name.lowercased() })
        guard existingNames.contains(username.lowercased()) else { return username }
        var counter = 2
        while existingNames.contains("\(username) (\(counter))".lowercased()) {
            counter += 1
        }
        return "\(username) (\(counter))"
    }

    /// Resolves what a session should actually connect with: its own data
    /// for a manual session, or its set's credentials. A dangling
    /// `loginSetID` throws rather than silently falling back (spec §2).
    public func resolvedLogin(for session: StoredSession) throws -> ResolvedLogin? {
        try LoginResolver.resolve(session: session, sets: loginSets, secrets: secrets)
    }

    /// Resolves what a session's jump host should actually connect with
    /// (M10c). `nil` when the session has no jump; a dangling `loginSetID`
    /// on the jump throws, same as `resolvedLogin` (spec §2).
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
    /// reference, `.jumpChainNotSupported` for a chain or self-reference.
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
            // A set-backed session exports the SET's username/authKind/
            // keyPath (and, with includePasswords, the SET's secret) instead
            // of its own — a missing/dangling set just falls back to the
            // session's own (possibly empty) values; export never aborts.
            let resolved = (try? resolvedLogin(for: session)) ?? nil
            let username = resolved?.username ?? session.username
            let authKind = resolved?.authKind ?? session.authKind
            let keyPath = resolved?.keyPath ?? session.keyPath

            var password: String?
            // Agent entries (M10d) never carry a secret and are never
            // counted as missing one -- there is nothing to be missing.
            // An `.s3` session's secret travels via `s3SecretAccessKey`
            // below instead (same keychain slot, different export field) --
            // skip here so it isn't fetched/counted twice.
            if includePasswords, authKind != .agent, session.kind != .s3 {
                password = resolved != nil ? resolved?.secret : self.password(for: session)
                if password == nil {
                    missingPasswordCount += 1
                }
            }

            // S3 fields (M12): only populated for an `.s3` session. The
            // secret access key mirrors `password` above -- same keychain
            // slot (the session's own `id`), same missing-password
            // accounting, same "only with includePasswords" gate.
            var s3AccessKeyID: String?
            var s3Region: String?
            var s3Endpoint: String?
            var s3Bucket: String?
            var s3UsePathStyle: Bool?
            var s3SecretAccessKey: String?
            if session.kind == .s3, let s3 = session.s3 {
                s3AccessKeyID = s3.accessKeyID
                s3Region = s3.region
                s3Endpoint = s3.endpoint
                s3Bucket = s3.bucket
                s3UsePathStyle = s3.usePathStyle
                if includePasswords {
                    s3SecretAccessKey = self.password(for: session)
                    if s3SecretAccessKey == nil {
                        missingPasswordCount += 1
                    }
                }
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
                id: session.id, name: session.name, host: session.host, port: session.port,
                username: username, authKind: authKind, keyPath: keyPath,
                groupID: includeGroups ? session.groupID : nil, password: password,
                jumpHost: jumpHost, jumpPort: jumpPort, jumpUsername: jumpUsername,
                jumpAuthKind: jumpAuthKind, jumpKeyPath: jumpKeyPath, jumpPassword: jumpPassword,
                kind: session.kind,
                s3AccessKeyID: s3AccessKeyID, s3Region: s3Region, s3Endpoint: s3Endpoint,
                s3Bucket: s3Bucket, s3UsePathStyle: s3UsePathStyle,
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

        public init(
            imported: Int, skipped: Int, passwordsImported: Int, passwordFailures: Int,
            storeFailures: Int
        ) {
            self.imported = imported
            self.skipped = skipped
            self.passwordsImported = passwordsImported
            self.passwordFailures = passwordFailures
            self.storeFailures = storeFailures
        }
    }

    /// Applies a previously computed `SessionImportPlan` (spec M9a §2.3).
    /// Purely additive — existing sessions and groups are never mutated. A
    /// keychain failure for one session's password does not abort the
    /// import; the session is still created and the failure is counted.
    /// A store-write failure for one session does not abort the import
    /// either, but that session is skipped entirely — including its
    /// password save, so no keychain entry is orphaned for a session that
    /// never landed in the store — and it is counted in `storeFailures`
    /// rather than `imported`.
    public func applyImport(_ plan: SessionImportPlan) -> SessionImportResult {
        var imported = 0
        var passwordsImported = 0
        var passwordFailures = 0
        var storeFailures = 0

        for group in plan.groupsToCreate {
            // A failed group write is not fatal: sessions still import
            // (possibly without their groupID association). SessionStore's
            // load() already nils out any dangling groupID defensively, so
            // no session ends up referencing a group that doesn't exist.
            try? store.upsertGroup(group)
        }
        for planned in plan.sessionsToImport {
            do {
                try store.upsert(planned.session)
                imported += 1
            } catch {
                storeFailures += 1
                continue
            }
            if let password = planned.password {
                do {
                    try secrets.savePassword(password, for: planned.session.id)
                    passwordsImported += 1
                } catch {
                    passwordFailures += 1
                }
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
            storeFailures: storeFailures)
    }
}
