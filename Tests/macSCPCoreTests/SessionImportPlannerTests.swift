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

/// Captures the whole `ImportConflict` a decider was handed, so a test can
/// assert on its `reason` — the capturing-decider shape this file and
/// `LoginSetImportPlannerTests.swift` already use for `DeciderCallLog`/
/// `CapturedKindLabel`, reused here rather than invented anew (M23/P3 T3).
private actor CapturedConflict {
    private(set) var value: ImportConflict?
    func record(_ value: ImportConflict) { self.value = value }
}

/// The plural sibling of `CapturedConflict`: every conflict a decider was
/// handed, in order — needed when a single run raises more than one
/// conflict and a test must pin what EACH one named, not just the last.
private actor CapturedConflicts {
    private(set) var values: [ImportConflict] = []
    func record(_ value: ImportConflict) { values.append(value) }
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
            id: UUID(), name: name, kind: .ssh,
            fields: sshExportFields(host: host, port: port, username: username),
            groupID: groupID, password: password)
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
        let existing = [sshSession(name: "anders", host: "WEB-01", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "neu", host: "web-01")]),
            arbiter: skipEverything)
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test func hostCaseAndPortDistinguishCorrectly() async {
        let existing = [sshSession(name: "a", host: "web-01", username: "root")]
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
        let existing = [sshSession(name: "web", host: "host-a", username: "root")]
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
        let existing = [sshSession(name: "a", host: "host", port: 22, username: "root")]
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
        let existing = [sshSession(name: "stored-name", host: "host", username: "root")]
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
        let existing = [sshSession(name: "stored-name", host: "host", username: "root")]
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, log: log))
        _ = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "  padded-name  ", host: "host")]),
            arbiter: arbiter)

        #expect(await log.names == ["padded-name"])
    }

    /// The defect this milestone fixes: a session collides on the
    /// CONNECTION, not the name (`SessionImportPlanner` keys on
    /// `duplicateKey`, the endpoint) — unlike a login set, which collides on
    /// its name. The conflict must say so via `.sameConnection`, naming the
    /// STORED session's own display summary — the same one-line identity the
    /// sidebar uses — rather than leaving the caller to assume, as the old
    /// shared "name already exists" message did, that a name collided.
    @Test func aSessionConflictReportsTheConnectionItCollidedWith() async {
        let existing = [sshSession(name: "prod", host: "prod.example.com", port: 2222, username: "deploy")]
        let captured = CapturedConflict()
        let arbiter = ImportConflictArbiter { conflict in
            await captured.record(conflict)
            return (.skip, false)
        }
        _ = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(name: "Backup Server", host: "prod.example.com", port: 2222, username: "deploy"),
            ]),
            arbiter: arbiter)

        #expect(await captured.value?.reason == .sameConnection(existing: "deploy@prod.example.com:2222"))
    }

    @Test func replaceKeepsTheExistingSessionID() async {
        let existing = [sshSession(name: "old", host: "host", username: "root")]
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

        let existing = [sshSession(name: "web", host: "host", username: "root")]
        let renamed = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web", host: "host")]),
            arbiter: ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog())))
        #expect(!renamed.sessionsToImport[0].replacesExisting)
    }

    @Test func renameGivesTheImportedSessionAUniqueNameAndFreshID() async {
        let existing = [sshSession(name: "web", host: "host", username: "root")]
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
        #expect(planned.ssh?.host == "host")
        #expect(planned.ssh?.username == "root")
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
        let existing = [sshSession(name: "taken", host: "host", username: "root")]
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
        let existing = [sshSession(name: "web", host: "host", username: "root")]
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
        let existing = [sshSession(name: "web", host: "host", username: "root")]
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
        let existing = [sshSession(name: "web", host: "host", username: "root")]
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
        let existing = [sshSession(name: "web", host: "host", username: "root")]
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

        let existing = [sshSession(name: "web", host: "host", username: "root")]
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
            id: UUID(), name: "web", kind: .ssh,
            fields: sshExportFields(host: "h", username: "root"),
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
            id: UUID(), name: "web", kind: .ssh,
            fields: sshExportFields(host: "h", username: "root", authKind: .agent),
            jumpHost: "bastion.example.com", jumpPort: 22, jumpUsername: "jumper",
            jumpAuthKind: .agent)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.ssh?.authKind == .agent)
        #expect(planned.session.jump?.authKind == .agent)
        #expect(planned.password == nil)
        #expect(planned.jumpPassword == nil)
    }

    // MARK: - Connection kind + S3 (M12)

    @Test func s3FileSessionBuildsStoredS3ConfigAndCarriesSecretAsPassword() async {
        let file = ExportedSession(
            id: UUID(), name: "s3-prod", kind: .s3,
            fields: s3ExportFields(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: true),
            s3SecretAccessKey: "shh-secret")
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
    /// `kind` is passed as nil ON PURPOSE — the shared `exported(...)` helper
    /// writes `.ssh`, which would make this test pass without ever exercising
    /// the default.
    @Test func fileSessionWithoutKindImportsAsSSH() async {
        let file = ExportedSession(
            id: UUID(), name: "web", kind: nil,
            fields: sshExportFields(host: "h", username: "root"))
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)
        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .ssh)
        #expect(planned.session.ssh?.host == "h")
        #expect(planned.session.s3 == nil)
        // The same for WebDAV: no WebDAV keys in the bag means no
        // `StoredWebDAVConfig` on the planned session.
        #expect(planned.session.webdav == nil)
    }

    /// A file session with no `paneVisibility` at all (legacy, pre-Task-4)
    /// must import as `.bothVisible`, the same default `StoredSession.
    /// paneVisibility` itself falls back to. `paneVisibility` is left nil ON
    /// PURPOSE, mirroring `fileSessionWithoutKindImportsAsSSH` above: a
    /// helper that filled in `.bothVisible` for every fixture would let this
    /// pass without ever exercising `makePlanned`'s `?? .bothVisible` fallback.
    @Test func fileSessionWithoutPaneVisibilityImportsAsBothVisible() async {
        let file = ExportedSession(
            id: UUID(), name: "web", kind: .ssh,
            fields: sshExportFields(host: "h", username: "root"))
        #expect(file.paneVisibility == nil)

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.paneVisibility == .bothVisible)
    }

    /// A file session that DOES carry a recorded preference imports with it
    /// intact rather than falling back to the default.
    @Test func fileSessionWithPaneVisibilityImportsItVerbatim() async {
        let file = ExportedSession(
            id: UUID(), name: "web", kind: .ssh,
            fields: sshExportFields(host: "h", username: "root"),
            paneVisibility: PaneVisibility(showsFiles: false, showsTerminal: true))

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.paneVisibility == PaneVisibility(showsFiles: false, showsTerminal: true))
    }

    // MARK: - WebDAV (M23 fix — the planner never built a StoredWebDAVConfig)

    @Test func webdavFileSessionBuildsStoredWebDAVConfigAndCarriesSecretAsPassword() async {
        let file = ExportedSession(
            id: UUID(), name: "nextcloud", kind: .webdav,
            fields: webdavExportFields(
                baseURL: "https://dav.example.com", username: "alice",
                useNextcloudPath: true),
            password: "dav-secret")
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
        let file = ExportedSession(id: UUID(), name: "nextcloud", kind: .webdav)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        let planned = plan.sessionsToImport[0]
        #expect(planned.session.kind == .webdav)
        #expect(planned.session.webdav == nil)
    }

    // MARK: - Blockless `.ssh` entries (M27)

    /// The mirror image of the WebDAV case above: an `.ssh` entry with an
    /// empty bag builds a record `SessionStore.load()` removes on sight, so
    /// planning it would promise the user an import that cannot survive the
    /// very next store read. It is rejected instead of planned.
    @Test func blocklessSSHFileSessionIsRejectedInsteadOfPlanned() async {
        // Untrimmed on purpose: `rejected` promises trimmed names (see its
        // doc comment on `SessionImportPlan`) the same as `replaced` and
        // `renamed` do, and nothing else in this suite feeds a name with
        // surrounding whitespace through the rejection path.
        let file = ExportedSession(id: UUID(), name: "  ghost  ", kind: .ssh, fields: [:])
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]), arbiter: neverAsked)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.rejected == ["ghost"])
        #expect(plan.skipped.isEmpty)
    }

    /// The M23 precedent, pinned: one unusable entry is reported and skipped,
    /// it does not fail the file around it. This is the test that goes red if
    /// anyone later turns the rejection into a whole-file verdict.
    @Test func oneRejectedEntryDoesNotStopTheRestOfTheFile() async {
        let files = [
            exported(name: "good-1", host: "host-a"),
            ExportedSession(id: UUID(), name: "broken", kind: .ssh, fields: [:]),
            exported(name: "good-2", host: "host-b"),
        ]
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming(files), arbiter: neverAsked)

        #expect(plan.sessionsToImport.map(\.session.name) == ["good-1", "good-2"])
        #expect(plan.rejected == ["broken"])
    }

    /// A rejected entry is not a conflict, so it must not establish a
    /// duplicate key either: two blockless entries in one file would
    /// otherwise collide with each other and put a decision to the user about
    /// a session nobody can import. `neverAsked` fails the test if the
    /// decider is consulted at all.
    @Test func rejectedEntriesNeverReachTheArbiter() async {
        // Named so file order and alphabetical order disagree: `rejected`'s
        // doc comment on `SessionImportPlan` promises file order, and an
        // implementation that instead SORTED the array would still pass an
        // alphabetically-ordered fixture. "zeta" before "alpha" makes a
        // sorting implementation produce `["alpha", "zeta"]` here and fail.
        let files = [
            ExportedSession(id: UUID(), name: "zeta", kind: .ssh, fields: [:]),
            ExportedSession(id: UUID(), name: "alpha", kind: .ssh, fields: [:]),
        ]
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming(files), arbiter: neverAsked)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.rejected == ["zeta", "alpha"])
    }

    /// Same rule the skipped-duplicate case already obeys: a group nothing
    /// imported references must not be created. Pinned at the new branch too,
    /// so a rejected entry cannot leave a ghost group behind.
    @Test func groupReferencedOnlyByARejectedEntryIsNotCreated() async {
        let fileGroup = ExportedGroup(id: UUID(), name: "Staging")
        let file = ExportedSession(
            id: UUID(), name: "broken", kind: .ssh, fields: [:], groupID: fileGroup.id)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([file], groups: [fileGroup]), arbiter: neverAsked)

        #expect(plan.groupsToCreate.isEmpty)
        #expect(plan.rejected == ["broken"])
    }

    /// The coupling this whole M27 fix exists to create, pinned directly
    /// rather than only implied by the rejection tests above: nothing the
    /// planner ever puts into `sessionsToImport` may satisfy
    /// `SessionStore.dropsOnLoad` — an entry that did would be reported as
    /// imported and then vanish on the very next store read, the exact
    /// defect this fix closed. If the rejection guard and the store's own
    /// load-time rule ever drift apart again (say, a later change adds a
    /// second condition straight into `SessionStore.load()`'s `removeAll`
    /// instead of folding it into `dropsOnLoad`), an entry the store would
    /// actually drop could once again reach `sessionsToImport` unrejected;
    /// this loop is what turns that red.
    ///
    /// Deliberately mixes FOUR outcomes in one run — unchanged import,
    /// replace, the replace-with-nothing-left-to-replace fallback that
    /// renames instead, and an outright rejection — so the invariant is
    /// checked against three separate `makePlanned` call sites at once, not
    /// only the single shape the rejection tests above already cover.
    @Test func nothingThePlannerAcceptsWouldBeDroppedOnTheNextLoad() async {
        let existing = [sshSession(name: "kept", host: "host-r", username: "root")]
        let arbiter = ImportConflictArbiter(
            decider: fixedDecider(.replace, applyToAll: true, log: DeciderCallLog()))
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(name: "fresh", host: "host-u"),
                exported(name: "kept", host: "host-r"),
                exported(name: "kept", host: "host-r"),
                ExportedSession(id: UUID(), name: "ghost", kind: .ssh, fields: [:]),
            ]),
            arbiter: arbiter)

        // Sanity on the mix itself: if these stop matching, the loop below
        // is no longer exercising the four paths this test is named for.
        #expect(plan.sessionsToImport.count == 3)
        #expect(plan.replaced == ["kept"])
        #expect(plan.renamed == ["kept (2)"])
        #expect(plan.rejected == ["ghost"])

        for planned in plan.sessionsToImport {
            #expect(!SessionStore.dropsOnLoad(planned.session))
        }
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
        let existing = webdavSession(
            name: "old",
            config: StoredWebDAVConfig(
                baseURL: "https://dav.example.com", username: "alice",
                useNextcloudPath: false))
        let file = ExportedSession(
            id: UUID(), name: "new", kind: .webdav,
            fields: webdavExportFields(
                baseURL: "https://dav.example.com", username: "alice",
                useNextcloudPath: true))
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
                    id: UUID(), name: "dav-\(baseURL)", kind: .webdav,
                    fields: webdavExportFields(baseURL: baseURL, username: "alice"))
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
        let existing = s3Session(
            name: "s3-prod",
            config: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: false))
        let file = ExportedSession(
            id: UUID(), name: "nextcloud", kind: .webdav,
            fields: webdavExportFields(
                baseURL: "https://dav.example.com", username: "alice"))
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
        let existing = s3Session(
            name: "s3-prod",
            config: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: false))
        let file = ExportedSession(
            id: UUID(), name: "s3-prod-copy", kind: .s3,
            fields: s3ExportFields(
                accessKeyID: "AKIAEXAMPLE",
                region: "us-east-1",  // region is not part of the key
                endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                usePathStyle: true))
        let plan = await SessionImportPlanner.plan(
            existing: [existing], existingGroups: [], incoming: incoming([file]),
            arbiter: skipEverything)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    /// SSH semantics must not shift: the endpoint triple still is the key,
    /// against the store and within one file.
    @Test func identicalSSHEndpointsStillCollide() async {
        let existing = [sshSession(name: "web", host: "web-01", username: "root")]
        let plan = await SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "web-copy"), exported(name: "web-copy-2")]),
            arbiter: skipEverything)

        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 2)
    }

    // MARK: - The identity rule, once it is DECLARED (M23/P3 T2)
    //
    // `duplicateKey` used to answer "which fields make a connection distinct"
    // with a `switch kind` of its own — the last compile-forcing
    // `ConnectionKind` site outside `BackendDescriptor`. The answer now comes
    // from `ConnectionField.identity`, so each backend states it once, next to
    // the field it is about.
    //
    // These five pin the rules the old switch's doc comment recorded, one test
    // each. They are CHARACTERIZATION tests: every one of them passes against
    // the old switch too, and that is the point — the rules must survive the
    // move. What they catch is the plausible ways a declaration-driven key can
    // get the answer wrong, each verified by mutating the implementation and
    // watching exactly the named test go red:
    //
    //   mark every field identifying      -> pathStyle case fails
    //   fold case on every field          -> bucket-case case fails
    //   drop the kind prefix              -> S3-vs-WebDAV case fails
    //   drop `port` from SSH's identity   -> different-port case fails
    //   fold no case at all               -> same-SSH-endpoint case fails
    //
    // `duplicateKey` is private, so all of them go through `plan(...)`.

    /// The positive half for SSH, and the one that must not shift: the name is
    /// not the key, the endpoint triple is. Sharper than
    /// `identicalSSHEndpointsStillCollide` above in two respects — it pins that
    /// exactly the SECOND entry is the one put to the user, by the name it was
    /// asked about, and it varies the host's CASE, so a key that stopped
    /// folding the host would fail here.
    @Test func twoSessionsToTheSameSSHEndpointCollide() async {
        let log = DeciderCallLog()
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "web", host: "web-01", port: 22, username: "root"),
                exported(name: "web-again", host: "WEB-01", port: 22, username: "root"),
            ]),
            arbiter: ImportConflictArbiter(decider: fixedDecider(.skip, log: log)))

        #expect(plan.sessionsToImport.map(\.session.name) == ["web"])
        #expect(plan.skipped.map(\.name) == ["web-again"])
        #expect(await log.names == ["web-again"])
    }

    /// THREE entries colliding on one key in a single run — what
    /// `twoSessionsToTheSameSSHEndpointCollide` cannot exercise with only
    /// two. `summaryByKey` is meant to be written ONCE per key, the moment
    /// the first entry claims it (`SessionImportPlanner.plan`'s `guard let
    /// collidingSummary = summaryByKey[key] else { summaryByKey[key] = ... }`
    /// branch) — a skipped duplicate must never overwrite it. Pins that BOTH
    /// the second and the third conflict name the FIRST entry ("first"), not
    /// whichever entry was seen most recently: a planner that wrote
    /// `summaryByKey[key]` on every accepted-OR-skipped entry (not only the
    /// first) would still pass `twoSessionsToTheSameSSHEndpointCollide` —
    /// there is no third entry there to observe the drift — but would make
    /// the third conflict here name "second" instead of "first". That is
    /// exactly the mutation a full run of this suite left undetected before
    /// this test existed.
    ///
    /// The host's case is varied per entry (`web-01` / `WEB-01` / `Web-01`,
    /// same trick as the two-session test above) so the three entries'
    /// display summaries — `SSHFieldSchema.displaySummary`, built from the
    /// VERBATIM host — are textually distinct from each other even though
    /// their case-folded identity key is the same. Without that, all three
    /// summaries would read identically and the test could not tell "names
    /// the first entry" apart from "names the second entry" at all.
    @Test func threeSessionsToTheSameSSHEndpointCollideAllNameTheFirst() async {
        let conflicts = CapturedConflicts()
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "first", host: "web-01", port: 22, username: "root"),
                exported(name: "second", host: "WEB-01", port: 22, username: "root"),
                exported(name: "third", host: "Web-01", port: 22, username: "root"),
            ]),
            arbiter: ImportConflictArbiter { conflict in
                await conflicts.record(conflict)
                return (.skip, false)
            })

        #expect(plan.sessionsToImport.map(\.session.name) == ["first"])
        #expect(plan.skipped.map(\.name) == ["second", "third"])

        // The first entry's own display summary -- verbatim host, so it is
        // "root@web-01", never "root@WEB-01" or "root@Web-01".
        let firstEntrysSummary = "root@web-01"
        #expect(
            await conflicts.values
                == [
                    ImportConflict(
                        itemName: "second", kindLabel: SessionImportPlanner.kindLabel,
                        reason: .sameConnection(existing: firstEntrysSummary)),
                    // The intended answer: still the FIRST entry, not
                    // "second" -- "second" was skipped, so it never claimed
                    // `summaryByKey`, and the connection this third entry
                    // collides with is, and has only ever been, the first
                    // one accepted.
                    ImportConflict(
                        itemName: "third", kindLabel: SessionImportPlanner.kindLabel,
                        reason: .sameConnection(existing: firstEntrysSummary)),
                ])
    }

    /// The port is part of SSH's identity, not decoration: a bastion reached
    /// on 2222 is a different connection from the box on 22, even under the
    /// same host and user name.
    @Test func aDifferentPortIsADifferentConnection() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "direct", host: "web-01", port: 22, username: "root"),
                exported(name: "forwarded", host: "web-01", port: 2222, username: "root"),
            ]),
            arbiter: neverAsked)

        #expect(plan.sessionsToImport.map(\.session.name) == ["direct", "forwarded"])
        #expect(plan.skipped.isEmpty)
    }

    /// Keys are KIND-PREFIXED, so two backends can never share one.
    ///
    /// The values are contrived so that the two renderings would be
    /// character-for-character IDENTICAL without that prefix: S3 contributes
    /// endpoint + bucket + access key, WebDAV contributes base URL + user
    /// name, and a `|` inside the WebDAV user name lines the two up exactly.
    /// Contrived, but deliberately so — with ordinary values this test would
    /// pass whether or not the prefix existed, which is the kind of test that
    /// proves nothing.
    @Test func anS3AndAWebDAVSessionNeverShareAKey() async {
        let sharedURL = "https://shared.example.com"
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                ExportedSession(
                    id: UUID(), name: "s3", kind: .s3,
                    fields: s3ExportFields(
                        accessKeyID: "AKIAEXAMPLE", endpoint: sharedURL, bucket: "alice")),
                ExportedSession(
                    id: UUID(), name: "dav", kind: .webdav,
                    fields: webdavExportFields(
                        baseURL: sharedURL, username: "alice|AKIAEXAMPLE")),
            ]),
            arbiter: neverAsked)

        #expect(plan.sessionsToImport.map(\.session.name) == ["s3", "dav"])
        #expect(plan.skipped.isEmpty)
    }

    /// Identifying values go into the key VERBATIM, with the single exception
    /// the test above pins. A bucket name and a URL path are case-SENSITIVE,
    /// and so is an access key ID; folding them would merge two genuinely
    /// different buckets into one import plus one silent duplicate.
    @Test func caseIsNotFoldedInABucketNameOrAURLPath() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                ExportedSession(
                    id: UUID(), name: "lower", kind: .s3,
                    fields: s3ExportFields(bucket: "archive")),
                ExportedSession(
                    id: UUID(), name: "upper", kind: .s3,
                    fields: s3ExportFields(bucket: "Archive")),
            ]),
            arbiter: neverAsked)

        #expect(plan.sessionsToImport.map(\.session.name) == ["lower", "upper"])
        #expect(plan.skipped.isEmpty)
    }

    /// Identity is a DECLARED subset of the fields, not all of them.
    /// `usePathStyle` is how a client addresses the bucket, not which bucket
    /// it is — two sessions differing only in it are one connection reached
    /// two ways, and the user must be asked rather than handed a silent second
    /// copy. `identicalS3EndpointBucketAndKeyStillCollide` above varies the
    /// region alongside it; this one isolates the toggle, so a key built from
    /// every field is caught here even if `region` were ever added to the
    /// identity.
    @Test func twoS3SessionsDifferingOnlyInPathStyleCollide() async {
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                ExportedSession(
                    id: UUID(), name: "virtual-host", kind: .s3,
                    fields: s3ExportFields(usePathStyle: false)),
                ExportedSession(
                    id: UUID(), name: "path-style", kind: .s3,
                    fields: s3ExportFields(usePathStyle: true)),
            ]),
            arbiter: skipEverything)

        #expect(plan.sessionsToImport.map(\.session.name) == ["virtual-host"])
        #expect(plan.skipped.map(\.name) == ["path-style"])
    }

    // MARK: - What a v1 import does DIFFERENTLY since the bag (M23/P3)
    //
    // Two behaviour changes fall out of routing v1's columns through
    // `SSHFieldSchema.apply` instead of copying them onto `StoredSSHConfig`
    // verbatim. Both were judged correct and kept; these tests exist so that
    // "kept" is a decision on record rather than something a later reader has
    // to rediscover by diffing against `c692dc8`.

    /// Decodes a v1 SSH entry written with the given raw column values —
    /// the real file shape, so these tests exercise the whole
    /// decode -> upgrade -> plan chain rather than `apply` alone.
    private func planFromV1SSHEntry(
        columns: String
    ) async throws -> (bag: [String: String], session: StoredSession) {
        let raw = Data("""
        {"format":"macscp-sessions","version":1,"encrypted":false,"payload":\
        {"includesSecrets":false,"groups":[],"sessions":[\
        {"id":"\(UUID().uuidString)","name":"web",\(columns)}]}}
        """.utf8)
        let decoded = try SessionExportCodec.decode(raw)
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded, arbiter: neverAsked)
        return (decoded.sessions[0].fields, plan.sessionsToImport[0].session)
    }

    /// v1 took host and user name verbatim; the bag routes them through
    /// `SSHFieldSchema.apply`, which trims. Kept deliberately: the planner
    /// keys `.ssh` duplicates on the host/port/user triple byte for byte, so
    /// an untrimmed host would re-import as a silent duplicate instead of
    /// raising the conflict the user should be offered.
    @Test func aV1PayloadsUntrimmedHostAndUsernameAreTrimmedOnImport() async throws {
        let (bag, session) = try await planFromV1SSHEntry(columns: """
        "host":"  h.example.com  ","port":22,"username":"  deploy  ",\
        "authKind":"password"
        """)

        // The upgrade is FAITHFUL — it hands the columns over byte for byte,
        // spaces and all. Asserting this first is what stops the two
        // expectations below from passing vacuously against a value that was
        // never untrimmed to begin with.
        #expect(bag["SSHField.host"] == "  h.example.com  ")
        #expect(bag["SSHField.username"] == "  deploy  ")

        // The trim happens where every other write goes through it.
        #expect(session.ssh?.host == "h.example.com")
        #expect(session.ssh?.username == "deploy")
    }

    /// v1 copied `keyPath` across whatever the auth kind was; `apply` clears
    /// it unless auth is `.privateKey`. Reachable for a session a pre-M23
    /// build saved after switching from key to password auth without clearing
    /// the stale path — the exact case `apply`'s doc comment describes. Kept:
    /// the value is inert (only ever read under private-key auth), and
    /// dropping it on import is the same cleanup a re-save would do.
    @Test func aV1PayloadsStaleKeyPathIsDroppedUnderPasswordAuth() async throws {
        let (bag, session) = try await planFromV1SSHEntry(columns: """
        "host":"h","port":22,"username":"u","authKind":"password",\
        "keyPath":"/legacy/key"
        """)

        // Again: the bag carries the path, so the drop below is `apply`'s
        // doing and not a column the upgrade quietly failed to read.
        #expect(bag["SSHField.keyPath"] == "/legacy/key")
        #expect(session.ssh?.authKind == .password)
        #expect(session.keyPath == nil)
    }

    /// The other half of the pair: under private-key auth the very same
    /// column still arrives intact, so the test above is pinning the auth-kind
    /// rule and not a blanket "key paths are dropped".
    @Test func aV1PayloadsKeyPathSurvivesUnderPrivateKeyAuth() async throws {
        let (_, session) = try await planFromV1SSHEntry(columns: """
        "host":"h","port":22,"username":"u","authKind":"privateKey",\
        "keyPath":"/legacy/key"
        """)

        #expect(session.keyPath == "/legacy/key")
    }
}
