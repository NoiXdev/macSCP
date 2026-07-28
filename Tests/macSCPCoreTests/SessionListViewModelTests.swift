import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionListViewModel")
@MainActor
struct SessionListViewModelTests {
    private func makeVM() -> (SessionListViewModel, InMemorySecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(store: SessionStore(directory: dir), secrets: secrets)
        return (vm, secrets, dir)
    }

    @Test func saveCreatesSessionAndStoresPassword() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "example.com", port: 22,
                             username: "tim", password: "geheim")
        #expect(stored != nil)
        #expect(vm.sessions.map(\.name) == ["web"])
        #expect(try secrets.password(for: stored!.id) == "geheim")
    }

    @Test func reloadSortsByNameCaseInsensitive() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.save(name: "zeta", host: "h", port: 22, username: "u", password: "p")
        vm.save(name: "Alpha", host: "h", port: 22, username: "u", password: "p")
        vm.save(name: "beta", host: "h", port: 22, username: "u", password: "p")
        #expect(vm.sessions.map(\.name) == ["Alpha", "beta", "zeta"])
    }

    @Test func deleteRemovesSessionAndSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "weg", host: "h", port: 22, username: "u", password: "p")!
        vm.delete(stored)
        #expect(vm.sessions.isEmpty)
        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func passwordReadsSecret() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")!
        #expect(vm.password(for: stored) == "pw")
    }

    @Test func corruptStoreYieldsLocalizedErrorMessage() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: dir.appendingPathComponent("sessions.json"))
        vm.reload()
        #expect(vm.sessions.isEmpty)
        let prefix = CoreL10n.string("core.session.loadFailed %@")
            .replacingOccurrences(of: "%@", with: "")
        #expect(vm.errorMessage?.hasPrefix(prefix) == true)
    }

    @Test func saveWithExistingNameUpdatesInsteadOfDuplicating() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = vm.save(name: "web", host: "alt.example.com", port: 22,
                            username: "tim", password: "p1")!
        let second = vm.save(name: "web", host: "neu.example.com", port: 2222,
                             username: "tim2", password: "p2")!

        #expect(second.id == first.id)
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.host == "neu.example.com")
        #expect(try secrets.password(for: first.id) == "p2")
    }

    @Test func saveWithFailingSecretsStillReloadsFromDisk() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: FailingSecretStore())

        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "p")
        #expect(stored == nil)
        let prefix = CoreL10n.string("core.session.saveFailed %@")
            .replacingOccurrences(of: "%@", with: "")
        #expect(vm.errorMessage?.hasPrefix(prefix) == true)
        // The store write succeeded — the list must reflect what's on disk.
        #expect(vm.sessions.map(\.name) == ["web"])
    }

    @Test func groupCRUDRoundtrip() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = vm.createGroup(named: "  Customers ")
        #expect(group?.name == "Customers")
        #expect(vm.groups.map(\.name) == ["Customers"])

        vm.renameGroup(group!, to: "Clients")
        #expect(vm.groups.map(\.name) == ["Clients"])

        #expect(vm.createGroup(named: "   ") == nil)
        #expect(vm.groups.count == 1)
    }

    @Test func dissolveKeepsSessionsAndUngroupsThem() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = vm.createGroup(named: "G")!
        let stored = vm.save(name: "s", host: "h", port: 22, username: "u",
                             password: "pw", groupID: group.id)!
        vm.dissolveGroup(group)
        #expect(vm.groups.isEmpty)
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.groupID == nil)
        #expect(vm.password(for: stored) == "pw") // secret untouched
    }

    @Test func moveAndFilterByGroup() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = vm.createGroup(named: "G")!
        let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "pw")!
        vm.moveSession(stored, toGroup: group.id)
        #expect(vm.sessions(inGroup: group.id).map(\.name) == ["s"])
        #expect(vm.sessions(inGroup: nil).isEmpty)
    }

    @Test func renameSessionTrimsAndRejectsEmpty() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "old", host: "h", port: 22, username: "u", password: "pw")!
        vm.renameSession(stored, to: "  new ")
        #expect(vm.sessions.first?.name == "new")
        vm.renameSession(vm.sessions.first!, to: "   ")
        #expect(vm.sessions.first?.name == "new")
    }

    @Test func updateSessionKeepsSecretWhenNewSecretIsNilOrEmpty() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "keep")!
        var updated = stored
        updated.host = "h2"
        vm.updateSession(updated, newSecret: nil)
        #expect(vm.password(for: stored) == "keep")
        vm.updateSession(updated, newSecret: "")
        #expect(vm.password(for: stored) == "keep")
        vm.updateSession(updated, newSecret: "next")
        #expect(vm.password(for: stored) == "next")
        #expect(vm.sessions.first?.host == "h2")
    }

    @Test func exportPayloadScopesAndCountsMissingPasswords() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = vm.createGroup(named: "Prod")!
        let a = vm.save(name: "a", host: "h1", port: 22, username: "u", password: "pw",
                        groupID: group.id)!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "u", password: "pw",
                        groupID: group.id)!
        let c = vm.save(name: "c", host: "h3", port: 22, username: "u", password: "pw")!
        // Only one session keeps its password in the keychain; the other two
        // simulate a missing secret (e.g. deleted out-of-band).
        try secrets.deletePassword(for: b.id)
        try secrets.deletePassword(for: c.id)

        let allResult = vm.exportPayload(for: .all, includeGroups: true, includePasswords: true)
        #expect(allResult.payload.sessions.count == 3)
        #expect(allResult.payload.groups.map(\.name) == ["Prod"])
        #expect(allResult.payload.sessions.filter { $0.password != nil }.count == 1)
        #expect(allResult.missingPasswordCount == 2)
        #expect(allResult.payload.includesSecrets == true)

        let groupResult = vm.exportPayload(for: .group(group), includeGroups: true, includePasswords: true)
        #expect(Set(groupResult.payload.sessions.map(\.name)) == Set(["a", "b"]))
        #expect(groupResult.payload.groups.map(\.name) == ["Prod"])

        let singleResult = vm.exportPayload(for: .single(c), includeGroups: false, includePasswords: true)
        #expect(singleResult.payload.sessions.count == 1)
        #expect(singleResult.payload.groups.isEmpty)
        #expect(singleResult.payload.sessions.first?.groupID == nil)

        let noSecretsResult = vm.exportPayload(for: .all, includeGroups: true, includePasswords: false)
        #expect(noSecretsResult.payload.sessions.allSatisfy { $0.password == nil })
        #expect(noSecretsResult.payload.includesSecrets == false)
        #expect(noSecretsResult.missingPasswordCount == 0)

        _ = a
    }

    @Test func applyImportCreatesEverythingAdditively() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(name: "existing", host: "other.example.com", port: 22,
                               username: "u", password: "keep")!

        let plan = SessionImportPlan(
            groupsToCreate: [StoredGroup(name: "Imported")],
            sessionsToImport: [
                PlannedSession(
                    session: StoredSession(name: "one", host: "h1", username: "root"),
                    password: "secret1"),
                PlannedSession(
                    session: StoredSession(name: "two", host: "h2", username: "root"),
                    password: nil),
            ],
            skipped: [
                ExportedSession(
                    id: UUID(), name: "dupe", host: "h1", port: 22, username: "root",
                    authKind: .password, keyPath: nil, groupID: nil, password: nil),
            ])

        let result = vm.applyImport(plan)

        #expect(result == SessionListViewModel.SessionImportResult(
            imported: 2, skipped: 1, passwordsImported: 1, passwordFailures: 0))
        #expect(vm.sessions.count == 3)
        #expect(vm.groups.map(\.name) == ["Imported"])
        let one = vm.sessions.first { $0.name == "one" }!
        #expect(try secrets.password(for: one.id) == "secret1")
        // Existing session is untouched.
        #expect(vm.sessions.first { $0.id == existing.id }?.host == "other.example.com")
        #expect(try secrets.password(for: existing.id) == "keep")
    }

    @Test func applyImportSurvivesKeychainFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: FailingSecretStore())

        let plan = SessionImportPlan(
            groupsToCreate: [],
            sessionsToImport: [
                PlannedSession(
                    session: StoredSession(name: "one", host: "h1", username: "root"),
                    password: "secret1"),
            ],
            skipped: [])

        let result = vm.applyImport(plan)

        #expect(result == SessionListViewModel.SessionImportResult(
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 1))
        #expect(vm.sessions.map(\.name) == ["one"])
    }
}

private final class FailingSecretStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {
        throw KeychainError(status: -1)
    }
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {
        throw KeychainError(status: -1)
    }
}
