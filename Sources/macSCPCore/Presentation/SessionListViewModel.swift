import Foundation
import Observation

/// Zustand der Sessions-Sidebar: Liste, Speichern, Löschen, Passwort-Zugriff.
/// Geheimnisse laufen ausschließlich über den SecretStore.
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
            errorMessage = "Sessions konnten nicht geladen werden: \(String(describing: error))"
        }
    }

    @discardableResult
    public func save(
        name: String, host: String, port: Int, username: String, password: String
    ) -> StoredSession? {
        let session = StoredSession(name: name, host: host, port: port, username: username)
        do {
            try store.upsert(session)
            try secrets.savePassword(password, for: session.id)
            reload()
            return session
        } catch {
            errorMessage = "Session konnte nicht gespeichert werden: \(String(describing: error))"
            return nil
        }
    }

    public func delete(_ session: StoredSession) {
        do {
            try store.delete(id: session.id)
            try secrets.deletePassword(for: session.id)
            reload()
        } catch {
            errorMessage = "Session konnte nicht gelöscht werden: \(String(describing: error))"
        }
    }

    public func password(for session: StoredSession) -> String? {
        (try? secrets.password(for: session.id)) ?? nil
    }
}
