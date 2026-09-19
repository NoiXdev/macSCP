import Foundation
import MacSCPTestSupport
import Synchronization
import Testing
@testable import macSCPCore

/// The terminal type as a setting with a per-session override (plan of
/// 2026-09-19, "Diagnostics and terminal wishes", Task 4): what is offered,
/// the order it resolves in, where each level is stored, and that the
/// resolved name is what `TerminalPanelViewModel` hands to `openShell`.
///
/// Known blind spot: nothing here proves SwiftTerm renders any of these
/// types faithfully. That was decided by reading SwiftTerm and the rig's
/// terminfo entries (the task report); the gated
/// `CitadelShellIntegrationTests.theChosenTerminalTypeReachesTheRemoteShell`
/// proves only that the name reaches the server.
@Suite("Terminal type", .timeLimit(.minutes(1)))
@MainActor
struct TerminalTypeTests {
    // MARK: - What is offered

    /// The offered list is a decision, pinned so that adding a name is a
    /// deliberate change with its own reading behind it rather than an
    /// enum case slipped in. Order is the pickers' order.
    @Test func theOfferedTypesAreExactlyTheThreeSwiftTermHonours() {
        #expect(TerminalType.allCases.map(\.rawValue) == ["xterm-256color", "xterm", "vt100"])
    }

    /// The default is the name every shell was opened with before the
    /// setting existed, so an untouched installation behaves as before.
    @Test func theDefaultIsTheNameShellsWereOpenedWithBefore() {
        #expect(TerminalType.default == .xterm256Color)
        #expect(TerminalType.default.rawValue == "xterm-256color")
    }

    // MARK: - Resolution order

    @Test func aSessionOverrideWinsOverTheGlobalSetting() {
        #expect(TerminalType.resolved(sessionOverride: .vt100, global: .xterm) == .vt100)
    }

    @Test func withoutAnOverrideTheGlobalSettingApplies() {
        #expect(TerminalType.resolved(sessionOverride: nil, global: .xterm) == .xterm)
        #expect(TerminalType.resolved(sessionOverride: nil, global: .vt100) == .vt100)
    }

    @Test func withNeitherTheDefaultApplies() {
        #expect(TerminalType.resolved(sessionOverride: nil, global: nil) == .default)
    }

    /// Every combination at once, so a resolver that got two of the three
    /// levels right by coincidence of the values chosen above is still red.
    @Test(arguments: [TerminalType?.none] + TerminalType.allCases.map(Optional.some))
    func theOverrideAlwaysWinsAndTheGlobalOnlyWithoutOne(override: TerminalType?) {
        for global in [TerminalType?.none] + TerminalType.allCases.map(Optional.some) {
            let expected = override ?? global ?? .default
            #expect(TerminalType.resolved(sessionOverride: override, global: global) == expected)
        }
    }

    // MARK: - A tab's stored session

    /// The app resolves a tab's override through the stored session the tab
    /// is connected to; no id, an id naming nothing, and a session without
    /// an override all mean "use the global setting".
    @Test func theOverrideIsLookedUpByTheConnectedSessionsID() {
        var withOverride = sshSession(name: "a", host: "host.invalid")
        withOverride.ssh?.terminalType = .vt100
        let without = sshSession(name: "b", host: "host.invalid")
        let sessions = [withOverride, without]

        #expect(TerminalType.sessionOverride(of: withOverride.id, in: sessions) == .vt100)
        #expect(TerminalType.sessionOverride(of: without.id, in: sessions) == nil)
        #expect(TerminalType.sessionOverride(of: UUID(), in: sessions) == nil)
        #expect(TerminalType.sessionOverride(of: nil, in: sessions) == nil)
    }

    // MARK: - The global setting

    private func settingsDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-terminal-type-\(UUID().uuidString)")
    }

    @Test func theGlobalSettingDefaultsToTheDefaultType() {
        let dir = settingsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SettingsStore(directory: dir).terminalType == .default)
    }

    @Test func theGlobalSettingSurvivesAReload() throws {
        let dir = settingsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalType = .vt100
        #expect(SettingsStore(directory: dir).terminalType == .vt100)

        // Stored as the name itself, so a person reading settings.json sees
        // what the server will see.
        let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["terminalType"] == .string("vt100"))
    }

    /// A name this build does not offer — a hand edit, or a later build's
    /// wider list — reads as the default rather than failing or reaching
    /// the server unchecked.
    @Test func anUnknownGlobalNameReadsAsTheDefault() throws {
        let dir = settingsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"terminalType": "linux"}"#.utf8)
            .write(to: dir.appendingPathComponent("settings.json"))
        #expect(SettingsStore(directory: dir).terminalType == .default)
    }

    // MARK: - The per-session override on disk

    private func storeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-terminal-type-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A LITERAL store file written before the field existed — not one this
    /// build encoded, which would round-trip even if the decoder demanded
    /// the key. It loads, keeps its session, and that session has no
    /// override: it uses the global setting.
    @Test func aStoreFileWrittenBeforeTheFieldLoadsAsUseTheGlobalSetting() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let old = """
            {"groups":[],"sessions":[{"id":"\(id.uuidString)","name":"old","kind":"ssh",
             "ssh":{"host":"host.invalid","port":22,"username":"u","authKind":"password"}}]}
            """
        try Data(old.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try SessionStore(directory: dir).all()

        #expect(sessions.map(\.id) == [id])
        #expect(sessions.first?.ssh?.host == "host.invalid")
        #expect(sessions.first?.ssh?.terminalType == nil)
        #expect(TerminalType.resolved(
            sessionOverride: sessions.first?.ssh?.terminalType, global: .xterm) == .xterm)
    }

    @Test func anOverrideSurvivesTheStore() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = sshSession(name: "web", host: "host.invalid")
        session.ssh?.terminalType = .vt100
        try SessionStore(directory: dir).upsert(session)

        #expect(try SessionStore(directory: dir).all().first?.ssh?.terminalType == .vt100)
        let text = try String(
            contentsOf: dir.appendingPathComponent("sessions-v2.json"), encoding: .utf8)
        #expect(text.contains(#""terminalType" : "vt100""#))
    }

    /// A name this build does not know must not cost the SESSION: the store
    /// decodes its whole file in one piece, so a throwing field would empty
    /// the sidebar. The unknown name reads as "use the global setting".
    @Test func anUnknownSessionNameKeepsTheSessionAndReadsAsNoOverride() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let file = """
            {"groups":[],"sessions":[{"id":"\(id.uuidString)","name":"later","kind":"ssh",
             "ssh":{"host":"host.invalid","port":22,"username":"u","authKind":"password",
                    "terminalType":"linux"}}]}
            """
        try Data(file.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try SessionStore(directory: dir).all()

        #expect(sessions.map(\.id) == [id])
        #expect(sessions.first?.ssh?.terminalType == nil)
    }

    // MARK: - The value handed to openShell

    /// The type a test's resolver answers with, changeable between opens.
    /// A class rather than a captured `var`: the resolver is a
    /// `@MainActor` closure, which Swift treats as `Sendable`.
    @MainActor private final class CurrentType {
        var type: TerminalType
        init(_ type: TerminalType) { self.type = type }
    }

    /// What `openShell` received, in call order.
    private final class OpenedNames: Sendable {
        private let names = Mutex<[String]>([])
        func record(_ name: String) { names.withLock { $0.append(name) } }
        var all: [String] { names.withLock { $0 } }
    }

    @Test func openShellReceivesTheResolvedTypesName() async throws {
        let opened = OpenedNames()
        let vm = TerminalPanelViewModel(
            terminalType: { .vt100 },
            openShell: { term, _, _ in
                opened.record(term)
                return MockShell()
            })

        vm.toggle()
        try await pollUntil("the shell is running") { vm.state == .running }

        #expect(opened.all == ["vt100"])
    }

    /// Read when a shell OPENS, not when the panel is built: a global
    /// change made in Settings reaches the next shell of a session that is
    /// already connected — Reopen after the shell ended picks it up.
    @Test func theTypeIsReadAgainForEachShellThatOpens() async throws {
        let opened = OpenedNames()
        let current = CurrentType(.xterm)
        let first = MockShell()
        let vm = TerminalPanelViewModel(
            terminalType: { current.type },
            openShell: { term, _, _ in
                let isFirst = opened.all.isEmpty
                opened.record(term)
                return isFirst ? first : MockShell()
            })

        vm.toggle()
        try await pollUntil("the first shell is running") { vm.state == .running }
        first.continuation.finish()
        try await pollUntil("the first shell has ended") {
            if case .ended = vm.state { return true }
            return false
        }

        current.type = .vt100
        vm.openIfNeeded()
        try await pollUntil("a second shell was asked for") { opened.all.count == 2 }

        #expect(opened.all == ["xterm", "vt100"])
    }

    // MARK: - The session editor

    private func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
    }

    @Test func editingASessionShowsItsOverride() {
        let form = makeForm()
        var stored = sshSession(name: "web", host: "host.invalid")
        stored.ssh?.terminalType = .xterm
        form.beginEditing(stored)
        #expect(form.terminalTypeOverride == .xterm)
    }

    @Test func editingASessionWithoutOneShowsUseTheGlobalSetting() {
        let form = makeForm()
        form.terminalTypeOverride = .vt100
        form.beginEditing(sshSession(name: "web", host: "host.invalid"))
        #expect(form.terminalTypeOverride == nil)
    }

    @Test func savingAnEditWritesTheChosenOverride() {
        let form = makeForm()
        form.beginEditing(sshSession(name: "web", host: "host.invalid"))
        form.terminalTypeOverride = .vt100
        #expect(form.validateForEditSave()?.ssh?.terminalType == .vt100)
    }

    /// Choosing "Use the global setting" again clears the stored override,
    /// rather than leaving the old one in place because `nil` looked like
    /// "unchanged".
    @Test func savingAnEditBackToTheGlobalSettingClearsTheOverride() {
        let form = makeForm()
        var stored = sshSession(name: "web", host: "host.invalid")
        stored.ssh?.terminalType = .vt100
        form.beginEditing(stored)
        form.terminalTypeOverride = nil
        let saved = form.validateForEditSave()
        #expect(saved != nil)
        #expect(saved?.ssh?.terminalType == nil)
    }

    /// Leaving edit mode is a mode switch like the group's, so an override
    /// picked for one session must not travel into whatever the form shows
    /// next (a new connection, an import fill).
    @Test func leavingEditModeForgetsTheOverride() {
        let form = makeForm()
        var stored = sshSession(name: "web", host: "host.invalid")
        stored.ssh?.terminalType = .vt100
        form.beginEditing(stored)
        form.exitEditMode()
        #expect(form.terminalTypeOverride == nil)
    }

    @Test func savingANewSessionCarriesTheOverride() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: InMemorySecretStore(),
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: ManagedKeyStore(directory: dir))
        let form = makeForm()
        form.host = "host.invalid"
        form.username = "u"

        let saved = list.save(
            name: "new", values: form.values, password: "", terminalType: .xterm)

        #expect(saved?.ssh?.terminalType == .xterm)
        #expect(try SessionStore(directory: dir).all().first?.ssh?.terminalType == .xterm)
    }
}
