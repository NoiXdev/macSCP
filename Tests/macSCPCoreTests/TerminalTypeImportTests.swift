import Foundation
import Testing
@testable import macSCPCore

/// The per-session terminal type across export and import (plan of
/// 2026-09-19, Task 4, fix round 1).
///
/// The rule, the coordinator's ruling: the export carries the override in a
/// key older importers ignore; an import restores it; a file WITHOUT the key
/// never erases a setting the user made. So a new session from such a file
/// uses the global setting, a Replace keeps the existing session's own
/// override, and a file that carries one wins. Skip changes nothing, and
/// Keep both (`.rename`) makes a new session, which takes only what the file
/// says.
///
/// The Cyberduck import writes its entries through this same planner and
/// never names a terminal type, so the `replaces` case below is its update
/// path.
@Suite("Terminal type across export and import")
@MainActor
struct TerminalTypeImportTests {
    // MARK: - Fixtures

    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-terminal-type-import-\(UUID().uuidString)")
    }

    private func listViewModel(in dir: URL) -> SessionListViewModel {
        SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
    }

    /// A stored SSH session on the loopback address with `override`.
    private func stored(_ name: String, override: TerminalType?) -> StoredSession {
        var session = sshSession(name: name, host: "127.0.0.1", port: 2222, username: "u")
        session.ssh?.terminalType = override
        return session
    }

    /// A file entry for the SAME connection as `session` — so the planner
    /// asks the arbiter — carrying `terminalType`.
    private func entry(
        sameConnectionAs session: StoredSession, terminalType: TerminalType?,
        replaces: UUID? = nil
    ) -> ExportedSession {
        ExportedSession(
            id: UUID(), name: "from-file", kind: .ssh,
            fields: BackendDescriptor.descriptor(for: .ssh).sessionValues(session).raw,
            terminalType: terminalType, replaces: replaces)
    }

    /// Plans `entries` against a store holding `existing`, answering every
    /// conflict with `resolution`, applies the plan, and returns the store's
    /// sessions afterwards.
    private func importing(
        _ entries: [ExportedSession], over existing: [StoredSession],
        resolving resolution: ImportConflictResolution?
    ) async throws -> [StoredSession] {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        for session in existing { try store.upsert(session) }
        let vm = listViewModel(in: dir)
        let plan = await SessionImportPlanner.plan(
            existing: vm.sessions, existingGroups: [],
            incoming: SessionExportPayload(includesSecrets: false, groups: [], sessions: entries),
            arbiter: ImportConflictArbiter { _ in resolution.map { ($0, false) } })
        _ = vm.applyImport(plan)
        return try SessionStore(directory: dir).all()
    }

    // MARK: - The file format

    /// A LITERAL entry written before the key existed decodes, with no
    /// override.
    @Test func anExportWrittenBeforeTheFieldDecodes() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"old","kind":"ssh","fields":{}}"#
        let decoded = try JSONDecoder().decode(ExportedSession.self, from: Data(old.utf8))
        #expect(decoded.terminalType == nil)
    }

    /// A name this build does not offer must not cost the whole file: it
    /// reads as "the file says nothing", like a missing key.
    @Test func anUnknownNameInAnExportDecodesAsNone() throws {
        let file = #"{"id":"\#(UUID().uuidString)","name":"n","kind":"ssh","fields":{},"terminalType":"linux"}"#
        let decoded = try JSONDecoder().decode(ExportedSession.self, from: Data(file.utf8))
        #expect(decoded.terminalType == nil)
    }

    @Test func theExportWritesTheOverrideUnderItsOwnKey() throws {
        let exported = ExportedSession(id: UUID(), name: "n", kind: .ssh, terminalType: .vt100)
        let json = try #require(String(data: try JSONEncoder().encode(exported), encoding: .utf8))
        #expect(json.contains(#""terminalType":"vt100""#))
        let without = ExportedSession(id: UUID(), name: "n", kind: .ssh)
        let jsonWithout = try #require(
            String(data: try JSONEncoder().encode(without), encoding: .utf8))
        #expect(!jsonWithout.contains("terminalType"), "no override writes no key")
    }

    // MARK: - Round trip

    /// Export -> encoded file -> decode -> plan -> apply, into an empty store.
    @Test func anOverrideSurvivesExportAndImport() async throws {
        let sourceDir = directory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let original = stored("web", override: .vt100)
        try SessionStore(directory: sourceDir).upsert(original)
        let (payload, _) = listViewModel(in: sourceDir).exportPayload(
            for: .single(original), includeGroups: false, includePasswords: false)
        #expect(payload.sessions.first?.terminalType == .vt100)
        let decoded = try SessionExportCodec.decode(
            try SessionExportCodec.encode(payload, password: nil), password: nil)

        let imported = try await importing(decoded.sessions, over: [], resolving: nil)

        #expect(imported.count == 1)
        #expect(imported.first?.ssh?.terminalType == .vt100)
    }

    /// A new session from a file without the key uses the global setting.
    @Test func aNewSessionFromAFileWithoutTheFieldUsesTheGlobalSetting() async throws {
        let template = stored("tpl", override: nil)
        let imported = try await importing(
            [entry(sameConnectionAs: template, terminalType: nil)], over: [], resolving: nil)
        #expect(imported.count == 1)
        #expect(imported.first?.ssh?.terminalType == nil)
    }

    // MARK: - Replace

    /// The finding this round fixes: a Replace from a file that says
    /// nothing about the terminal type used to write `nil` over the user's
    /// own override.
    @Test func replaceWithAFileWithoutTheFieldKeepsTheExistingOverride() async throws {
        let existing = stored("web", override: .vt100)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: nil)], over: [existing],
            resolving: .replace)

        let replaced = try #require(after.first { $0.id == existing.id })
        #expect(after.count == 1)
        #expect(replaced.name == "from-file", "the Replace itself must have happened")
        #expect(replaced.ssh?.terminalType == .vt100)
    }

    @Test func replaceWithAFileCarryingAnOverrideTakesTheFilesValue() async throws {
        let existing = stored("web", override: .vt100)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: .xterm)], over: [existing],
            resolving: .replace)

        #expect(after.count == 1)
        #expect(after.first { $0.id == existing.id }?.ssh?.terminalType == .xterm)
    }

    /// A Replace onto a session that had no override, from a file carrying
    /// one: the file's value, not the missing one.
    @Test func replaceOntoASessionWithoutAnOverrideTakesTheFilesValue() async throws {
        let existing = stored("web", override: nil)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: .vt100)], over: [existing],
            resolving: .replace)
        #expect(after.first { $0.id == existing.id }?.ssh?.terminalType == .vt100)
    }

    // MARK: - Skip and Keep both

    @Test func skipLeavesTheExistingOverrideAlone() async throws {
        let existing = stored("web", override: .vt100)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: .xterm)], over: [existing],
            resolving: .skip)
        #expect(after.map(\.id) == [existing.id])
        #expect(after.first?.ssh?.terminalType == .vt100)
    }

    /// Keep both makes a NEW session: it takes the file's value (none here),
    /// and does not borrow the existing session's — while the existing one
    /// keeps its own.
    @Test func keepBothGivesTheNewSessionOnlyWhatTheFileSays() async throws {
        let existing = stored("web", override: .vt100)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: nil)], over: [existing],
            resolving: .rename)

        #expect(after.count == 2)
        #expect(after.first { $0.id == existing.id }?.ssh?.terminalType == .vt100)
        #expect(after.first { $0.id != existing.id }?.ssh?.terminalType == nil)
    }

    @Test func keepBothWithAFileCarryingAnOverrideGivesItToTheNewSession() async throws {
        let existing = stored("web", override: .vt100)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: .xterm)], over: [existing],
            resolving: .rename)

        #expect(after.first { $0.id == existing.id }?.ssh?.terminalType == .vt100)
        #expect(after.first { $0.id != existing.id }?.ssh?.terminalType == .xterm)
    }

    // MARK: - The Cyberduck import's update path

    /// An entry naming the record it updates (`replaces`) is how the
    /// Cyberduck import rewrites a session it created before. Such an entry
    /// never carries a terminal type, so it keeps the one the user set.
    @Test func anUpdateByIDWithoutTheFieldKeepsTheExistingOverride() async throws {
        let existing = stored("web", override: .xterm)
        let after = try await importing(
            [entry(sameConnectionAs: existing, terminalType: nil, replaces: existing.id)],
            over: [existing], resolving: nil)

        #expect(after.count == 1)
        #expect(after.first?.id == existing.id)
        #expect(after.first?.ssh?.terminalType == .xterm)
    }
}
