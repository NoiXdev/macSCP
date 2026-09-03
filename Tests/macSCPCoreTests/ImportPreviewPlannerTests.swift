import Foundation
import Testing
@testable import macSCPCore

/// `ImportPreviewPlanner` — the pure planner behind the import preview
/// (`docs/superpowers/specs/2026-09-03-cyberduck-import-design.md` §2/§3/§6).
///
/// No store, no file system, no keychain: every fixture is a `StoredSession`
/// or an `ExternalBookmark` built in memory. No secret ever reaches this
/// planner, so no expectation here can leak one.
@Suite("ImportPreviewPlanner")
struct ImportPreviewPlannerTests {

    // MARK: - Matching

    @Test func aBookmarkNothingMatchesIsNewAndSelected() {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: ImportSwitches())

        #expect(rows.count == 1)
        #expect(rows.first?.status == .new)
        #expect(rows.first?.selected == true)
        #expect(rows.first?.id == sftpBookmark().id)
    }

    @Test func provenanceMatchesEvenWhenTheConnectionMoved() throws {
        let storedID = UUID()
        let stored = sshSession(
            id: storedID, name: "Web", host: "old.example.net", port: 22,
            username: "deploy", importID: sftpBookmark().id)

        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(host: "new.example.net")], against: [stored],
            switches: ImportSwitches())

        let row = try #require(rows.first)
        #expect(matchedID(row.status) == storedID)
        let changes = try #require(changeList(row.status))
        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.host
                                   && $0.old == "old.example.net"
                                   && $0.new == "new.example.net" })
        #expect(row.selected == true)
    }

    @Test func provenanceIsConsultedBeforeTheConnectionKey() throws {
        let provenanceID = UUID()
        let connectionID = UUID()
        // One session macSCP imported from this bookmark and the user then
        // moved; one unrelated session that now sits on the bookmark's
        // connection. The order in §2 says the first one wins.
        let moved = sshSession(
            id: provenanceID, name: "Web 01", host: "moved.example.net", port: 22,
            username: "deploy", importID: sftpBookmark().id)
        let squatter = sshSession(
            id: connectionID, name: "Someone else", host: "web-01.example.net", port: 22,
            username: "deploy")

        let row = try #require(ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [squatter, moved], switches: ImportSwitches()).first)

        #expect(row.status.storedSessionID == provenanceID)
        // The anchor: on its own, the squatter IS what the connection key finds.
        let withoutProvenance = try #require(ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [squatter], switches: ImportSwitches()).first)
        #expect(withoutProvenance.status.storedSessionID == connectionID)
    }

    @Test func theConnectionKeyMatchesASessionWithADifferentName() throws {
        let storedID = UUID()
        // Same host (in a different case — DNS folds it), port and user; the
        // NAME differs, and a name is never a match criterion.
        let stored = sshSession(
            id: storedID, name: "Something else entirely", host: "WEB-01.example.net",
            port: 2222, username: "deploy")
        let bookmark = sftpBookmark(
            nickname: "Web 01", host: "web-01.example.net", port: 2222, username: "deploy")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)

        #expect(matchedID(row.status) == storedID)
        let changes = try #require(changeList(row.status))
        // The nickname is a Cyberduck-known field, so it is listed …
        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.name
                                   && $0.old == "Something else entirely"
                                   && $0.new == "Web 01" })
        // … and so is the host's spelling, which the import would rewrite.
        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.host })
        #expect(row.selected == true)
    }

    @Test func anIdenticalBookmarkIsKnownUnchangedAndUnselected() throws {
        let storedID = UUID()
        let stored = sshSession(
            id: storedID, name: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")

        let row = try #require(ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: "Web 01", host: "web-01.example.net", port: 2222,
                          username: "deploy")],
            against: [stored], switches: ImportSwitches()).first)

        #expect(row.status == .knownUnchanged(storedID))
        #expect(row.selected == false)
    }

    @Test func aSessionWithTheSameNameButADifferentConnectionIsNotAMatch() throws {
        let stored = sshSession(
            name: "Web 01", host: "elsewhere.example.net", port: 22, username: "root")

        let row = try #require(ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: "Web 01", host: "web-01.example.net", port: 2222,
                          username: "deploy")],
            against: [stored], switches: ImportSwitches()).first)

        #expect(row.status == .new)
    }

    @Test func theChangeListNamesEveryDifferingSSHField() throws {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "root",
            keyPath: "/keys/old", importID: sftpBookmark().id)
        let bookmark = sftpBookmark(
            nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy", keyPath: "/keys/new")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        let fields = try #require(changeList(row.status)).map(\.field)

        #expect(fields.contains(ImportPreviewPlanner.FieldKey.port))
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.username))
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.keyPath))
        // Host and name are equal here, so neither may appear.
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.host) == false)
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.name) == false)
    }

    @Test func theChangeListNamesTheS3EndpointAndBucket() throws {
        let stored = s3Session(
            name: "Backups", endpoint: "https://s3.amazonaws.com", bucket: "old-bucket",
            accessKeyID: "AKIAEXAMPLE", importID: s3Bookmark().id)
        let bookmark = s3Bookmark(
            nickname: "Backups", host: "objects.example.net", port: 9000,
            username: "AKIAEXAMPLE", path: "new-bucket")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        let changes = try #require(changeList(row.status))

        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.endpoint
                                   && $0.new == "https://objects.example.net:9000" })
        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.bucket
                                   && $0.old == "old-bucket" && $0.new == "new-bucket" })
        #expect(changes.contains { $0.field == ImportPreviewPlanner.FieldKey.username } == false)
    }

    @Test func theLabelsSwitchMovesLabelsInAndOutOfTheChangeList() throws {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            tags: ["prod"])
        let bookmark = sftpBookmark(
            nickname: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            labels: ["staging"])

        let withoutSwitch = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        #expect(withoutSwitch.status == .knownUnchanged(stored.id))

        let withSwitch = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored],
            switches: ImportSwitches(takeLabelsAsTags: true)).first)
        let changes = try #require(changeList(withSwitch.status))
        #expect(changes.map(\.field) == [ImportPreviewPlanner.FieldKey.labels])
        #expect(changes.first?.old == "prod")
        #expect(changes.first?.new == "staging")
    }

    // MARK: - Rows nothing can import

    @Test func anUnsupportedProtocolIsUnselectedAndNotSelectable() throws {
        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark(protocol: .unsupported("ftp"), host: "files.example.net")],
            against: [], switches: ImportSwitches()).first)

        #expect(row.status == .unsupported("ftp"))
        #expect(row.selected == false)
        #expect(row.isSelectable == false)
        // Positive anchor for the negative check above: a supported row IS
        // selectable, so `isSelectable` is not simply false everywhere.
        let supported = try #require(ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: ImportSwitches()).first)
        #expect(supported.isSelectable == true)
    }

    @Test func anUnreadableFileIsUnreadableEvenThoughItsProtocolReadsUnsupported() throws {
        // Task 2 gives an unreadable file `.unsupported("")` and an empty
        // host, so `unreadable` has to be consulted BEFORE the protocol.
        let broken = ExternalBookmark(
            id: "malformed.duck", source: CyberduckBookmarkSource.id, nickname: nil,
            protocol: .unsupported(""), host: "", port: nil, username: nil,
            keyPath: nil, path: nil, labels: [], fileName: "malformed.duck",
            unreadable: "malformed.duck: not a property list")
        #expect(broken.protocol == .unsupported(""))  // the anchor for the line above

        let row = try #require(ImportPreviewPlanner.preview(
            [broken], against: [], switches: ImportSwitches()).first)

        #expect(row.status == .unreadable("malformed.duck: not a property list"))
        #expect(row.selected == false)
        #expect(row.isSelectable == false)
    }

    @Test func anUnreadableFileIsRefusedEvenWhenItsProtocolWasRead() throws {
        // Cyberduck's reader cannot produce this shape — it leaves the
        // protocol at `.unsupported("")` — but the ordering rule is about the
        // FIELD, not about that one source: a later `BookmarkSource` may well
        // read a protocol out of a file it then fails to parse.
        let broken = ExternalBookmark(
            id: "half-read.duck", source: CyberduckBookmarkSource.id, nickname: "Web 01",
            protocol: .sftp, host: "web-01.example.net", port: 22, username: "deploy",
            keyPath: nil, path: nil, labels: [], fileName: "half-read.duck",
            unreadable: "half-read.duck: truncated")
        #expect(broken.protocol == .sftp)  // the anchor: the protocol IS readable

        var rows = ImportPreviewPlanner.preview(
            [broken], against: [], switches: ImportSwitches())
        #expect(rows.first?.status == .unreadable("half-read.duck: truncated"))

        // And a ticked row of that shape still never reaches the payload.
        for index in rows.indices { rows[index].selected = true }
        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.isEmpty)
    }

    // MARK: - The payload

    @Test func payloadCarriesOnlySelectedNewAndChangedRows() {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            importID: "known-1")
        let bookmarks = [
            sftpBookmark(id: "new-1", host: "fresh.example.net"),
            sftpBookmark(id: "known-1", nickname: "Web 01", host: "web-01.example.net",
                         port: 2222, username: "deploy"),
            bookmark(id: "ftp-1", protocol: .unsupported("ftp"), host: "files.example.net"),
            ExternalBookmark(
                id: "broken.duck", source: CyberduckBookmarkSource.id, nickname: nil,
                protocol: .unsupported(""), host: "", port: nil, username: nil,
                keyPath: nil, path: nil, labels: [], fileName: "broken.duck",
                unreadable: "broken.duck: not a property list"),
        ]

        var rows = ImportPreviewPlanner.preview(
            bookmarks, against: [stored], switches: ImportSwitches())
        // Select every row, including the two that must never be importable.
        for index in rows.indices { rows[index].selected = true }

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], switches: ImportSwitches())

        #expect(payload.sessions.count == 2)
        #expect(payload.sessions.contains { $0.importID == "ftp-1" } == false)
        #expect(payload.sessions.contains { $0.importID == "broken.duck" } == false)
        #expect(payload.sessions.contains { $0.importID == "new-1" })
        #expect(payload.sessions.contains { $0.importID == "known-1" })

        // Deselecting is what keeps a row out; the two above are kept out
        // regardless of selection.
        let noneSelected = rows.map { row -> PreviewRow in
            var copy = row; copy.selected = false; return copy
        }
        #expect(ImportPreviewPlanner.payload(
            for: noneSelected, sessions: [stored], switches: ImportSwitches())
            .sessions.isEmpty)
    }

    @Test func aNewSFTPBookmarkWithAKeyFileBecomesAPrivateKeySession() throws {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: "Web 01", host: "web-01.example.net", port: 2222,
                          username: "deploy", keyPath: "/keys/id_ed25519")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.first)

        #expect(exported.kind == .ssh)
        #expect(exported.name == "Web 01")
        #expect(field(SSHField.host, of: exported) == "web-01.example.net")
        #expect(field(SSHField.port, of: exported) == "2222")
        #expect(field(SSHField.username, of: exported) == "deploy")
        #expect(field(SSHField.keyPath, of: exported) == "/keys/id_ed25519")
        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.privateKey.rawValue)
    }

    @Test func aNewSFTPBookmarkWithoutAKeyFileBecomesAPasswordSessionOnTheDefaultPort() throws {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: nil, host: "web-01.example.net", port: nil,
                          username: "deploy")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.first)

        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.password.rawValue)
        #expect(field(SSHField.keyPath, of: exported).isEmpty)
        #expect(field(SSHField.port, of: exported)
                == String(SSHFieldSchema.port(SSHFieldSchema.defaults)))
        // No nickname — the host is the fallback name.
        #expect(exported.name == "web-01.example.net")
    }

    @Test func anS3BookmarkOnAmazonUsesTheAWSDefaultEndpoint() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(nickname: "Backups", host: "s3.amazonaws.com", port: 443,
                        username: "AKIAEXAMPLE", path: "backups")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.first)

        #expect(exported.kind == .s3)
        #expect(field(S3Field.endpoint, of: exported) == awsPresetEndpoint)
        #expect(field(S3Field.accessKeyID, of: exported) == "AKIAEXAMPLE")
        #expect(field(S3Field.bucket, of: exported) == "backups")
        #expect(field(S3Field.startsAtBucketList, of: exported) == "false")
        #expect(field(S3Field.region, of: exported)
                == S3FieldSchema.defaults[S3Field.region])
    }

    @Test func anS3BookmarkOnAnotherHostUsesACustomEndpointWithThePort() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(host: "objects.example.net", port: 9000, username: "minio",
                        path: "media")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.first)

        #expect(field(S3Field.endpoint, of: exported) == "https://objects.example.net:9000")
    }

    @Test func anS3BookmarkWithoutAPathStartsAtTheBucketList() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(host: "objects.example.net", port: nil, username: "minio", path: "")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches()).sessions.first)

        #expect(field(S3Field.startsAtBucketList, of: exported) == "true")
        #expect(field(S3Field.bucket, of: exported).isEmpty)
        #expect(field(S3Field.endpoint, of: exported) == "https://objects.example.net")
    }

    @Test func anUpdateKeepsTheStoredNameGroupAndTagsAndCarriesTheStoredID() throws {
        let storedID = UUID()
        let groupID = UUID()
        let stored = sshSession(
            id: storedID, name: "The name the user chose", host: "web-01.example.net",
            port: 22, username: "deploy", tags: ["prod"], groupID: groupID,
            importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Cyberduck's own name", host: "web-01.example.net",
            port: 2222, username: "deploy", labels: ["staging"])

        let rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], switches: ImportSwitches()).sessions.first)

        // The stored record's id is what makes this an UPDATE rather than a
        // second session: it is the id `PlannedSession.replacesExisting`
        // overwrites in place.
        #expect(exported.id == storedID)
        #expect(exported.name == "The name the user chose")
        #expect(exported.groupID == groupID)
        #expect(exported.tags == ["prod"])
        // What Cyberduck knows IS replaced.
        #expect(field(SSHField.port, of: exported) == "2222")
    }

    @Test func theLabelsSwitchReplacesTheStoredTagsOnAnUpdate() throws {
        let storedID = UUID()
        let stored = sshSession(
            id: storedID, name: "Web 01", host: "web-01.example.net", port: 22,
            username: "deploy", tags: ["prod"], importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy", labels: ["staging"])
        let rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored],
            switches: ImportSwitches(takeLabelsAsTags: true))

        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [stored],
            switches: ImportSwitches(takeLabelsAsTags: true)).sessions.first)

        #expect(exported.tags == ["staging"])
    }

    @Test func anUpdateKeepsWhatCyberduckDoesNotKnow() throws {
        let storedID = UUID()
        let stored = s3Session(
            id: storedID, name: "Backups", endpoint: "https://objects.example.net",
            bucket: "media", accessKeyID: "minio", region: "eu-central-1",
            usePathStyle: true, importID: "known-s3")
        let bookmark = s3Bookmark(
            id: "known-s3", nickname: "Backups", host: "objects.example.net", port: nil,
            username: "minio", path: "media-2")

        let rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], switches: ImportSwitches()).sessions.first)

        #expect(field(S3Field.region, of: exported) == "eu-central-1")
        #expect(field(S3Field.usePathStyle, of: exported) == "true")
        #expect(field(S3Field.bucket, of: exported) == "media-2")
    }

    @Test func provenanceIsSetOnNewAndUpdatedSessions() throws {
        let storedID = UUID()
        let stored = sshSession(
            id: storedID, name: "Web 01", host: "web-01.example.net", port: 22,
            username: "deploy", importID: "known-1")
        let bookmarks = [
            sftpBookmark(id: "known-1", nickname: "Web 01", host: "web-01.example.net",
                         port: 2222, username: "deploy"),
            sftpBookmark(id: "new-1", host: "fresh.example.net"),
        ]
        let before = Date()

        let rows = ImportPreviewPlanner.preview(
            bookmarks, against: [stored], switches: ImportSwitches())
        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], switches: ImportSwitches())

        #expect(payload.sessions.count == 2)
        for exported in payload.sessions {
            #expect(exported.importSource == CyberduckBookmarkSource.id)
            let stamp = try #require(exported.importedAt)
            #expect(stamp >= before)
        }
        #expect(payload.sessions.compactMap(\.importID).sorted() == ["known-1", "new-1"])
    }

    @Test func createGroupNamedAddsOneGroupAndPointsNewSessionsAtIt() throws {
        let switches = ImportSwitches(createGroupNamed: "Cyberduck")
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: switches)

        let group = try #require(payload.groups.first)
        #expect(payload.groups.count == 1)
        #expect(group.name == "Cyberduck")
        #expect(payload.sessions.first?.groupID == group.id)
    }

    @Test func aChosenGroupWinsOverCreateGroupNamed() throws {
        let groupID = UUID()
        let switches = ImportSwitches(groupID: groupID, createGroupNamed: "Cyberduck")
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: switches)

        #expect(payload.groups.isEmpty)
        #expect(payload.sessions.first?.groupID == groupID)
    }

    @Test func theSecretsSwitchIsWhatThePayloadDeclares() {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: ImportSwitches())

        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches())
            .includesSecrets == false)
        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [], switches: ImportSwitches(takeSecrets: true))
            .includesSecrets == true)
    }

    // MARK: - Fixtures

    /// Stated independently of the planner on purpose: the planner reads it
    /// off S3's own AWS preset, and a test that read the same preset would
    /// assert nothing about what the value is.
    private let awsPresetEndpoint = "https://s3.amazonaws.com"

    private func field<F: BackendFieldID>(_ id: F, of exported: ExportedSession) -> String {
        FieldValues(raw: exported.fields)[id]
    }

    private func changeList(_ status: PreviewStatus) -> [FieldChange]? {
        guard case .knownChanged(_, let changes) = status else { return nil }
        return changes
    }

    private func matchedID(_ status: PreviewStatus) -> UUID? {
        switch status {
        case .knownUnchanged(let id): return id
        case .knownChanged(let id, _): return id
        case .new, .unsupported, .unreadable: return nil
        }
    }

    private func bookmark(
        id: String = "11111111-1111-1111-1111-111111111111",
        protocol: ExternalProtocol, nickname: String? = nil, host: String,
        port: Int? = nil, username: String? = nil, keyPath: String? = nil,
        path: String? = nil, labels: [String] = []
    ) -> ExternalBookmark {
        ExternalBookmark(
            id: id, source: CyberduckBookmarkSource.id, nickname: nickname,
            protocol: `protocol`, host: host, port: port, username: username,
            keyPath: keyPath, path: path, labels: labels, fileName: "\(id).duck",
            unreadable: nil)
    }

    private func sftpBookmark(
        id: String = "11111111-1111-1111-1111-111111111111",
        nickname: String? = "Web 01", host: String = "web-01.example.net",
        port: Int? = 22, username: String? = "deploy", keyPath: String? = nil,
        labels: [String] = []
    ) -> ExternalBookmark {
        bookmark(id: id, protocol: .sftp, nickname: nickname, host: host, port: port,
                 username: username, keyPath: keyPath, labels: labels)
    }

    private func s3Bookmark(
        id: String = "22222222-2222-2222-2222-222222222222",
        nickname: String? = "Backups", host: String = "s3.amazonaws.com",
        port: Int? = nil, username: String? = "AKIAEXAMPLE", path: String? = "backups",
        labels: [String] = []
    ) -> ExternalBookmark {
        bookmark(id: id, protocol: .s3, nickname: nickname, host: host, port: port,
                 username: username, path: path, labels: labels)
    }

    private func sshSession(
        id: UUID = UUID(), name: String, host: String, port: Int, username: String,
        keyPath: String? = nil, tags: [String] = [], groupID: UUID? = nil,
        importID: String? = nil
    ) -> StoredSession {
        StoredSession(
            id: id, name: name, groupID: groupID, kind: .ssh,
            ssh: StoredSSHConfig(
                host: host, port: port, username: username,
                authKind: keyPath == nil ? .password : .privateKey, keyPath: keyPath),
            tags: tags,
            importSource: importID == nil ? nil : CyberduckBookmarkSource.id,
            importID: importID,
            importedAt: importID == nil ? nil : Date(timeIntervalSince1970: 0))
    }

    private func s3Session(
        id: UUID = UUID(), name: String, endpoint: String, bucket: String,
        accessKeyID: String, region: String = "eu-central-1", usePathStyle: Bool = false,
        startsAtBucketList: Bool = false, tags: [String] = [], groupID: UUID? = nil,
        importID: String? = nil
    ) -> StoredSession {
        StoredSession(
            id: id, name: name, groupID: groupID, kind: .s3,
            s3: StoredS3Config(
                accessKeyID: accessKeyID, region: region, endpoint: endpoint,
                bucket: bucket, usePathStyle: usePathStyle,
                startsAtBucketList: startsAtBucketList),
            tags: tags,
            importSource: importID == nil ? nil : CyberduckBookmarkSource.id,
            importID: importID,
            importedAt: importID == nil ? nil : Date(timeIntervalSince1970: 0))
    }
}
