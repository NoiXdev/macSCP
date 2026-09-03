import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The import sheet's view model, over a FAKE bookmark source, plus the
/// presentation that turns one `PreviewRow` into the four columns the sheet
/// draws.
///
/// Nothing here touches Cyberduck's folder or the keychain (the plan's
/// global constraint): the source is a value that hands back bookmarks built
/// in memory, and the store side is a list of `StoredSession`s. No secret
/// ever reaches this model — `ImportSwitches.takeSecrets` only travels
/// through to `SessionExportPayload.includesSecrets`, and the reader that
/// resolves a secret lives in the applier, not here.
@MainActor
@Suite("Import-from-source view model")
struct ImportFromSourceViewModelTests {
    // MARK: - Fixtures

    /// A source that hands back whatever it was built with. It conforms to
    /// the real protocol, so a change to `BookmarkSource` breaks this fake
    /// rather than leaving the tests measuring an obsolete shape.
    private struct FakeSource: BookmarkSource {
        static let id = "fake"
        static let displayNameKey = "import.source.fake"

        var bookmarks: [ExternalBookmark] = []
        var failure: (any Error)?

        func locate(home: URL) -> URL? { nil }

        func read(from folder: URL) throws -> [ExternalBookmark] {
            if let failure { throw failure }
            return bookmarks
        }
    }

    private struct FolderUnreadable: Error {}

    private static let folder = URL(fileURLWithPath: "/nowhere/bookmarks")

    private func bookmark(
        id: String, protocol protocolValue: ExternalProtocol = .sftp,
        nickname: String? = nil, host: String = "", port: Int? = nil,
        username: String? = nil, path: String? = nil, labels: [String] = [],
        fileName: String = "bookmark.duck", unreadable: String? = nil
    ) -> ExternalBookmark {
        ExternalBookmark(
            id: id, source: FakeSource.id, nickname: nickname, protocol: protocolValue,
            host: host, port: port, username: username, keyPath: nil, path: path,
            labels: labels, fileName: fileName, unreadable: unreadable)
    }

    private func sshSession(
        id: UUID = UUID(), name: String, host: String, port: Int, username: String,
        tags: [String] = [], groupID: UUID? = nil, importID: String? = nil
    ) -> StoredSession {
        StoredSession(
            id: id, name: name, groupID: groupID, kind: .ssh,
            ssh: StoredSSHConfig(
                host: host, port: port, username: username, authKind: .password,
                keyPath: nil),
            tags: tags,
            importSource: importID == nil ? nil : FakeSource.id,
            importID: importID,
            importedAt: importID == nil ? nil : Date(timeIntervalSince1970: 0))
    }

    /// One of each of the five statuses the sheet has to draw, in one model:
    /// a bookmark nothing matches, one that matches unchanged, one that
    /// matches with a differing port, an FTP one, and a file that would not
    /// parse.
    private func loadedModel(
        sessions: [StoredSession] = [], groups: [StoredGroup] = []
    ) -> ImportFromSourceViewModel {
        let model = ImportFromSourceViewModel(sessions: sessions, groups: groups)
        model.load(source: FakeSource(bookmarks: fiveBookmarks()), folder: Self.folder)
        return model
    }

    private func fiveBookmarks() -> [ExternalBookmark] {
        [
            bookmark(id: "new", nickname: "Fresh", host: "fresh.example.net", port: 22,
                     username: "deploy"),
            bookmark(id: "same", nickname: "Same", host: "same.example.net", port: 22,
                     username: "deploy", labels: ["prod"]),
            bookmark(id: "moved", nickname: "Moved", host: "moved.example.net", port: 2222,
                     username: "deploy"),
            bookmark(id: "ftp", protocol: .unsupported("ftp"), nickname: "Files",
                     host: "files.example.net", port: 21, username: "anon"),
            bookmark(id: "broken.duck", nickname: nil, fileName: "broken.duck",
                     unreadable: "broken.duck: not a property list"),
        ]
    }

    /// The two stored sessions the fixtures above match. `same` is matched
    /// by the connection key and agrees on every field the source knows;
    /// `moved` is matched by PROVENANCE and differs by its port — which is
    /// part of the connection key, so provenance is the only thing that can
    /// still recognise it.
    private func matchingStore() -> (sessions: [StoredSession], same: UUID, moved: UUID) {
        let sameID = UUID()
        let movedID = UUID()
        return (
            [
                sshSession(id: sameID, name: "Same", host: "same.example.net", port: 22,
                           username: "deploy"),
                sshSession(id: movedID, name: "Moved", host: "moved.example.net", port: 22,
                           username: "deploy", importID: "moved"),
            ],
            sameID, movedID)
    }

    // MARK: - Loading

    @Test func theRowsAreTheSourcesBookmarksJudgedAgainstTheStore() {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)

        #expect(model.rows.map(\.id) == ["new", "same", "moved", "ftp", "broken.duck"])
        #expect(model.rows[0].status == .new)
        #expect(model.rows[1].status == .knownUnchanged(store.same))
        #expect(model.rows[2].status.storedSessionID == store.moved)
        #expect(model.rows[3].status == .unsupported("ftp"))
        #expect(model.loadError == nil)
    }

    /// The default ticks are the planner's (`.new` and `.knownChanged` on,
    /// `.knownUnchanged` off, the two unimportable ones off and unticked) —
    /// the model must not invent its own.
    @Test func theDefaultTicksAreThePlanners() {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)

        #expect(model.rows.map(\.selected) == [true, false, true, false, false])
    }

    @Test func aFolderTheSourceCannotReadLeavesNoRowsAndAMessage() {
        let model = ImportFromSourceViewModel(sessions: [], groups: [])
        model.load(source: FakeSource(failure: FolderUnreadable()), folder: Self.folder)

        #expect(model.rows.isEmpty)
        #expect(model.loadError != nil)
        #expect(model.canImport == false)
    }

    @Test func aFolderWithNoBookmarksIsEmptyRatherThanBroken() {
        let model = ImportFromSourceViewModel(sessions: [], groups: [])
        model.load(source: FakeSource(), folder: Self.folder)

        #expect(model.rows.isEmpty)
        #expect(model.loadError == nil)
    }

    // MARK: - The summary line

    @Test func theSummaryCountsImportsUpdatesSkipsAndUnimportableRows() {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)

        // `new` + `moved` ticked; `moved` is the update. `same` is the one
        // selectable row left unticked. `ftp` and `broken.duck` cannot be
        // ticked at all.
        #expect(model.summary.importing == 2)
        #expect(model.summary.updating == 1)
        #expect(model.summary.skipped == 1)
        #expect(model.summary.unimportable == 2)
    }

    /// Task 3's fix round 2: a ticked unchanged row is a provenance-only
    /// UPDATE, and the planner counts it in `plan.replaced`. So the summary
    /// has to count it as one too, or the user ticks a row that looks
    /// untouched and reads "1 replaced".
    @Test func aTickedUnchangedRowCountsAsAnUpdate() throws {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)
        let unchanged = try #require(model.rows.first { $0.id == "same" })

        model.toggle(row: unchanged)

        #expect(model.summary.importing == 3)
        #expect(model.summary.updating == 2)
        #expect(model.summary.skipped == 0)
    }

    // MARK: - Ticking

    @Test func togglingARowFlipsItAndOnlyIt() throws {
        let model = loadedModel()
        let first = try #require(model.rows.first)

        model.toggle(row: first)

        #expect(model.rows[0].selected == false)
        #expect(model.rows.dropFirst().map(\.selected) == [true, true, false, false])
    }

    /// The negative half of `PreviewStatus.isSelectable`, with the positive
    /// anchor beside it: a selectable row in the same model does flip.
    @Test func anUnimportableRowCannotBeTicked() throws {
        // Against the store, so the anchor row starts UNTICKED: a toggle
        // that turned a ticked row off would prove nothing about a toggle
        // reaching a row at all.
        let model = loadedModel(sessions: matchingStore().sessions)
        let unsupported = try #require(model.rows.first { $0.id == "ftp" })
        let unreadable = try #require(model.rows.first { $0.id == "broken.duck" })
        let selectable = try #require(model.rows.first { $0.id == "same" })

        model.toggle(row: unsupported)
        model.toggle(row: unreadable)
        model.toggle(row: selectable)

        #expect(model.rows.first { $0.id == "ftp" }?.selected == false)
        #expect(model.rows.first { $0.id == "broken.duck" }?.selected == false)
        #expect(model.rows.first { $0.id == "same" }?.selected == true)
    }

    @Test func selectAllAndSelectNoneOnlyTouchWhatCanBeImported() {
        let model = loadedModel()

        model.selectAll()
        #expect(model.rows.map(\.selected) == [true, true, true, false, false])
        #expect(model.canImport)

        model.selectNone()
        #expect(model.rows.allSatisfy { $0.selected == false })
        #expect(model.canImport == false)
    }

    /// Flipping the second switch re-plans (labels move in and out of the
    /// change list), and a re-plan must not silently undo what the user
    /// ticked.
    ///
    /// The row is one the user UNTICKED, and one whose status the flip does
    /// not change — so the planner's own default for it stays `true` across
    /// the re-plan. A row ticked ON would have been the wrong fixture:
    /// `same` goes from unchanged to changed when labels come into play, and
    /// a changed row starts ticked, so the tick would have survived by
    /// accident and the test would have been green with the restore deleted
    /// (measured 2026-09-03).
    @Test func aTickSurvivesASwitchFlip() throws {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)
        let ticked = try #require(model.rows.first { $0.id == "new" })
        model.toggle(row: ticked)
        #expect(model.rows.first { $0.id == "new" }?.selected == false,
                "the fixture starts from a row the user turned OFF")

        model.takesGroupAndLabels = true

        #expect(model.rows.first { $0.id == "new" }?.selected == false, """
            Re-planning after a switch flip put the planner's default back over what the user             had decided.
            """)
    }

    /// And the re-plan really happens: with the labels switch on, the stored
    /// session's empty tag list differs from the bookmark's `["prod"]`, so
    /// the row that was `.knownUnchanged` becomes `.knownChanged`.
    @Test func theLabelsSwitchRePlansTheRows() throws {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)
        #expect(model.rows.first { $0.id == "same" }?.status == .knownUnchanged(store.same))

        model.takesGroupAndLabels = true

        let row = try #require(model.rows.first { $0.id == "same" })
        #expect(row.status.storedSessionID == store.same)
        #expect(row.status != .knownUnchanged(store.same))
    }

    // MARK: - The group picker

    @Test func theGroupDefaultsToANewGroupNamedAfterTheSource() {
        let model = loadedModel()

        #expect(model.groupChoice == .create(model.sourceName))
        #expect(model.groupChoices.contains(.ungrouped))
        #expect(model.groupChoices.contains(.create(model.sourceName)))
    }

    @Test func anExistingGroupOfThatNameIsChosenRatherThanASecondOne() {
        let existing = StoredGroup(name: "Fake")
        let model = loadedModel(groups: [existing])

        #expect(model.sourceName == existing.name)
        #expect(model.groupChoice == .existing(existing.id))
        #expect(model.groupChoices.contains(.create(existing.name)) == false)
    }

    // MARK: - The payload

    @Test func thePayloadCarriesOnlyTheTickedRows() {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)

        let payload = model.payload()

        #expect(payload.sessions.map(\.importID) == ["new", "moved"])
        #expect(payload.sessions.allSatisfy { $0.importSource == FakeSource.id })
    }

    @Test func thePayloadFilesIntoTheChosenGroupOnlyWithTheSwitch() throws {
        let model = loadedModel()

        #expect(model.payload().groups.isEmpty)

        model.takesGroupAndLabels = true
        let payload = model.payload()
        let group = try #require(payload.groups.first)
        #expect(group.name == model.sourceName)
        #expect(payload.sessions.allSatisfy { $0.groupID == group.id })
    }

    @Test func thePayloadTakesTheChosenExistingGroup() throws {
        let existing = StoredGroup(name: "Servers")
        let model = loadedModel(groups: [existing])
        model.takesGroupAndLabels = true
        model.groupChoice = .existing(existing.id)

        let payload = model.payload()

        let group = try #require(payload.groups.first { $0.name == existing.name })
        #expect(payload.sessions.allSatisfy { $0.groupID == group.id })
    }

    @Test func thePayloadTakesNoGroupWhenTheChoiceIsNone() {
        let model = loadedModel()
        model.takesGroupAndLabels = true
        model.groupChoice = .ungrouped

        let payload = model.payload()

        #expect(payload.groups.isEmpty)
        #expect(payload.sessions.allSatisfy { $0.groupID == nil })
    }

    @Test func thePayloadAnnouncesSecretsOnlyWithTheirSwitch() {
        let model = loadedModel()

        #expect(model.payload().includesSecrets == false)

        model.takeSecrets = true
        #expect(model.payload().includesSecrets)
    }

    /// The applier needs a bookmark per exported entry to ask the keychain
    /// with, and it must find one for exactly the rows the payload carries.
    @Test func theTickedBookmarksAreReachableByTheirImportID() {
        let store = matchingStore()
        let model = loadedModel(sessions: store.sessions)

        let byID = model.selectedBookmarksByID
        let payload = model.payload()

        #expect(Set(byID.keys) == ["new", "moved"])
        #expect(payload.sessions.allSatisfy { byID[$0.importID ?? ""] != nil })
    }

    // MARK: - What the sheet draws

    /// Every status the table can show, through the one mapper the sheet
    /// calls. `statusText` switches over `PreviewStatus` exhaustively, so a
    /// sixth case is a compile error here rather than a row with no text.
    @Test func everyStatusHasItsOwnLine() {
        let stored = UUID()
        let texts = [
            ImportPreviewPresentation.statusText(for: .new),
            ImportPreviewPresentation.statusText(for: .knownUnchanged(stored)),
            ImportPreviewPresentation.statusText(
                for: .knownChanged(stored, [FieldChange(
                    field: ImportPreviewPlanner.FieldKey.port, old: "22", new: "2222")])),
            ImportPreviewPresentation.statusText(for: .unsupported("ftp")),
            ImportPreviewPresentation.statusText(for: .unreadable("broken.duck: no")),
        ]

        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == texts.count, "\(texts)")
    }

    /// The change list is what makes a `.knownChanged` row worth reading:
    /// the field's own name and both values.
    @Test func aChangedRowNamesTheFieldAndBothValues() {
        let text = ImportPreviewPresentation.statusText(
            for: .knownChanged(UUID(), [
                FieldChange(field: ImportPreviewPlanner.FieldKey.port, old: "22", new: "2222"),
                FieldChange(
                    field: ImportPreviewPlanner.FieldKey.host, old: "a.example.net",
                    new: "b.example.net"),
            ]))

        #expect(text.contains("22"))
        #expect(text.contains("2222"))
        #expect(text.contains("a.example.net"))
        #expect(text.contains("b.example.net"))
    }

    /// Only a change is tinted — the design's one visual distinction in the
    /// status column.
    @Test func onlyAChangedRowIsTinted() {
        #expect(ImportPreviewPresentation.isChange(.knownChanged(UUID(), [])))
        #expect(ImportPreviewPresentation.isChange(.new) == false)
        #expect(ImportPreviewPresentation.isChange(.knownUnchanged(UUID())) == false)
        #expect(ImportPreviewPresentation.isChange(.unsupported("ftp")) == false)
        #expect(ImportPreviewPresentation.isChange(.unreadable("x")) == false)
    }

    @Test func theNameColumnFallsBackFromNicknameToHostToFileName() {
        #expect(ImportPreviewPresentation.name(
            for: bookmark(id: "a", nickname: "Web", host: "web.example.net")) == "Web")
        #expect(ImportPreviewPresentation.name(
            for: bookmark(id: "b", host: "web.example.net")) == "web.example.net")
        #expect(ImportPreviewPresentation.name(
            for: bookmark(id: "c", fileName: "broken.duck",
                          unreadable: "broken.duck: no")) == "broken.duck")
    }

    @Test func theTargetColumnReadsUserAtHostAndEndpointWithBucket() {
        let sftp = ImportPreviewPresentation.target(
            for: bookmark(id: "a", host: "web.example.net", port: 2222, username: "deploy"))
        #expect(sftp == "deploy@web.example.net:2222")

        let s3 = ImportPreviewPresentation.target(
            for: bookmark(id: "b", protocol: .s3, host: "s3.example.net",
                          username: "AKIAEXAMPLE", path: "backups"))
        #expect(s3.contains("s3.example.net"))
        #expect(s3.contains("backups"))
    }

    /// The badge is the backend's own, read off its descriptor — the same
    /// text the sidebar and the tab strip put on a session of that kind, so
    /// the preview cannot call a protocol something the rest of the app does
    /// not. A protocol macSCP has no backend for has no descriptor to read,
    /// and is shown under the source's own spelling.
    @Test func theBadgeNamesTheProtocolThroughTheBackendDescriptor() {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        #expect(ImportPreviewPresentation.badge(for: bookmark(id: "a"))
                == L10n.string(ssh.badgeLabelKey, ssh.badgeLabelDefault))

        let s3 = BackendDescriptor.descriptor(for: .s3)
        #expect(ImportPreviewPresentation.badge(for: bookmark(id: "b", protocol: .s3))
                == L10n.string(s3.badgeLabelKey, s3.badgeLabelDefault))

        #expect(ImportPreviewPresentation.badge(
            for: bookmark(id: "c", protocol: .unsupported("davs"))) == "DAVS")
    }
}
