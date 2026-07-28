import Foundation
import Testing
@testable import macSCPCore

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

    @Test func duplicateTripleIsSkippedDespiteDifferentName() {
        let existing = [StoredSession(name: "anders", host: "WEB-01", username: "root")]
        let plan = SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "neu", host: "web-01")]))
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test func hostCaseAndPortDistinguishCorrectly() {
        let existing = [StoredSession(name: "a", host: "web-01", username: "root")]
        let plan = SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(host: "Web-01", port: 2222),     // other port -> import
                exported(host: "web-01", username: "deploy"), // other user -> import
            ]))
        #expect(plan.sessionsToImport.count == 2)
        #expect(plan.skipped.isEmpty)
    }

    @Test func inFileDuplicatesKeepFirst() {
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "erste", host: "Host-A"),
                exported(name: "zweite", host: "host-a"),
            ]))
        #expect(plan.sessionsToImport.map(\.session.name) == ["erste"])
        #expect(plan.skipped.map(\.name) == ["zweite"])
    }

    @Test func groupsMatchByNameOrGetCreatedFresh() {
        let existingGroup = StoredGroup(name: "Prod")
        let fileGroupProd = ExportedGroup(id: UUID(), name: "Prod")
        let fileGroupNew = ExportedGroup(id: UUID(), name: "Staging")
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [existingGroup],
            incoming: incoming(
                [exported(name: "p", host: "h1", groupID: fileGroupProd.id),
                 exported(name: "s", host: "h2", groupID: fileGroupNew.id)],
                groups: [fileGroupProd, fileGroupNew]))
        #expect(plan.groupsToCreate.map(\.name) == ["Staging"])
        let p = plan.sessionsToImport.first { $0.session.name == "p" }!
        let s = plan.sessionsToImport.first { $0.session.name == "s" }!
        #expect(p.session.groupID == existingGroup.id)          // matched by name
        #expect(s.session.groupID == plan.groupsToCreate[0].id) // fresh group
        #expect(plan.groupsToCreate[0].id != fileGroupNew.id)   // fresh id
    }

    @Test func importedSessionsGetFreshIDsAndCarryPasswords() {
        let file = exported(password: "geheim")
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]))
        #expect(plan.sessionsToImport[0].session.id != file.id)
        #expect(plan.sessionsToImport[0].password == "geheim")
    }

    @Test func unknownGroupReferenceFallsBackToNil() {
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(groupID: UUID())])) // group not in file
        #expect(plan.sessionsToImport[0].session.groupID == nil)
    }
}
