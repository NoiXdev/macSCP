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
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.isEmpty)
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
            for: rows, sessions: [stored], groups: [], switches: ImportSwitches())

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
            for: noneSelected, sessions: [stored], groups: [], switches: ImportSwitches())
            .sessions.isEmpty)
    }

    @Test func aNewSFTPBookmarkWithAKeyFileBecomesAPrivateKeySession() throws {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: "Web 01", host: "web-01.example.net", port: 2222,
                          username: "deploy", keyPath: "/keys/id_ed25519")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

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
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

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
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

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
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

        #expect(field(S3Field.endpoint, of: exported) == "https://objects.example.net:9000")
    }

    /// The same import, asserted THROUGH the parse rather than against the
    /// spelling: what an imported bookmark has to satisfy is that the app can
    /// dial it, and the literal above is only one string that does. A planner
    /// that wrote `objects.example.net:9000`, or bracketed nothing for an
    /// IPv6 literal, would keep passing a literal comparison in one of the
    /// two directions and fail here (2026-09-03).
    @Test func anImportedS3EndpointIsOneTheParseAccepts() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(host: "objects.example.net", port: 9000, username: "minio",
                        path: "media")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

        let endpoint = field(S3Field.endpoint, of: exported)
        let components = try #require(S3FieldSchema.endpointComponents(endpoint))
        #expect(components.host == "objects.example.net")
        #expect(components.port == 9000)
        #expect(S3FieldSchema.canonicalEndpoint(endpoint) == endpoint)
    }

    /// An IPv6 bookmark, where composing `host:port` by hand produces
    /// `https://::1:9000` — a string with no host at all. The planner asks
    /// `S3FieldSchema.endpointSpelling` for the spelling instead, so the
    /// bracket is not this file's business to remember.
    @Test func anImportedIPv6S3EndpointIsBracketedAndParses() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(host: "::1", port: 9000, username: "minio", path: "media")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

        let endpoint = field(S3Field.endpoint, of: exported)
        let components = try #require(S3FieldSchema.endpointComponents(endpoint))
        #expect(components.url?.host() == "::1")
        #expect(components.port == 9000)
    }

    @Test func anS3BookmarkWithoutAPathStartsAtTheBucketList() throws {
        let rows = ImportPreviewPlanner.preview(
            [s3Bookmark(host: "objects.example.net", port: nil, username: "minio", path: "")],
            against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches()).sessions.first)

        #expect(field(S3Field.startsAtBucketList, of: exported) == "true")
        #expect(field(S3Field.bucket, of: exported).isEmpty)
        #expect(field(S3Field.endpoint, of: exported) == "https://objects.example.net")
    }

    @Test func anUpdateTakesTheNicknameAndReplacesItsRecordById() throws {
        let storedID = UUID()
        let group = StoredGroup(name: "Servers")
        var stored = sshSession(
            id: storedID, name: "The name the user chose", host: "web-01.example.net",
            port: 22, username: "deploy", tags: ["prod"], groupID: group.id,
            importID: "known-1")
        stored.position = 7
        stored.paneVisibility = .bothVisible
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Cyberduck's own name", host: "web-01.example.net",
            port: 2222, username: "deploy", labels: ["staging"])

        let rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], groups: [group],
            switches: ImportSwitches()).sessions.first)

        // `replaces` is what makes this an UPDATE rather than a second
        // session: `SessionImportPlanner` overwrites that record in place and
        // asks the arbiter nothing about the connection.
        #expect(exported.replaces == storedID)
        #expect(exported.id == storedID)
        // The maintainer's decision (design §0 item 3): an update overwrites
        // everything the source knows, and the nickname is one of those.
        #expect(exported.name == "Cyberduck's own name")
        #expect(field(SSHField.port, of: exported) == "2222")
        // What the source does not know is copied off the record.
        #expect(exported.groupID == group.id)
        #expect(exported.position == 7)
        #expect(exported.paneVisibility == .bothVisible)
        #expect(exported.tags == ["prod"])
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
            for: rows, sessions: [stored], groups: [],
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
            for: rows, sessions: [stored], groups: [], switches: ImportSwitches()).sessions.first)

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
            for: rows, sessions: [stored], groups: [], switches: ImportSwitches())

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
            for: rows, sessions: [], groups: [], switches: switches)

        let group = try #require(payload.groups.first)
        #expect(payload.groups.count == 1)
        #expect(group.name == "Cyberduck")
        #expect(payload.sessions.first?.groupID == group.id)
    }

    @Test func aChosenGroupWinsOverCreateGroupNamed() throws {
        let chosen = StoredGroup(name: "Servers")
        let switches = ImportSwitches(groupID: chosen.id, createGroupNamed: "Cyberduck")
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [chosen], switches: switches)

        // Nothing named "Cyberduck" is created — the picker had an answer —
        // and the answer it had is the group the payload carries.
        #expect(payload.groups.map(\.name) == ["Servers"])
        #expect(payload.sessions.first?.groupID == chosen.id)
    }

    /// The group is created ONCE for the whole run, not once per row — the
    /// creation sits outside the loop, and nothing else pins that.
    @Test func createGroupNamedMakesOneGroupForEveryRow() throws {
        let switches = ImportSwitches(createGroupNamed: "Cyberduck")
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(id: "a", host: "a.example.net"),
             sftpBookmark(id: "b", host: "b.example.net"),
             sftpBookmark(id: "c", host: "c.example.net")],
            against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: switches)

        #expect(payload.sessions.count == 3)
        #expect(payload.groups.count == 1)
        let group = try #require(payload.groups.first)
        #expect(payload.sessions.allSatisfy { $0.groupID == group.id })
    }

    /// The `.new` half of the labels switch, both ways — only the two UPDATE
    /// cells were covered.
    @Test func aNewRowTakesTheLabelsAsTagsOnlyWithTheSwitch() throws {
        let bookmark = sftpBookmark(labels: ["prod", "eu"])

        let off = try #require(ImportPreviewPlanner.payload(
            for: ImportPreviewPlanner.preview(
                [bookmark], against: [], switches: ImportSwitches()),
            sessions: [], groups: [], switches: ImportSwitches()).sessions.first)
        #expect(off.tags == nil)

        let on = ImportSwitches(takeLabelsAsTags: true)
        let taken = try #require(ImportPreviewPlanner.payload(
            for: ImportPreviewPlanner.preview([bookmark], against: [], switches: on),
            sessions: [], groups: [], switches: on).sessions.first)
        #expect(taken.tags == ["prod", "eu"])
    }

    /// `SessionImportPlanner` resolves `ExportedSession.groupID` against the
    /// payload's OWN `groups` and drops a reference it does not carry, so a
    /// chosen group that is not in the payload silently loses every session
    /// it was meant to hold.
    @Test func theChosenGroupIsCarriedIntoThePayload() throws {
        let chosen = StoredGroup(name: "Servers")
        let other = StoredGroup(name: "Not this one")
        let switches = ImportSwitches(groupID: chosen.id)
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [other, chosen], switches: switches)

        #expect(payload.groups.count == 1)
        #expect(payload.groups.first?.id == chosen.id)
        #expect(payload.groups.first?.name == "Servers")
    }

    /// The same rule for the group an UPDATE copied off its record: carried,
    /// or the update moves the session to the top level.
    @Test func theGroupAnUpdateCopiedFromTheStoreIsCarriedIntoThePayload() throws {
        let group = StoredGroup(name: "Servers")
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            groupID: group.id, importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")
        let rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], groups: [group], switches: ImportSwitches())

        #expect(payload.sessions.first?.groupID == group.id)
        #expect(payload.groups.map(\.id) == [group.id])
    }

    /// A group the catalogue does not know cannot be carried — the payload
    /// names no group at all rather than a reference that resolves to nothing.
    @Test func aGroupTheCatalogueDoesNotKnowIsNotCarried() throws {
        let switches = ImportSwitches(groupID: UUID())
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: switches)

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: switches)

        #expect(payload.groups.isEmpty)
        #expect(payload.sessions.first?.groupID == nil)
    }

    @Test func theSecretsSwitchIsWhatThePayloadDeclares() {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: ImportSwitches())

        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches())
            .includesSecrets == false)
        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [], switches: ImportSwitches(takeSecrets: true))
            .includesSecrets == true)
    }

    // MARK: - The auth kind an update must not invent (review I-2)

    /// A bookmark with no `Private Key File` says NOTHING about how the
    /// connection authenticates — Cyberduck has no column for "uses an
    /// agent". Design §3's "agent is never inferred" therefore has to hold in
    /// both directions: an update must not read that silence as `.password`.
    @Test func anUpdateNeverDemotesAgentAuth() throws {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            authKind: .agent, importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        let exported = try #require(ImportPreviewPlanner.payload(
            for: [row], sessions: [stored], groups: [],
            switches: ImportSwitches()).sessions.first)

        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.agent.rawValue)
        // Nothing about auth changed, so the row must not claim it did.
        let changes = try #require(changeList(row.status))
        #expect(changes.map(\.field) == [ImportPreviewPlanner.FieldKey.port])
    }

    /// The same silence over a stored key path: the key file is not gone just
    /// because the bookmark never mentioned one, and clearing it would leave
    /// `.privateKey` with no key — an entry the backend schema refuses.
    @Test func anUpdateKeepsAStoredKeyPathTheBookmarkDoesNotMention() throws {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            keyPath: "/keys/id_ed25519", importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        let exported = try #require(ImportPreviewPlanner.payload(
            for: [row], sessions: [stored], groups: [],
            switches: ImportSwitches()).sessions.first)

        #expect(field(SSHField.keyPath, of: exported) == "/keys/id_ed25519")
        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.privateKey.rawValue)
        #expect(try #require(changeList(row.status)).map(\.field)
                == [ImportPreviewPlanner.FieldKey.port])
    }

    /// A key file IS a positive statement, and it is the one thing that moves
    /// the auth kind — reported, so the row says what it will do.
    @Test func aBookmarksKeyFileMakesTheUpdateUsePrivateKeyAuth() throws {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 22, username: "deploy",
            authKind: .agent, importID: "known-1")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 22,
            username: "deploy", keyPath: "/keys/id_ed25519")

        let row = try #require(ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches()).first)
        let exported = try #require(ImportPreviewPlanner.payload(
            for: [row], sessions: [stored], groups: [],
            switches: ImportSwitches()).sessions.first)

        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.privateKey.rawValue)
        #expect(field(SSHField.keyPath, of: exported) == "/keys/id_ed25519")
        let fields = try #require(changeList(row.status)).map(\.field)
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.authKind))
        #expect(fields.contains(ImportPreviewPlanner.FieldKey.keyPath))
    }

    /// A NEW session has no auth to preserve, so the bookmark's silence is
    /// the only evidence there is and it means password — unchanged from
    /// §3, and the anchor that the rule above is about UPDATES.
    @Test func aNewRowStillTakesPasswordAuthWithoutAKeyFile() throws {
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark()], against: [], switches: ImportSwitches())
        let exported = try #require(ImportPreviewPlanner.payload(
            for: rows, sessions: [], groups: [],
            switches: ImportSwitches()).sessions.first)

        #expect(field(SSHField.authKind, of: exported)
                == StoredSession.AuthKind.password.rawValue)
    }

    // MARK: - A ticked unchanged row takes provenance (review I-3)

    @Test func aSelectedUnchangedRowBecomesAProvenanceOnlyUpdate() throws {
        let storedID = UUID()
        let group = StoredGroup(name: "Servers")
        var stored = sshSession(
            id: storedID, name: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy", tags: ["prod"], groupID: group.id)
        stored.position = 3
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")

        var rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())
        #expect(rows.first?.status == .knownUnchanged(storedID))
        #expect(rows.first?.selected == false)  // the anchor: it starts unticked
        rows[0].selected = true

        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], groups: [group], switches: ImportSwitches())

        let exported = try #require(payload.sessions.first)
        #expect(exported.replaces == storedID)
        #expect(exported.importSource == CyberduckBookmarkSource.id)
        #expect(exported.importID == "known-1")
        // Nothing else changed.
        #expect(exported.name == "Web 01")
        #expect(exported.groupID == group.id)
        #expect(exported.position == 3)
        #expect(exported.tags == ["prod"])
        #expect(field(SSHField.host, of: exported) == "web-01.example.net")
        #expect(field(SSHField.port, of: exported) == "2222")
    }

    /// End to end: the ticked unchanged row reaches `SessionImportPlanner`,
    /// updates the very record it matched — one session, its own id, its
    /// Keychain slot untouched — and comes out carrying the provenance that
    /// lets the NEXT run recognise it after its connection moves. Without
    /// this path a key-matched session can never be stamped, and the run
    /// after a port change creates a second session instead of updating it.
    @Test func aTickedUnchangedRowStampsProvenanceThroughThePlanner() async throws {
        let storedID = UUID()
        let stored = sshSession(
            id: storedID, name: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")
        let bookmark = sftpBookmark(
            id: "known-1", nickname: "Web 01", host: "web-01.example.net", port: 2222,
            username: "deploy")
        var rows = ImportPreviewPlanner.preview(
            [bookmark], against: [stored], switches: ImportSwitches())
        rows[0].selected = true
        let payload = ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], groups: [], switches: ImportSwitches())

        let plan = await SessionImportPlanner.plan(
            existing: [stored], existingGroups: [], incoming: payload,
            arbiter: ImportConflictArbiter { _ in
                Issue.record("the row matched this very record; nothing to arbitrate")
                return nil
            })

        #expect(plan.sessionsToImport.count == 1)
        let planned = try #require(plan.sessionsToImport.first)
        #expect(planned.session.id == storedID)
        #expect(planned.replacesExisting)
        #expect(planned.keepsExistingSecret)
        #expect(planned.session.importSource == CyberduckBookmarkSource.id)
        #expect(planned.session.importID == "known-1")
        #expect(planned.session.ssh?.host == "web-01.example.net")
        #expect(planned.session.ssh?.port == 2222)
    }

    @Test func anUntickedUnchangedRowStaysOutOfThePayload() {
        let stored = sshSession(
            name: "Web 01", host: "web-01.example.net", port: 2222, username: "deploy")
        let rows = ImportPreviewPlanner.preview(
            [sftpBookmark(nickname: "Web 01", host: "web-01.example.net", port: 2222,
                          username: "deploy")],
            against: [stored], switches: ImportSwitches())

        #expect(ImportPreviewPlanner.payload(
            for: rows, sessions: [stored], groups: [], switches: ImportSwitches())
            .sessions.isEmpty)
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
        authKind: StoredSession.AuthKind? = nil,
        keyPath: String? = nil, tags: [String] = [], groupID: UUID? = nil,
        importID: String? = nil
    ) -> StoredSession {
        StoredSession(
            id: id, name: name, groupID: groupID, kind: .ssh,
            ssh: StoredSSHConfig(
                host: host, port: port, username: username,
                authKind: authKind ?? (keyPath == nil ? .password : .privateKey),
                keyPath: keyPath),
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
