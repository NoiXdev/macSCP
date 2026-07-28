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
    public private(set) var errorMessage: String?

    private let store: SessionStore
    private let secrets: any SecretStore
    /// Per-session audit log persistence (M9b) — only consumed here to clean
    /// up a session's log file on `delete(_:)`. Defaulted so existing call
    /// sites (and most tests) don't need to know about it.
    private let auditStore: AuditLogStore

    public init(
        store: SessionStore, secrets: any SecretStore,
        auditStore: AuditLogStore = AuditLogStore(directory: AuditLogStore.defaultDirectory)
    ) {
        self.store = store
        self.secrets = secrets
        self.auditStore = auditStore
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
    }

    /// Sessions belonging to the given group, or ungrouped sessions when
    /// `groupID` is `nil`.
    public func sessions(inGroup groupID: UUID?) -> [StoredSession] {
        sessions.filter { $0.groupID == groupID }
    }

    @discardableResult
    public func save(
        name: String, host: String, port: Int, username: String, password: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil,
        groupID: UUID? = nil
    ) -> StoredSession? {
        let session: StoredSession
        if let existing = sessions.first(where: { $0.name == name }) {
            var updated = existing
            updated.host = host
            updated.port = port
            updated.username = username
            updated.authKind = authKind
            updated.keyPath = keyPath
            updated.groupID = groupID
            session = updated
        } else {
            session = StoredSession(name: name, host: host, port: port,
                                    username: username, authKind: authKind, keyPath: keyPath,
                                    groupID: groupID)
        }
        do {
            try store.upsert(session)
            try secrets.savePassword(password, for: session.id)
            reload()
            return session
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.saveFailed %@"), String(describing: error))
            return nil
        }
    }

    public func delete(_ session: StoredSession) {
        do {
            try store.delete(id: session.id)
            try secrets.deletePassword(for: session.id)
            // Throw-free by design (M9b) — an orphaned log file is a minor
            // leak, never a reason to fail the session deletion itself.
            auditStore.deleteLog(for: session.id)
            reload()
        } catch {
            reload()
            errorMessage = String(
                format: CoreL10n.string("core.session.deleteFailed %@"), String(describing: error))
        }
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
    public func updateSession(_ updated: StoredSession, newSecret: String?) {
        do {
            try store.upsert(updated)
            if let newSecret, !newSecret.isEmpty {
                try secrets.savePassword(newSecret, for: updated.id)
            }
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
            var password: String?
            if includePasswords {
                password = self.password(for: session)
                if password == nil {
                    missingPasswordCount += 1
                }
            }
            return ExportedSession(
                id: session.id, name: session.name, host: session.host, port: session.port,
                username: session.username, authKind: session.authKind, keyPath: session.keyPath,
                groupID: includeGroups ? session.groupID : nil, password: password)
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
        }

        reload()
        return SessionImportResult(
            imported: imported, skipped: plan.skipped.count,
            passwordsImported: passwordsImported, passwordFailures: passwordFailures,
            storeFailures: storeFailures)
    }
}
