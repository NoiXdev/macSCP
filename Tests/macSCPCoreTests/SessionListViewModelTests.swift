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
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        return (vm, secrets, dir)
    }

    /// `makeVM` over a store whose reads can be made to fail after the merge
    /// candidates have been planned (M28/T2).
    private func makeLockableVM() -> (SessionListViewModel, LockableReadSecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        let secrets = LockableReadSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        return (vm, secrets, dir)
    }

    @Test func saveCreatesSessionAndStoresPassword() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "example.com", port: 22, username: "tim"),
            password: "geheim")
        #expect(stored != nil)
        #expect(vm.sessions.map(\.name) == ["web"])
        #expect(try secrets.password(for: stored!.id) == "geheim")
    }

    /// `save(tags:)` (P3a/T5): whatever the caller passes goes through
    /// `TagList.normalized` — trimmed, empties dropped, exact duplicates
    /// dropped, order kept.
    @Test func savingCarriesTagsOntoTheStoredSession() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = vm.save(
            name: "box",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "",
            tags: ["  docker ", "docker", "web"])
        #expect(saved?.tags == ["docker", "web"])
    }

    /// `save` matches an existing session by NAME and mutates it (see the
    /// big comment on `save` itself) — this pins that a second save under
    /// the same name REPLACES the tag set rather than merging into it.
    /// Without this test, "replaces" vs. "appends" would be an unobserved
    /// implementation choice.
    @Test func savingAgainUnderTheSameNameReplacesTheTags() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = vm.save(
            name: "box", values: sshValues(host: "h", port: 22, username: "u"),
            password: "", tags: ["web"])
        let again = vm.save(
            name: "box", values: sshValues(host: "h", port: 22, username: "u"),
            password: "", tags: ["docker"])
        #expect(again?.tags == ["docker"])
    }

    /// Omitting `tags:` entirely must not disturb an existing session's
    /// tags into something unexpected — the default is `[]`, and `save`
    /// unconditionally normalizes+assigns it, so a re-save that forgets to
    /// pass `tags:` clears them. This is the "replaces" contract holding for
    /// the parameter's own default, not a special case.
    @Test func omittingTagsOnASecondSaveClearsThem() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = vm.save(
            name: "box", values: sshValues(host: "h", port: 22, username: "u"),
            password: "", tags: ["docker"])
        let again = vm.save(
            name: "box", values: sshValues(host: "h", port: 22, username: "u"),
            password: "")
        #expect(again?.tags == [])
    }

    @Test func reloadSortsByNameCaseInsensitive() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.save(
            name: "zeta",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")
        vm.save(
            name: "Alpha",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")
        vm.save(
            name: "beta",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")
        #expect(vm.sessions.map(\.name) == ["Alpha", "beta", "zeta"])
    }

    @Test func deleteRemovesSessionAndSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "weg",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")!
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
            auditStore: auditStore, loginSetStore: LoginSetStore(directory: dir),
            keys: ManagedKeyStore(directory: dir))

        let stored = vm.save(
            name: "weg",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")!
        auditStore.append(AuditEvent(kind: .connected, detail: "connected to h as u"), for: stored.id)
        #expect(auditStore.events(for: stored.id).count == 1)

        vm.delete(stored)

        #expect(auditStore.events(for: stored.id).isEmpty)
    }

    @Test func passwordReadsSecret() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
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
        let first = vm.save(
            name: "web",
            values: sshValues(host: "alt.example.com", port: 22, username: "tim"),
            password: "p1")!
        let second = vm.save(
            name: "web",
            values: sshValues(host: "neu.example.com", port: 2222, username: "tim2"),
            password: "p2")!

        #expect(second.id == first.id)
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.ssh?.host == "neu.example.com")
        #expect(try secrets.password(for: first.id) == "p2")
    }

    /// M12/T7b: saving an S3 session goes through the same `save(...)`
    /// entry point as SSH, just with `kind` and S3's own field values (M23/T7)
    /// — the secret access key rides the existing `password:` slot (no
    /// separate S3 secret path) and must never land in the store file.
    @Test func saveWithS3KindPersistsConfigAndKeepsSecretInKeychainOnly() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: true)
        let stored = vm.save(
            name: "bucket",
            values: S3FieldSchema.values(from: s3),
            password: "SECRET",
            kind: .s3)

        #expect(stored != nil)
        #expect(stored?.kind == .s3)
        #expect(stored?.s3 == s3)
        #expect(vm.sessions.first?.kind == .s3)
        #expect(vm.sessions.first?.s3 == s3)
        #expect(try secrets.password(for: stored!.id) == "SECRET")

        let raw = try String(contentsOf: dir.appendingPathComponent("sessions-v2.json"), encoding: .utf8)
        #expect(!raw.contains("SECRET"))
    }

    /// Review fix (bug-fix round after Task 9): mirrors
    /// `saveWithS3KindPersistsConfigAndKeepsSecretInKeychainOnly` above for
    /// WebDAV. Before this fix, `save(...)` had no `webdav:` parameter at
    /// all, so `ContentView.startSession`'s "Save & connect" path could not
    /// carry a WebDAV session's `baseURL`/`useNextcloudPath` through --
    /// it silently fell back to `kind: .ssh, s3: nil`, producing a stored
    /// session that can never connect again. This proves the fixed `save()`
    /// persists `kind == .webdav` and a populated, secret-free
    /// `StoredWebDAVConfig`, with the password in the Keychain only.
    @Test func saveWithWebDAVKindPersistsConfigAndKeepsSecretInKeychainOnly() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let webdav = StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "dave", useNextcloudPath: true)
        let stored = vm.save(
            name: "dav-prod",
            values: WebDAVFieldSchema.values(from: webdav),
            password: "SECRET",
            kind: .webdav)

        #expect(stored != nil)
        #expect(stored?.kind == .webdav)
        #expect(stored?.webdav == webdav)
        #expect(vm.sessions.first?.kind == .webdav)
        #expect(vm.sessions.first?.webdav == webdav)
        #expect(try secrets.password(for: stored!.id) == "SECRET")

        let raw = try String(contentsOf: dir.appendingPathComponent("sessions-v2.json"), encoding: .utf8)
        #expect(!raw.contains("SECRET"))
    }

    /// The other half of the placeholder's death (M23/T7): the NEW-session save
    /// path. `ContentView`'s S3 and WebDAV branches passed the literal
    /// `host: "unused", port: 22, username: "unused"`, which made every non-SSH
    /// session share the import duplicate key `unused|22|unused` and left the
    /// audit trail reading "connected to unused as unused". `save` writes only
    /// the fields the backend owns now, so those two stay blank.
    @Test func saveWritesNoPlaceholderForABackendWithoutHostOrUserName() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let webdav = StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "dave", useNextcloudPath: false)

        let bucket = vm.save(
            name: "bucket", values: S3FieldSchema.values(from: s3),
            password: "SECRET", kind: .s3)
        let cloud = vm.save(
            name: "cloud", values: WebDAVFieldSchema.values(from: webdav),
            password: "SECRET", kind: .webdav)

        // `ssh == nil`, NOT `host == ""` (fix round 1): since M23/T8 the
        // conveniences return "" unconditionally for a block-less session, so
        // asserting on them would pass even if `save` wrote nothing at all.
        // The absence of the block is the claim that still bites.
        #expect(bucket?.ssh == nil)
        #expect(cloud?.ssh == nil)
        // WebDAV's own user name lives on its own block, never on SSH's.
        #expect(cloud?.webdav?.username == "dave")
        let raw = try String(contentsOf: dir.appendingPathComponent("sessions-v2.json"), encoding: .utf8)
        #expect(!raw.contains("unused"))
    }

    /// An agent login stores no session-level secret and its leftover manual
    /// slot is cleaned up — the rule that used to read `authKind == .agent` and
    /// now reads `descriptor.requiresSecret(values)` (M23/T7). The auth kind
    /// travels inside `values`, so this also pins that the descriptor sees it.
    @Test func saveWithAgentAuthDeletesTheSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = vm.save(
            name: "web", values: sshValues(host: "h", username: "u"), password: "typed")!
        #expect(try secrets.password(for: first.id) == "typed")

        let switched = vm.save(
            name: "web",
            values: sshValues(host: "h", username: "u", authKind: .agent),
            password: "typed")!

        #expect(switched.id == first.id)
        #expect(switched.ssh?.authKind == .agent)
        #expect(try secrets.password(for: switched.id) == nil)
    }

    /// `save` matches an EXISTING session by name, so a "Save & connect" whose
    /// name collides with a session of a DIFFERENT kind changes that session's
    /// protocol. Mutating rather than rebuilding is what carries group and
    /// login-set binding forward (M23/T6) — but it must not carry the previous
    /// backend's own block forward, or an `.ssh` session keeps a populated `s3`
    /// block (endpoint, bucket, access key id) that reaches the store file,
    /// the export codec and `SessionImportPlanner.duplicateKey`.
    @Test func savingOverAnExistingNameOfAnotherKindClearsTheOldBackendBlock() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: true)
        _ = vm.save(
            name: "shared", values: S3FieldSchema.values(from: s3),
            password: "SECRET", kind: .s3)

        let asSSH = vm.save(
            name: "shared",
            values: sshValues(host: "h.example.com", port: 2222, username: "tim"),
            password: "pw")!

        #expect(asSSH.kind == .ssh)
        #expect(asSSH.s3 == nil)
        #expect(asSSH.ssh?.host == "h.example.com")
        let raw = try String(contentsOf: dir.appendingPathComponent("sessions-v2.json"), encoding: .utf8)
        #expect(!raw.contains("backups"))
    }

    /// The same rule in the other direction: SSH's own fields are not a place
    /// for an S3 session to keep a stale key path, auth kind or port.
    @Test func savingOverAnSSHNameAsS3ClearsTheSSHOnlyFields() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = vm.save(
            name: "shared",
            values: sshValues(
                host: "h.example.com", port: 2222, username: "tim",
                authKind: .privateKey, keyPath: "/keys/id_ed25519"),
            password: "pw")

        let s3 = StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let asS3 = vm.save(
            name: "shared", values: S3FieldSchema.values(from: s3),
            password: "SECRET", kind: .s3)!

        #expect(asS3.kind == .s3)
        #expect(asS3.s3 == s3)
        // `ssh == nil`, not the five field-by-field assertions this used to
        // make (fix round 2). Those were not vacuous — the overwritten session
        // held real values, so a total failure to clear would have shown — but
        // they could not tell `ssh == nil` apart from
        // `ssh == StoredSSHConfig(host: "", username: "")`. That is exactly the
        // "placeholder resurrected as an empty block" outcome this milestone
        // exists to prevent, so the test passed against the one result it most
        // needed to catch.
        #expect(asS3.ssh == nil)
    }

    @Test func saveWithFailingSecretsStillReloadsFromDisk() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: FailingSecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")
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
        let stored = vm.save(
            name: "s",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            groupID: group.id)!
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
        let stored = vm.save(
            name: "s",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        vm.moveSession(stored, toGroup: group.id)
        #expect(vm.sessions(inGroup: group.id).map(\.name) == ["s"])
        #expect(vm.sessions(inGroup: nil).isEmpty)
    }

    // MARK: - Nesting and order (D1/D2, Task 2)

    /// The drag path end to end: two identities in, a persisted order out.
    @Test func draggingASessionOntoAFolderPersistsTheNewOrder() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = vm.createGroup(named: "Folder")!
        let loose = vm.save(
            name: "loose", values: sshValues(host: "h", username: "u"), password: "")!
        _ = vm.save(
            name: "inside", values: sshValues(host: "h", username: "u"), password: "",
            groupID: folder.id)

        #expect(vm.move(.session(loose.id), intoGroup: folder.id) == nil)

        #expect(vm.children(of: folder.id).map(\.id) == vm.sessions(inGroup: folder.id)
            .sorted { $0.position < $1.position }.map(\.id))
        #expect(vm.sessions.first { $0.id == loose.id }?.groupID == folder.id)
        #expect(vm.sessions.first { $0.id == loose.id }?.position == 1)
    }

    /// Nesting a folder under another one, and the refusal that guards it:
    /// the move that would make a folder its own ancestor changes nothing and
    /// SAYS so — both by what it returns and by what the user is told.
    @Test func aMoveThatWouldCloseACycleChangesNothingAndReportsIt() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = vm.createGroup(named: "Outer")!
        let inner = vm.createGroup(named: "Inner")!
        #expect(vm.move(.group(inner.id), intoGroup: outer.id) == nil)

        #expect(vm.move(.group(outer.id), intoGroup: inner.id) == .wouldCycle)

        #expect(vm.groups.first { $0.id == outer.id }?.parentID == nil)
        #expect(vm.groups.first { $0.id == inner.id }?.parentID == outer.id)
        #expect(vm.errorMessage != nil)
    }

    /// The one-shot sort, through the view model that owns the write.
    @Test func sortingAFoldersChildrenByNamePersists() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = vm.createGroup(named: "Folder")!
        for name in ["charlie", "alpha", "bravo"] {
            _ = vm.save(
                name: name, values: sshValues(host: "h", username: "u"), password: "",
                groupID: folder.id)
        }
        // Reversed by hand first, so the assertion below cannot pass on the
        // name order `reload()` already imposes on `sessions`.
        for session in vm.sessions(inGroup: folder.id).reversed() {
            _ = vm.move(.session(session.id), intoGroup: folder.id)
        }
        #expect(childNames(of: folder.id, in: vm) == ["charlie", "bravo", "alpha"])

        vm.sortChildrenByName(of: folder.id)

        #expect(childNames(of: folder.id, in: vm) == ["alpha", "bravo", "charlie"])
    }

    /// The names of a parent's children, in the order the sidebar reads them.
    private func childNames(of parentID: UUID?, in vm: SessionListViewModel) -> [String] {
        vm.children(of: parentID).map { item in
            switch item {
            case .group(let id): vm.groups.first { $0.id == id }?.name ?? "?"
            case .session(let id): vm.sessions.first { $0.id == id }?.name ?? "?"
            }
        }
    }

    /// Dissolving a nested folder through the view model keeps every session
    /// and every sub-folder, one level up.
    @Test func dissolvingANestedFolderKeepsItsMembersUnderTheParent() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = vm.createGroup(named: "Outer")!
        let middle = vm.createGroup(named: "Middle")!
        let inner = vm.createGroup(named: "Inner")!
        #expect(vm.move(.group(middle.id), intoGroup: outer.id) == nil)
        #expect(vm.move(.group(inner.id), intoGroup: middle.id) == nil)
        let held = vm.save(
            name: "held", values: sshValues(host: "h", username: "u"), password: "",
            groupID: middle.id)!

        vm.dissolveGroup(vm.groups.first { $0.id == middle.id }!)

        #expect(vm.groups.count == 2)
        #expect(vm.groups.first { $0.id == inner.id }?.parentID == outer.id)
        #expect(vm.sessions.first { $0.id == held.id }?.groupID == outer.id)
    }

    @Test func renameSessionTrimsAndRejectsEmpty() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "old",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        vm.renameSession(stored, to: "  new ")
        #expect(vm.sessions.first?.name == "new")
        vm.renameSession(vm.sessions.first!, to: "   ")
        #expect(vm.sessions.first?.name == "new")
    }

    /// P2 terminal-chrome milestone, Task 4: writes the toggled visibility
    /// into the STORED session, not just the caller's local copy — a second
    /// `sessions.first` lookup (not the `stored` value the test already
    /// holds) is what actually proves the write landed.
    @Test func updatePaneVisibilityPersistsToTheStoredSession() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "s",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        #expect(stored.paneVisibility == .filesOnly)

        vm.updatePaneVisibility(
            for: stored.id, to: PaneVisibility(showsFiles: false, showsTerminal: true))

        #expect(vm.sessions.first?.paneVisibility == PaneVisibility(showsFiles: false, showsTerminal: true))
    }

    /// A no-op, not a crash, when the id no longer names a stored session
    /// (e.g. deleted between the toggle click and this write).
    @Test func updatePaneVisibilityIsANoOpForAnUnknownID() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        vm.updatePaneVisibility(for: UUID(), to: PaneVisibility(showsFiles: false, showsTerminal: true))

        #expect(vm.sessions.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func updateSessionKeepsSecretWhenNewSecretIsNilOrEmpty() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "s",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "keep")!
        var updated = stored
        updated.ssh?.host = "h2"
        vm.updateSession(updated, newSecret: nil)
        #expect(vm.password(for: stored) == "keep")
        vm.updateSession(updated, newSecret: "")
        #expect(vm.password(for: stored) == "keep")
        vm.updateSession(updated, newSecret: "next")
        #expect(vm.password(for: stored) == "next")
        #expect(vm.sessions.first?.ssh?.host == "h2")
    }

    /// The premise the connection form's collision warning rests on: the
    /// two save paths do NOT do the same thing to a name that already
    /// exists. `save` upserts by name, so it replaces. `updateSession`
    /// upserts by id, so a rename onto a taken name replaces nothing and
    /// leaves the store holding two sessions of that name — which is why
    /// `SessionNameConflict` has a second case and a second sentence for
    /// the edit path.
    @Test func updateSessionUpsertsByIdSoARenameCanDuplicateAName() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let web = vm.save(
            name: "web", values: sshValues(host: "h", port: 22, username: "u"),
            password: "")!
        let other = vm.save(
            name: "other", values: sshValues(host: "h2", port: 22, username: "u"),
            password: "")!
        var renamed = other
        renamed.name = "web"
        vm.updateSession(renamed, newSecret: nil)

        #expect(vm.sessions.count == 2)
        #expect(vm.sessions.filter { $0.name == "web" }.count == 2)
        // And the session that was already called "web" is untouched: not
        // replaced, not merged, still its own id.
        #expect(vm.sessions.contains { $0.id == web.id && $0.ssh?.host == "h" })
    }

    @Test func exportPayloadScopesAndCountsMissingPasswords() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = vm.createGroup(named: "Prod")!
        _ = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "u"),
            password: "pw",
            groupID: group.id)!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "u"),
            password: "pw",
            groupID: group.id)!
        let c = vm.save(
            name: "c",
            values: sshValues(host: "h3", port: 22, username: "u"),
            password: "pw")!
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

    /// Does a bucket-list session's export actually CARRY the toggle?
    /// (Re-review 3, open item 2.)
    ///
    /// It was covered only indirectly: `s3ExportFields` gained the optional
    /// parameter, and the two planner tests that set it built
    /// `ExportedSession.fields` from that fixture directly — bypassing the
    /// codec. So the fixture proved what the fixture writes, and nothing
    /// proved what `exportPayload` + `SessionExportCodec.encode`/`decode`
    /// write. This starts from a SAVED session and goes through both.
    ///
    /// The `bucket` half is asserted beside it: a list-mode session stores
    /// no bucket (`S3FieldSchema.bucketToCarry`), so a file that carried one
    /// would re-import a session claiming both.
    @Test func aBucketListSessionExportsItsToggleThroughTheCodec() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        var values = BackendDescriptor.descriptor(for: .s3).defaultValues
        values[S3Field.endpoint] = "https://minio.example.com"
        values[S3Field.region] = "us-east-1"
        values[S3Field.accessKeyID] = "AKIA"
        // Typed BEFORE the toggle was flipped — the shape the save path is
        // supposed to drop, and the one a fixture-built bag never has.
        values[S3Field.bucket] = "photos"
        values[bool: S3Field.startsAtBucketList] = true
        _ = vm.save(name: "account", values: values, password: "sk", kind: .s3)

        let payload = vm.exportPayload(
            for: .all, includeGroups: false, includePasswords: false).payload
        let decoded = try SessionExportCodec.decode(
            SessionExportCodec.encode(payload, password: nil))

        let exported = try #require(decoded.sessions.first)
        let fields = FieldValues(raw: exported.fields)
        #expect(fields[bool: S3Field.startsAtBucketList])
        #expect(fields[S3Field.bucket].isEmpty)
    }

    /// The positive check beside it: a session pointed at ONE bucket
    /// exports the toggle too — as `false`, with its bucket intact. Without
    /// this, a codec that dropped the key entirely would still satisfy the
    /// test above (an absent key reads as `false`... only when the toggle is
    /// meant to be off).
    @Test func aSingleBucketSessionExportsTheToggleOffAndItsBucket() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        var values = BackendDescriptor.descriptor(for: .s3).defaultValues
        values[S3Field.endpoint] = "https://minio.example.com"
        values[S3Field.region] = "us-east-1"
        values[S3Field.accessKeyID] = "AKIA"
        values[S3Field.bucket] = "photos"
        _ = vm.save(name: "one-bucket", values: values, password: "sk", kind: .s3)

        let payload = vm.exportPayload(
            for: .all, includeGroups: false, includePasswords: false).payload
        let decoded = try SessionExportCodec.decode(
            SessionExportCodec.encode(payload, password: nil))

        let exported = try #require(decoded.sessions.first)
        // The KEY is present, not merely absent-and-therefore-false: that is
        // the half the test above cannot see.
        let key = "\(S3Field.namespace).\(S3Field.startsAtBucketList.rawValue)"
        #expect(exported.fields[key] == "false")
        #expect(FieldValues(raw: exported.fields)[S3Field.bucket] == "photos")
    }

    /// The export carries the TREE, not just which folder a session sits in:
    /// a nested folder's parent and everyone's rank travel with it. The
    /// ancestor travels too, even though no session sits in it directly —
    /// without it the child would arrive naming a folder the file never
    /// carried, and the import would lift it to the top level.
    @Test func exportPayloadCarriesNestingAndPositions() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = vm.createGroup(named: "Outer")!
        let inner = vm.createGroup(named: "Inner")!
        #expect(vm.move(.group(inner.id), intoGroup: outer.id) == nil)
        _ = vm.save(
            name: "b", values: sshValues(host: "h1", port: 22, username: "u"),
            password: "", groupID: inner.id)!
        _ = vm.save(
            name: "a", values: sshValues(host: "h2", port: 22, username: "u"),
            password: "", groupID: inner.id)!
        vm.sortChildrenByName(of: inner.id)

        let (payload, _) = vm.exportPayload(
            for: .all, includeGroups: true, includePasswords: false)

        let exportedOuter = try #require(payload.groups.first { $0.name == "Outer" })
        let exportedInner = try #require(payload.groups.first { $0.name == "Inner" })
        let storedInner = try #require(vm.groups.first { $0.id == inner.id })
        #expect(storedInner.parentID == outer.id)
        #expect(exportedInner.parentID == exportedOuter.id)
        #expect(exportedInner.position == storedInner.position)

        // Ranks come from the store, so the once-only sort the user just ran
        // is what the file records.
        let exportedA = try #require(payload.sessions.first { $0.name == "a" })
        let exportedB = try #require(payload.sessions.first { $0.name == "b" })
        #expect(exportedA.position == 0)
        #expect(exportedB.position == 1)
    }

    @Test func applyImportCreatesEverythingAdditively() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(
            name: "existing",
            values: sshValues(host: "other.example.com", port: 22, username: "u"),
            password: "keep")!

        let plan = SessionImportPlan(
            groupsToCreate: [StoredGroup(name: "Imported")],
            sessionsToImport: [
                PlannedSession(
                    session: sshSession(name: "one", host: "h1", username: "root"),
                    password: "secret1"),
                PlannedSession(
                    session: sshSession(name: "two", host: "h2", username: "root"),
                    password: nil),
            ],
            skipped: [
                ExportedSession(
                    id: UUID(), name: "dupe", kind: .ssh,
                    fields: sshExportFields(host: "h1", username: "root")),
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
        #expect(vm.sessions.first { $0.id == existing.id }?.ssh?.host == "other.example.com")
        #expect(try secrets.password(for: existing.id) == "keep")
    }

    /// M19 finding 1: a replace sourced from a secret-free export must not
    /// leave the OLD password bound to the reused id. Doing so makes a session
    /// the user just replaced connect with a credential that appears neither
    /// in the imported file nor anywhere on screen.
    @Test func replacingWithoutASecretRemovesTheStaleOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "old.example.com", port: 22, username: "u"),
            password: "old-pw")!

        let replacement = sshSession(
            id: existing.id, name: "web", host: "new.example.com", username: "u2")
        let result = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(session: replacement, password: nil, replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(result.secretsRemoved == 1)
        #expect(result.imported == 1)
        #expect(try secrets.password(for: existing.id) == nil)
        #expect(vm.sessions.first { $0.id == existing.id }?.ssh?.host == "new.example.com")
    }

    /// M19/T8 review (leftover 4): the login-set twin (`applyLoginSetImport`)
    /// treats an EMPTY string the same as no secret at all (`!secret.isEmpty`
    /// guards its save branch); this applier did not, so a file carrying
    /// `"password": ""` on a replace took the SAVE branch instead of the
    /// removal one — writing an empty Keychain entry and counting a
    /// `passwordsImported` for a "password" that is not one, instead of
    /// removing the stale credential the way `nil` does two tests up.
    @Test func replacingWithAnEmptyPasswordRemovesTheStaleOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "old.example.com", port: 22, username: "u"),
            password: "old-pw")!

        let replacement = sshSession(
            id: existing.id, name: "web", host: "new.example.com", username: "u2")
        let result = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(session: replacement, password: "", replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(result.secretsRemoved == 1)
        #expect(result.passwordsImported == 0)
        #expect(try secrets.password(for: existing.id) == nil)
        #expect(vm.sessions.first { $0.id == existing.id }?.ssh?.host == "new.example.com")
    }

    /// A replace that DOES carry a secret simply overwrites, and reports no
    /// removal — the user loses nothing and is told nothing alarming.
    @Test func replacingWithASecretOverwritesIt() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "old.example.com", port: 22, username: "u"),
            password: "old-pw")!

        let replacement = sshSession(
            id: existing.id, name: "web", host: "new.example.com", username: "u2")
        let result = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(session: replacement, password: "new-pw", replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(result.secretsRemoved == 0)
        #expect(result.passwordsImported == 1)
        #expect(try secrets.password(for: existing.id) == "new-pw")
    }

    /// M19 review (important 1): the stale-secret probe used `try?`, so a
    /// Keychain that is there but not ANSWERING — locked, prompt denied,
    /// `errSecInteractionNotAllowed` — read as "there is no secret", and the
    /// replace left the old password bound to the reused id with nothing said
    /// to the user. That is the very state finding 1 exists to eliminate, and
    /// it re-flattened the distinction `hasStoredPassphrase` had just drawn
    /// 250 lines away. The delete is idempotent, so it no longer depends on
    /// what the probe could establish.
    @Test func aReplaceRemovesTheStaleSecretEvenWhenTheKeychainCannotBeRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsReads: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "old.example.com", port: 22, username: "u"),
            password: "old-pw")!
        #expect(secrets.peek(existing.id) == "old-pw")

        let result = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(
                    session: sshSession(
                        id: existing.id, name: "web", host: "new.example.com", username: "u2"),
                    password: nil, replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(secrets.peek(existing.id) == nil)
        // Nothing is CLAIMED: the probe could not establish that a secret was
        // there, and the summary never reports a removal it cannot prove.
        #expect(result.secretsRemoved == 0)
    }

    /// …and when the DELETE itself fails, the old credential really can
    /// survive the replace. That is the one case the user has to hear about.
    @Test func aRemovalThatFailsIsReported() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsDeletes: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "old.example.com", port: 22, username: "u"),
            password: "old-pw")!

        let result = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(
                    session: sshSession(
                        id: existing.id, name: "web", host: "new.example.com", username: "u2"),
                    password: nil, replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(result.secretRemovalFailures == 1)
        #expect(result.secretsRemoved == 0)
        #expect(secrets.peek(existing.id) == "old-pw")
    }

    /// A fresh (non-replacing) import that carries no password must not delete
    /// anything.
    ///
    /// The obvious version of this — a fresh session plus an unrelated stored
    /// password — is VACUOUS: the imported session's brand-new UUID addresses
    /// nothing under its own id either way, so dropping the applier's
    /// `replacesExisting` guard leaves it green. The fresh session therefore
    /// carries an id that DOES have a slot (the leftover state a re-import
    /// after a delete produces), which is the only arrangement where the guard
    /// is load-bearing. Same construction as the login-set twin
    /// `aFreshImportWithoutASecretRemovesNothing`.
    @Test func aFreshImportWithoutAPasswordRemovesNothing() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = vm.save(
            name: "keep",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "kept")!
        let fresh = sshSession(name: "new", host: "h2", username: "u")
        try secrets.savePassword("orphaned-but-not-ours-to-delete", for: fresh.id)

        let result = vm.applyImport(SessionImportPlan(sessionsToImport: [
            PlannedSession(session: fresh, password: nil),
        ]))

        #expect(result.secretsRemoved == 0)
        #expect(result.secretRemovalFailures == 0)
        #expect(try secrets.password(for: fresh.id) == "orphaned-but-not-ours-to-delete")
        #expect(try secrets.password(for: existing.id) == "kept")
    }

    /// The planner mints a FRESH `secretID` for every imported jump, so a
    /// replaced record's old jump slot is unreachable afterwards — it must not
    /// stay in the Keychain forever.
    @Test func replacingCleansUpTheOldJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldJump = StoredSession.JumpSpec(
            host: "bastion", port: 22, username: "j", authKind: .password)
        let existing = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: oldJump,
            jumpSecret: "jump-pw")!
        let storedJumpID = try #require(vm.sessions.first { $0.id == existing.id }?.jump?.secretID)
        #expect(try secrets.password(for: storedJumpID) == "jump-pw")

        let replacement = sshSession(
            id: existing.id, name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(
                host: "bastion", port: 22, username: "j", authKind: .password))
        _ = vm.applyImport(SessionImportPlan(
            sessionsToImport: [
                PlannedSession(
                    session: replacement, password: "pw", jumpPassword: "new-jump-pw",
                    replacesExisting: true),
            ],
            replaced: ["web"]))

        #expect(try secrets.password(for: storedJumpID) == nil)
    }

    /// `plan.cancelled` must be authoritative on its own, not merely inferred
    /// from the other arrays being empty (which is all a real planner ever
    /// produces): a plan that intentionally carries non-empty content
    /// alongside `cancelled: true` still must apply and report nothing.
    @Test func applyImportIgnoresEverythingWhenPlanIsCancelled() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Hold on to the ghost session's own id — asserting against a fresh
        // random UUID would pass even if the password HAD been written.
        let ghost = sshSession(name: "ghost", host: "h1", username: "root")
        let plan = SessionImportPlan(
            groupsToCreate: [StoredGroup(name: "Ghost")],
            sessionsToImport: [PlannedSession(session: ghost, password: "pw")],
            cancelled: true)

        let result = vm.applyImport(plan)

        #expect(result == SessionListViewModel.SessionImportResult(
            imported: 0, skipped: 0, passwordsImported: 0, passwordFailures: 0,
            storeFailures: 0))
        #expect(vm.sessions.isEmpty)
        #expect(vm.groups.isEmpty)
        #expect(try secrets.password(for: ghost.id) == nil)
    }

    @Test func applyImportSurvivesKeychainFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: FailingSecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let plan = SessionImportPlan(
            groupsToCreate: [],
            sessionsToImport: [
                PlannedSession(
                    session: sshSession(name: "one", host: "h1", username: "root"),
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
        // The SESSION store is the only one meant to be broken here, so the
        // other three get a directory of their own — pointing them at `dir`
        // would break them too and make the assertions below ambiguous about
        // which store refused.
        let otherStores = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-aux-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherStores)
        }
        // `dir` is a plain file, not a directory: SessionStore.persist()'s
        // createDirectory(at:) throws, simulating an unwritable store while
        // load() (called first, and tolerant of a missing path) still
        // succeeds with an empty store.
        try Data("blocked".utf8).write(to: dir)

        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: otherStores),
            loginSetStore: LoginSetStore(directory: otherStores),
            keys: ManagedKeyStore(directory: otherStores))

        let planned = PlannedSession(
            session: sshSession(name: "one", host: "h1", username: "root"),
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

    /// `reload()` reports an unreadable SESSION store — and swallowed an
    /// unreadable LOGIN-SET store three lines below it. The two stores are
    /// separate files, so `logins.json` can be unreadable while
    /// `sessions.json` is perfectly fine: the sets then vanish from the
    /// sheet as "No login sets yet", a state indistinguishable from a store
    /// that legitimately holds none, while every set-bound session shows its
    /// login as missing. Nothing else in the app reports it, because nothing
    /// else reads that store on the way in.
    @Test func unreadableLoginSetStoreIsReportedInsteadOfLookingEmpty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Only the login-set store is broken — a real store on real corrupt
        // JSON, the same shape the trust stores are tested with.
        try "not valid json".write(to: dir.appendingPathComponent("logins.json"),
                                   atomically: true, encoding: .utf8)

        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        // The sessions themselves are readable, so that half stays quiet.
        #expect(vm.sessions.isEmpty)
        #expect(vm.loginSets.isEmpty)
        let message = try #require(vm.errorMessage)
        #expect(message.contains("login"))
    }

    /// The other half of the same `reload()`: when BOTH stores fail, neither
    /// message may swallow the other. Reporting only one would leave the
    /// user fixing half a problem.
    @Test func bothStoreFailuresAreReportedTogether() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not valid json".write(to: dir.appendingPathComponent("sessions-v2.json"),
                                   atomically: true, encoding: .utf8)
        try "not valid json".write(to: dir.appendingPathComponent("logins.json"),
                                   atomically: true, encoding: .utf8)

        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let message = try #require(vm.errorMessage)
        #expect(message.contains("session"))
        #expect(message.contains("login"))
    }

    // MARK: - Login sets (M10b)

    @Test func saveWithLoginSetSkipsSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")
        #expect(vm.loginSets.map(\.id) == [set.id])

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "should-not-be-stored",
            loginSetID: set.id)!

        #expect(stored.loginSetID == set.id)
        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func deleteLoginSetRestoresSessions() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Deploy Key", username: "deploy", authKind: .privateKey, keyPath: "/k")
        vm.saveLoginSet(set, secret: "pp")

        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!
        #expect(vm.usageCount(of: set.id) == 2)
        #expect(Set(vm.sessionsUsing(setID: set.id).map(\.id)) == Set([a.id, b.id]))

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 2, secretFailures: 0))
        for session in [a, b] {
            let restored = vm.sessions.first { $0.id == session.id }!
            #expect(restored.loginSetID == nil)
            #expect(restored.ssh?.username == "deploy")
            #expect(restored.ssh?.authKind == .privateKey)
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
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!
        secrets.failingSessionID = b.id

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 2, secretFailures: 1))
        // Both sessions are restored (values + nil reference) regardless of
        // the keychain failure -- only the secret copy for `b` is missing.
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == a.id }?.ssh?.username == "root")
        #expect(vm.sessions.first { $0.id == b.id }?.ssh?.username == "root")
    }

    /// M28 final review (I-1): `deleteLoginSet` decides a deletion from the
    /// set's own Keychain read, and a swallowed read makes a locked Keychain
    /// look exactly like a set with nothing to hand back -- every referencing
    /// session is restored WITHOUT its secret, and the set's slot, the only
    /// copy for a session bound by `applyMerge`, is then deleted. The read
    /// therefore throws and nothing changes on a failure, the same rule
    /// `applyMerge` already follows for its carry.
    @Test func deleteLoginSetChangesNothingWhenTheSetsSecretCannotBeRead() throws {
        let (vm, secrets, dir) = makeLockableVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Deploy", username: "deploy")
        vm.saveLoginSet(set, secret: "s3cr3t")
        let bound = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!
        // The set's slot is the only copy of this session's credential --
        // the state `applyMerge` leaves behind.
        #expect(secrets.storedIDs == [set.id])

        secrets.failReads(for: [set.id])
        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 0, secretFailures: 0))
        #expect(vm.loginSets.map(\.id) == [set.id])
        #expect(vm.sessions.first { $0.id == bound.id }?.loginSetID == set.id)
        #expect(secrets.storedIDs == [set.id])
        #expect(vm.errorMessage != nil)
    }

    @Test func applyMergeAbortsAndRewiresNothingWhenCarryingSecretToSetFails() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = NewIDFailingSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "root"),
            password: "a")!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "root"),
            password: "a")!
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
        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "irrelevant")!
        _ = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "passphrase")!
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
        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "root"),
            password: "a")!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "root"),
            password: "a")!

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

    // MARK: - applyMerge tells "unreadable" apart from "empty" (M28/T2)

    /// The merge carries one member's secret onto the new set and then deletes
    /// every member's own slot. A read that FAILS has to abort that: with the
    /// read swallowed, a Keychain that will not answer is indistinguishable
    /// from a group of empty slots, so nothing is carried, the rollback that
    /// exists for a failed carry never fires, and the loop takes the only copy
    /// each member has.
    ///
    /// The store answers while `mergeCandidates()` plans and stops answering
    /// afterwards, which is the real timeline: `LoginMergePlanner.candidates`
    /// reads first, a confirmation dialog sits in between, and `applyMerge`
    /// reads again.
    @Test func anUnreadableMemberSecretRollsTheMergeBackAndDeletesNothing() throws {
        let (vm, secrets, dir) = makeLockableVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(
            name: "a", values: sshValues(host: "h1", port: 22, username: "root"),
            password: "shared")!
        let b = vm.save(
            name: "b", values: sshValues(host: "h2", port: 22, username: "root"),
            password: "shared")!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!

        secrets.failReads(for: [a.id, b.id])
        let result = vm.applyMerge(candidate, name: "root")

        #expect(result == nil)
        #expect(vm.errorMessage != nil)
        // The rollback deleted the set it had just created, and no session was
        // rewired onto it.
        #expect(vm.loginSets.isEmpty)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        // The point of the test: both members still hold their own secret, and
        // the store holds nothing else -- no slot under a set id either.
        // Checked over the ids the store actually has rather than by looking up
        // the two ids the test expects, so a slot under any third id would fail
        // this too. No secret VALUE takes part in the comparison, so no failure
        // message can print one.
        #expect(secrets.storedIDs == Set([a.id, b.id]))
    }

    /// One member unreadable while the OTHER answers -- a denied prompt for a
    /// single item, not a locked keychain. The distinction is what this test
    /// adds: with the read back on `try?` the search skips the member it could
    /// not read, carries the readable member's secret, and lets the loop delete
    /// the unreadable one's -- a secret this process never managed to look at.
    /// A store that fails EVERY read cannot show that, because then there is
    /// nothing to carry from anywhere.
    @Test func oneUnreadableMemberAbortsTheMergeEvenWhenAnotherMemberAnswers() throws {
        let (vm, secrets, dir) = makeLockableVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(
            name: "a", values: sshValues(host: "h1", port: 22, username: "root"),
            password: "shared")!
        let b = vm.save(
            name: "b", values: sshValues(host: "h2", port: 22, username: "root"),
            password: "shared")!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!

        // Which member is unreadable, not where it sits: the search reads every
        // member and has no early exit, so `a`'s read throws whether it is met
        // first or last. Both members hold the same secret here, which keeps
        // this about the failing read rather than about a disagreement.
        secrets.failReads(for: [a.id])
        let result = vm.applyMerge(candidate, name: "root")

        #expect(result == nil)
        #expect(vm.errorMessage != nil)
        #expect(vm.loginSets.isEmpty)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        #expect(secrets.storedIDs == Set([a.id, b.id]))
    }

    /// No keychain failure at all, and the merge still used to take a real
    /// secret: `save` stores an empty passphrase for an unencrypted private key
    /// as a slot that EXISTS, and `LoginMergePlanner` groups private-key
    /// sessions without comparing passphrases, so the empty member can come
    /// first. Selecting it carried "" onto the set and then deleted the other
    /// member's real passphrase -- the group's only copy of it.
    @Test func anEmptyMemberSlotNeverWinsTheMergeCarryOverARealSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realPassphrase = "real"
        let a = vm.save(
            name: "a",
            values: sshValues(
                host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "")!
        let b = vm.save(
            name: "b",
            values: sshValues(
                host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: realPassphrase)!
        // Both slots exist; `a`'s is the empty one, and `a` comes first.
        #expect(secrets.storedIDs == Set([a.id, b.id]))

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!
        #expect(candidate.sessionIDs.first == a.id)

        let set = vm.applyMerge(candidate, name: "root")

        #expect(set != nil)
        // Where the real passphrase still lives, searched over every id the
        // store holds rather than looked up under the one id expected -- so a
        // failure reads as "gone from the store entirely" (empty set) instead
        // of a flag, and "it survived under some other id" cannot pass either.
        // Only ids take part in the comparison, so no failure message can print
        // the secret.
        let idsHoldingTheRealPassphrase = secrets.storedIDs.filter {
            secrets.peek($0) == realPassphrase
        }
        #expect(idsHoldingTheRealPassphrase == Set([set!.id]))
        // And both members' own slots are gone.
        #expect(secrets.storedIDs == Set([set!.id]))
    }

    /// The all-empty group: every member's slot exists and holds "". There is
    /// no secret to carry, so the set gets no slot at all -- and nothing is
    /// lost, because "" is what every member had.
    @Test func memberSlotsHoldingOnlyTheEmptyStringLetTheMergeCarryNothing() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(
            name: "a",
            values: sshValues(
                host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "")!
        let b = vm.save(
            name: "b",
            values: sshValues(
                host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "")!
        #expect(secrets.storedIDs == Set([a.id, b.id]))

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)

        let set = vm.applyMerge(candidates.first!, name: "root")

        #expect(set != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == set?.id)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == set?.id)
        #expect(secrets.storedIDs.isEmpty)
    }

    /// Members holding DIFFERENT non-empty secrets. A login set is one
    /// credential, so a set built from these could have served at most one of
    /// them -- and the merge got there by writing the first onto the set and
    /// deleting the second, which existed nowhere else. Refusing takes nothing
    /// away: it declines a merge that could not have worked. Reachable through
    /// the planner because a `.passphrase`-role secret is never read there and
    /// so never enters the grouping key, unlike a `.password` group, whose
    /// members must already share a secret value to be grouped at all.
    @Test func membersWithDifferentPassphrasesAbortTheMergeAndKeepBothSecrets() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let passphraseA = "first"
        let passphraseB = "second"
        let a = vm.save(
            name: "a",
            values: sshValues(
                host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: passphraseA)!
        let b = vm.save(
            name: "b",
            values: sshValues(
                host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: passphraseB)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)

        let result = vm.applyMerge(candidates.first!, name: "root")

        #expect(result == nil)
        #expect(vm.errorMessage != nil)
        #expect(vm.loginSets.isEmpty)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        // Both secrets survive, each still under its own member's id and
        // nowhere else. Searched over every id the store holds, so a failure
        // reads as "gone" (an empty set) rather than as a flag, and only ids
        // take part in the comparison.
        let idsHoldingTheFirst = secrets.storedIDs.filter { secrets.peek($0) == passphraseA }
        let idsHoldingTheSecond = secrets.storedIDs.filter { secrets.peek($0) == passphraseB }
        #expect(idsHoldingTheFirst == Set([a.id]))
        #expect(idsHoldingTheSecond == Set([b.id]))
        #expect(secrets.storedIDs == Set([a.id, b.id]))
        // The reported reason may not quote what it compared. Reduced to a
        // Bool first so the message itself never reaches a failure report.
        let messageQuotesASecret = (vm.errorMessage ?? "").contains(passphraseA)
            || (vm.errorMessage ?? "").contains(passphraseB)
        #expect(!messageQuotesASecret)
        // Not asserted here: the localized TEXT. `CoreL10n.string` resolves
        // against the host's preferred language -- for the long-standing
        // `core.login.mergeFailed %@` just as much as for the new reason key
        // -- so a fixed expected text would pin the test environment, passing
        // on a German Mac and failing in an English CI. That all four Core
        // catalogs carry the same key set is what `LocalizableStringsTests`
        // checks, off disk.
    }

    /// The counterpart that must stay green: members that agree still merge.
    @Test func membersSharingOnePassphraseStillMerge() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let passphrase = "shared"
        let a = vm.save(
            name: "a",
            values: sshValues(
                host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: passphrase)!
        let b = vm.save(
            name: "b",
            values: sshValues(
                host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: passphrase)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)

        let set = vm.applyMerge(candidates.first!, name: "root")

        #expect(set != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == set?.id)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == set?.id)
        let idsHoldingThePassphrase = secrets.storedIDs.filter { secrets.peek($0) == passphrase }
        #expect(idsHoldingThePassphrase == Set([set!.id]))
        #expect(secrets.storedIDs == Set([set!.id]))
    }

    /// A group with no stored secret at all -- no slot, as opposed to a slot
    /// holding "" -- is not the failure case: there is nothing to carry and
    /// nothing to lose, so the merge goes through and deleting the absent slots
    /// is a no-op. Private-key sessions make this
    /// reachable through the planner at all -- `LoginMergePlanner.candidates`
    /// skips the Keychain for a `.passphrase`-role secret field, which is what
    /// `SSHFieldSchema` declares its passphrase to be, so two members with no
    /// stored passphrase still form a candidate. Under `.password` the same
    /// planner drops a secret-less session instead.
    @Test func genuinelyEmptyMemberSlotsStillMerge() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = vm.save(
            name: "a",
            values: sshValues(
                host: "h1", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "")!
        let b = vm.save(
            name: "b",
            values: sshValues(
                host: "h2", port: 22, username: "root", authKind: .privateKey, keyPath: "/k"),
            password: "")!
        // `save` stores the empty passphrase of an unencrypted key, which is a
        // slot that EXISTS. Removing both is what makes the group have no
        // stored secret at all, which is the case under test.
        try secrets.deletePassword(for: a.id)
        try secrets.deletePassword(for: b.id)
        #expect(secrets.storedIDs.isEmpty)

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)

        let set = vm.applyMerge(candidates.first!, name: "root")

        #expect(set != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == set?.id)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == set?.id)
        // Nothing was there to carry, so nothing is stored -- not under the
        // set's id either.
        #expect(secrets.storedIDs.isEmpty)
    }

    /// The carry itself is unchanged by the throwing reads: one member's secret
    /// lands on the set and both members' own slots go.
    @Test func aReadableMemberSecretIsCarriedByTheMergeAndTheOwnSlotsGo() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memberSecret = "shared"
        let a = vm.save(
            name: "a", values: sshValues(host: "h1", port: 22, username: "root"),
            password: memberSecret)!
        let b = vm.save(
            name: "b", values: sshValues(host: "h2", port: 22, username: "root"),
            password: memberSecret)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)

        let set = vm.applyMerge(candidates.first!, name: "root")

        #expect(set != nil)
        // Compared through a Bool so a failure prints `false` instead of the
        // secret the comparison looked at.
        let carriedTheMemberSecret = try secrets.password(for: set!.id) == memberSecret
        #expect(carriedTheMemberSecret)
        // Exactly one slot is left and it is the set's -- both members' own
        // slots are gone.
        #expect(secrets.storedIDs == Set([set!.id]))
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == set!.id)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == set!.id)
    }

    @Test func suggestedSetNameAvoidsCollision() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(vm.suggestedSetName(forLabel: "root") == "root")

        vm.saveLoginSet(LoginSet(name: "root", username: "root"), secret: nil)
        vm.saveLoginSet(LoginSet(name: "root (2)", username: "root"), secret: nil)

        #expect(vm.suggestedSetName(forLabel: "root") == "root (3)")
    }

    @Test func ignoreMergePersists() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "root"),
            password: "a")!
        _ = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "root"),
            password: "a")!

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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!

        // The set's user name has to land in the BAG now that the flat
        // `username` column is gone -- login sets are never exported, so a
        // reference that is not resolved into values here is lost.
        let withSecret = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        #expect(withSecret.payload.sessions.first?.fields["SSHField.username"] == "deploy")
        #expect(withSecret.payload.sessions.first?.password == "s")
        #expect(withSecret.missingPasswordCount == 0)

        try secrets.deletePassword(for: set.id)
        let withoutSecret = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        #expect(withoutSecret.payload.sessions.first?.fields["SSHField.username"] == "deploy")
        #expect(withoutSecret.payload.sessions.first?.password == nil)
        #expect(withoutSecret.missingPasswordCount == 1)
    }

    @Test func resolvedLoginMissingSetThrows() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: UUID())!

        #expect(throws: LoginResolveError.missingSet) {
            try vm.resolvedCredentials(for: stored)
        }
    }

    // MARK: - Jump host (M10c)

    @Test func saveCleansOrphanedJumpSlotWhenJumpRemoved() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first { $0.id == stored.id }?.jump == nil)
    }

    @Test func saveCleansOrphanedJumpSlotWhenSwitchingToSetMode() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "s")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    // MARK: - Switching a jump to a login set (M28/T3)

    /// The defect this task closes: switching a jump from manual to a login
    /// set dropped the old bastion slot on the strength of the new MODE alone.
    /// Nothing carries that value -- `save` writes `jumpSecret` only for a
    /// manual jump -- so the slot is the only copy, and a set holding no
    /// secret leaves the jump unable to authenticate with nothing to go back
    /// to. Secretless sets are ordinary: the login-set export leaves secrets
    /// out by default.
    @Test func switchingAJumpToASetWithoutASecretKeepsTheBastionSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: nil)
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) != nil)
        // The binding itself still went through -- only the cleanup was
        // skipped.
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// The positive twin, stated from the guard's side: the set holds its
    /// secret, so the old slot is genuinely redundant and goes.
    /// `saveCleansOrphanedJumpSlotWhenSwitchingToSetMode` above covers the
    /// same switch from M10c's side and predates the coverage question.
    @Test func switchingAJumpToASetThatHoldsItsSecretDropsTheOldSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "s")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// An agent set needs no secret at all, so it covers its login while
    /// holding nothing -- the M10d rule, and the reason the guard asks
    /// `setCoversItsLogin` rather than "is a secret stored".
    @Test func switchingAJumpToAnAgentSetDropsTheOldSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper", authKind: .agent)
        vm.saveLoginSet(set, secret: nil)
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// A Keychain that will not answer is not a set holding nothing. The set
    /// below DOES hold its secret, so the deletion would even be correct --
    /// and the guard still refuses, because it could not establish that.
    @Test func switchingAJumpWhileTheKeychainIsSilentKeepsTheBastionSlot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsReads: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "s")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) != nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// `setCoversItsLogin` answers `true` for a private-key set without
    /// reading anything, because the passphrase field is visible but not
    /// required -- right for an unencrypted key, not enough for a DELETION:
    /// an encrypted key whose passphrase is stored nowhere leaves the jump
    /// unable to authenticate, and nothing at this site can tell the two
    /// apart. See `jumpSetDemonstrablyCoversItsLogin` for why a managed key's
    /// own slot cannot close that gap either.
    @Test func switchingAJumpToAPrivateKeySetWithoutAPassphraseKeepsTheBastionSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "Bastion", username: "jumper", authKind: .privateKey, keyPath: "/k")
        vm.saveLoginSet(set, secret: nil)
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) != nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// …and the positive twin: a private-key set whose own slot holds the
    /// passphrase is the one thing that CAN be established here -- that slot
    /// is exactly what `LoginResolver.resolveJump` reads for a set-bound jump.
    @Test func switchingAJumpToAPrivateKeySetHoldingItsPassphraseDropsTheOldSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "Bastion", username: "jumper", authKind: .privateKey, keyPath: "/k")
        vm.saveLoginSet(set, secret: "pp")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// A session-mode jump never reads its `loginSetID` -- it survives as an
    /// inert data carrier once `sessionID` is set (the same F-1 rule
    /// `sessionsUsing(setID:)` applies). So the coverage question must not
    /// fire for one: the referenced session owns the login, and the old manual
    /// slot is orphaned exactly as
    /// `saveJumpSwitchingManualToSessionDeletesJumpSecretSlot` has it. The set below holds nothing, which is what
    /// makes this fail if the guard forgets to check `sessionID`.
    @Test func switchingAJumpToSessionModeDropsTheOldSlotDespiteAStaleSetID() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: nil)
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "bastion.example.com", port: 22, username: "jumper"),
            password: "bp")!
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let sessionJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused",
            loginSetID: set.id, secretID: jump.secretID, sessionID: bastion.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: sessionJump)

        #expect(secrets.peek(jump.secretID) == nil)
        #expect(vm.sessions.first(where: { $0.name == "web" })?.jump?.sessionID == bastion.id)
    }

    /// The coverage question asks whether the SET needs a secret and holds
    /// one. It says nothing about whether the set can serve a JUMP at all,
    /// and a WebDAV set slips through both arms: its password field is
    /// declared without `isRequired` (`WebDAVFieldSchema.credentialSchema`,
    /// the M23 decision that keeps anonymous shares connectable), so
    /// `setCoversItsLogin` answers `true` without reading anything, and
    /// `authKind` is `.password` (`WebDAVFieldSchema.loginSet` builds every
    /// set that way), so the private-key arm never fires either. Deleting on
    /// that answer destroys the only copy of the bastion password.
    @Test func switchingAJumpToAWebDAVSetKeepsTheBastionSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Share", username: "dav", kind: .webdav)
        vm.saveLoginSet(set, secret: nil)
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) != nil)
        // The binding itself still went through -- only the cleanup was
        // skipped, exactly as for a secretless SSH set.
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    /// The same gap in its other shape: an S3 set that HOLDS its secret is
    /// covered on both arms, so the old slot went. What the jump would then
    /// authenticate with is a secret access key -- `LoginResolver.resolveJump`
    /// hands a set-bound jump to `sshLogin(from:)`, which reads the set's
    /// Keychain slot whatever `kind` says. Applicability, not coverage, is
    /// what refuses this.
    @Test func switchingAJumpToAnS3SetHoldingItsSecretKeepsTheBastionSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "Bucket", username: "", kind: .s3, accessKeyID: "AKIAEXAMPLE")
        vm.saveLoginSet(set, secret: "sak")
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(secrets.peek(jump.secretID) != nil)

        let setJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: setJump)

        #expect(secrets.peek(jump.secretID) != nil)
        #expect(vm.sessions.first?.jump?.loginSetID == set.id)
    }

    @Test func deleteSessionCleansJumpSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!
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
        #expect(restored.ssh?.username == "u")
        #expect(vm.loginSets.isEmpty)
    }

    @Test func deleteLoginSetRestoresBothReferences() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Shared", username: "shared")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id,
            jump: jump)!
        #expect(vm.usageCount(of: set.id) == 1) // counted once despite two references

        let result = vm.deleteLoginSet(set)

        // A session referencing the set on BOTH the target and the jump is
        // still restored exactly once.
        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.ssh?.username == "shared")
        #expect(restored.jump?.loginSetID == nil)
        #expect(restored.jump?.username == "shared")
        #expect(try secrets.password(for: stored.id) == "s3cr3t")
        #expect(try secrets.password(for: restored.jump!.secretID) == "s3cr3t")
    }

    /// F-1 fix (final review): a session-mode jump (`jump.sessionID` non-nil)
    /// must never be treated as a login-set reference, even if a stale
    /// `loginSetID` happens to sit alongside it -- an inert leftover from a
    /// switch to session mode (`ConnectionViewModel.buildJumpSpec` now nils
    /// it when building a fresh spec, but this proves the Core-side
    /// belt-and-suspenders guards independently, for a JumpSpec constructed
    /// with both fields set directly). Without the guards this session would
    /// inflate `sessionsUsing(setID:)`'s usage count and `deleteLoginSet`
    /// would write the set's secret into the jump's otherwise-unused
    /// `secretID` slot.
    @Test func deleteLoginSetIgnoresDanglingLoginSetIDOnSessionModeJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "pp")
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "bastion.example.com", port: 22, username: "jumper"),
            password: "pp")!

        let jump = StoredSession.JumpSpec(
            host: "unused", username: "unused", loginSetID: set.id, sessionID: bastion.id)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

        #expect(vm.sessionsUsing(setID: set.id).map(\.id) == [])
        #expect(vm.usageCount(of: set.id) == 0)

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 0, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        // Untouched: still session mode, still carrying the (never acted
        // upon) stale loginSetID -- nothing was "restored" because this jump
        // was never actually using the set.
        #expect(restored.jump?.sessionID == bastion.id)
        #expect(restored.jump?.loginSetID == set.id)
        #expect(try secrets.password(for: restored.jump!.secretID) == nil)
    }

    @Test func exportResolvesJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Bastion", username: "jumper")
        vm.saveLoginSet(set, secret: "jp")
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2222, username: "unused", loginSetID: set.id)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

        let withJump = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)
        let exportedJump = withJump.payload.sessions.first!
        #expect(exportedJump.jumpHost == "bastion.example.com")
        #expect(exportedJump.jumpPort == 2222)
        #expect(exportedJump.jumpUsername == "jumper")
        #expect(exportedJump.jumpAuthKind == .password)
        #expect(exportedJump.jumpPassword == "jp")
        #expect(withJump.missingPasswordCount == 0)

        let noJump = vm.save(
            name: "plain",
            values: sshValues(host: "h2", port: 22, username: "u"),
            password: "pw")!
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
                    session: sshSession(name: "one", host: "h1", username: "root", jump: jump),
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

    // MARK: - Connection kind + S3 (M12)

    /// End-to-end: an `.s3` session (built directly via the store, since the
    /// VM's `save()` API is still SSH-only in this milestone) survives a
    /// full export -> plan -> applyImport round trip with its kind and
    /// secret-free config intact, and its Keychain secret (the access key's
    /// secret) carried through the same `password` channel as an SSH
    /// session's password.
    @Test func s3SessionSurvivesExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let s3Config = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
            usePathStyle: true)
        let original = s3Session(name: "s3-prod", config: s3Config)
        try store.upsert(original)
        try secrets.savePassword("shh-secret", for: original.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, missingPasswordCount) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: true)
        #expect(missingPasswordCount == 0)
        let exported = payload.sessions.first!
        #expect(exported.kind == .s3)
        #expect(exported.fields["S3Field.accessKeyID"] == "AKIAEXAMPLE")
        #expect(exported.fields["S3Field.region"] == "eu-central-1")
        #expect(exported.fields["S3Field.endpoint"] == "https://s3.eu-central-1.amazonaws.com")
        #expect(exported.fields["S3Field.bucket"] == "my-bucket")
        #expect(exported.fields["S3Field.usePathStyle"] == "true")
        #expect(exported.s3SecretAccessKey == "shh-secret")
        // The plaintext SSH `password` field must stay empty for an S3
        // session -- the secret only travels via `s3SecretAccessKey`.
        #expect(exported.password == nil)

        // Round trip the payload through the encrypted codec too, proving
        // the whole chain (not just the in-memory struct) preserves it.
        let data = try SessionExportCodec.encode(payload, password: "export-pw")
        let decoded = try SessionExportCodec.decode(data, password: "export-pw")

        // Nothing exists in the target store, so the planner must not reach
        // for the arbiter at all (M19).
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importTarget = dir.appendingPathComponent("import-target")
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: importTarget), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: importTarget),
            loginSetStore: LoginSetStore(directory: importTarget),
            keys: ManagedKeyStore(directory: importTarget))
        let result = importedVM.applyImport(plan)
        #expect(result.imported == 1)
        #expect(result.passwordsImported == 1)

        let imported = importedVM.sessions.first!
        #expect(imported.kind == .s3)
        #expect(imported.s3 == s3Config)
        #expect(imported.id != original.id) // fresh id (M9a import rule)
        #expect(importedVM.password(for: imported) == "shh-secret")
    }

    /// A set-bound `.s3` session (M12/M13) stores its secret under the
    /// login SET's id, not the session's own id -- exactly like an SSH
    /// session bound to a set. The export builder must prefer the
    /// resolved set's secret for `s3SecretAccessKey`, the same way it
    /// already does for the plaintext SSH `password` field; reading only
    /// the session's own (here empty) keychain slot would silently drop
    /// the credential and miscount it as missing.
    @Test func exportResolvesS3LoginSet() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let set = LoginSet(name: "S3 Deploy", username: "unused", kind: .s3, accessKeyID: "AKIASET")
        vm.saveLoginSet(set, secret: "set-secret")

        let s3Config = StoredS3Config(
            accessKeyID: "AKIAOWN", region: "eu-central-1",
            endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
            usePathStyle: true)
        let session = s3Session(name: "s3-bound", loginSetID: set.id, config: s3Config)
        try store.upsert(session)

        let (payload, missingPasswordCount) = vm.exportPayload(
            for: .single(session), includeGroups: false, includePasswords: true)
        let exported = payload.sessions.first!
        #expect(exported.s3SecretAccessKey == "set-secret")
        #expect(missingPasswordCount == 0)
        // The access-key-ID still comes from the session's own config --
        // resolving a login set's access key ID is deferred to M13.
        #expect(exported.fields["S3Field.accessKeyID"] == "AKIAOWN")
    }

    /// An `.s3` session with NO stored block names no server, so the export
    /// must not go looking for a secret for it — neither counting it in the
    /// user-visible "N passwords missing" total nor carrying a key that, on
    /// import, would claim a Keychain slot for a session with no S3 block at
    /// all. Collapsing the per-protocol columns briefly dropped this guard
    /// (M23/P3 fix round 1); this pins it so it cannot be dropped silently
    /// again.
    @Test func exportOfBlocklessS3SessionFetchesNoSecretAndCountsNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        // A secret DOES sit in the keychain under this id: the assertion below
        // is that the export never reaches for it, not that there is nothing
        // to reach for.
        let session = StoredSession(name: "s3-blockless", kind: .s3)
        try store.upsert(session)
        try secrets.savePassword("shh-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, missingPasswordCount) = vm.exportPayload(
            for: .single(session), includeGroups: false, includePasswords: true)

        let exported = payload.sessions.first!
        #expect(exported.s3SecretAccessKey == nil)
        #expect(exported.password == nil)
        #expect(missingPasswordCount == 0)
        // And the bag stays empty, so the import side reads it back as "no
        // block" rather than inventing a server the file never named.
        #expect(exported.fields.isEmpty)
    }

    // MARK: - Connection kind + WebDAV (M23 fix)

    /// End-to-end twin of `s3SessionSurvivesExportImportRoundtrip`: a
    /// `.webdav` session must come back out of a full export -> encode ->
    /// decode -> plan -> applyImport round trip with its base URL, user name
    /// and Nextcloud flag intact. Before the fix the export carried no WebDAV
    /// columns at all, so the imported session had `kind == .webdav` and
    /// `webdav == nil` — the server was simply gone.
    @Test func webdavSessionSurvivesExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let webdavConfig = StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "alice", useNextcloudPath: true)
        let original = webdavSession(name: "nextcloud", config: webdavConfig)
        try store.upsert(original)
        try secrets.savePassword("dav-secret", for: original.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, missingPasswordCount) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: true)
        #expect(missingPasswordCount == 0)
        let exported = payload.sessions.first!
        #expect(exported.kind == .webdav)
        #expect(exported.fields["WebDAVField.baseURL"] == "https://dav.example.com/dav")
        #expect(exported.fields["WebDAVField.username"] == "alice")
        #expect(exported.fields["WebDAVField.useNextcloudPath"] == "true")
        // WebDAV's secret travels in the shared `password` slot (M21) — the
        // export never grew a WebDAV secret column, and must not.
        #expect(exported.password == "dav-secret")

        let data = try SessionExportCodec.encode(payload, password: "export-pw")
        let decoded = try SessionExportCodec.decode(data, password: "export-pw")

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importTarget = dir.appendingPathComponent("import-target")
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: importTarget), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: importTarget),
            loginSetStore: LoginSetStore(directory: importTarget),
            keys: ManagedKeyStore(directory: importTarget))
        let result = importedVM.applyImport(plan)
        #expect(result.imported == 1)
        #expect(result.passwordsImported == 1)

        let imported = importedVM.sessions.first!
        #expect(imported.kind == .webdav)
        #expect(imported.webdav?.baseURL == "https://dav.example.com/dav")
        #expect(imported.webdav?.username == "alice")
        #expect(imported.webdav?.useNextcloudPath == true)
        #expect(imported.webdav == webdavConfig)
        #expect(imported.id != original.id) // fresh id (M9a import rule)
        #expect(importedVM.password(for: imported) == "dav-secret")
    }

    /// The WebDAV twin of `exportOfBlocklessS3SessionFetchesNoSecretAndCountsNothing`:
    /// a `.webdav` session with NO stored block names no server, so the
    /// export must not go looking for a secret for it either — neither
    /// counting it in the user-visible "N passwords missing" total nor
    /// carrying a key that, on import, would claim a Keychain slot for a
    /// session with no WebDAV block at all. `exportPayload`'s `password`
    /// branch had an `.s3` guard restored (fix round 1) with no matching
    /// `.webdav` counterpart — this pins that the counterpart now exists.
    @Test func exportOfBlocklessWebDAVSessionFetchesNoSecretAndCountsNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        // A secret DOES sit in the keychain under this id: the assertion below
        // is that the export never reaches for it, not that there is nothing
        // to reach for.
        let session = StoredSession(name: "dav-blockless", kind: .webdav)
        try store.upsert(session)
        try secrets.savePassword("shh-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, missingPasswordCount) = vm.exportPayload(
            for: .single(session), includeGroups: false, includePasswords: true)

        let exported = payload.sessions.first!
        #expect(exported.password == nil)
        #expect(missingPasswordCount == 0)
        // And the bag stays empty, so the import side reads it back as "no
        // block" rather than inventing a server the file never named.
        #expect(exported.fields.isEmpty)
    }

    /// The optional path, same round trip for a session that has NO WebDAV
    /// block: nothing may be invented on the way through, and the secret-free
    /// export must stay secret-free.
    @Test func sessionWithoutWebDAVBlockSurvivesRoundtripWithNilConfig() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let original = sshSession(name: "web", host: "web-01", username: "root")
        try store.upsert(original)

        let vm = SessionListViewModel(
            store: store, secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, _) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: false)
        let exported = payload.sessions.first!
        #expect(exported.fields["WebDAVField.baseURL"] == nil)
        #expect(exported.fields["WebDAVField.username"] == nil)
        #expect(exported.fields["WebDAVField.useNextcloudPath"] == nil)
        // Structural since M23/P3: an SSH session's bag holds SSH keys and
        // nothing else, so no other backend can leak into its entry.
        #expect(exported.fields.keys.allSatisfy { $0.hasPrefix("SSHField.") })

        let data = try SessionExportCodec.encode(payload, password: nil)
        let decoded = try SessionExportCodec.decode(data, password: nil)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importTarget = dir.appendingPathComponent("import-target")
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: importTarget), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: importTarget),
            loginSetStore: LoginSetStore(directory: importTarget),
            keys: ManagedKeyStore(directory: importTarget))
        #expect(importedVM.applyImport(plan).imported == 1)
        let imported = importedVM.sessions.first!
        #expect(imported.kind == .ssh)
        #expect(imported.webdav == nil)
    }

    /// A `.macscp` file written BEFORE this fix: a `.webdav` session with no
    /// `webdav*` columns. It must still import — the missing columns decode as
    /// `nil`, exactly the way the `s3*` columns already do.
    @Test func preFixExportFileStillImports() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = Data("""
        {"format":"macscp-sessions","version":1,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[],"sessions":[{"id":"\(UUID().uuidString)","name":"nextcloud","host":"unused",\
        "port":22,"username":"unused","authKind":"password","kind":"webdav"}]}}
        """.utf8)
        let decoded = try SessionExportCodec.decode(raw, password: nil)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        #expect(importedVM.applyImport(plan).imported == 1)
        let imported = importedVM.sessions.first!
        #expect(imported.kind == .webdav)
        #expect(imported.webdav == nil)
    }

    /// The M26 defect, end to end. A file entry that builds a blockless
    /// `.ssh` record used to be counted as imported and to have its password
    /// written to the Keychain under the planned id — while
    /// `SessionStore.load()` removed the record itself on the very next read,
    /// which `applyImport`'s closing `reload()` performs immediately. The user
    /// was told "1 imported" for a session not in the sidebar, and the secret
    /// became an orphan no delete path can reach, because every
    /// `deletePassword` caller resolves its id from a session in the reloaded
    /// list.
    @Test func blocklessSSHEntryIsNeitherImportedNorLeavesAnOrphanSecret() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ExportedSession(
            id: UUID(), name: "ghost", kind: .ssh, fields: [:], password: "orphan-secret")
        let payload = SessionExportPayload(
            includesSecrets: true, groups: [], sessions: [file])
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })

        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let result = vm.applyImport(plan)

        #expect(result.imported == 0)
        #expect(plan.rejected == ["ghost"])
        #expect(vm.sessions.isEmpty)
        // No Keychain slot may be left behind for a record that is not
        // there — checked across every id `secrets` actually holds, not by
        // looking up the one id the fix planned to use. After the fix
        // `plan.sessionsToImport` is itself empty, so a loop keyed on it
        // would run zero times and prove nothing at all; `storedIDs` proves
        // the stronger claim, "empty, full stop", which is what "no orphan"
        // actually means.
        #expect(secrets.storedIDs.isEmpty)
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func saveSwitchingTargetToAgentDeletesSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        #expect(try secrets.password(for: stored.id) == "pw")

        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u", authKind: .agent),
            password: "")

        #expect(try secrets.password(for: stored.id) == nil)
        #expect(vm.sessions.first?.ssh?.authKind == .agent)
    }

    @Test func updateSessionSwitchingTargetToAgentDeletesSessionSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        var updated = stored
        updated.ssh?.authKind = .agent

        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: stored.id) == nil)
        #expect(vm.sessions.first?.ssh?.authKind == .agent)
    }

    @Test func saveJumpSwitchingManualToAgentDeletesJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        // Same secretID, but the jump now switches to agent mode -- the old
        // manual slot must still be cleaned up even though the id itself
        // didn't change (unlike the existing "removed/replaced slot" cases
        // `cleanOrphanedJumpSlot` already covered).
        let agentJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "jumper", authKind: .agent, secretID: jump.secretID)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: agentJump)

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first?.jump?.authKind == .agent)
    }

    /// M11a hand-off (T2 review): switching a jump from manual to SESSION
    /// mode must clean the now-orphaned `secretID` slot exactly like the
    /// manual->agent switch above -- even though `buildJumpSpec` happens to
    /// carry the SAME `secretID` forward as a data carrier (spec §1), the
    /// slot is no longer read once `sessionID` is set (the referenced
    /// session's own login is used instead), so the stale manual secret must
    /// not survive the switch.
    @Test func saveJumpSwitchingManualToSessionDeletesJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 22, username: "root"),
            password: "bp")!

        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        // Same secretID (carried forward as an inert data carrier), but the
        // jump now references the bastion session instead.
        let sessionJump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "jumper",
            secretID: jump.secretID, sessionID: bastion.id)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: sessionJump)

        #expect(try secrets.password(for: jump.secretID) == nil)
        #expect(vm.sessions.first(where: { $0.name == "web" })?.jump?.sessionID == bastion.id)
    }

    /// M28 final review (Critical): the jump's login-MODE picker is a mode
    /// switch over fields the user did not type. In Set mode the App fills
    /// `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/`jumpPassword` from the
    /// selected set before every submit (the fill inside
    /// `SessionListViewModel.resolveJumpLoginSet`), so a
    /// switch to Manual that keeps them leaves the SET's secret pre-filled in
    /// the manual field -- and the next save persists it into THIS session's
    /// own jump slot. That is the damage `selectJumpSourceMode`'s doc comment
    /// describes for the source switcher, one picker over.
    ///
    /// Written end-to-end rather than on the view model alone because the
    /// loss only becomes one when `updateSession` writes the field into
    /// `jump.secretID`. The set here is a WebDAV set: after M28/T7 that is a
    /// binding `LoginResolver.resolveJump` refuses outright, so the secret
    /// arriving in the session's own slot would also silence the refusal --
    /// the spec no longer has a `loginSetID` for it to judge.
    ///
    /// Only the picker-mode half of the fix is pinned here. The picker
    /// binding (`ConnectionFormView`) is still App-side and unpinned; the
    /// fill's own `kind` guard moved to Core in M29-P2
    /// (`SessionListViewModel.resolveJumpLoginSet`) and is covered by
    /// `SubmitPreparationTests.aJumpBoundToANonSSHSetIsRefusedBeforeItsSecretIsRead`.
    @Test func jumpLoginModeSwitchDropsASetFilledSecretInsteadOfSavingIt() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shareSecret = "share-secret"
        let share = LoginSet(name: "Share", username: "web-user", kind: .webdav)
        vm.saveLoginSet(share, secret: shareSecret)

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: share.id)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

        let form = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        form.beginEditing(stored)
        #expect(form.jumpLoginMode == .set)
        #expect(form.jumpSelectedLoginSetID == share.id)
        // Exactly what the fill does for a set-bound jump before every
        // submit, secret included -- spelled out here rather than routed
        // through `SessionListViewModel.resolveJumpLoginSet`, because this
        // test is about what `selectJumpLoginMode` does with an
        // already-filled form, not about how it got filled.
        form.jumpUsername = share.username
        form.jumpPassword = shareSecret

        form.selectJumpLoginMode(.manual)
        // M30: leaving Set mode now demands the jump's own secret, and
        // `selectJumpLoginMode` has just cleared the field -- so a real user
        // types one here. A DIFFERENT value than the share's on purpose: it
        // sharpens what this test proves, from "the share's secret does not
        // land in the jump slot when nothing is typed" to "it does not land
        // there even when something else is".
        form.jumpPassword = "typed-by-the-user"

        let updated = form.validateForEditSave()!
        vm.updateSession(updated, newSecret: nil, jumpSecret: form.jumpPassword)

        let jumpSlot = updated.jump!.secretID
        // Compared as a Bool so no secret can reach a failure message.
        let jumpSlotHoldsTheSharesSecret = secrets.peek(jumpSlot) == shareSecret
        #expect(jumpSlotHoldsTheSharesSecret == false)
        // Was "no slot written at all", which only held while the field was
        // empty. Under M30 the user must type something, so the sharper
        // question is WHAT the slot holds: exactly what they typed, and
        // nothing carried over from the share.
        let jumpSlotHoldsWhatTheUserTyped = secrets.peek(jumpSlot) == "typed-by-the-user"
        #expect(jumpSlotHoldsWhatTheUserTyped)
        // The share's own slot is untouched -- this is about copying, not
        // moving.
        #expect(secrets.storedIDs.contains(share.id))
    }

    /// M11a/T3 review (defense in depth): a session-referencing jump owns NO
    /// secret — the referenced connection does. The write guard therefore
    /// lives in the store layer too, not only at the App call sites: even a
    /// caller that hands over the resolved secret must not get it copied into
    /// this jump's (unused) slot. Covers both `save` and `updateSession`.
    @Test func sessionModeJumpNeverStoresASecretEvenIfOffered() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 22, username: "root"),
            password: "bp")!

        let sessionJump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: sessionJump,
            jumpSecret: "leaked-on-save")!
        #expect(try secrets.password(for: sessionJump.secretID) == nil)

        var updated = stored
        updated.name = "web renamed"
        vm.updateSession(updated, newSecret: nil, jumpSecret: "leaked-on-update")
        #expect(try secrets.password(for: sessionJump.secretID) == nil)
        #expect(vm.sessions.first(where: { $0.name == "web renamed" })?.jump?.sessionID == bastion.id)
    }

    @Test func updateSessionJumpSwitchingManualToAgentDeletesJumpSecretSlot() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "jp")!
        #expect(try secrets.password(for: jump.secretID) == "jp")

        var updated = stored
        updated.ssh?.jump?.authKind = .agent
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func saveNeverStoresPasswordForAgentTarget() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u", authKind: .agent),
            password: "leaked")!

        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func saveNeverStoresJumpSecretForAgentJump() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)
        _ = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw",
            jump: jump,
            jumpSecret: "leaked")!

        #expect(try secrets.password(for: jump.secretID) == nil)
    }

    @Test func exportPayloadSkipsSecretForAgentAndDoesNotCountMissing() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u", authKind: .agent),
            password: "")!

        let result = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)

        #expect(result.payload.sessions.first?.fields["SSHField.authKind"] == "agent")
        #expect(result.payload.sessions.first?.password == nil)
        #expect(result.missingPasswordCount == 0)
    }

    @Test func exportPayloadSkipsJumpSecretForAgentAndDoesNotCountMissing() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.ssh?.username == "deploy")
        #expect(restored.ssh?.authKind == .agent)
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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!

        // M22/T9: `resolvedLogin` collapsed into `resolvedCredentials`, which
        // returns the backend's own field values. An agent set has no visible
        // secret field at all, so neither secret row carries anything.
        let resolved = try #require(try vm.resolvedCredentials(for: stored))
        #expect(resolved[SSHField.username] == "deploy")
        #expect(resolved[SSHField.authKind] == StoredSession.AuthKind.agent.rawValue)
        #expect(resolved[SSHField.keyPath] == "")
        #expect(resolved[SSHField.password] == "")
        #expect(resolved[SSHField.passphrase] == "")
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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!

        set.authKind = .agent
        vm.saveLoginSet(set, secret: nil)

        let result = vm.deleteLoginSet(set)

        #expect(result == SessionListViewModel.LoginSetDeleteResult(restored: 1, secretFailures: 0))
        let restored = vm.sessions.first { $0.id == stored.id }!
        #expect(restored.loginSetID == nil)
        #expect(restored.ssh?.authKind == .agent)
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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

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
        let a = vm.save(
            name: "a",
            values: sshValues(host: "h1", port: 22, username: "root", authKind: .agent),
            password: "")!
        let b = vm.save(
            name: "b",
            values: sshValues(host: "h2", port: 22, username: "root", authKind: .agent),
            password: "")!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!
        // `LoginMergeCandidate.authKind` was removed in M24/T2 (`kind` +
        // `values` replaced the SSH-shaped properties); read the same fact
        // back through the field bag.
        #expect(candidate.values[SSHField.authKind] == "agent")

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
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "pw")!
        #expect(try vm.resolvedJumpLogin(for: stored) == nil)

        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: UUID())
        let withJump = vm.save(
            name: "web2",
            values: sshValues(host: "h2", port: 22, username: "u"),
            password: "pw",
            jump: jump)!
        #expect(throws: LoginResolveError.missingSet) {
            _ = try vm.resolvedJumpLogin(for: withJump)
        }
    }

    // MARK: - Jump-from-saved-session restoration + export (M11a Task 2)

    @Test func sessionsUsingAsJumpFindsReferences() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b", port: 22, username: "u"),
            password: "p")!
        let other = vm.save(
            name: "other",
            values: sshValues(host: "o", port: 22, username: "u"),
            password: "p")!
        let jumpToBastion = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(
            name: "a",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jumpToBastion)!
        let jumpToOther = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: other.id)
        let b = vm.save(
            name: "b",
            values: sshValues(host: "tb", port: 22, username: "u"),
            password: "pw",
            jump: jumpToOther)!
        _ = vm.save(
            name: "plain",
            values: sshValues(host: "tp", port: 22, username: "u"),
            password: "pw")!

        #expect(Set(vm.sessionsUsingAsJump(bastion.id).map(\.id)) == Set([a.id]))
        #expect(vm.sessionsUsingAsJump(other.id).map(\.id) == [b.id])
    }

    /// Regression bracket for the M24 non-SSH guard in `delete(_:)`: an SSH
    /// bastion must still restore every referencing jump exactly as before.
    @Test func deletingAnSSHBastionStillRestores() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 2022, username: "deploy"),
            password: "s")!
        let jumpA = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(
            name: "a",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jumpA)!
        let jumpB = StoredSession.JumpSpec(
            host: "ignored2", username: "ignored2", sessionID: bastion.id)
        let b = vm.save(
            name: "b",
            values: sshValues(host: "tb", port: 22, username: "u"),
            password: "pw",
            jump: jumpB)!

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

    /// M24: an S3 bastion has no SSH host/port/login to restore -- `affected`
    /// is computed only for `.ssh` (`SessionListViewModel.swift`), so an S3
    /// bastion never even reaches the restoration block. The referencing
    /// session must be left alone rather than gain a placeholder bastion that
    /// looks configured but can never be dialled.
    @Test func deletingANonSSHBastionRestoresNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let bastion = s3Session(name: "bucket")
        try store.upsert(bastion)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let referencing = vm.save(
            name: "web",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

        let result = vm.delete(bastion)

        #expect(result == SessionListViewModel.JumpRestoreResult(restored: 0, secretFailures: 0))
        let stillReferencing = vm.sessions.first { $0.id == referencing.id }!
        #expect(stillReferencing.jump?.sessionID == bastion.id)
        #expect(stillReferencing.jump?.host != "")
        #expect(stillReferencing.jump?.host == "ignored")
        #expect(stillReferencing.jump?.username == "ignored")
        #expect(vm.sessions.contains { $0.id == bastion.id } == false)
    }

    /// M26: unlike the S3 case above, a blockless `.ssh` session still makes
    /// `affected` non-empty (`sessionsUsingAsJump` doesn't care whether the
    /// block exists, only that `kind == .ssh` and something references it),
    /// so this exercises the `if let ssh = session.ssh` inside `delete`'s
    /// restoration block rather than the `affected.isEmpty` short-circuit.
    /// That guard is unreachable through `SessionStore.load()` (Task 1 drops
    /// such a record at load time), which is why the blockless session is
    /// built directly rather than through `vm.save`/`sshSession` -- no
    /// fixture can produce one -- and written to the store with a bare
    /// `upsert`, which does not filter (only `load` does).
    ///
    /// `store.load()` filtering the blockless record out of every read means
    /// `vm.sessions`/`store.all()` can't prove `delete` actually ran the
    /// deletion below the guard -- they would report `broken` as gone
    /// whether `delete` ran to completion or returned early, because the very
    /// next `load()` (inside `delete`'s own `store.delete(id:)` call, or any
    /// earlier one) filters it regardless. Only reading the raw file
    /// distinguishes the two: an early `return` before `store.delete(id:)`
    /// never triggers that filtered rewrite, so `broken`'s bytes would still
    /// be sitting in `sessions-v2.json` after `delete` returns.
    ///
    /// Pins that the guard is written as `if let ssh { ... }` around the
    /// restoration, not an early `return`: an early return would skip the
    /// deletion below it.
    @Test func deletingASessionStillRemovesItWhenItsBlockIsMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let brokenID = UUID()
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: brokenID)
        let referencing = vm.save(
            name: "web",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

        // Direct construction, no fixture: `sshSession` always fills `ssh`,
        // and this is the one shape no fixture is meant to produce (see
        // `SessionFixtures.swift`'s header comment). `upsert`, not `save`, so
        // the write bypasses `SessionListViewModel` entirely -- `save` routes
        // through `SSHFieldSchema.apply`, which cannot construct a session
        // without a block.
        let broken = StoredSession(id: brokenID, name: "blockless", kind: .ssh)
        try store.upsert(broken)

        // Matches the record's own `id` key, not the referencing session's
        // `jump.sessionID` -- which carries the SAME uuid on purpose (the
        // dangling reference asserted below) and would otherwise make this
        // check pass vacuously both before and after the delete.
        let sessionsFile = dir.appendingPathComponent("sessions-v2.json")
        let idKey = "\"id\" : \"\(brokenID.uuidString)\""
        let beforeDelete = try String(contentsOf: sessionsFile, encoding: .utf8)
        #expect(beforeDelete.contains(idKey))

        let result = vm.delete(broken)

        // `restored` counts `affected.size` -- how many jumps referenced the
        // deleted session -- not how many were actually restored; it stays 1
        // here even though the guard skips the restoration itself, exactly
        // as it would for a per-item Keychain failure elsewhere in this
        // function. `secretFailures` is the field that reports the guard's
        // effect: no secret write was even attempted.
        #expect(result == SessionListViewModel.JumpRestoreResult(restored: 1, secretFailures: 0))

        let afterDelete = try String(contentsOf: sessionsFile, encoding: .utf8)
        #expect(!afterDelete.contains(idKey))

        let stillReferencing = vm.sessions.first { $0.id == referencing.id }!
        #expect(stillReferencing.jump?.sessionID == brokenID)
        #expect(stillReferencing.jump?.host == "ignored")
        #expect(stillReferencing.jump?.username == "ignored")
    }

    /// M25/T1: the restoration block (bastion login + secret + the `for
    /// referencing in affected` loop) only has anything to do once `affected`
    /// is non-empty, and since M24 `affected` is always empty for a non-SSH
    /// session. Before the hoist, `bastionSecret` was still computed
    /// unconditionally -- for an `.s3` session that reads the Keychain slot
    /// holding its SECRET ACCESS KEY, fetched only to be discarded. Reusing
    /// `NoReadAllowedSecretStore` (below, shared with
    /// `deleteRestoresFromAgentBastionWithoutSecret`) fails the test the
    /// moment `password(for:)` is called at all.
    @Test func deletingANonSSHSessionNeverReadsTheKeychain() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = NoReadAllowedSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let s3 = StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let bucket = vm.save(
            name: "bucket", values: S3FieldSchema.values(from: s3), password: "SECRET", kind: .s3)!

        let result = vm.delete(bucket)

        #expect(result.restored == 0)
        #expect(vm.sessions.contains { $0.id == bucket.id } == false)
    }

    @Test func deleteRestoresFromAgentBastionWithoutSecret() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = NoReadAllowedSecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 2022, username: "deploy", authKind: .agent),
            password: "")!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(
            name: "a",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

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
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 2022, username: "deploy"),
            password: "s")!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let a = vm.save(
            name: "a",
            values: sshValues(host: "ta", port: 22, username: "u"),
            password: "pw",
            jump: jump)!
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
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 2022, username: "deploy"),
            password: "s")!
        let jump = StoredSession.JumpSpec(
            host: "ignored", username: "ignored", sessionID: bastion.id)
        let target = vm.save(
            name: "web",
            values: sshValues(host: "target.example.com", port: 22, username: "u"),
            password: "pw",
            jump: jump)!

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
        let target2 = vm.save(
            name: "web2",
            values: sshValues(host: "target2.example.com", port: 22, username: "u"),
            password: "pw",
            jump: danglingJump)!
        let exported2 = vm.exportPayload(
            for: .single(target2), includeGroups: false, includePasswords: true)
        let payload2 = exported2.payload.sessions.first!
        #expect(payload2.jumpHost == "own-host")
        #expect(payload2.jumpPort == 2121)
        #expect(payload2.jumpUsername == "own-user")
    }

    // MARK: - applyMerge builds a set of the candidate's own kind (M24/T3)

    @Test func mergingTwoS3SessionsCreatesAnS3SetCarryingTheAccessKeyID() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let a = vm.save(
            name: "a", values: S3FieldSchema.values(from: s3), password: "sh4red", kind: .s3)!
        let b = vm.save(
            name: "b", values: S3FieldSchema.values(from: s3), password: "sh4red", kind: .s3)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!
        #expect(candidate.kind == .s3)

        let set = vm.applyMerge(candidate, name: "acct")

        #expect(set?.kind == .s3)
        #expect(set?.accessKeyID == "AKIAEXAMPLE")
        for session in [a, b] {
            #expect(vm.sessions.first { $0.id == session.id }?.loginSetID == set?.id)
        }
    }

    @Test func mergingCarriesTheSecretOntoTheSetBeforeDeletingTheSessionSlots() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let a = vm.save(
            name: "a", values: S3FieldSchema.values(from: s3), password: "sh4red", kind: .s3)!
        let b = vm.save(
            name: "b", values: S3FieldSchema.values(from: s3), password: "sh4red", kind: .s3)!

        let candidates = vm.mergeCandidates()
        #expect(candidates.count == 1)
        let candidate = candidates.first!

        let set = vm.applyMerge(candidate, name: "acct")

        #expect(set != nil)
        #expect(try secrets.password(for: set!.id) == "sh4red")
        #expect(try secrets.password(for: a.id) == nil)
        #expect(try secrets.password(for: b.id) == nil)
    }

    @Test func applyMergeRefusesACandidateWhoseSessionsAreOfMixedKind() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s3 = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "backups", usePathStyle: false)
        let bucket = vm.save(
            name: "bucket", values: S3FieldSchema.values(from: s3), password: "s3cret", kind: .s3)!
        let host = vm.save(
            name: "host", values: sshValues(host: "h1", port: 22, username: "root"),
            password: "pw")!

        // Hand-built, not planner-produced: `LoginMergePlanner` puts `kind` in
        // its grouping key, so it can never hand out a mixed group. This is
        // the "a candidate is a plain value anything could build" case the
        // guard in `applyMerge` defends against.
        let candidate = LoginMergeCandidate(
            kind: .s3, values: S3FieldSchema.values(from: s3),
            displayLabel: "AKIAEXAMPLE", sessionIDs: [bucket.id, host.id])

        let result = vm.applyMerge(candidate, name: "acct")

        #expect(result == nil)
        // Nothing happened: no set, no rewiring, no deleted secret.
        #expect(vm.loginSets.isEmpty)
        #expect(vm.sessions.first { $0.id == bucket.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == host.id }?.loginSetID == nil)
        #expect(try secrets.password(for: bucket.id) == "s3cret")
        #expect(try secrets.password(for: host.id) == "pw")
    }

    /// `applyMerge`'s SECOND defense in depth (M24 closeout, Finding E): the
    /// kind guard above is not enough on its own -- a hand-built `.s3`
    /// candidate over sessions whose `kind` says `.s3` but which carry NO
    /// stored S3 block would pass that guard (kind matches) and still build
    /// a set with an empty `accessKeyID`, then delete both Keychain slots.
    /// `LoginMergePlanner.candidates` already filters such sessions out
    /// (`hasStoredConfiguration`, `LoginMergePlanner.swift`), so this is
    /// unreachable through the planner -- exactly the same "candidate is a
    /// plain value anything could build" threat model as the mixed-kind test
    /// above, one step further.
    @Test func applyMergeRefusesACandidateWhoseSessionsLackTheStoredBlockTheirKindClaims() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        // Blockless `.s3` sessions -- no fixture can build these (`s3Session`
        // in `SessionFixtures.swift` always fills a block), so this
        // constructs `StoredSession` directly, the same sanctioned exception
        // `BackendDescriptorTests` uses for the identical shape.
        let a = StoredSession(name: "a", kind: .s3)
        let b = StoredSession(name: "b", kind: .s3)
        try store.upsert(a)
        try store.upsert(b)
        try secrets.savePassword("secret-a", for: a.id)
        try secrets.savePassword("secret-b", for: b.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))

        // Hand-built, not planner-produced: `kind` matches on both sides
        // (`.s3` == `.s3`), so the FIRST guard alone would let this through.
        let candidate = LoginMergeCandidate(
            kind: .s3, values: FieldValues(), displayLabel: "", sessionIDs: [a.id, b.id])

        let result = vm.applyMerge(candidate, name: "acct")

        #expect(result == nil)
        // Nothing happened: no set, no rewiring, no deleted secret.
        #expect(vm.loginSets.isEmpty)
        #expect(vm.sessions.first { $0.id == a.id }?.loginSetID == nil)
        #expect(vm.sessions.first { $0.id == b.id }?.loginSetID == nil)
        #expect(try secrets.password(for: a.id) == "secret-a")
        #expect(try secrets.password(for: b.id) == "secret-b")
    }

    // MARK: - Secret guard asks the schema, not authKind (M25/T3)
    //
    // `StoredSession.authKind` fabricates `.password` for a `.s3`/`.webdav`
    // session (no `ssh` block to read), so the two guards below moved from
    // reading it to asking `BackendDescriptor.visibleSecretField(for:)`
    // instead. These five tests are a regression bracket, not a bug
    // reproduction: the fabricated value happened to give the right answer
    // in every one of these cases already, so all five are expected to pass
    // both before and after the guards are rewritten (task report has the
    // verified before/after status per test).

    @Test func updateSessionClearsALeftoverSlotWhenSwitchingToAgent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let session = sshSession(name: "web", authKind: .password)
        try store.upsert(session)
        try secrets.savePassword("pw", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        var updated = session
        updated.ssh?.authKind = .agent
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: session.id) == nil)
    }

    /// Without the schema-based guard, `updated.authKind` for an `.s3`
    /// session fabricates `.password` -- never `.agent` -- so this happens
    /// to survive on its own; asking the schema must not regress it (the
    /// brief's warning: asking the wrong direction would delete an S3
    /// session's secret).
    @Test func updateSessionKeepsAnS3SessionsSecret() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let session = s3Session(name: "bucket")
        try store.upsert(session)
        try secrets.savePassword("s3-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        var updated = session
        updated.name = "bucket renamed"
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: session.id) == "s3-secret")
    }

    /// Twin of the S3 case above for `.webdav`.
    @Test func updateSessionKeepsAWebDAVSessionsSecret() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let session = webdavSession(name: "cloud")
        try store.upsert(session)
        try secrets.savePassword("webdav-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        var updated = session
        updated.name = "cloud renamed"
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: session.id) == "webdav-secret")
    }

    /// Blockless twin of `updateSessionKeepsAnS3SessionsSecret`. Pins a latch
    /// that holds by accident: `S3Field.secretAccessKey` declares no
    /// `visibleWhen`, so `visibleSecretField(for:)` finds it in
    /// `visibleFields` regardless of what `sessionValues(_:)` returns -- and
    /// for a blockless `.s3` session that is the empty bag. So the field
    /// counts as "on screen" even though the session has no S3 block at all,
    /// and `updateSession` takes the "keep" branch instead of deleting the
    /// Keychain slot. If S3 ever grew a secret field gated by a
    /// `visibleWhen` (say a toggle that hides the key under some other auth
    /// mode), a blockless session could stop matching that condition, flip
    /// `visibleSecretField(for:)` to nil, and this same rename-only edit
    /// would silently delete the slot instead.
    @Test func updateSessionOfABlocklessS3SessionKeepsTheKeychainSlot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let session = StoredSession(name: "s3-blockless", kind: .s3)
        try store.upsert(session)
        try secrets.savePassword("s3-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        var updated = session
        updated.name = "s3-blockless renamed"
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: session.id) == "s3-secret")
    }

    /// Blockless twin of `updateSessionKeepsAWebDAVSessionsSecret`, same
    /// reasoning as the S3 case above: `WebDAVField.password` declares no
    /// `visibleWhen` either, so it is "visible" against the empty bag a
    /// blockless `.webdav` session yields, and `updateSession` keeps the
    /// Keychain slot instead of deleting it. A future `visibleWhen` on this
    /// field (say an "anonymous access" toggle) would change the answer for
    /// exactly this case.
    @Test func updateSessionOfABlocklessWebDAVSessionKeepsTheKeychainSlot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let store = SessionStore(directory: dir)
        let session = StoredSession(name: "webdav-blockless", kind: .webdav)
        try store.upsert(session)
        try secrets.savePassword("webdav-secret", for: session.id)

        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        var updated = session
        updated.name = "webdav-blockless renamed"
        vm.updateSession(updated, newSecret: nil)

        #expect(try secrets.password(for: session.id) == "webdav-secret")
    }

    /// Success criterion 4 (spec): the agent-ness of a SET-BOUND session
    /// comes from the SET, not from the session's own (SSH-shaped) values.
    /// A blanket replacement of the fallback with a schema question about
    /// the session would make this session start looking for a secret and
    /// count itself in the user-visible "N passwords missing" total -- that
    /// is the regression this test exists to catch.
    @Test func exportingASessionBoundToAnAgentLoginSetCarriesNoPasswordAndCountsNone() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Agent Set", username: "deploy", authKind: .agent)
        vm.saveLoginSet(set, secret: nil)
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "ignored"),
            password: "",
            loginSetID: set.id)!

        let result = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)

        #expect(result.payload.sessions.first?.password == nil)
        #expect(result.missingPasswordCount == 0)
    }

    /// Twin of the set-bound case above for a MANUAL agent session (no
    /// login set involved) -- this is the one where the new fallback schema
    /// question actually runs.
    @Test func exportingAManualAgentSessionCarriesNoPasswordAndCountsNone() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u", authKind: .agent),
            password: "")!

        let result = vm.exportPayload(for: .single(stored), includeGroups: false, includePasswords: true)

        #expect(result.payload.sessions.first?.password == nil)
        #expect(result.missingPasswordCount == 0)
    }

    // MARK: - setCoversItsLogin (M28/T1)

    @Test func aPasswordSetWithoutASecretIsNotCovered() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "deploy", username: "deploy", authKind: .password)

        #expect(try vm.setCoversItsLogin(set) == false)
    }

    @Test func aPasswordSetHoldingASecretIsCovered() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "deploy", username: "deploy", authKind: .password)
        try secrets.savePassword("pw", for: set.id)

        #expect(try vm.setCoversItsLogin(set) == true)
    }

    /// The M10d rule: a login that needs no secret is never a reason to touch
    /// the Keychain. `NoReadAllowedSecretStore` (below) fails the test the
    /// moment `password(for:)` is called at all, so this pins the ORDER of the
    /// two arms, not just the answer.
    @Test func anAgentSetIsCoveredWithoutReadingTheKeychain() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: NoReadAllowedSecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let set = LoginSet(name: "agent", username: "deploy", authKind: .agent)

        #expect(try vm.setCoversItsLogin(set) == true)
    }

    /// The second way a set can need nothing, and the reason M28 takes no
    /// `ManagedKeyStore` dependency: a key set's `passphrase` field is on
    /// screen but not required (`aPrivateKeyLoginSetShowsAnOptionalPassphraseField`
    /// in `BackendDescriptorTests` pins that), so an empty slot is not a gap.
    @Test func aPrivateKeySetIsCoveredWithoutASetSecret() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "key", username: "deploy", authKind: .privateKey, keyPath: "/k")

        #expect(try vm.setCoversItsLogin(set) == true)
    }

    @Test func anS3SetWithoutASecretIsNotCovered() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "minio", username: "", kind: .s3, accessKeyID: "AKIA")

        #expect(try vm.setCoversItsLogin(set) == false)
    }

    /// WebDAV declares no required secret at all (`WebDAVFieldSchema.credential`
    /// marks neither of its two fields required, so anonymous shares stay
    /// connectable), so an empty slot is not a gap here either.
    @Test func aWebDAVSetIsCoveredWithoutASecret() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "cloud", username: "tim", kind: .webdav)

        #expect(try vm.setCoversItsLogin(set) == true)
    }

    /// The most important test of this milestone. `kind` and `authKind` are
    /// independent columns and the login-set importer copies both verbatim, so
    /// a set can declare S3 storage with agent auth. Asking `authKind` would
    /// call this covered and delete a session's only secret access key. Asking
    /// the schema does not: `S3FieldSchema.values(from:)` writes only
    /// `accessKeyID`, and `S3Field.secretAccessKey` carries no `visibleWhen`,
    /// so the required secret field stays on screen whatever `authKind` says.
    @Test func anS3SetDeclaringAgentAuthIsStillNotCovered() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "minio", username: "", authKind: .agent, kind: .s3, accessKeyID: "AKIA")

        #expect(try vm.setCoversItsLogin(set) == false)
    }

    /// A keychain that will not answer is not an empty one. Everything in M28
    /// hangs on this: the two deleting binders decide from this answer, and a
    /// swallowed read would report the INTACT secret seeded below as missing.
    @Test func anUnreadableKeychainMakesCoverageThrowRatherThanFalse() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsReads: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let set = LoginSet(name: "deploy", username: "deploy", authKind: .password)
        try secrets.savePassword("pw", for: set.id)

        #expect(throws: KeychainError.self) { try vm.setCoversItsLogin(set) }
        #expect(secrets.peek(set.id) != nil)
    }

    /// M30: the value demanded when a session leaves Set mode must REPLACE
    /// the stored one. Without that, the new validation rule would be
    /// pointless -- the user types a password and the old one stays anyway.
    @Test func aNewSecretOnEditReplacesTheStoredOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "h", username: "u")
        try secrets.savePassword("old", for: session.id)

        vm.updateSession(session, newSecret: "new")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let replaced = try secrets.password(for: session.id) == "new"
        #expect(replaced)
    }

    /// M32: a failed session write must not take the session's secret with
    /// it. Before this, the loop rewired and deleted with two `try?` in a
    /// row, so a store that refused the write left the session unbound --
    /// still resolving its login from its own slot -- and deleted exactly
    /// that slot.
    ///
    /// The failure is PRODUCED, not simulated: the session directory is made
    /// read-only, so `upsert` genuinely fails. `SessionStore.persist` writes
    /// with `.atomic`, which renames a temp file into place, so locking the
    /// FILE would not do it -- the directory has to go. The login-set store
    /// gets its own writable directory, because `applyMerge` writes the set
    /// first and would otherwise fail before reaching the loop.
    @Test func aFailedRewireKeepsTheSessionsOwnSecret() throws {
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-sessions-\(UUID().uuidString)")
        let loginDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-logins-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: sessionDir.path)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: loginDir)
        }
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: sessionDir), secrets: secrets,
            auditStore: AuditLogStore(directory: loginDir),
            loginSetStore: LoginSetStore(directory: loginDir),
            keys: ManagedKeyStore(directory: loginDir))

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "the-only-copy")!

        // Locked only AFTER the session exists, or there would be nothing to
        // merge.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sessionDir.path)

        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            displayLabel: "u", sessionIDs: [stored.id])
        _ = vm.applyMerge(candidate, name: "Shared")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let keptItsSecret = try secrets.password(for: stored.id) == "the-only-copy"
        #expect(keptItsSecret)
    }

    /// Positive control for the test above: with a writable directory the
    /// merge does its job -- the session is rewired and its own slot goes.
    /// Without this, a version of `applyMerge` that deleted nothing at all
    /// would satisfy the first test.
    @Test func aSuccessfulRewireStillTakesTheSessionsOwnSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "carried")!
        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            displayLabel: "u", sessionIDs: [stored.id])

        let set = vm.applyMerge(candidate, name: "Shared")

        #expect(set != nil)
        let slotIsGone = try secrets.password(for: stored.id) == nil
        #expect(slotIsGone)
        #expect(vm.sessions.first { $0.id == stored.id }?.loginSetID == set?.id)
    }

    // MARK: - Duplicating a session
    //
    // What the copy IS is `SessionDuplication`'s answer and is pinned in
    // `SessionDuplicationTests`. What is checked here is the half only a
    // store can answer: that the copy reaches the store under its own name,
    // and that no Keychain slot it can reach holds anything.
    //
    // Every assertion about a secret below is made on a `Bool` computed
    // first, never on the read itself. `#expect` renders what it was given,
    // and a `#expect(try secrets.password(for: copy.id) == nil)` that FAILS
    // would render the secret it found into the test log — the one moment
    // the check is worth having is the one moment it would leak.

    @Test func duplicatingStoresACopyUnderAFreeName() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = vm.save(
            name: "web", values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")!

        let copy = vm.duplicateSession(template)

        #expect(copy?.name == "web 2")
        #expect(vm.sessions.map(\.name) == ["web", "web 2"])
        #expect(copy?.id != template.id)
    }

    /// The asymmetry the design calls the rule at work: a session that owns
    /// its password hands none of it over, so the copy asks once on its
    /// first connect.
    @Test func theCopyOfAPasswordSessionCarriesNoSecretOfItsOwn() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = vm.save(
            name: "web", values: sshValues(host: "h", port: 22, username: "u"),
            password: "p")!

        let copy = vm.duplicateSession(template)!

        let copyHasASecret = try secrets.password(for: copy.id) != nil
        #expect(!copyHasASecret, "the copy's own Keychain slot must be empty")
        let templateKeptItsSecret = try secrets.password(for: template.id) != nil
        #expect(templateKeptItsSecret, "duplicating must not disturb the template's slot")
    }

    /// The other half of the same rule: a session bound to a login set is
    /// complete the moment it is copied, because its credential never hung
    /// on the session at all.
    @Test func theCopyOfALoginSetSessionResolvesImmediately() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")
        let template = vm.save(
            name: "web", values: sshValues(host: "h", port: 22, username: "u"),
            password: "", loginSetID: set.id)!

        let copy = vm.duplicateSession(template)!

        #expect(copy.loginSetID == set.id)
        let copyHasItsOwnSlot = try secrets.password(for: copy.id) != nil
        #expect(!copyHasItsOwnSlot)
        let resolvedSecret = try vm.resolvedCredentials(for: copy)?[SSHField.password] ?? ""
        #expect(!resolvedSecret.isEmpty, "a set-bound copy resolves its credential from the set")
    }

    /// The slot a fresh session id says nothing about. A manual jump's
    /// secret lives under `JumpSpec.secretID`, and a copy that took that
    /// field over raw would read the template's Keychain entry while every
    /// other assertion in this suite stayed green.
    @Test func theCopyOfAJumpSessionReachesNoJumpSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = StoredSession.JumpSpec(host: "bastion", username: "hop")
        let template = vm.save(
            name: "web", values: sshValues(host: "h", port: 22, username: "u"),
            password: "p", jump: spec, jumpSecret: "hop-secret")!

        let copy = vm.duplicateSession(template)!

        let copySecretID = try #require(copy.jump?.secretID)
        #expect(copySecretID != spec.secretID)
        let copyReachesAJumpSecret = try secrets.password(for: copySecretID) != nil
        #expect(!copyReachesAJumpSecret, "the copy's jump slot must be empty")
        let templateKeptItsJumpSecret = try secrets.password(for: spec.secretID) != nil
        #expect(templateKeptItsJumpSecret, "duplicating must not disturb the template's jump slot")
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

/// Test double for a Keychain that answers for some ids and refuses others, so
/// a test can fail ONE member's read while the rest answer -- the difference
/// between "the whole keychain is locked" and "this one item's prompt was
/// denied", which the merge has to treat the same way but which a store failing
/// every read cannot express.
///
/// `failReads(for:)` is called AFTER `mergeCandidates()` has planned, which is
/// the real timeline: `LoginMergePlanner.candidates` reads first, a
/// confirmation dialog follows (`LoginSetsSheet.applyMerge`), and
/// `SessionListViewModel.applyMerge` reads again. `UnreliableSecretStore`
/// cannot express that -- its `failsReads` is fixed at init -- though only for
/// a `.credential`-role secret, which is the one the planner reads; under a
/// `.passphrase` role it plans without reading at all and a permanently failing
/// store would do just as well.
///
/// Writes and deletes keep working on purpose: a double that refused those too
/// would satisfy "nothing was deleted" by itself instead of letting the code
/// under test earn it. `storedIDs` is what checks that, mirroring
/// `InMemorySecretStore.storedIDs`.
private final class LockableReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private var failingIDs: Set<UUID> = []

    /// Every read for one of `ids` throws from here on; other ids still answer.
    func failReads(for ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        failingIDs = ids
    }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failingIDs.contains(sessionID) { throw KeychainError(status: -25308) }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }

    /// See `InMemorySecretStore.storedIDs`.
    var storedIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.keys)
    }
}

/// Test double proving a delete path never reads the keychain for the
/// deleted session's own secret: `password(for:)` fails the test if called at
/// all. Shared by two callers with different reasons to expect zero reads —
/// the agent-bastion restore path (M11a Task 2,
/// `deleteRestoresFromAgentBastionWithoutSecret`) and the non-SSH delete path
/// (M25/T1, `deletingANonSSHSessionNeverReadsTheKeychain`) — so the failure
/// message below names neither caller specifically; a regression in either
/// path should read as what it is instead of misattributing to the other.
/// `savePassword`/`deletePassword` behave like `InMemorySecretStore` so
/// unrelated calls (e.g. writing another session's own, non-agent secret)
/// still work normally.
private final class NoReadAllowedSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        Issue.record("this path must not read the keychain")
        return nil
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
