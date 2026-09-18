import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// `SessionEditorNewGroupPlan` — the session editor's "New group…" button
/// (jump-and-groups plan, Task 5). Where the group lands, what the prompt is
/// titled, and that the picker shows the created group afterwards. That
/// `SessionEditorGroupPicker` reads this plan is `GroupPickerWiringGuardTests`'
/// claim, not this suite's.
@MainActor
@Suite("Session editor new-group plan")
struct SessionEditorNewGroupPlanTests {
    private static func makeSessionList(in directory: URL) -> SessionListViewModel {
        SessionListViewModel(
            store: SessionStore(directory: directory),
            secrets: EditorNewGroupSecretStore(),
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-new-group-\(UUID().uuidString)")
    }

    private static func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in
            fatalError("not exercised by these tests — nothing here dials")
        })
    }

    // MARK: - Where it lands

    @Test func withNoGroupChosenTheNewGroupLandsAtTheTopLevel() {
        let work = StoredGroup(name: "Work")
        #expect(SessionEditorNewGroupPlan.parentID(forSelection: nil, groups: [work]) == nil)
    }

    @Test func withAGroupChosenTheNewGroupLandsInsideIt() {
        let work = StoredGroup(name: "Work")
        #expect(SessionEditorNewGroupPlan.parentID(forSelection: work.id, groups: [work]) == work.id)
    }

    /// A selection naming no group — deleted from the sidebar while the
    /// editor was open — is what the picker cannot show either: top level,
    /// rather than a create the store would refuse for its missing parent.
    @Test func aChosenGroupThatNoLongerExistsLandsAtTheTopLevel() {
        let work = StoredGroup(name: "Work")
        #expect(SessionEditorNewGroupPlan.parentID(forSelection: UUID(), groups: [work]) == nil)
    }

    // MARK: - The prompt's title

    @Test func thePromptIsTitledLikeTheSidebarsForTheSameParent() {
        let work = StoredGroup(name: "Work")
        #expect(
            SessionEditorNewGroupPlan.title(forSelection: work.id, groups: [work])
                == SidebarNewGroupAlertPlan.title(parentID: work.id, groups: [work]))
        #expect(
            SessionEditorNewGroupPlan.title(forSelection: nil, groups: [work])
                == SidebarNewGroupAlertPlan.title(parentID: nil, groups: [work]))
        #expect(
            SessionEditorNewGroupPlan.title(forSelection: UUID(), groups: [work])
                == SidebarNewGroupAlertPlan.title(parentID: nil, groups: [work]))
    }

    // MARK: - Commit: created, nested, and selected

    @Test func committingAtTheTopLevelCreatesTheGroupAndSelectsIt() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionList = Self.makeSessionList(in: directory)
        let form = Self.makeForm()

        let created = try #require(
            SessionEditorNewGroupPlan.commit(name: "Work", form: form, sessionList: sessionList))

        #expect(created.parentID == nil)
        #expect(sessionList.groups.map(\.id) == [created.id])
        #expect(form.selectedGroupID == created.id)
    }

    @Test func committingWithAGroupChosenCreatesInsideItAndSelectsTheNewOne() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionList = Self.makeSessionList(in: directory)
        let work = try #require(sessionList.createGroup(named: "Work"))
        let form = Self.makeForm()
        form.selectedGroupID = work.id

        let created = try #require(
            SessionEditorNewGroupPlan.commit(name: "Prod", form: form, sessionList: sessionList))

        #expect(created.parentID == work.id)
        #expect(form.selectedGroupID == created.id)
        #expect(
            GroupPickerEntries.build(groups: sessionList.groups).map(\.path) == ["Work", "Work / Prod"])
    }

    /// An empty name creates nothing, and the picker keeps what it showed —
    /// the same no-op `createGroup(named:)` already answers for it.
    @Test func anEmptyNameCreatesNothingAndKeepsTheSelection() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionList = Self.makeSessionList(in: directory)
        let work = try #require(sessionList.createGroup(named: "Work"))
        let form = Self.makeForm()
        form.selectedGroupID = work.id

        let created = SessionEditorNewGroupPlan.commit(name: "   ", form: form, sessionList: sessionList)

        #expect(created == nil)
        #expect(sessionList.groups.map(\.id) == [work.id])
        #expect(form.selectedGroupID == work.id)
    }

    // MARK: - Catalogue

    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SessionEditorNewGroupPlanTests.swift`.
    private static let catalogDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")

    /// Every key the editor's "New group…" button, its tooltip and its
    /// prompt read. All but the tooltip are the sidebar's own, reused so the
    /// same action reads the same everywhere; the tooltip is new with this
    /// task. `L10n.string` falls back to English silently, so a key missing
    /// from one language is red only here.
    private static let editorNewGroupKeys = [
        "sidebar.newGroup",
        "connection.field.group.new.help",
        "sidebar.newGroup.title",
        "sidebar.newGroup.title.inFolder %@",
        "sidebar.newGroup.placeholder",
        "sidebar.newGroup.create",
        "common.cancel",
    ]

    @Test func everyKeyTheEditorsNewGroupReadsIsTranslatedInAllFourLanguages() throws {
        let locales = try FileManager.default
            .contentsOfDirectory(atPath: Self.catalogDirectory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
        #expect(locales == ["de", "en", "fr", "pl"])
        for locale in locales {
            let path = Self.catalogDirectory
                .appendingPathComponent("\(locale).lproj/Localizable.strings")
                .path(percentEncoded: false)
            let entries = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for key in Self.editorNewGroupKeys {
                let value = entries[key] ?? ""
                #expect(!value.isEmpty, "\(locale).lproj has no text for \(key)")
            }
        }
    }
}

/// Stores nothing and answers nothing — the same stand-in several suites in
/// this target keep privately, so no test here reaches the real Keychain.
private struct EditorNewGroupSecretStore: SecretStore {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {}
}
