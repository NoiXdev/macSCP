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

    public init(store: SessionStore, secrets: any SecretStore) {
        self.store = store
        self.secrets = secrets
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
}
