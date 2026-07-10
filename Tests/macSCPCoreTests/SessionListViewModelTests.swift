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
