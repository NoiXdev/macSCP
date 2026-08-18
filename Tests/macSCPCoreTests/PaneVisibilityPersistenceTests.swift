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
/// — `?? .filesOnly` on a missing key — mirrors `kind`'s `?? .ssh`
/// instead, since `groupID` stays genuinely optional (a session can have no
/// group) while every session has SOME current pane visibility once this
/// field exists.
@Suite("Pane visibility persistence")
@MainActor
struct PaneVisibilityPersistenceTests {
    // MARK: - StoredSession decode

    /// A `sessions.json` written before this field existed must still load,
    /// landing as "files only" — no terminal, which is what every session
    /// did before this field existed (maintainer ruling, whole-phase
    /// re-review; the first default here was `.bothVisible`, which would
    /// have made every legacy record open a terminal and start a shell on
    /// its next connect). Against a LITERAL pre-Task-4 file (no
    /// `paneVisibility` key at all), not something freshly encoded by
    /// `StoredSession` itself, which would trivially round-trip even if the
    /// decoder secretly required the key.
    @Test func legacyJSONWithoutPaneVisibilityDecodesAsFilesOnly() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"old","kind":"ssh",
             "ssh":{"host":"h","port":22,"username":"u","authKind":"password"}}
            """.data(using: .utf8)!

        let session = try JSONDecoder().decode(StoredSession.self, from: legacy)

        #expect(session.paneVisibility == .filesOnly)
        #expect(session.paneVisibility.showsFiles == true)
        #expect(session.paneVisibility.showsTerminal == false)
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

    /// A session that never carried a recorded preference (`.filesOnly`,
    /// the field's own default) exports and re-imports as `.filesOnly` too
    /// — the ordinary case, exercised end to end rather than assumed from
    /// the decode-level tests above alone.
    @Test func defaultPaneVisibilitySurvivesExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-panevis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let original = sshSession(name: "default-vis", host: "h.example.com", username: "u")
        #expect(original.paneVisibility == .filesOnly)
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
        #expect(importedVM.sessions.first?.paneVisibility == .filesOnly)
    }

    // MARK: - Malformed field must not cost the user their sessions

    /// A pane-visibility object that is BROKEN rather than absent — here the
    /// `showsTerminal` key is missing entirely — must fall back to the
    /// default instead of throwing. The field decides which half of a window
    /// is showing; it must never be able to take a user's whole
    /// `sessions-v2.json` down with it, which is what a throwing decode does:
    /// `SessionStore` decodes the file as ONE container, so one broken
    /// cosmetic value inside one session fails the load of every session in
    /// it.
    ///
    /// Deliberately against a LITERAL file written to disk, not a re-encoded
    /// `StoredSession` — an encoder can only ever produce values its own
    /// decoder accepts, so a round-trip could not express this input at all.
    ///
    /// The second session in the file is the point of the test: it is
    /// untouched and well-formed, and it is what a throwing decode used to
    /// take with it.
    @Test func aMalformedPaneVisibilityDoesNotFailTheWholeStoreFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-pane-malformed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brokenID = UUID()
        let healthyID = UUID()
        let file = """
            {"groups":[],"sessions":[
             {"id":"\(brokenID.uuidString)","name":"broken","kind":"ssh",
              "ssh":{"host":"h","port":22,"username":"u","authKind":"password"},
              "paneVisibility":{"showsFiles":true}},
             {"id":"\(healthyID.uuidString)","name":"healthy","kind":"ssh",
              "ssh":{"host":"h2","port":22,"username":"u2","authKind":"password"},
              "paneVisibility":{"showsFiles":false,"showsTerminal":true}}]}
            """
        try file.write(
            to: dir.appendingPathComponent("sessions-v2.json"), atomically: true, encoding: .utf8)

        let sessions = try SessionStore(directory: dir).all()

        #expect(sessions.count == 2)
        #expect(sessions.first(where: { $0.id == brokenID })?.paneVisibility == .filesOnly)
        #expect(sessions.first(where: { $0.id == healthyID })?.paneVisibility
            == PaneVisibility(showsFiles: false, showsTerminal: true))
    }

    /// The other malformed shape: the keys are present but carry values of
    /// the wrong type. Each half falls back on its own, so whatever the file
    /// could still say is kept — here the readable `showsTerminal: false`
    /// survives while the unreadable `showsFiles` falls back to the default.
    ///
    /// Not a re-encode either, for the same reason as above.
    @Test func aWrongTypedHalfFallsBackWithoutDiscardingTheReadableHalf() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"typed-wrong","kind":"ssh",
             "ssh":{"host":"h","port":22,"username":"u","authKind":"password"},
             "paneVisibility":{"showsFiles":"yes","showsTerminal":false}}
            """.data(using: .utf8)!

        let session = try JSONDecoder().decode(StoredSession.self, from: json)

        #expect(session.paneVisibility == PaneVisibility(showsFiles: true, showsTerminal: false))
    }

    /// A `paneVisibility` that is not even an object (here: a string) is the
    /// coarsest breakage, and lands on the plain default rather than
    /// throwing.
    @Test func aPaneVisibilityThatIsNotAnObjectFallsBackToTheDefault() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"not-an-object","kind":"ssh",
             "ssh":{"host":"h","port":22,"username":"u","authKind":"password"},
             "paneVisibility":"both"}
            """.data(using: .utf8)!

        let session = try JSONDecoder().decode(StoredSession.self, from: json)

        #expect(session.paneVisibility == .filesOnly)
    }
}
