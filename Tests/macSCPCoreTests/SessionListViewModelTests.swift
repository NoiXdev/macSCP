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
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
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

    @Test func deleteRemovesTheSessionsAuditLog() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        let auditDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-audit-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: auditDir)
        }
        let auditStore = AuditLogStore(directory: auditDir)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: auditStore)

        let stored = vm.save(name: "weg", host: "h", port: 22, username: "u", password: "p")!
        auditStore.append(AuditEvent(kind: .connected, detail: "connected to h as u"), for: stored.id)
        #expect(auditStore.events(for: stored.id).count == 1)

        vm.delete(stored)

        #expect(auditStore.events(for: stored.id).isEmpty)
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
        _ = vm.save(name: "a", host: "h1", port: 22, username: "u", password: "pw",
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
            imported: 2, skipped: 1, passwordsImported: 1, passwordFailures: 0,
            storeFailures: 0))
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
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 1,
            storeFailures: 0))
        #expect(vm.sessions.map(\.name) == ["one"])
    }

    @Test func applyImportReportsOnlyActuallyWrittenSessionsAndSkipsOrphanedPassword() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // `dir` is a plain file, not a directory: SessionStore.persist()'s
        // createDirectory(at:) throws, simulating an unwritable store while
        // load() (called first, and tolerant of a missing path) still
        // succeeds with an empty store.
        try Data("blocked".utf8).write(to: dir)

        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(store: SessionStore(directory: dir), secrets: secrets)

        let planned = PlannedSession(
            session: StoredSession(name: "one", host: "h1", username: "root"),
            password: "secret1")
        let plan = SessionImportPlan(
            groupsToCreate: [], sessionsToImport: [planned], skipped: [])

        let result = vm.applyImport(plan)

        #expect(result == SessionListViewModel.SessionImportResult(
            imported: 0, skipped: 0, passwordsImported: 0, passwordFailures: 0,
            storeFailures: 1))
        #expect(vm.sessions.isEmpty)
        // The store write failed, so the password must never have been
        // saved -- otherwise it would orphan a keychain entry for a
        // session that doesn't exist in the store.
        #expect(try secrets.password(for: planned.session.id) == nil)
    }

    // MARK: - Login sets (M10b)

    @Test func saveWithLoginSetSkipsSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")
        #expect(vm.loginSets.map(\.id) == [set.id])

        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "should-not-be-stored", loginSetID: set.id)!

        #expect(stored.loginSetID == set.id)
        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func deleteLoginSetRestoresSessions() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Deploy Key", username: "deploy", authKind: .privateKey, keyPath: "/k")
        vm.saveLoginSet(set, secret: "pp")

        let a = vm.save(name: "a", host: "h1", port: 22, username: "ignored",
                        password: "", loginSetID: set.id)!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "ignored",
                        password: "", loginSetID: set.id)!
        #expect(vm.usageCount(of: set.id) == 2)
        #expect(Set(vm.sessionsUsing(setID: set.id).map(\.id)) == Set([a.id, b.id]))

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 2, secretFailures: 0))
        for session in [a, b] {
            let restored = vm.sessions.first { $0.id == session.id }!
            #expect(restored.loginSetID == nil)
            #expect(restored.username == "deploy")
            #expect(restored.authKind == .privateKey)
            #expect(restored.keyPath == "/k")
            #expect(try secrets.password(for: session.id) == "pp")
        }
        #expect(vm.loginSets.isEmpty)
        #expect(try secrets.password(for: set.id) == nil)
    }

    @Test func deleteLoginSetCountsSecretFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = SelectiveFailingSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))

        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let a = vm.save(name: "a", host: "h1", port: 22, username: "ignored",
                        password: "", loginSetID: set.id)!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "ignored",
                        password: "", loginSetID: set.id)!
        secrets.failingSessionID = b.id

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 2, secretFailures: 1))
        // Both sessions are restored (values + nil reference) regardless of
        // the keychain failure -- only the secret copy for `b` is missing.
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == a.id }?.username == "root")
        #expect(vm.sessions.first { $0.id == b.id }?.username == "root")
    }

    @Test func applyMergeAbortsAndRewiresNothingWhenCarryingSecretToSetFails() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = NewIDFailingSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))

        let a = vm.save(name: "a", host: "h1", port: 22, username: "root", password: "a")!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "root", password: "a")!
        // Only the two existing session ids may be written from here on --
        // the new set's (never-before-seen) id will throw, simulating a
        // keychain failure specifically while carrying the secret onto it.
        secrets.failNewIDs = true

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!

        let result = vm.applyMerge(candidate, name: "root")

        #expect(result == nil)
        // Nothing was rewired -- both sessions must still be unset.
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        // Both session secrets survive untouched.
        #expect(try secrets.password(for: a.id) == "a")
        #expect(try secrets.password(for: b.id) == "a")
        // No set was left behind in the store.
        #expect(vm.loginSets.isEmpty)
    }

    @Test func applyMergeUsesFirstSessionWithASecretAsSource() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two .privateKey sessions sharing username/keyPath: `a` (first in
        // input order) has NO stored secret, `b` does -- the merge must
        // still carry `b`'s secret onto the new set rather than silently
        // dropping it because the naive "always use the first session"
        // picked a secret-less source.
        let a = vm.save(name: "a", host: "h1", port: 22, username: "root",
                        password: "irrelevant", authKind: .privateKey, keyPath: "/k")!
        _ = vm.save(name: "b", host: "h2", port: 22, username: "root",
                   password: "passphrase", authKind: .privateKey, keyPath: "/k")!
        try secrets.deletePassword(for: a.id)

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!
        #expect(candidate.sessionIDs.first == a.id)

        let set = vm.applyMerge(candidate, name: "root")

        #expect(set != nil)
        #expect(try secrets.password(for: set!.id) == "passphrase")
    }

    @Test func applyMergeCreatesSetAndRewires() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(name: "a", host: "h1", port: 22, username: "root", password: "a")!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "root", password: "a")!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!

        let set = vm.applyMerge(candidate, name: "root")

        #expect(set?.username == "root")
        #expect(set?.authKind == .password)
        #expect(try secrets.password(for: set!.id) == "a")
        for session in [a, b] {
            #expect(vm.sessions.first { $0.id == session.id }?.loginSetID == set?.id)
            #expect(try secrets.password(for: session.id) == nil)
        }
    }

    @Test func suggestedSetNameAvoidsCollision() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(vm.suggestedSetName(forUsername: "root") == "root")

        vm.saveLoginSet(LoginSet(name: "root", username: "root"), secret: nil)
        vm.saveLoginSet(LoginSet(name: "root (2)", username: "root"), secret: nil)

        #expect(vm.suggestedSetName(forUsername: "root") == "root (3)")
    }

    @Test func ignoreMergePersists() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = vm.save(name: "a", host: "h1", port: 22, username: "root", password: "a")!
        _ = vm.save(name: "b", host: "h2", port: 22, username: "root", password: "a")!

        #expect(vm.mergeCandidates().count == 1)
        let candidate = vm.mergeCandidates().first!
        vm.ignoreMerge(candidate)

        #expect(vm.mergeCandidates().isEmpty)
    }

    @Test func exportResolvesLoginSet() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Deploy", username: "deploy")
        vm.saveLoginSet(set, secret: "s")
        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "", loginSetID: set.id)!

        let withSecret = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        #expect(withSecret.payload.sessions.first?.username == "deploy")
        #expect(withSecret.payload.sessions.first?.password == "s")
        #expect(withSecret.missingPasswordCount == 0)

        try secrets.deletePassword(for: set.id)
        let withoutSecret = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        #expect(withoutSecret.payload.sessions.first?.username == "deploy")
        #expect(withoutSecret.payload.sessions.first?.password == nil)
        #expect(withoutSecret.missingPasswordCount == 1)
    }

    @Test func resolvedLoginMissingSetThrows() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "", loginSetID: UUID())!

        #expect(throws: LoginResolveError.missingSet) {
            try vm.resolvedLogin(for: stored)
        }
    }

    // MARK: - Jump host (M10c)

    @Test func saveCleansOrphanedJumpSlotWhenJumpRemoved() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                             jump: jump, jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first { $0.id == stored.id }?.jump == nil)
    }

    @Test func saveCleansOrphanedJumpSlotWhenSwitchingToSetMode() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "s")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                   jump: jump, jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw", jump: setJump)

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    @Test func deleteSessionCleansJumpSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                             jump: jump, jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        vm.delete(stored)

        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func deleteLoginSetRestoresJumpReference() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper", authKind: .privateKey, keyPath: "/k")
        vm.saveLoginSet(set, secret: "pp")

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let stored = vm.save(name: "web", host: "target.example.com", port: 22, username: "u",
                             password: "pw", jump: jump)!
        #expect(vm.usageCount(of: set.id) == 1)

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.jump?.loginSetID == nil)
        #expect(restored.jump?.username == "jumper")
        #expect(restored.jump?.authKind == .privateKey)
        #expect(restored.jump?.keyPath == "/k")
        #expect(try secrets.password(for: restored.jump!.secretID) == "pp")
        // Only the jump was referencing the set -- the target itself is
        // untouched.
        #expect(restored.username == "u")
        #expect(vm.loginSets.isEmpty)
    }

    @Test func deleteLoginSetRestoresBothReferences() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Shared", username: "shared")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let stored = vm.save(name: "web", host: "target.example.com", port: 22, username: "ignored",
                             password: "", loginSetID: set.id, jump: jump)!
        #expect(vm.usageCount(of: set.id) == 1) // counted once despite two references

        let result = vm.deleteLoginSet(set)

        // A session referencing the set on BOTH the target and the jump is
        // still restored exactly once.
        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.username == "shared")
        #expect(restored.jump?.loginSetID == nil)
        #expect(restored.jump?.username == "shared")
        #expect(try secrets.password(for: stored.id) == "s3cr3t")
        #expect(try secrets.password(for: restored.jump!.secretID) == "s3cr3t")
    }

    @Test func exportResolvesJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "jp")
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2222, username: "unused", loginSetID: set.id)
        let stored = vm.save(name: "web", host: "target.example.com", port: 22, username: "u",
                             password: "pw", jump: jump)!

        let withJump = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        let exportedJump = withJump.payload.sessions.first!
        #expect(exportedJump.jumpHost == "bastion.example.com")
        #expect(exportedJump.jumpPort == 2222)
        #expect(exportedJump.jumpUsername == "jumper")
        #expect(exportedJump.jumpAuthKind == .password)
        #expect(exportedJump.jumpPassword == "jp")
        #expect(withJump.missingPasswordCount == 0)

        let noJump = vm.save(name: "plain", host: "h2", port: 22, username: "u", password: "pw")!
        let withoutJump = vm.exportPayload(for: .single(noJump), includeGroups: false, includePasswords: true)
        let exportedPlain = withoutJump.payload.sessions.first!
        #expect(exportedPlain.jumpHost == nil)
        #expect(exportedPlain.jumpPort == nil)
        #expect(exportedPlain.jumpUsername == nil)
        #expect(exportedPlain.jumpAuthKind == nil)
        #expect(exportedPlain.jumpKeyPath == nil)
        #expect(exportedPlain.jumpPassword == nil)

        try secrets.deletePassword(for: set.id)
        let missingSecret = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        #expect(missingSecret.payload.sessions.first?.jumpPassword == nil)
        #expect(missingSecret.missingPasswordCount == 1)
    }

    @Test func applyImportStoresJumpPasswordUnderFreshSecretID() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let plan = SessionImportPlan(
            groupsToCreate: [],
            sessionsToImport: [
                PlannedSession(
                    session: StoredSession(name: "one", host: "h1", username: "root", jump: jump),
                    password: "target-secret", jumpPassword: "jump-secret"),
            ],
            skipped: [])

        let result = vm.applyImport(plan)

        #expect(result.imported == 1)
        #expect(result.passwordFailures == 0)
        let imported = vm.sessions.first { $0.name == "one" }!
        #expect(try secrets.password(for: imported.id) == "target-secret")
        #expect(try secrets.password(for: imported.jump!.secretID) == "jump-secret")
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func saveSwitchingTargetToAgentDeletesSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")!
        #expect(try secrets.password(for: stored.id) == "pw")

        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "", authKind: .agent)

        #expect(try secrets.password(for: stored.id) == nil)
        #expect(vm.sessions.first?.authKind == .agent)
    }

    @Test func updateSessionSwitchingTargetToAgentDeletesSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")!
        var updated = stored
        updated.authKind = .agent

        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: stored.id) == nil)
        #expect(vm.sessions.first?.authKind == .agent)
    }

    @Test func saveJumpSwitchingManualToAgentDeletesJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                   jump: jump, jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        // Same secretID, but the jump now switches to agent mode -- the old
        // manual slot must still be cleaned up even though the id itself
        // didn't change (unlike the existing "removed/replaced slot" cases
        // `cleanOrphanedJumpSlot` already covered).
        let agentJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "jumper", authKind: .agent, secretID: jump.secretID)
        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw", jump: agentJump)

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.authKind == .agent)
    }

    @Test func updateSessionJumpSwitchingManualToAgentDeletesJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                             jump: jump, jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        var updated = stored
        updated.jump?.authKind = .agent
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func saveNeverStoresPasswordForAgentTarget() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "leaked",
                             authKind: .agent)!

        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func saveNeverStoresJumpSecretForAgentJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)
        _ = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw",
                   jump: jump, jumpSecret: "leaked")!

        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func exportPayloadSkipsSecretForAgentAndDoesNotCountMissing() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "",
                             authKind: .agent)!

        let result = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)

        #expect(result.payload.sessions.first?.authKind == .agent)
        #expect(result.payload.sessions.first?.password == nil)
        #expect(result.missingPasswordCount == 0)
    }

    @Test func exportPayloadSkipsJumpSecretForAgentAndDoesNotCountMissing() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)
        let stored = vm.save(name: "web", host: "target.example.com", port: 22, username: "u",
                             password: "pw", jump: jump)!

        let result = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)

        #expect(result.payload.sessions.first?.jumpAuthKind == .agent)
        #expect(result.payload.sessions.first?.jumpPassword == nil)
        #expect(result.missingPasswordCount == 0)
    }

    @Test func deleteLoginSetRestoresAgentSetWithoutSecretTransferOrFailure() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Agent Set", username: "deploy", authKind: .agent)
        vm.saveLoginSet(set, secret: nil)
        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "", loginSetID: set.id)!

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.username == "deploy")
        #expect(restored.authKind == .agent)
        #expect(restored.keyPath == nil)
        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func saveLoginSetNeverStoresSecretForAgentKind() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Agent", username: "deploy", authKind: .agent)

        vm.saveLoginSet(set, secret: "should-not-be-stored")

        #expect(try secrets.password(for: set.id) == nil)
    }

    @Test func resolvedLoginForAgentSetYieldsAgentAuthKindWithNilSecret() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Agent", username: "deploy", authKind: .agent)
        vm.saveLoginSet(set, secret: nil)
        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "", loginSetID: set.id)!

        let resolved = try vm.resolvedLogin(for: stored)
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .agent, keyPath: nil, secret: nil))
    }

    // MARK: - C-1 regression: editing a set to .agent must not keep/transfer a stale secret

    @Test func saveLoginSetEditedToAgentClearsStaleSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        var set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")
        #expect(try secrets.password(for: set.id) == "s3cr3t")

        // Edit the same set (same id) to agent mode -- must scrub the
        // leftover keychain slot from before the switch, mirroring the
        // session-level hygiene in `save`/`updateSession`.
        set.authKind = .agent
        vm.saveLoginSet(set, secret: nil)

        #expect(try secrets.password(for: set.id) == nil)
    }

    @Test func deleteLoginSetEditedToAgentDoesNotTransferStaleSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        var set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")
        let stored = vm.save(name: "web", host: "h", port: 22, username: "ignored",
                             password: "", loginSetID: set.id)!

        set.authKind = .agent
        vm.saveLoginSet(set, secret: nil)

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.authKind == .agent)
        // The stale password-era secret must never have been transferred
        // into the session's own slot, nor left behind on the set's slot.
        #expect(try secrets.password(for: stored.id) == nil)
        #expect(try secrets.password(for: set.id) == nil)
    }

    @Test func deleteLoginSetEditedToAgentDoesNotTransferStaleSecretToJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        var set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "s3cr3t")
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let stored = vm.save(name: "web", host: "target.example.com", port: 22, username: "u",
                             password: "pw", jump: jump)!

        set.authKind = .agent
        vm.saveLoginSet(set, secret: nil)

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.jump?.loginSetID == nil)
        #expect(restored.jump?.authKind == .agent)
        // Jump's own slot must stay empty -- no stale secret transferred.
        #expect(try secrets.password(for: restored.jump!.secretID) == nil)
        #expect(try secrets.password(for: set.id) == nil)
    }

    @Test func applyMergeCreatesAgentSetWithoutSecretRead() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(name: "a", host: "h1", port: 22, username: "root", password: "", authKind: .agent)!
        let b = vm.save(name: "b", host: "h2", port: 22, username: "root", password: "", authKind: .agent)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!
        #expect(candidate.authKind == .agent)

        let set = vm.applyMerge(candidate, name: "root")

        #expect(set?.authKind == .agent)
        #expect(try secrets.password(for: set!.id) == nil)
        for session in [a, b] {
            #expect(vm.sessions.first { $0.id == session.id }?.loginSetID == set?.id)
        }
    }

    @Test func resolvedJumpLoginResolvesOrThrows() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")!
        #expect(try vm.resolvedJumpLogin(for: stored) == nil)

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: UUID())
        let withJump = vm.save(name: "web2", host: "h2", port: 22, username: "u", password: "pw",
                               jump: jump)!
        #expect(throws: LoginResolveError.missingSet) {
            _ = try vm.resolvedJumpLogin(for: withJump)
        }
    }

    // MARK: - Jump-from-saved-session restoration + export (M11a Task 2)

    @Test func sessionsUsingAsJumpFindsReferences() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(name: "bastion", host: "b", port: 22, username: "u", password: "p")!
        let other = vm.save(name: "other", host: "o", port: 22, username: "u", password: "p")!
        let jumpToBastion = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(name: "a", host: "ta", port: 22, username: "u", password: "pw",
                        jump: jumpToBastion)!
        let jumpToOther = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: other.id)
        let b = vm.save(name: "b", host: "tb", port: 22, username: "u", password: "pw", jump: jumpToOther)!
        _ = vm.save(name: "plain", host: "tp", port: 22, username: "u", password: "pw")!

        #expect(Set(vm.sessionsUsingAsJump(bastion.id).map(\.id)) == Set([a.id]))
        #expect(vm.sessionsUsingAsJump(other.id).map(\.id) == [b.id])
    }

    @Test func deleteRestoresJumpReferences() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(name: "bastion", host: "b.example.com", port: 2022,
                              username: "deploy", password: "s")!
        let jumpA = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(name: "a", host: "ta", port: 22, username: "u", password: "pw", jump: jumpA)!
        let jumpB = StoredSession.JumpSpec(
            host: "ignored2", username: "ignored2", sessionID: bastion.id)
        let b = vm.save(name: "b", host: "tb", port: 22, username: "u", password: "pw", jump: jumpB)!

        let result = vm.delete(bastion)

        #expect(result == SessionListViewModel.JumpRestoreResult(restored: 2, secretFailures: 0))
        #expect(vm.sessions.map(\.name).sorted() == ["a", "b"])
        for id in [a.id, b.id] {
            let restored = vm.sessions.first { $0.id == id }!
            #expect(restored.jump?.sessionID == nil)
            #expect(restored.jump?.loginSetID == nil)
            #expect(restored.jump?.host == "b.example.com")
            #expect(restored.jump?.port == 2022)
            #expect(restored.jump?.username == "deploy")
            #expect(restored.jump?.authKind == .password)
            #expect(try secrets.password(for: restored.jump!.secretID) == "s")
        }
    }

    @Test func deleteRestoresFromAgentBastionWithoutSecret() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = NoReadAllowedSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))

        let bastion = vm.save(name: "bastion", host: "b.example.com", port: 2022,
                              username: "deploy", password: "", authKind: .agent)!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(name: "a", host: "ta", port: 22, username: "u", password: "pw", jump: jump)!

        let result = vm.delete(bastion)

        #expect(result == SessionListViewModel.JumpRestoreResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == a.id }!
        #expect(restored.jump?.authKind == .agent)
        #expect(restored.jump?.username == "deploy")
        #expect(restored.jump?.sessionID == nil)
    }

    @Test func deleteCountsSecretFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = SelectiveFailingSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))

        let bastion = vm.save(name: "bastion", host: "b.example.com", port: 2022,
                              username: "deploy", password: "s")!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(name: "a", host: "ta", port: 22, username: "u", password: "pw", jump: jump)!
        secrets.failingSessionID = jump.secretID

        let result = vm.delete(bastion)

        #expect(result == SessionListViewModel.JumpRestoreResult(restored: 1, secretFailures: 1))
        let restored = vm.sessions.first { $0.id == a.id }!
        #expect(restored.jump?.host == "b.example.com")
        #expect(restored.jump?.username == "deploy")
        #expect(restored.jump?.sessionID == nil)
        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func exportResolvesSessionJump() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(name: "bastion", host: "b.example.com", port: 2022,
                              username: "deploy", password: "s")!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let target = vm.save(name: "web", host: "target.example.com", port: 22, username: "u",
                             password: "pw", jump: jump)!

        let exported = vm.exportPayload(for: .single(target), includeGroups: false, includePasswords: true)
        let payload = exported.payload.sessions.first!
        #expect(payload.jumpHost == "b.example.com")
        #expect(payload.jumpPort == 2022)
        #expect(payload.jumpUsername == "deploy")
        #expect(payload.jumpAuthKind == .password)
        #expect(payload.jumpPassword == "s")
        #expect(exported.missingPasswordCount == 0)

        // A dangling session reference (points at a UUID that never existed,
        // e.g. an externally edited store) falls back to the jump's own
        // values and never aborts the export.
        let danglingJump = StoredSession.JumpSpec(
            host: "own-host", port: 2121, username: "own-user", sessionID: UUID())
        let target2 = vm.save(name: "web2", host: "target2.example.com", port: 22, username: "u",
                              password: "pw", jump: danglingJump)!
        let exported2 = vm.exportPayload(
            for: .single(target2), includeGroups: false, includePasswords: true)
        let payload2 = exported2.payload.sessions.first!
        #expect(payload2.jumpHost == "own-host")
        #expect(payload2.jumpPort == 2121)
        #expect(payload2.jumpUsername == "own-user")
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

/// Test double: like `InMemorySecretStore`, but `savePassword` throws for one
/// designated session id -- used to prove a single keychain failure during
/// `deleteLoginSet` is counted, not fatal (M10b Task 2).
private final class SelectiveFailingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    var failingSessionID: UUID?

    func savePassword(_ password: String, for sessionID: UUID) throws {
        if sessionID == failingSessionID {
            throw KeychainError(status: -1)
        }
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}

/// Test double: like `InMemorySecretStore`, but once `failNewIDs` is set,
/// `savePassword` throws for any id that doesn't already have a stored
/// entry -- used to simulate a keychain failure specifically while carrying
/// a secret onto a BRAND-NEW id (e.g. a freshly created login set), while
/// pre-existing secrets stay readable/writable normally (M10b B2 review).
private final class NewIDFailingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    var failNewIDs = false

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock()
        let alreadyExists = storage[sessionID] != nil
        lock.unlock()
        if failNewIDs && !alreadyExists {
            throw KeychainError(status: -1)
        }
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}

/// Test double proving the agent-bastion restore path (M11a Task 2) never
/// reads the keychain for the deleted session's own secret: `password(for:)`
/// fails the test if called at all. `savePassword`/`deletePassword` behave
/// like `InMemorySecretStore` so unrelated calls (e.g. writing another
/// session's own, non-agent secret) still work normally.
private final class NoReadAllowedSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        Issue.record("agent bastion restore must not read the keychain")
        return nil
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
