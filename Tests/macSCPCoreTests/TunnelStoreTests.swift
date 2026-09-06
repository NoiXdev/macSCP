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

    // MARK: - "Absent" and "unreadable" are two different answers

    /// `allProfiles()` cannot tell an empty store from a broken one, and
    /// that is deliberate for its readers (the sidebar glyph, autostart) —
    /// but it is exactly the wrong answer for a caller that STOPS things
    /// which are no longer listed. `readProfiles()` is that caller's reader:
    /// it reports the failure instead of flattening it to `[]`.
    @Test func readProfilesReportsAnUndecodableFileInsteadOfReadingItAsEmpty() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: dir.appendingPathComponent("tunnels.json"))

        // The control beside it: the SAME file still reads as empty through
        // the lenient reader, so this pins a difference between the two and
        // not merely a property of one.
        #expect(store.allProfiles() == [])

        switch store.readProfiles() {
        case .success(let profiles):
            Issue.record("an undecodable tunnels.json was reported as \(profiles.count) profiles")
        case .failure:
            break
        }
    }

    /// A MISSING file is a legitimately empty store, not a failed read: a
    /// fresh install has never written one. Measured beside it below —
    /// deleting the LAST profile leaves a file holding zero profiles rather
    /// than no file — so "missing" and "emptied" are two different states on
    /// disk and both are genuinely empty.
    @Test func readProfilesReportsAMissingFileAsAnEmptyStore() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profiles = try store.readProfiles().get()
        #expect(profiles == [])
    }

    /// What `persist` writes for zero profiles — the finding the reconcile's
    /// missing-file note rests on. `macscp tunnels rm` of the last profile
    /// goes through `delete(id:)`, which persists the emptied container, so
    /// it leaves `tunnels.json` PRESENT and decodable with an empty array.
    /// Removing the file itself is nothing this app or its CLI does.
    @Test func deletingTheLastProfileLeavesAnEmptyFileRatherThanNoFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = profile(sessionID: UUID())
        try store.upsert(only)

        try store.delete(id: only.id)

        let path = dir.appendingPathComponent("tunnels.json").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: path), """
            deleting the last profile removed tunnels.json — the reconcile treats a missing \
            file as an empty store, which would then be indistinguishable from a file \
            somebody removed by hand.
            """)
        #expect(try store.readProfiles().get() == [])
    }

    /// A store that reads fine reports success, which is the positive beside
    /// the failure check above: without it, a `readProfiles()` that always
    /// failed would satisfy that test.
    @Test func readProfilesReportsAReadableFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = profile(sessionID: UUID())
        try store.upsert(stored)

        #expect(try store.readProfiles().get() == [stored])
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

    /// An observer that deletes a session's profiles the way the production
    /// one does.
    ///
    /// A stand-in for `TunnelManager.deletionObserver`, which lives in the
    /// App target and cannot be reached from here: it stops the session's
    /// runners AND calls `deleteAll(for:)`, and the stopping half is pinned
    /// by `TunnelManagerTests`. `TunnelStore` carried this conformance
    /// itself until the final review's fix round (2026-09-06) removed it —
    /// a store that only rewrites `tunnels.json` leaves the tunnels running,
    /// so nothing in production ever registered it and only this test did.
    /// `try?` is the production adapter's own choice: an unwritable
    /// `tunnels.json` is a residual, never a reason to fail the session
    /// deletion.
    private struct ProfileDeleting: SessionDeletionObserver {
        let store: TunnelStore
        func sessionDeleted(id: UUID) { try? store.deleteAll(for: id) }
    }

    /// Deleting a session reaches the `SessionDeletionObserver` seam, and an
    /// observer that removes the session's port-forwarding profiles leaves
    /// none behind.
    ///
    /// The seam is Core's (`SessionListViewModel.delete(_:)` tells its
    /// observers; see that seam's own doc comment for why it lives there
    /// rather than on `SessionStore`). What production registers on it is
    /// `TunnelManager.deletionObserver`, one target up.
    @Test @MainActor func deletingASessionRemovesItsProfiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tunnels-deletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tunnelStore = TunnelStore(directory: dir)
        let viewModel = makeViewModel(directory: dir)
        viewModel.addDeletionObserver(ProfileDeleting(store: tunnelStore))

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
