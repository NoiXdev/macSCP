import Foundation
import Testing
@testable import macSCPCore

/// Records which item names the decider was actually asked about, in order
/// (mirrors `DeciderCallLog` in `ImportConflictTests.swift` and
/// `LoginSetImportPlannerTests.swift`, duplicated per that established
/// convention so this suite has no cross-file dependency on it).
private actor DeciderCallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

/// Captures the `kindLabel` an `ImportConflict` carried, so a test can pin
/// the literal the planner sends without the app being able to see it
/// (Core has no UI language; the app maps this label to localized text).
private actor CapturedKindLabel {
    private(set) var value: String?
    func record(_ value: String) { self.value = value }
}

@Suite("SessionImportPlanner")
struct SessionImportPlannerTests {
    private func incoming(_ sessions: [ExportedSession], groups: [ExportedGroup] = []) -> SessionExportPayload {
        SessionExportPayload(includesSecrets: false, groups: groups, sessions: sessions)
    }

    private func exported(
        name: String = "s", host: String = "web-01", port: Int = 22,
        username: String = "root", groupID: UUID? = nil, password: String? = nil
    ) -> ExportedSession {
        ExportedSession(
            id: UUID(), name: name, host: host, port: port, username: username,
            authKind: .password, keyPath: nil, groupID: groupID, password: password)
    }

    /// Restores the pre-M19 behaviour with a single click: every duplicate is
    /// skipped, and the sticky rule means nothing further is asked. Every
    /// test that used to assert "duplicates are silently skipped" now passes
    /// this and keeps its original expectation.
    private var skipEverything: ImportConflictArbiter {
        ImportConflictArbiter { _ in (.skip, true) }
    }

    /// Fails the test if the planner asks about anything at all — used by the
    /// cases that must not produce a conflict in the first place.
    private var neverAsked: ImportConflictArbiter {
        ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil }
    }

    /// A decider that always returns the same fixed answer, logging every
    /// name it was asked about.
    private func fixedDecider(
        _ resolution: ImportConflictResolution, applyToAll: Bool = false, log: DeciderCallLog
    ) -> ImportConflictDecider {
        { conflict in
            await log.record(conflict.itemName)
            return (resolution, applyToAll)
        }
    }

    @Test func duplicateTripleIsSkippedDespiteDifferentName() async {
        let existing = [StoredSession(name: "anders", host: "WEB-01", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "neu", host: "web-01")]),
            arbiter: skipEverything)
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test func hostCaseAndPortDistinguishCorrectly() async {
        let existing = [StoredSession(name: "a", host: "web-01", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(host: "Web-01", port: 2222),     // other port -> import
                exported(host: "web-01", username: "deploy"), // other user -> import
            ]),
            arbiter: neverAsked)
        #expect(plan.sessionsToImport.count == 2)
        #expect(plan.skipped.isEmpty)
    }

    /// The duplicate key stays `(host, port, username)` — M19 only changed how
    /// a duplicate is HANDLED, not what counts as one. Two sessions sharing a
    /// name on different hosts are not a conflict and must never be asked
    /// about.
    @Test func sameNameOnDifferentHostsIsNotAConflict() async {
        let existing = [StoredSession(name: "web", host: "host-a", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web", host: "host-b")]),
            arbiter: neverAsked)
        #expect(plan.sessionsToImport.map(\.session.name) == ["web"])
        #expect(plan.skipped.isEmpty)
    }

    @Test func inFileDuplicatesKeepFirst() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "erste", host: "Host-A"),
                exported(name: "zweite", host: "host-a"),
            ]),
            arbiter: skipEverything)
        #expect(plan.sessionsToImport.map(\.session.name) == ["erste"])
        #expect(plan.skipped.map(\.name) == ["zweite"])
    }

    @Test func groupsMatchByNameOrGetCreatedFresh() async {
        let existingGroup = StoredGroup(name: "Prod")
        let fileGroupProd = ExportedGroup(id: UUID(), name: "Prod")
        let fileGroupNew = ExportedGroup(id: UUID(), name: "Staging")
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [existingGroup],
            incoming: incoming(
                [exported(name: "p", host: "h1", groupID: fileGroupProd.id),
                 exported(name: "s", host: "h2", groupID: fileGroupNew.id)],
                groups: [fileGroupProd, fileGroupNew]),
            arbiter: neverAsked)
        #expect(plan.groupsToCreate.map(\.name) == ["Staging"])
        let p = plan.sessionsToImport.first { $0.session.name == "p" }!
        let s = plan.sessionsToImport.first { $0.session.name == "s" }!
        #expect(p.session.groupID == existingGroup.id)          // matched by name
        #expect(s.session.groupID == plan.groupsToCreate[0].id) // fresh group
        #expect(plan.groupsToCreate[0].id != fileGroupNew.id)   // fresh id
    }

    @Test func importedSessionsGetFreshIDsAndCarryPasswords() async {
        let file = exported(password: "geheim")
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)
        #expect(plan.sessionsToImport[0].session.id != file.id)
        #expect(plan.sessionsToImport[0].password == "geheim")
    }

    @Test func unknownGroupReferenceFallsBackToNil() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(groupID: UUID())]), // group not in file
            arbiter: neverAsked)
        #expect(plan.sessionsToImport[0].session.groupID == nil)
    }

    /// M9a final review, Finding 2 (important): a file whose only sessions
    /// referencing a group are all skipped as duplicates must not create
    /// that group — otherwise "0 imported" still leaves a ghost group behind
    /// in the store.
    @Test func ghostGroupIsNotCreatedWhenAllItsSessionsAreDuplicates() async {
        let existing = [StoredSession(name: "a", host: "host", port: 22, username: "root")]
        let ghostGroup = ExportedGroup(id: UUID(), name: "GhostGroup")
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming(
                [exported(host: "host", port: 22, username: "root", groupID: ghostGroup.id)],
                groups: [ghostGroup]),
            arbiter: skipEverything)
        #expect(plan.groupsToCreate.isEmpty)
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    // MARK: - Conflict resolution (M19)

    @Test func conflictCarriesTheSessionNameAndTheStableKindLabel() async {
        let existing = [StoredSession(name: "stored-name", host: "host", username: "root")]
        let log = DeciderCallLog()
        let captured = CapturedKindLabel()
        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            await captured.record(conflict.kindLabel)
            return (.skip, false)
        }
        _ = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "file-name", host: "host")]),
            arbiter: arbiter)

        // The user sees the INCOMING session's name, not the triple.
        #expect(await log.names == ["file-name"])
        // A literal, not a reference to the constant: a typo in the planner's
        // `kindLabel` must fail this test rather than pass by both sides
        // drifting together.
        #expect(await captured.value == "session")
    }

    /// Everything else about the incoming item is trimmed before it is
    /// stored or reported; the conflict shown to the user must not be the
    /// one place a padded name leaks through.
    @Test func conflictCarriesTheTrimmedSessionName() async {
        let existing = [StoredSession(name: "stored-name", host: "host", username: "root")]
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, log: log))
        _ = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "  padded-name  ", host: "host")]),
            arbiter: arbiter)

        #expect(await log.names == ["padded-name"])
    }

    @Test func replaceKeepsTheExistingSessionID() async {
        let existing = [StoredSession(name: "old", host: "host", username: "root")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.replace, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "new", host: "host", password: "pw")]),
            arbiter: arbiter)

        #expect(plan.sessionsToImport.count == 1)
        // The id carries over so anything referencing the stored session
        // still points at it after `applyImport`'s upsert overwrites it.
        #expect(plan.sessionsToImport[0].session.id == existing[0].id)
        #expect(plan.sessionsToImport[0].session.name == "new")
        #expect(plan.sessionsToImport[0].password == "pw")
        // The applier's seam (M19 T6): true only when this planned session
        // actually overwrites an existing record.
        #expect(plan.sessionsToImport[0].replacesExisting)
        #expect(plan.replaced == ["new"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.renamed.isEmpty)
        #expect(!plan.cancelled)
    }

    /// `replacesExisting` must be false on every path that does NOT bind to
    /// an existing record: a fresh (non-colliding) import, and a `.rename`
    /// resolution that always mints a fresh id.
    @Test func freshAndRenamedSessionsAreNotMarkedAsReplacing() async {
        let fresh = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(name: "fresh", host: "host")]), arbiter: neverAsked)
        #expect(!fresh.sessionsToImport[0].replacesExisting)

        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let renamed = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web", host: "host")]),
            arbiter: ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog())))
        #expect(!renamed.sessionsToImport[0].replacesExisting)
    }

    @Test func renameGivesTheImportedSessionAUniqueNameAndFreshID() async {
        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let file = exported(name: "web", host: "host")
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([file]), arbiter: arbiter)

        #expect(plan.sessionsToImport.count == 1)
        let planned = plan.sessionsToImport[0].session
        #expect(planned.name != existing[0].name)
        #expect(planned.id != existing[0].id)
        #expect(planned.id != file.id)
        // Host/port/username are untouched — a renamed duplicate is a second
        // entry for the SAME endpoint, deliberately.
        #expect(planned.host == "host")
        #expect(planned.username == "root")
        #expect(plan.renamed == [planned.name])
        #expect(plan.replaced.isEmpty)
        #expect(plan.skipped.isEmpty)
    }

    /// Unlike the login-set planner (whose collision key IS the name), a
    /// session collides on `(host, port, username)`. A rename therefore only
    /// has to make the NAME unique: a name nothing else uses is kept as it
    /// stands instead of gaining a pointless " (2)".
    ///
    /// `renamed` reports actual renames only: since "free" was never in use,
    /// the stored name equals the file's trimmed name, so nothing was
    /// actually renamed and the summary must not claim otherwise.
    @Test func renameKeepsAnAlreadyFreeNameUnchanged() async {
        let existing = [StoredSession(name: "taken", host: "host", username: "root")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "free", host: "host")]),
            arbiter: arbiter)

        #expect(plan.sessionsToImport.map(\.session.name) == ["free"])
        #expect(plan.renamed.isEmpty)
    }

    /// A renamed session must not collide with a name committed earlier in
    /// the same run — the second rename has to skip past whatever the first
    /// one produced.
    @Test func renameStaysUniqueAcrossSeveralCollisionsInOneRun() async {
        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let arbiter = ImportConflictArbiter(
            decider: fixedDecider(.rename, applyToAll: true, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web", host: "host"), exported(name: "WEB", host: "host")]),
            arbiter: arbiter)

        #expect(plan.sessionsToImport.count == 2)
        let names = plan.sessionsToImport.map(\.session.name)
        // Compared under the planner's OWN name key (trimmed,
        // case-insensitive) — a case-sensitive comparison here would stay
        // green even if the two renames landed on "web (2)" and "WEB (2)",
        // which collide under the planner's actual matching rule.
        let normalized = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        #expect(normalized.count == 2)          // the renames differ from each other
        #expect(!normalized.contains("web"))    // and from the existing name
        #expect(Set(plan.renamed) == Set(names))
    }

    /// `SessionStore.upsert` matches on id, so two planned sessions carrying
    /// the same id would silently overwrite each other. An existing session
    /// may therefore be the target of a `replace` at most ONCE per run: the
    /// second incoming duplicate of the same triple must fall back to a fresh
    /// id under a unique name.
    @Test func replaceNeverBindsTwoIncomingSessionsToTheSameExistingID() async {
        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let arbiter = ImportConflictArbiter(
            decider: fixedDecider(.replace, applyToAll: true, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(name: "alpha", host: "host", password: "a"),
                exported(name: "beta", host: "host", password: "b"),
            ]),
            arbiter: arbiter)

        #expect(plan.sessionsToImport.count == 2)
        let ids = plan.sessionsToImport.map(\.session.id)
        #expect(Set(ids).count == 2)        // no two planned sessions share an id
        #expect(ids.contains(existing[0].id))  // the first collision still replaces the real record
        // Neither incoming session is silently dropped.
        #expect(Set(plan.sessionsToImport.compactMap(\.password)) == ["a", "b"])
        // Exactly one of them actually replaced something.
        #expect(plan.replaced == ["alpha"])
        // "beta" fell back to a fresh id, but nothing named "beta" was taken,
        // so its stored name equals the file's trimmed name -- not an actual
        // rename, and the summary must not claim one.
        #expect(plan.renamed.isEmpty)
        #expect(plan.sessionsToImport.first { $0.session.name == "beta" }?.replacesExisting == false)
    }

    /// The defensive fallback is reachable with an EMPTY store too: two
    /// sessions inside the same file share a triple and collide with each
    /// other, not with anything existing. A `.replace` decision then has
    /// nothing on record to replace — it must land in `renamed`, not
    /// `replaced`, since the summary UI reads those arrays.
    @Test func replaceOfAnInFileDuplicateWithNoExistingMatchFallsBackToRename() async {
        let arbiter = ImportConflictArbiter(
            decider: fixedDecider(.replace, applyToAll: true, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(name: "A", host: "host"), exported(name: "A", host: "host")]),
            arbiter: arbiter)

        #expect(plan.sessionsToImport.map(\.session.name) == ["A", "A (2)"])
        #expect(Set(plan.sessionsToImport.map(\.session.id)).count == 2)
        #expect(plan.renamed == ["A (2)"])
        #expect(plan.replaced.isEmpty)
    }

    @Test func applyToAllStopsAskingAndAppliesTheSameResolution() async {
        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, applyToAll: true, log: log))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "one", host: "host"), exported(name: "two", host: "host")]),
            arbiter: arbiter)

        #expect(plan.skipped.map(\.name) == ["one", "two"])
        #expect(plan.sessionsToImport.isEmpty)
        #expect(await log.names.count == 1)  // the second used the sticky rule, not a fresh ask
    }

    /// Cancelling applies NOTHING — including groups. The ghost-group
    /// invariant (M9a Finding 2) has to hold on this path too: a cancelled
    /// import must not leave a group behind for sessions that never landed.
    @Test func cancellingImportsNothingAndCreatesNoGroups() async {
        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let group = ExportedGroup(id: UUID(), name: "Prod")
        let arbiter = ImportConflictArbiter { _ in nil }
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming(
                [exported(name: "fresh", host: "other-host", groupID: group.id),
                 exported(name: "dupe", host: "host", groupID: group.id)],
                groups: [group]),
            arbiter: arbiter)

        #expect(plan.cancelled)
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.groupsToCreate.isEmpty)
        // Not even the session accepted BEFORE the cancelled conflict survives.
        #expect(plan.skipped.isEmpty)
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
    }

    /// The connection form trims on save (`ContentView.saveSession`), so
    /// import is the only path that could otherwise store a session name
    /// carrying whitespace the UI would never create — and the summary
    /// arrays must report exactly the name that was stored.
    @Test func namesAreTrimmedWhenStoredAndWhenReported() async {
        let plain = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(name: "  web  ")]), arbiter: neverAsked)
        #expect(plain.sessionsToImport[0].session.name == "web")

        let existing = [StoredSession(name: "web", host: "host", username: "root")]
        let replacing = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "  fresh  ", host: "host")]),
            arbiter: ImportConflictArbiter { _ in (.replace, true) })
        #expect(replacing.sessionsToImport[0].session.name == "fresh")
        #expect(replacing.replaced == ["fresh"])

        let renaming = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "  web  ", host: "host")]),
            arbiter: ImportConflictArbiter { _ in (.rename, true) })
        #expect(renaming.sessionsToImport[0].session.name == "web (2)")
        #expect(renaming.renamed == ["web (2)"])
    }

    // MARK: - Jump host fields (M10c)

    @Test func plannedSessionCarriesJumpFieldsWithFreshSecretID() async {
        let file = ExportedSession(
            id: UUID(), name: "web", host: "h", port: 22, username: "root",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            jumpHost: "bastion.example.com", jumpPort: 2222, jumpUsername: "jumper",
            jumpAuthKind: .privateKey, jumpKeyPath: "/k", jumpPassword: "jp")
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        let jump = planned.session.jump
        #expect(jump?.host == "bastion.example.com")
        #expect(jump?.port == 2222)
        #expect(jump?.username == "jumper")
        #expect(jump?.authKind == .privateKey)
        #expect(jump?.keyPath == "/k")
        // Sets are never imported -- a jump referencing one falls back to
        // manual mode with the resolved values baked into the spec.
        #expect(jump?.loginSetID == nil)
        #expect(planned.jumpPassword == "jp")
    }

    @Test func plannedSessionOmitsJumpWhenFileSessionHasNone() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([exported()]), arbiter: neverAsked)
        #expect(plan.sessionsToImport[0].session.jump == nil)
        #expect(plan.sessionsToImport[0].jumpPassword == nil)
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func plannedSessionCarriesAgentAuthKindThrough() async {
        let file = ExportedSession(
            id: UUID(), name: "web", host: "h", port: 22, username: "root",
            authKind: .agent, keyPath: nil, groupID: nil, password: nil,
            jumpHost: "bastion.example.com", jumpPort: 22, jumpUsername: "jumper",
            jumpAuthKind: .agent, jumpKeyPath: nil, jumpPassword: nil)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.authKind == .agent)
        #expect(planned.session.jump?.authKind == .agent)
        #expect(planned.password == nil)
        #expect(planned.jumpPassword == nil)
    }

    // MARK: - Connection kind + S3 (M12)

    @Test func s3FileSessionBuildsStoredS3ConfigAndCarriesSecretAsPassword() async {
        let file = ExportedSession(
            id: UUID(), name: "s3-prod", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            kind: .s3,
            s3AccessKeyID: "AKIAEXAMPLE", s3Region: "eu-central-1",
            s3Endpoint: "https://s3.eu-central-1.amazonaws.com", s3Bucket: "my-bucket",
            s3UsePathStyle: true, s3SecretAccessKey: "shh-secret")
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .s3)
        #expect(planned.session.s3 == StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
            usePathStyle: true))
        // The S3 secret travels in the SAME `password` slot the SSH secret
        // uses -- no separate PlannedSession field.
        #expect(planned.password == "shh-secret")
    }

    /// A file session with no `kind` at all (legacy, pre-M12) must import as
    /// `.ssh` with no S3 config, same as `StoredSession.kind`'s own default.
    @Test func fileSessionWithoutKindImportsAsSSH() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([exported()]), arbiter: neverAsked)
        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .ssh)
        #expect(planned.session.s3 == nil)
        // The same for WebDAV: no `webdav*` columns in the file means no
        // `StoredWebDAVConfig` on the planned session.
        #expect(planned.session.webdav == nil)
    }

    // MARK: - WebDAV (M23 fix — the planner never built a StoredWebDAVConfig)

    @Test func webdavFileSessionBuildsStoredWebDAVConfigAndCarriesSecretAsPassword() async {
        let file = ExportedSession(
            id: UUID(), name: "nextcloud", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: "dav-secret",
            kind: .webdav,
            webdavBaseURL: "https://dav.example.com", webdavUsername: "alice",
            webdavUseNextcloudPath: true)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .webdav)
        #expect(planned.session.webdav == StoredWebDAVConfig(
            baseURL: "https://dav.example.com", username: "alice", useNextcloudPath: true))
        // WebDAV's secret uses the shared `password` slot, like SSH's — there
        // is no separate WebDAV secret column, and none may be added.
        #expect(planned.password == "dav-secret")
    }

    /// A `.webdav` file entry from a PRE-FIX export carries no `webdav*`
    /// columns at all. It must still plan (kind preserved, no config), rather
    /// than crash or be silently retyped.
    @Test func webdavFileSessionWithoutColumnsKeepsKindAndHasNoConfig() async {
        let file = ExportedSession(
            id: UUID(), name: "nextcloud", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            kind: .webdav)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .webdav)
        #expect(planned.session.webdav == nil)
    }

    /// The replace path (M19) goes through the same `makePlanned` builder, so
    /// an overwritten record must land with its WebDAV config too — the field
    /// must not be dropped on one branch and carried on another.
    ///
    /// The two sessions are GENUINE duplicates: same `baseURL`, same WebDAV
    /// username. The fixture used to rely on both carrying the `"unused"`
    /// host/port/username placeholder, which made every non-SSH session in the
    /// world one duplicate key — the collision this test now avoids depending
    /// on. What it pins is unchanged: the replace branch carries `webdav`
    /// through `makePlanned`. The incoming entry differs in
    /// `useNextcloudPath`, so a dropped config could not pass as the stored
    /// one.
    @Test func replacedWebDAVSessionKeepsItsConfig() async {
        let existing = StoredSession(
            name: "old", host: "unused", username: "unused", kind: .webdav,
            webdav: StoredWebDAVConfig(
                baseURL: "https://dav.example.com", username: "alice",
                useNextcloudPath: false))
        let file = ExportedSession(
            id: UUID(), name: "new", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            kind: .webdav,
            webdavBaseURL: "https://dav.example.com", webdavUsername: "alice",
            webdavUseNextcloudPath: true)
        let plan = await SessionImportPlanner.plan(
            existing: [existing], existingGroups: [], incoming: incoming([file]),
            arbiter: ImportConflictArbiter { _ in (.replace, false) })

        let planned = plan.sessionsToImport[0]
        #expect(planned.replacesExisting)
        #expect(planned.session.id == existing.id)
        #expect(planned.session.webdav == StoredWebDAVConfig(
            baseURL: "https://dav.example.com", username: "alice", useNextcloudPath: true))
    }

    // MARK: - Kind-aware duplicate key

    /// Every S3 and WebDAV session stores the literal placeholder
    /// `host: "unused", port: 22, username: "unused"`, so an endpoint-triple
    /// key made all of them ONE duplicate. Three distinct WebDAV servers in a
    /// file used to arrive as one import plus two "skipped as duplicates".
    @Test func differentWebDAVServersAreNotDuplicates() async {
        let baseURLs: [String] = [
            "https://a.example.com", "https://b.example.com", "https://c.example.com",
        ]
        let files = baseURLs
            .map { baseURL in
                ExportedSession(
                    id: UUID(), name: "dav-\(baseURL)", host: "unused", port: 22,
                    username: "unused", authKind: .password, keyPath: nil, groupID: nil,
                    password: nil, kind: .webdav,
                    webdavBaseURL: baseURL, webdavUsername: "alice",
                    webdavUseNextcloudPath: false)
            }
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming(files), arbiter: neverAsked)

        #expect(plan.sessionsToImport.count == 3)
        #expect(plan.skipped.isEmpty)
    }

    /// The cross-backend case, and the destructive one: a stored S3 session
    /// and an incoming WebDAV session share nothing but the placeholders. A
    /// `Replace` here used to hand the S3 record's id to the WebDAV session —
    /// `upsert` overwrote it in place and the applier then dropped the S3
    /// secret under that reused id, destroying an unrelated connection.
    @Test func s3AndWebDAVSessionsDoNotCollide() async {
        let existing = StoredSession(
            name: "s3-prod", host: "unused", username: "unused", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: false))
        let file = ExportedSession(
            id: UUID(), name: "nextcloud", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            kind: .webdav,
            webdavBaseURL: "https://dav.example.com", webdavUsername: "alice",
            webdavUseNextcloudPath: false)
        let plan = await SessionImportPlanner.plan(
            existing: [existing], existingGroups: [], incoming: incoming([file]),
            arbiter: neverAsked)

        #expect(plan.sessionsToImport.count == 1)
        #expect(plan.sessionsToImport.first?.replacesExisting == false)
        #expect(plan.sessionsToImport.first?.session.id != existing.id)
    }

    /// Two S3 sessions are the same connection when endpoint, bucket AND
    /// access key match — the positive half of the S3 key, so the fix cannot
    /// be "never collide".
    @Test func identicalS3EndpointBucketAndKeyStillCollide() async {
        let existing = StoredSession(
            name: "s3-prod", host: "unused", username: "unused", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: false))
        let file = ExportedSession(
            id: UUID(), name: "s3-prod-copy", host: "unused", port: 22, username: "unused",
            authKind: .password, keyPath: nil, groupID: nil, password: nil,
            kind: .s3,
            s3AccessKeyID: "AKIAEXAMPLE", s3Region: "us-east-1",  // region is not part of the key
            s3Endpoint: "https://s3.eu-central-1.amazonaws.com", s3Bucket: "my-bucket",
            s3UsePathStyle: true)
        let plan = await SessionImportPlanner.plan(
            existing: [existing], existingGroups: [], incoming: incoming([file]),
            arbiter: skipEverything)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    /// SSH semantics must not shift: the endpoint triple still is the key,
    /// against the store and within one file.
    @Test func identicalSSHEndpointsStillCollide() async {
        let existing = [StoredSession(name: "web", host: "web-01", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web-copy"), exported(name: "web-copy-2")]),
            arbiter: skipEverything)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 2)
    }
}
