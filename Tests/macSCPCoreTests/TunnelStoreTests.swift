import Foundation
import Testing
@testable import macSCPCore

@Suite("TunnelStore")
struct TunnelStoreTests {
    private func makeTempStore() -> (TunnelStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tunnels-\(UUID().uuidString)")
        return (TunnelStore(directory: dir), dir)
    }

    private func profile(
        sessionID: UUID, name: String = "web", autoStart: TunnelProfile.AutoStart = .off
    ) -> TunnelProfile {
        TunnelProfile(
            sessionID: sessionID, name: name,
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            autoStart: autoStart)
    }

    @Test func emptyWhenNoFileExists() {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.allProfiles() == [])
    }

    @Test func upsertPersistsAndRoundtrips() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let saved = profile(sessionID: sessionID)
        try store.upsert(saved)
        #expect(store.allProfiles() == [saved])
        #expect(store.profiles(for: sessionID) == [saved])
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        var saved = profile(sessionID: sessionID)
        try store.upsert(saved)
        saved.name = "web-renamed"
        try store.upsert(saved)
        let all = store.allProfiles()
        #expect(all.count == 1)
        #expect(all.first?.name == "web-renamed")
    }

    @Test func deleteRemovesProfile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = profile(sessionID: UUID())
        try store.upsert(saved)
        try store.delete(id: saved.id)
        #expect(store.allProfiles() == [])
    }

    @Test func deleteUnknownIdIsNoop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = profile(sessionID: UUID())
        try store.upsert(saved)
        try store.delete(id: UUID())
        #expect(store.allProfiles() == [saved])
    }

    @Test func deleteAllForSessionRemovesOnlyThatSessionsProfiles() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionA = UUID()
        let sessionB = UUID()
        let a1 = profile(sessionID: sessionA, name: "a1")
        let a2 = profile(sessionID: sessionA, name: "a2")
        let b1 = profile(sessionID: sessionB, name: "b1")
        try store.upsert(a1)
        try store.upsert(a2)
        try store.upsert(b1)

        try store.deleteAll(for: sessionA)

        #expect(store.profiles(for: sessionA) == [])
        #expect(store.profiles(for: sessionB) == [b1])
    }

    @Test func autoStartFiltersByTheRequestedMoment() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appStart = profile(sessionID: UUID(), name: "app-start", autoStart: .appStart)
        let login = profile(sessionID: UUID(), name: "login", autoStart: .login)
        let off = profile(sessionID: UUID(), name: "off", autoStart: .off)
        try store.upsert(appStart)
        try store.upsert(login)
        try store.upsert(off)

        #expect(store.autoStart(.appStart) == [appStart])
        #expect(store.autoStart(.login) == [login])
        #expect(store.autoStart(.off) == [off])
    }

    @Test func unreadableFileReadsAsEmpty() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: dir.appendingPathComponent("tunnels.json"))
        #expect(store.allProfiles() == [])
    }

    /// The written file's own keys never spell a secret field — computed as
    /// a `Bool` before the expectation, so neither the file's content nor
    /// the check's own source text can leak one through a failure message
    /// (the "two exits" rule: `#expect` prints the source text of what it
    /// checks, not only the values).
    @Test func writtenFileHoldsNoSecretLikeKey() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(profile(sessionID: UUID()))

        let forbidden = ["password", "passphrase", "secret", "token", "privatekey"]
        let contents = try String(
            contentsOf: dir.appendingPathComponent("tunnels.json"), encoding: .utf8
        ).lowercased()
        let holdsNoSecretLikeKey = forbidden.allSatisfy { !contents.contains($0) }
        #expect(holdsNoSecretLikeKey)
    }

    // MARK: - Session-deletion pin

    @MainActor
    private func makeViewModel(directory: URL) -> SessionListViewModel {
        SessionListViewModel(
            store: SessionStore(directory: directory), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
    }

    /// Deleting a session removes its port-forwarding profiles too — through
    /// the `SessionDeletionObserver` seam `TunnelStore` conforms to,
    /// registered on the view model that actually orchestrates a session's
    /// deletion (`SessionListViewModel.delete(_:)`; see that seam's own doc
    /// comment for why the observer lives there rather than on
    /// `SessionStore` itself).
    @Test @MainActor func deletingASessionRemovesItsProfiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tunnels-deletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tunnelStore = TunnelStore(directory: dir)
        let viewModel = makeViewModel(directory: dir)
        viewModel.addDeletionObserver(tunnelStore)

        let session = viewModel.save(
            name: "web", values: sshValues(host: "example.com", port: 22, username: "tim"),
            password: "")
        let saved = try #require(session)
        try tunnelStore.upsert(profile(sessionID: saved.id))
        #expect(tunnelStore.profiles(for: saved.id).count == 1)

        viewModel.delete(saved)

        #expect(tunnelStore.profiles(for: saved.id) == [])
    }
}
