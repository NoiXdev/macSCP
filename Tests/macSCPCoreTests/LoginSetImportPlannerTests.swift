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
        #expect(Set(names).count == 2)          // the two renames differ from each other
        #expect(!names.contains("Prod"))         // and from the existing name
        #expect(plan.renamed.count == 2)
        #expect(Set(plan.renamed) == Set(names))
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
