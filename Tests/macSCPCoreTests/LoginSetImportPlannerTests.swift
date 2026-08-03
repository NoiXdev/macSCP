import Foundation
import Testing
@testable import macSCPCore

/// Records which item names the decider was actually asked about, in order
/// (mirrors `DeciderCallLog` in `ImportConflictTests.swift`, duplicated per
/// that file's established convention so this suite has no cross-file
/// dependency on it).
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

@Suite("LoginSetImportPlanner")
struct LoginSetImportPlannerTests {
    private func fileSet(
        name: String = "Prod", username: String = "root",
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil,
        kind: ConnectionKind = .ssh, accessKeyID: String? = nil,
        secret: String? = nil, embeddedKey: EmbeddedKey? = nil
    ) -> ExportedLoginSet {
        ExportedLoginSet(
            id: UUID(), name: name, kind: kind, username: username, authKind: authKind,
            keyPath: keyPath, accessKeyID: accessKeyID, secret: secret, embeddedKey: embeddedKey)
    }

    private func payload(
        _ sets: [ExportedLoginSet], includesSecrets: Bool = false, includesKeyFiles: Bool = false
    ) -> LoginSetExportPayload {
        LoginSetExportPayload(includesSecrets: includesSecrets, includesKeyFiles: includesKeyFiles, sets: sets)
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

    @Test func importsNonCollidingSetsUnchanged() async {
        let existing = [LoginSet(name: "Staging", username: "deploy")]
        let arbiter = ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil }
        let plan = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "Prod")]), arbiter: arbiter)

        #expect(plan.setsToImport.count == 1)
        #expect(plan.setsToImport[0].set.name == "Prod")
        #expect(plan.skipped.isEmpty)
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
        #expect(!plan.cancelled)
    }

    @Test func detectsCollisionsByTrimmedCaseInsensitiveName() async {
        let existing = [LoginSet(name: "  Prod  ", username: "root")]
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, log: log))
        _ = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "PROD")]), arbiter: arbiter)

        #expect(await log.names == ["PROD"])
    }

    @Test func skipDropsTheIncomingSet() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "Prod")]), arbiter: arbiter)

        #expect(plan.setsToImport.isEmpty)
        #expect(plan.skipped == ["Prod"])
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
    }

    @Test func replaceKeepsTheExistingIDSoReferencingSessionsStillPoint() async {
        let existing = [LoginSet(name: "Prod", username: "old-user")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.replace, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "Prod", username: "new-user")]),
            arbiter: arbiter)

        #expect(plan.setsToImport.count == 1)
        #expect(plan.setsToImport[0].set.id == existing[0].id)
        #expect(plan.setsToImport[0].set.username == "new-user")
        #expect(plan.setsToImport[0].replacesExisting)
        #expect(plan.replaced == ["Prod"])
    }

    @Test func renameGivesAUniqueNameAndAFreshID() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let incomingID = UUID()
        let incomingSet = ExportedLoginSet(
            id: incomingID, name: "Prod", kind: .ssh, username: "root", authKind: .password,
            keyPath: nil, accessKeyID: nil, secret: nil, embeddedKey: nil)
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([incomingSet]), arbiter: arbiter)

        #expect(plan.setsToImport.count == 1)
        #expect(plan.setsToImport[0].set.name != existing[0].name)
        #expect(plan.setsToImport[0].set.id != incomingID)
        #expect(plan.setsToImport[0].set.id != existing[0].id)
        #expect(!plan.setsToImport[0].replacesExisting)
        #expect(plan.renamed == [plan.setsToImport[0].set.name])
    }

    /// A renamed set must not collide with a set renamed earlier in the same
    /// run — the second collision has to skip past whatever name the first
    /// rename produced.
    @Test func renameStaysUniqueAcrossSeveralCollisionsInOneRun() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.rename, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing,
            incoming: payload([fileSet(name: "Prod"), fileSet(name: "prod")]),
            arbiter: arbiter)

        #expect(plan.setsToImport.count == 2)
        let names = plan.setsToImport.map(\.set.name)
        // Compared under the planner's OWN collision key (trimmed,
        // case-insensitive) — a case-sensitive comparison here would stay
        // green even if both renames landed on "Prod (2)" vs "prod (2)",
        // which collide under the planner's actual matching rule.
        let normalizedNames = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        #expect(normalizedNames.count == 2)   // the two renames differ from each other
        #expect(!normalizedNames.contains("prod"))  // and from the existing name
        #expect(plan.renamed.count == 2)
        #expect(Set(plan.renamed) == Set(names))
    }

    /// Names are never enforced unique in the store (`LoginSetsSheet` only
    /// checks non-empty), so an export can legitimately contain "Prod" and
    /// "prod" — two DIFFERENT incoming sets that both collide, under
    /// case-insensitive matching, with the SAME existing set. Both cannot be
    /// bound to that existing set's id: the second must fall back to a
    /// fresh id under a unique name instead of silently overwriting whatever
    /// the first one just wrote.
    @Test func replaceNeverBindsTwoIncomingSetsToTheSameExistingID() async {
        let existingID = UUID()
        let existing = [LoginSet(id: existingID, name: "Prod", username: "old-user")]
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.replace, applyToAll: true, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing,
            incoming: payload([fileSet(name: "Prod", username: "alice"), fileSet(name: "prod", username: "bob")]),
            arbiter: arbiter)

        #expect(plan.setsToImport.count == 2)
        let ids = plan.setsToImport.map(\.set.id)
        #expect(Set(ids).count == 2)  // no two planned sets may share an id
        #expect(ids.contains(existingID))  // the first collision still replaces the real set

        let usernames = Set(plan.setsToImport.map(\.set.username))
        #expect(usernames == ["alice", "bob"])  // neither incoming set is silently dropped

        // Exactly one planned set actually replaces the existing record; the
        // other must have been renamed instead of also claiming existingID.
        let replacing = plan.setsToImport.filter(\.replacesExisting)
        #expect(replacing.count == 1)
        #expect(replacing[0].set.id == existingID)
    }

    /// The defensive fallback (nothing on record to replace) is reachable
    /// with an EMPTY store too: two identically-named sets in the same
    /// incoming file collide with each other, not with anything existing.
    /// Pins that this stays a clean rename rather than a force-unwrap crash,
    /// and that a `.replace` decision landing in `renamed` — not `replaced`
    /// — is deliberate, since the summary UI reads those arrays.
    @Test func replaceOfAnInFileDuplicateWithNoExistingMatchFallsBackToRename() async {
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.replace, applyToAll: true, log: DeciderCallLog()))
        let plan = await LoginSetImportPlanner.plan(
            existing: [], incoming: payload([fileSet(name: "A"), fileSet(name: "A")]), arbiter: arbiter)

        #expect(plan.setsToImport.map(\.set.name) == ["A", "A (2)"])
        #expect(plan.renamed == ["A (2)"])
        #expect(plan.replaced.isEmpty)
        #expect(plan.setsToImport.map(\.replacesExisting) == [false, false])
    }

    @Test func conflictCarriesTheStableKindLabelForTheAppToMap() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let captured = CapturedKindLabel()
        let arbiter = ImportConflictArbiter { conflict in
            await captured.record(conflict.kindLabel)
            return (.skip, false)
        }
        _ = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "Prod")]), arbiter: arbiter)

        // A literal, not a reference to the constant: a typo in the
        // planner's `kindLabel` must fail this test rather than pass by
        // both sides drifting together.
        #expect(await captured.value == "loginSet")
    }

    @Test func applyToAllStopsAskingAndAppliesTheSameResolution() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter(decider: fixedDecider(.skip, applyToAll: true, log: log))
        let plan = await LoginSetImportPlanner.plan(
            existing: existing,
            incoming: payload([fileSet(name: "Prod"), fileSet(name: "prod")]),
            arbiter: arbiter)

        #expect(plan.skipped == ["Prod", "prod"])
        #expect(plan.setsToImport.isEmpty)
        #expect(await log.names.count == 1)   // second collision used the sticky rule, not a fresh ask
    }

    @Test func cancellingAppliesNothing() async {
        let existing = [LoginSet(name: "Prod", username: "root")]
        let arbiter = ImportConflictArbiter { _ in nil }
        let plan = await LoginSetImportPlanner.plan(
            existing: existing,
            incoming: payload([fileSet(name: "NonColliding"), fileSet(name: "Prod")]),
            arbiter: arbiter)

        #expect(plan.cancelled)
        #expect(plan.setsToImport.isEmpty)
        #expect(plan.skipped.isEmpty)
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
    }

    /// The editor trims on save (`LoginSetsSheet.swift`), so import is the
    /// only path that could otherwise produce a set whose name carries
    /// whitespace the UI would never create.
    @Test func importedNameIsTrimmedOfSurroundingWhitespace() async {
        let arbiter = ImportConflictArbiter { _ in Issue.record("no collisions expected"); return nil }
        let plan = await LoginSetImportPlanner.plan(
            existing: [], incoming: payload([fileSet(name: "  Prod  ")]), arbiter: arbiter)

        #expect(plan.setsToImport[0].set.name == "Prod")
    }

    // The summary arrays feed the import result UI, so they must report the
    // same name that was actually stored — not the file's untrimmed spelling.
    @Test func summaryNamesAreTrimmedOnEveryResolution() async {
        let existing = [LoginSet(id: UUID(), name: "Prod", username: "deploy", authKind: .password)]

        let replacing = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "  Prod  ")]),
            arbiter: ImportConflictArbiter { _ in (.replace, true) })
        #expect(replacing.replaced == ["Prod"])

        let skipping = await LoginSetImportPlanner.plan(
            existing: existing, incoming: payload([fileSet(name: "  Prod  ")]),
            arbiter: ImportConflictArbiter { _ in (.skip, true) })
        #expect(skipping.skipped == ["Prod"])
    }

    @Test func secretsAndKeysOnlyRideAlongWhenThePayloadSaysSo() async {
        let key = EmbeddedKey(
            fileContents: Data("key-bytes".utf8), name: "id_ed25519", comment: "",
            fingerprint: "SHA256:abc", publicKeyOpenSSH: "ssh-ed25519 AAAA...", hasPassphrase: false,
            passphrase: nil)
        let withSecrets = fileSet(name: "A", secret: "s3cr3t", embeddedKey: key)
        let arbiter = ImportConflictArbiter { _ in Issue.record("no collisions expected"); return nil }

        let planWithout = await LoginSetImportPlanner.plan(
            existing: [], incoming: payload([withSecrets], includesSecrets: false, includesKeyFiles: false),
            arbiter: arbiter)
        #expect(planWithout.setsToImport[0].secret == nil)
        #expect(planWithout.setsToImport[0].embeddedKey == nil)

        let planWith = await LoginSetImportPlanner.plan(
            existing: [], incoming: payload([withSecrets], includesSecrets: true, includesKeyFiles: true),
            arbiter: arbiter)
        #expect(planWith.setsToImport[0].secret == "s3cr3t")
        #expect(planWith.setsToImport[0].embeddedKey == key)
    }
}
