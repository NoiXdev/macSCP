import Foundation
import Testing
@testable import macSCPCore

/// Provenance on a stored session (Cyberduck import, M24, Task 1):
/// `importSource`/`importID`/`importedAt` are additive and optional, carried
/// through export/import, and dropped by `SessionDuplication.copy` — the copy
/// did not come from Cyberduck. See `StoredSession.importSource`.
@Suite("Session provenance")
struct SessionProvenanceTests {
    /// A record encoded without the three keys (a payload written before
    /// this field existed) decodes with all three `nil` — the same
    /// additive-persistence convention `groupID`/`loginSetID`/`kind` follow.
    @Test func decodingWithoutProvenanceKeysYieldsNil() throws {
        let session = sshSession(name: "plain", host: "example.com", username: "tim")
        var data = try JSONEncoder().encode(session)
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        object?.removeValue(forKey: "importSource")
        object?.removeValue(forKey: "importID")
        object?.removeValue(forKey: "importedAt")
        data = try JSONSerialization.data(withJSONObject: object as Any)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(decoded.importSource == nil)
        #expect(decoded.importID == nil)
        #expect(decoded.importedAt == nil)
    }

    /// A record carrying the three fields round-trips through
    /// encode/decode unchanged.
    @Test func provenanceRoundTrips() throws {
        var session = sshSession(name: "imported", host: "example.com", username: "tim")
        session.importSource = "cyberduck"
        session.importID = "11111111-2222-3333-4444-555555555555"
        session.importedAt = Date(timeIntervalSince1970: 1_735_000_000)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)

        #expect(decoded == session)
        #expect(decoded.importSource == "cyberduck")
        #expect(decoded.importID == "11111111-2222-3333-4444-555555555555")
        #expect(decoded.importedAt == session.importedAt)
    }

    /// `ExportedSession` carries the three fields through its own
    /// encode/decode the same way `StoredSession` does.
    @Test func exportedSessionRoundTripsProvenance() throws {
        let exported = ExportedSession(
            id: UUID(), name: "imported",
            importSource: "cyberduck",
            importID: "22222222-3333-4444-5555-666666666666",
            importedAt: Date(timeIntervalSince1970: 1_735_000_000))

        let data = try JSONEncoder().encode(exported)
        let decoded = try JSONDecoder().decode(ExportedSession.self, from: data)

        #expect(decoded == exported)
        #expect(decoded.importSource == "cyberduck")
        #expect(decoded.importID == "22222222-3333-4444-5555-666666666666")
        #expect(decoded.importedAt == exported.importedAt)
    }

    /// End to end: a `StoredSession` carrying provenance, exported and then
    /// re-imported through `SessionImportPlanner`, restores all three on the
    /// planned session.
    @Test func importRestoresProvenanceFromExport() async throws {
        let importedAt = Date(timeIntervalSince1970: 1_735_000_000)
        let exported = ExportedSession(
            id: UUID(), name: "from-cyberduck", kind: .ssh,
            fields: sshExportFields(host: "example.com", username: "tim"),
            importSource: "cyberduck",
            importID: "33333333-4444-5555-6666-777777777777",
            importedAt: importedAt)
        let payload = SessionExportPayload(includesSecrets: false, groups: [], sessions: [exported])

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter(decider: { _ in (.skip, true) }))

        let planned = try #require(plan.sessionsToImport.first)
        #expect(planned.session.importSource == "cyberduck")
        #expect(planned.session.importID == "33333333-4444-5555-6666-777777777777")
        #expect(planned.session.importedAt == importedAt)
    }

    /// `SessionDuplication.copy` drops all three: a manual duplicate did not
    /// come from Cyberduck.
    @Test func duplicationDropsProvenance() {
        var template = sshSession(name: "imported", host: "example.com", username: "tim")
        template.importSource = "cyberduck"
        template.importID = "44444444-5555-6666-7777-888888888888"
        template.importedAt = Date()

        let copy = SessionDuplication.copy(of: template, avoiding: [template])

        #expect(copy.importSource == nil)
        #expect(copy.importID == nil)
        #expect(copy.importedAt == nil)
    }

    /// A legacy JSON fixture (pre-M23, no provenance keys at all — copied
    /// from `StoredSessionCompatTests.decodesM3aJsonWithoutKeyPath`) still
    /// loads, with provenance resolving to `nil` the same way `kind` and
    /// `keyPath` resolve to their own legacy defaults.
    @Test func legacyJsonWithoutProvenanceStillLoads() throws {
        let json = """
        [{"authKind":"password","host":"example.com","id":"11111111-2222-3333-4444-555555555555",
          "name":"alt","port":22,"username":"tim"}]
        """
        let sessions = try JSONDecoder()
            .decode([LegacyStoredSession].self, from: Data(json.utf8))
            .map { $0.upgraded() }
        #expect(sessions.first?.kind == .ssh)
        #expect(sessions.first?.ssh?.host == "example.com")
        #expect(sessions.first?.importSource == nil)
        #expect(sessions.first?.importID == nil)
        #expect(sessions.first?.importedAt == nil)
    }
}
