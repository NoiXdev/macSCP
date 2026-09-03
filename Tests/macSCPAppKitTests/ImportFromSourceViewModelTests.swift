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
        /// Set only by the test that asks WHERE the read ran.
        var recorder: Recorder?

        func locate(home: URL) -> URL? { nil }

        func read(from folder: URL) throws -> [ExternalBookmark] {
            recorder?.record(isMainThread: Thread.isMainThread)
            if let failure { throw failure }
            return bookmarks
        }
    }

    /// Records the thread `read(from:)` ran on. A reference type because
    /// `BookmarkSource` is `Sendable` and the source is passed BY VALUE — a
    /// `var` on the struct would be written on a copy the test never sees.
    /// `@unchecked Sendable` over a lock, the same shape
    /// `DiagnosticsViewModelTests`' own recorders use.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var wasMainThread: Bool?
        /// `nil` until `read` has run at all — which is itself worth
        /// distinguishing from "ran, and not on the main thread".
        var ranOnMainThread: Bool? { lock.withLock { wasMainThread } }
        func record(isMainThread: Bool) { lock.withLock { wasMainThread = isMainThread } }
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

    /// A model loaded from `fiveBookmarks()`. What the five rows come out AS
    /// depends on what it is planned against, and only the store built by
    /// `matchingStore()` produces one of each of the five statuses — called
    /// bare (the default empty store), the first three rows are all `.new`.
    /// The sentence is here rather than on the fixture list because it is a
    /// claim about the PAIR, and it was written as if it held at every call
    /// site, which is the enumeration-in-a-comment mistake CLAUDE.md names.
    private func loadedModel(
        sessions: [StoredSession] = [], groups: [StoredGroup] = []
    ) async -> ImportFromSourceViewModel {
        let model = ImportFromSourceViewModel(sessions: sessions, groups: groups)
        await model.load(source: FakeSource(bookmarks: fiveBookmarks()), folder: Self.folder)
        return model
    }

    /// Five bookmarks: two ordinary sftp ones, one whose port moved, an FTP
    /// one (a protocol with no backend) and a file that would not parse.
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

    @Test func theRowsAreTheSourcesBookmarksJudgedAgainstTheStore() async {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)

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
    @Test func theDefaultTicksAreThePlanners() async {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)

        #expect(model.rows.map(\.selected) == [true, false, true, false, false])
    }

    @Test func aFolderTheSourceCannotReadLeavesNoRowsAndAMessage() async {
        let model = ImportFromSourceViewModel(sessions: [], groups: [])
        await model.load(source: FakeSource(failure: FolderUnreadable()), folder: Self.folder)

        #expect(model.rows.isEmpty)
        #expect(model.loadError != nil)
        #expect(model.canImport == false)
    }

    /// The read runs OFF the main actor (I-3): `read(from:)` is a directory
    /// listing plus one file read and one plist parse per bookmark, and the
    /// folder may be on a network volume the picker happily accepted.
    ///
    /// `Thread.isMainThread` inside the source, recorded through a reference
    /// the test still holds — the source is passed by value, so a flag on the
    /// struct would be written on a copy nobody can read.
    ///
    /// The two expectations are separate on purpose: `ranOnMainThread` is an
    /// optional, and a `!= true` on its own would also be satisfied by a read
    /// that never happened.
    @Test func theFolderIsReadOffTheMainActor() async {
        let recorder = Recorder()
        let model = ImportFromSourceViewModel(sessions: [], groups: [])

        await model.load(
            source: FakeSource(bookmarks: fiveBookmarks(), recorder: recorder),
            folder: Self.folder)

        #expect(recorder.ranOnMainThread != nil, "the anchor: the source was actually read")
        #expect(recorder.ranOnMainThread == false, """
            The bookmark folder was read on the main thread. A directory on a network volume \
            would freeze the window with no spinner until the last file is parsed.
            """)
        // And the model is back on the main actor afterwards, holding what
        // the read produced.
        #expect(model.rows.count == fiveBookmarks().count)
    }

    @Test func aFolderWithNoBookmarksIsEmptyRatherThanBroken() async {
        let model = ImportFromSourceViewModel(sessions: [], groups: [])
        await model.load(source: FakeSource(), folder: Self.folder)

        #expect(model.rows.isEmpty)
        #expect(model.loadError == nil)
    }

    // MARK: - The summary line

    @Test func theSummaryCountsImportsUpdatesSkipsAndUnimportableRows() async {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)

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
    @Test func aTickedUnchangedRowCountsAsAnUpdate() async throws {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)
        let unchanged = try #require(model.rows.first { $0.id == "same" })

        model.toggle(row: unchanged)

        #expect(model.summary.importing == 3)
        #expect(model.summary.updating == 2)
        #expect(model.summary.skipped == 0)
    }

    // MARK: - Ticking

    @Test func togglingARowFlipsItAndOnlyIt() async throws {
        let model = await loadedModel()
        let first = try #require(model.rows.first)

        model.toggle(row: first)

        #expect(model.rows[0].selected == false)
        #expect(model.rows.dropFirst().map(\.selected) == [true, true, false, false])
    }

    /// The negative half of `PreviewStatus.isSelectable`, with the positive
    /// anchor beside it: a selectable row in the same model does flip.
    @Test func anUnimportableRowCannotBeTicked() async throws {
        // Against the store, so the anchor row starts UNTICKED: a toggle
        // that turned a ticked row off would prove nothing about a toggle
        // reaching a row at all.
        let model = await loadedModel(sessions: matchingStore().sessions)
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

    @Test func selectAllAndSelectNoneOnlyTouchWhatCanBeImported() async {
        let model = await loadedModel()

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
    @Test func aTickSurvivesASwitchFlip() async throws {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)
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
    @Test func theLabelsSwitchRePlansTheRows() async throws {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)
        #expect(model.rows.first { $0.id == "same" }?.status == .knownUnchanged(store.same))

        model.takesGroupAndLabels = true

        let row = try #require(model.rows.first { $0.id == "same" })
        #expect(row.status.storedSessionID == store.same)
        #expect(row.status != .knownUnchanged(store.same))
    }

    // MARK: - The group picker

    @Test func theGroupDefaultsToANewGroupNamedAfterTheSource() async {
        let model = await loadedModel()

        #expect(model.groupChoice == .create(model.sourceName))
        #expect(model.groupChoices.contains(.ungrouped))
        #expect(model.groupChoices.contains(.create(model.sourceName)))
    }

    @Test func anExistingGroupOfThatNameIsChosenRatherThanASecondOne() async {
        let existing = StoredGroup(name: "Fake")
        let model = await loadedModel(groups: [existing])

        #expect(model.sourceName == existing.name)
        #expect(model.groupChoice == .existing(existing.id))
        #expect(model.groupChoices.contains(.create(existing.name)) == false)
    }

    // MARK: - The payload

    @Test func thePayloadCarriesOnlyTheTickedRows() async {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)

        let payload = model.payload()

        #expect(payload.sessions.map(\.importID) == ["new", "moved"])
        #expect(payload.sessions.allSatisfy { $0.importSource == FakeSource.id })
    }

    @Test func thePayloadFilesIntoTheChosenGroupOnlyWithTheSwitch() async throws {
        let model = await loadedModel()

        #expect(model.payload().groups.isEmpty)

        model.takesGroupAndLabels = true
        let payload = model.payload()
        let group = try #require(payload.groups.first)
        #expect(group.name == model.sourceName)
        #expect(payload.sessions.allSatisfy { $0.groupID == group.id })
    }

    @Test func thePayloadTakesTheChosenExistingGroup() async throws {
        let existing = StoredGroup(name: "Servers")
        let model = await loadedModel(groups: [existing])
        model.takesGroupAndLabels = true
        model.groupChoice = .existing(existing.id)

        let payload = model.payload()

        let group = try #require(payload.groups.first { $0.name == existing.name })
        #expect(payload.sessions.allSatisfy { $0.groupID == group.id })
    }

    @Test func thePayloadTakesNoGroupWhenTheChoiceIsNone() async {
        let model = await loadedModel()
        model.takesGroupAndLabels = true
        model.groupChoice = .ungrouped

        let payload = model.payload()

        #expect(payload.groups.isEmpty)
        #expect(payload.sessions.allSatisfy { $0.groupID == nil })
    }

    @Test func thePayloadAnnouncesSecretsOnlyWithTheirSwitch() async {
        let model = await loadedModel()

        #expect(model.payload().includesSecrets == false)

        model.takeSecrets = true
        #expect(model.payload().includesSecrets)
    }

    /// The applier needs a bookmark per exported entry to ask the keychain
    /// with, and it must find one for exactly the rows the payload carries.
    @Test func theTickedBookmarksAreReachableByTheirImportID() async {
        let store = matchingStore()
        let model = await loadedModel(sessions: store.sessions)

        let byID = model.selectedBookmarksByID
        let payload = model.payload()

        #expect(Set(byID.keys) == ["new", "moved"])
        #expect(payload.sessions.allSatisfy { byID[$0.importID ?? ""] != nil })
    }

    // MARK: - The keychain half of an import

    /// A stand-in for a secret. Held in a NAMED CONSTANT and compared into a
    /// `Bool` before any expectation: `#expect` reports the SOURCE TEXT of
    /// what it checks, so a value written into an expectation leaks through
    /// the failure message — which is exactly when somebody is reading it.
    /// Nothing here touches the real keychain; `read` is a closure.
    /// `nonisolated` because the `read` seam is `@Sendable` — the reader it
    /// stands in for resumes from its own queue, so the closure genuinely
    /// leaves this actor.
    nonisolated private static let stubSecret = "stand-in-not-a-real-credential"

    private func exported(importID: String, kind: ConnectionKind) -> ExportedSession {
        ExportedSession(
            id: UUID(), name: importID, kind: kind, fields: [:], importSource: FakeSource.id,
            importID: importID)
    }

    /// The rule I-1 exists for: only a query that RAN and found nothing is
    /// reported. `.notAttempted` means the reader asked the keychain nothing,
    /// because the bookmark cannot have an item — counting it told the user
    /// that passwords "could not be read" about items that never existed.
    ///
    /// The positive anchor sits in the same test: the `.notFound` entry IS
    /// counted, so a rule that stopped counting anything would fail here too.
    @Test func onlyAQueryThatRanAndFoundNothingIsCounted() async {
        var payload = SessionExportPayload(
            includesSecrets: true, groups: [],
            sessions: [
                exported(importID: "found", kind: .ssh),
                exported(importID: "missing", kind: .ssh),
                exported(importID: "never-asked", kind: .ssh),
            ])
        let bookmarks = Dictionary(
            uniqueKeysWithValues: ["found", "missing", "never-asked"].map {
                ($0, bookmark(id: $0, host: "\($0).example.net", username: "deploy"))
            })

        let notRead = await ExternalImportSecrets.fill(
            into: &payload, bookmarks: bookmarks,
            read: { bookmark in
                switch bookmark.id {
                case "found": return .found(Self.stubSecret)
                case "missing": return .notFound
                default: return .notAttempted
                }
            })

        #expect(notRead == 1)
        let filledTheFoundOne = payload.sessions[0].password == Self.stubSecret
        let leftTheMissingOneAlone = payload.sessions[1].password == nil
        let leftTheUnaskedOneAlone = payload.sessions[2].password == nil
        #expect(filledTheFoundOne)
        #expect(leftTheMissingOneAlone)
        #expect(leftTheUnaskedOneAlone)
    }

    /// An S3 session's credential is its secret access key, not a password —
    /// the same split `SessionImportPlanner` makes on the way back out. Put
    /// in the wrong slot it is silently dropped, and the session imports
    /// without a credential.
    @Test func anS3SecretLandsInTheAccessKeySlotAndNotThePassword() async {
        var payload = SessionExportPayload(
            includesSecrets: true, groups: [],
            sessions: [exported(importID: "bucket", kind: .s3)])
        let bookmarks = [
            "bucket": bookmark(
                id: "bucket", protocol: .s3, host: "s3.example.net", username: "AKIAEXAMPLE",
                path: "backups")
        ]

        _ = await ExternalImportSecrets.fill(
            into: &payload, bookmarks: bookmarks, read: { _ in .found(Self.stubSecret) })

        let landedOnTheAccessKey = payload.sessions[0].s3SecretAccessKey == Self.stubSecret
        let didNotLandOnThePassword = payload.sessions[0].password == nil
        #expect(landedOnTheAccessKey)
        #expect(didNotLandOnThePassword)
    }

    /// An entry with no bookmark behind it — its row was dropped, or the
    /// payload carries something the preview did not produce — is skipped
    /// without being counted as a failure.
    @Test func anEntryWithNoBookmarkBehindItIsNeitherFilledNorCounted() async {
        var payload = SessionExportPayload(
            includesSecrets: true, groups: [],
            sessions: [exported(importID: "orphan", kind: .ssh)])

        let notRead = await ExternalImportSecrets.fill(
            into: &payload, bookmarks: [:], read: { _ in .notFound })

        #expect(notRead == 0)
        #expect(payload.sessions[0].password == nil)
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
