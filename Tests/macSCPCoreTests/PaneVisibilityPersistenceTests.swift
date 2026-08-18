import Foundation
import Testing
@testable import macSCPCore

/// Persistence of `StoredSession.paneVisibility` across the store and the
/// export/import path (P2 terminal-chrome milestone, Task 4).
///
/// `groupID` is the precedent this field follows for WHERE it lives (a fact
/// about the session, not a connection property — see `StoredSession.swift`'s
/// doc comment on `paneVisibility`) and for whether export carries it
/// (unconditionally, like `kind`/`fields` — `includeGroups` gates GROUP
/// membership specifically, which pane visibility is not). The CODING shape
/// — `?? .bothVisible` on a missing key — mirrors `kind`'s `?? .ssh`
/// instead, since `groupID` stays genuinely optional (a session can have no
/// group) while every session has SOME current pane visibility once this
/// field exists.
@Suite("Pane visibility persistence")
@MainActor
struct PaneVisibilityPersistenceTests {
    // MARK: - StoredSession decode

    /// A `sessions.json` written before this field existed must still load,
    /// landing as "both visible" — against a LITERAL pre-Task-4 file (no
    /// `paneVisibility` key at all), not something freshly encoded by
    /// `StoredSession` itself, which would trivially round-trip even if the
    /// decoder secretly required the key.
    @Test func legacyJSONWithoutPaneVisibilityDecodesAsBothVisible() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"old","kind":"ssh",
             "ssh":{"host":"h","port":22,"username":"u","authKind":"password"}}
            """.data(using: .utf8)!

        let session = try JSONDecoder().decode(StoredSession.self, from: legacy)

        #expect(session.paneVisibility == .bothVisible)
        #expect(session.paneVisibility.showsFiles == true)
        #expect(session.paneVisibility.showsTerminal == true)
    }

    /// A hand-edited (or corrupted) store file claiming "neither half
    /// visible" must not be trusted as-is — `PaneVisibility`'s own repair
    /// (pinned in isolation by `PaneVisibilityTests.
    /// aStoredStateWithNothingVisibleIsRepaired`) has to actually fire when
    /// reached THROUGH `StoredSession`'s decode path, not merely exist on
    /// `PaneVisibility` in the abstract — this test proves the wiring, not
    /// just the rule.
    @Test func storedSessionClaimingNothingVisibleIsRepairedOnLoad() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"repaired","kind":"ssh",
             "ssh":{"host":"h","port":22,"username":"u","authKind":"password"},
             "paneVisibility":{"showsFiles":false,"showsTerminal":false}}
            """.data(using: .utf8)!

        let session = try JSONDecoder().decode(StoredSession.self, from: json)

        #expect(session.paneVisibility.showsFiles == true)
        #expect(session.paneVisibility.showsTerminal == false)
    }

    /// The ordinary case: a session with a real (non-default) recorded
    /// preference round-trips intact.
    @Test func nonDefaultPaneVisibilityRoundTrips() throws {
        var session = sshSession(name: "term-only")
        session.paneVisibility = PaneVisibility(showsFiles: false, showsTerminal: true)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)

        #expect(decoded.paneVisibility == PaneVisibility(showsFiles: false, showsTerminal: true))
    }

    // MARK: - Export payload

    /// A payload written before this field existed decodes each session's
    /// `paneVisibility` as `nil` — the import side, not the codec, supplies
    /// the "both visible" default (mirroring `kind == nil` -> `.ssh`, applied
    /// by `SessionImportPlanner` rather than at decode time). Pinned against
    /// a literal pre-Task-4 `ExportedSession` shape.
    @Test func legacyExportedSessionJSONDecodesWithNilPaneVisibility() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"old","kind":"ssh","fields":{}}
            """.data(using: .utf8)!

        let exported = try JSONDecoder().decode(ExportedSession.self, from: legacy)

        #expect(exported.paneVisibility == nil)
    }

    // MARK: - Export/import round trip (SessionListViewModel + SessionImportPlanner)

    /// Step 1's finding: `groupID` is carried through `exportPayload`
    /// (`includeGroups ? session.groupID : nil` — not silently dropped), so
    /// the same intent applies here: a recorded pane visibility survives a
    /// full export -> plan -> applyImport round trip, unconditionally (not
    /// gated behind `includeGroups`, which is specifically about group
    /// membership).
    @Test func paneVisibilitySurvivesExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-panevis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        var original = sshSession(name: "term-only", host: "h.example.com", username: "u")
        original.paneVisibility = PaneVisibility(showsFiles: false, showsTerminal: true)
        try store.upsert(original)

        let vm = SessionListViewModel(
            store: store, secrets: InMemorySecretStore(),
            loginSetStore: LoginSetStore(directory: dir))
        let (payload, _) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: false)
        let exported = payload.sessions.first!
        #expect(exported.paneVisibility == PaneVisibility(showsFiles: false, showsTerminal: true))

        // Through the encoded/decoded codec too, not just the in-memory struct.
        let data = try SessionExportCodec.encode(payload, password: nil)
        let decoded = try SessionExportCodec.decode(data, password: nil)

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: dir.appendingPathComponent("import-target")),
            secrets: InMemorySecretStore())
        let result = importedVM.applyImport(plan)

        #expect(result.imported == 1)
        let imported = importedVM.sessions.first!
        #expect(imported.paneVisibility == PaneVisibility(showsFiles: false, showsTerminal: true))
    }

    /// A session that never carried a recorded preference (`.bothVisible`,
    /// the field's own default) exports and re-imports as `.bothVisible` too
    /// — the ordinary case, exercised end to end rather than assumed from
    /// the decode-level tests above alone.
    @Test func defaultPaneVisibilitySurvivesExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-panevis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let original = sshSession(name: "default-vis", host: "h.example.com", username: "u")
        #expect(original.paneVisibility == .bothVisible)
        try store.upsert(original)

        let vm = SessionListViewModel(
            store: store, secrets: InMemorySecretStore(),
            loginSetStore: LoginSetStore(directory: dir))
        let (payload, _) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: false)

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in Issue.record("decider must not be asked"); return nil })
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: dir.appendingPathComponent("import-target")),
            secrets: InMemorySecretStore())
        let result = importedVM.applyImport(plan)

        #expect(result.imported == 1)
        #expect(importedVM.sessions.first?.paneVisibility == .bothVisible)
    }
}
