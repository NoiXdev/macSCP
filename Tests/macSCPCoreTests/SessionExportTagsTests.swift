import Foundation
import Testing
@testable import macSCPCore

/// Persistence of `StoredSession.tags` across the export/import path (P3a,
/// Task 3). `StoredSessionTagsTests.swift` already pins normalization and
/// the `StoredSession` decode default; this file is only about the file
/// format and the planner.
///
/// `paneVisibility` is the precedent this field follows, not `groupID`:
/// like `paneVisibility`, a tag list is a fact about the session with its
/// own concrete default (`[]`, mirroring `.filesOnly`) -- not a reference
/// into something else the file also carries the way `groupID` is a
/// reference into `ExportedGroup`. So `tags` is optional in
/// `ExportedSession`, decoded/encoded with `decodeIfPresent`/
/// `encodeIfPresent` exactly like `paneVisibility`, written unconditionally
/// on export (never gated behind `includeGroups`, which is specifically
/// about group membership), and falls back to `?? []` on import rather
/// than needing the id-remapping `groupID` gets from `SessionImportPlanner`'s
/// `groupIDMap`.
@Suite("Session export/import tags")
@MainActor
struct SessionExportTagsTests {
    /// The ordinary case: a tag list set on the session survives an
    /// `ExportedSession` encode/decode round trip. Built through
    /// `ExportedSession`'s own designated initializer with the same
    /// `tags:` argument `SessionListViewModel.exportPayload`'s closure
    /// passes -- there is no separate `ExportedSession(from:)` conversion
    /// initializer in this codebase, so this is the actual construction
    /// site rather than a hand-rolled substitute.
    @Test func exportRoundTripCarriesTags() throws {
        let session = StoredSession(name: "box", tags: ["docker", "web"])
        let exported = ExportedSession(
            id: session.id, name: session.name, kind: session.kind, tags: session.tags)

        let data = try JSONEncoder().encode(exported)
        let restored = try JSONDecoder().decode(ExportedSession.self, from: data)

        #expect(restored.tags == ["docker", "web"])
    }

    /// The migration proof: a `.macscp` file exported before this task
    /// carries no `"tags"` key on its sessions at all -- `ExportedSession`'s
    /// only REQUIRED fields are `id` and `name` (every other key, `tags`
    /// included, is `decodeIfPresent`), so this is the minimal legacy shape,
    /// against a literal hand-written JSON string rather than something
    /// `ExportedSession` re-encoded itself (which could only ever produce a
    /// shape its own decoder already accepts). The `fields` bag names a real
    /// SSH connection so the planner does not reject the entry outright as
    /// an empty, storeless record -- that rejection is a real behavior
    /// (`SessionImportPlanner.wouldBeDroppedByStore`) this test must not
    /// trip over while trying to prove something else.
    @Test func anExportFileWithoutTheTagsKeyImportsAsUntagged() async throws {
        let raw = """
            {"id":"\(UUID().uuidString)","name":"legacy-box","kind":"ssh",
             "fields":{"SSHField.host":"h","SSHField.port":"22",
                       "SSHField.username":"root","SSHField.authKind":"password",
                       "SSHField.keyPath":""}}
            """.data(using: .utf8)!
        let file = try JSONDecoder().decode(ExportedSession.self, from: raw)
        #expect(file.tags == nil)

        let payload = SessionExportPayload(includesSecrets: false, groups: [], sessions: [file])
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in
                Issue.record("decider must not be asked for a fresh, non-colliding entry")
                return nil
            })

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tags-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let result = vm.applyImport(plan)

        #expect(result.imported == 1)
        #expect(vm.sessions.first?.tags == [])
    }

    /// The positive case, exercised through the REAL production wiring on
    /// both ends -- `SessionListViewModel.exportPayload`'s closure and
    /// `SessionImportPlanner.makePlanned` -- rather than through
    /// `ExportedSession`'s initializer directly. Without this, neither the
    /// export closure's `tags: session.tags` argument nor the planner's
    /// `session.tags = fileSession.tags ?? []` line is actually
    /// exercised with a NON-nil tag list: `anExportFileWithoutTheTagsKeyImportsAsUntagged`
    /// only proves the `nil` fallback, which a constant `[]` on either side
    /// would also satisfy. Mirrors
    /// `PaneVisibilityPersistenceTests.paneVisibilitySurvivesExportImportRoundtrip`.
    @Test func tagsSurviveExportImportRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tags-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        var original = sshSession(name: "tagged", host: "h.example.com", username: "u")
        original.tags = ["docker", "web"]
        try store.upsert(original)

        let vm = SessionListViewModel(
            store: store, secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let (payload, _) = vm.exportPayload(
            for: .single(original), includeGroups: false, includePasswords: false)
        let exported = payload.sessions.first!
        #expect(exported.tags == ["docker", "web"])

        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in
                Issue.record("decider must not be asked for a fresh, non-colliding entry")
                return nil
            })
        let importTarget = dir.appendingPathComponent("import-target")
        let importedVM = SessionListViewModel(
            store: SessionStore(directory: importTarget), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: importTarget),
            loginSetStore: LoginSetStore(directory: importTarget),
            keys: ManagedKeyStore(directory: importTarget))
        let result = importedVM.applyImport(plan)

        #expect(result.imported == 1)
        #expect(importedVM.sessions.first?.tags == ["docker", "web"])
    }

    /// `SessionImportPlanner.makePlanned` hands the file's tag list to
    /// `session.tags` unexamined; `StoredSession.tags`'s setter normalizes it
    /// (see
    /// `StoredSessionTagsTests.aDirectAssignmentNormalizesBecauseThePropertyOwnsTheRule`
    /// for the property-level pin). The planner used to call the rule by hand
    /// -- and in P3a/T3 was found having forgotten to, which is why the rule
    /// moved to the property. This test does not care which of the two holds
    /// the rule: it asserts the OUTCOME at the import boundary, so it stays
    /// the thing that goes red if either ever stops normalizing. Against a
    /// literal hand-edited export file, the same reasoning as
    /// `anExportFileWithoutTheTagsKeyImportsAsUntagged`.
    @Test func importNormalizesTagsSoAHandEditedExportFileCannotSmuggleDuplicates() async throws {
        let raw = """
            {"id":"\(UUID().uuidString)","name":"tampered","kind":"ssh",
             "fields":{"SSHField.host":"h","SSHField.port":"22",
                       "SSHField.username":"root","SSHField.authKind":"password",
                       "SSHField.keyPath":""},
             "tags":["  docker ","docker",""]}
            """.data(using: .utf8)!
        let file = try JSONDecoder().decode(ExportedSession.self, from: raw)

        let payload = SessionExportPayload(includesSecrets: false, groups: [], sessions: [file])
        let plan = await SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in
                Issue.record("decider must not be asked for a fresh, non-colliding entry")
                return nil
            })

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tags-normalize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let result = vm.applyImport(plan)

        #expect(result.imported == 1)
        #expect(vm.sessions.first?.tags == ["docker"])
    }
}
