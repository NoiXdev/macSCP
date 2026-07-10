import Foundation
import Observation

/// State of the sessions sidebar: list, save, delete, password access.
/// Secrets go exclusively through the SecretStore.
@Observable
@MainActor
public final class SessionListViewModel {
    public private(set) var sessions: [StoredSession] = []
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
            errorMessage = nil
        } catch {
            sessions = []
            errorMessage = String(
                format: CoreL10n.string("core.session.loadFailed %@"), String(describing: error))
        }
    }

    @discardableResult
    public func save(
        name: String, host: String, port: Int, username: String, password: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil
    ) -> StoredSession? {
        let session: StoredSession
        if let existing = sessions.first(where: { $0.name == name }) {
            var updated = existing
            updated.host = host
            updated.port = port
            updated.username = username
            updated.authKind = authKind
            updated.keyPath = keyPath
            session = updated
        } else {
            session = StoredSession(name: name, host: host, port: port,
                                    username: username, authKind: authKind, keyPath: keyPath)
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
}
