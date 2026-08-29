import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionStore")
struct SessionStoreTests {
    private func makeTempStore() -> (SessionStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sessions-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    @Test func emptyWhenNoFileExists() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.all() == [])
    }

    @Test func upsertPersistsAndRoundtrips() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        #expect(try store.all() == [session])
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        session.name = "web-neu"
        try store.upsert(session)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "web-neu")
    }

    @Test func deleteRemovesSession() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: session.id)
        #expect(try store.all() == [])
    }

    @Test func deleteUnknownIdIsNoop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: UUID())
        #expect(try store.all() == [session])
    }

    @Test func corruptFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: dir.appendingPathComponent("sessions.json"))
        #expect(throws: (any Error).self) {
            _ = try store.all()
        }
    }

    @Test func groupsRoundtripThroughTheStore() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = StoredGroup(name: "Customers")
        try store.upsertGroup(group)
        let session = sshSession(name: "web", host: "h", username: "u", groupID: group.id)
        try store.upsert(session)

        #expect(try store.allGroups() == [group])
        #expect(try store.all().first?.groupID == group.id)
    }

    @Test func legacyPlainArrayFileLoadsWithoutGroups() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = """
        [{"authKind":"password","host":"legacy.example","id":"11111111-1111-1111-1111-111111111111",\
        "name":"old","port":22,"username":"tim"}]
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("sessions.json"))

        #expect(try store.allGroups().isEmpty)
        let sessions = try store.all()
        #expect(sessions.count == 1)
        #expect(sessions.first?.name == "old")
        #expect(sessions.first?.groupID == nil)
    }

    @Test func dissolveGroupUngroupsItsSessionsInOneWrite() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = StoredGroup(name: "Temp")
        try store.upsertGroup(group)
        try store.upsert(sshSession(name: "a", host: "h", username: "u", groupID: group.id))
        try store.dissolveGroup(id: group.id)

        #expect(try store.allGroups().isEmpty)
        #expect(try store.all().first?.groupID == nil)
    }

    @Test func orphanedGroupIDIsTreatedAsNilOnLoad() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(sshSession(name: "a", host: "h", username: "u", groupID: UUID()))
        #expect(try store.all().first?.groupID == nil)
    }

    @Test func groupRenamePersistsViaUpsertGroup() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var group = StoredGroup(name: "Old")
        try store.upsertGroup(group)
        group.name = "New"
        try store.upsertGroup(group)
        #expect(try store.allGroups() == [group])
        #expect(try store.allGroups().count == 1)
    }

    // MARK: - Nesting and order (D1/D2, Task 2)

    /// Dissolving generalizes what the flat case already did. `groupID = nil`
    /// was never "no group" as a rule — for a TOP-LEVEL group it is one level
    /// up, and one level up from a nested group is its parent.
    ///
    /// Sub-folders travel with the sessions. Left behind they would name a
    /// group that is gone, and `load()`'s repair lifts such a group to the
    /// TOP level — a different place than the one the user dissolved, and a
    /// silent one.
    @Test func dissolveLiftsSessionsAndSubfoldersToTheParent() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = StoredGroup(name: "Outer")
        let middle = StoredGroup(name: "Middle", parentID: outer.id)
        let inner = StoredGroup(name: "Inner", parentID: middle.id)
        for group in [outer, middle, inner] { try store.upsertGroup(group) }
        try store.upsert(sshSession(name: "a", groupID: middle.id))

        try store.dissolveGroup(id: middle.id)

        let groups = try store.allGroups()
        #expect(groups.map(\.name).sorted() == ["Inner", "Outer"])
        #expect(groups.first { $0.name == "Inner" }?.parentID == outer.id)
        #expect(try store.all().map(\.groupID) == [outer.id])
    }

    /// The receiving parent is renumbered in one go: the lifted members take
    /// the dissolved group's slot, and every sibling keeps a position of its
    /// own.
    @Test func dissolveLeavesTheReceivingParentGaplessAndUnique() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = StoredGroup(name: "Outer")
        let middle = StoredGroup(name: "Middle", parentID: outer.id)
        for group in [outer, middle, StoredGroup(name: "Other", parentID: outer.id)] {
            try store.upsertGroup(group)
        }
        try store.upsert(sshSession(name: "a", groupID: middle.id))
        try store.upsert(sshSession(name: "b", groupID: outer.id))
        try store.upsertGroup(StoredGroup(name: "Inner", parentID: middle.id))

        try store.dissolveGroup(id: middle.id)

        // The count is asserted first, and on purpose: `0..<count` is
        // satisfied by an empty list too, so without it this would go on
        // passing over a parent that had lost every child.
        let positions = try positionsOfChildren(of: outer.id, in: store)
        #expect(positions.count == 4)  // Inner + "a", lifted; "Other" + "b", already there
        #expect(positions == Array(0..<positions.count))
    }

    /// A parent that names a group the file does not hold is lifted to the
    /// top level on the way in — the `parentID` counterpart of the stray
    /// `groupID` sweep next to it. Nothing is dropped.
    @Test func aParentThatIsNotInTheFileIsLiftedOnLoad() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsertGroup(StoredGroup(name: "Orphan", parentID: UUID()))
        let groups = try store.allGroups()
        #expect(groups.map(\.name) == ["Orphan"])
        #expect(groups.first?.parentID == nil)
    }

    /// A cycle can only arrive through a file another installation wrote, so
    /// it is written by hand here. Both groups survive it: the ring is cut,
    /// never emptied.
    @Test func aCyclicParentChainIsCutOnLoadAndKeepsBothGroups() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = "AAAAAAAA-0000-0000-0000-000000000001"
        let b = "BBBBBBBB-0000-0000-0000-000000000002"
        let file = """
        {"groups":[\
        {"id":"\(a)","name":"A","parentID":"\(b)","position":0},\
        {"id":"\(b)","name":"B","parentID":"\(a)","position":1}],\
        "sessions":[]}
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(file.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let groups = try store.allGroups()
        #expect(groups.map(\.name).sorted() == ["A", "B"])
        #expect(!GroupTree.hasCycle(groups))
    }

    /// `applyOrdering` writes where a row sits and nothing else — and the
    /// claim is worth a test because the caller hands over a WHOLE tree that
    /// it read at some earlier moment. A write that took anything but the
    /// ordering fields from it would roll back a rename made in between, and
    /// one that took the tree's MEMBERSHIP would resurrect a deleted session
    /// or drop a newly saved one.
    @Test func applyOrderingWritesTheOrderingFieldsAndNothingElse() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = StoredGroup(name: "Folder")
        try store.upsertGroup(folder)
        let session = sshSession(name: "current", host: "h", username: "u")
        try store.upsert(session)

        var staleSession = session
        staleSession.name = "stale"
        staleSession.groupID = folder.id
        staleSession.position = 3
        var staleGroup = folder
        staleGroup.name = "renamed"
        staleGroup.position = 7
        try store.applyOrdering(SidebarOrdering.Tree(
            groups: [staleGroup, StoredGroup(name: "gone")],
            sessions: [staleSession, sshSession(name: "gone", host: "h", username: "u")]))

        #expect(try store.allGroups().map(\.name) == ["Folder"])
        #expect(try store.allGroups().first?.position == 7)
        #expect(try store.all().map(\.name) == ["current"])
        #expect(try store.all().first?.groupID == folder.id)
        #expect(try store.all().first?.position == 3)
    }

    /// The positions of a parent's children, in the order the sidebar reads
    /// them — derived from the store rather than from the array the test
    /// wrote, because that array is exactly what a renumbering write is
    /// allowed to replace.
    private func positionsOfChildren(of parentID: UUID?, in store: SessionStore) throws -> [Int] {
        let tree = SidebarOrdering.Tree(groups: try store.allGroups(), sessions: try store.all())
        return SidebarOrdering.children(of: parentID, in: tree).map { item in
            switch item {
            case .group(let id): tree.groups.first { $0.id == id }?.position ?? -1
            case .session(let id): tree.sessions.first { $0.id == id }?.position ?? -1
            }
        }
    }

    // MARK: - Blockless-record drop (M26/T1)
    //
    // These fixtures are written BY HAND as JSON, not produced through the
    // store: no save path in the app can write a `.ssh` record with no `ssh`
    // block (`SessionListViewModel.save` always attaches one), so the only
    // way this shape reaches disk is a hand-edited or damaged
    // `sessions-v2.json`. That is exactly the case under test, so a real
    // `SessionStore` reads a fixture file rather than going through a mock —
    // a mock would not exercise the read path this suite is about.

    /// A record with `"kind": "ssh"` and no `"ssh"` key, next to a healthy
    /// SSH neighbour, in the CURRENT container format (`sessions-v2.json`,
    /// not the pre-M23 legacy shape).
    private let blocklessSSHFixture = """
    {
      "groups": [],
      "sessions": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "broken",
          "kind": "ssh"
        },
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "healthy",
          "kind": "ssh",
          "ssh": {
            "host": "example.com",
            "port": 22,
            "username": "tim",
            "authKind": "password"
          }
        }
      ]
    }
    """

    private func writeBlocklessSSHFixture(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(blocklessSSHFixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))
    }

    @Test func aBlocklessSSHRecordIsDroppedWhenLoading() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)

        let sessions = try store.all()
        #expect(!sessions.contains { $0.name == "broken" })
    }

    @Test func aHealthyNeighbourSurvivesTheDrop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)

        let sessions = try store.all()
        let healthy = try #require(sessions.first { $0.name == "healthy" })
        #expect(healthy.kind == .ssh)
        #expect(healthy.ssh?.host == "example.com")
        #expect(healthy.ssh?.port == 22)
        #expect(healthy.ssh?.username == "tim")
        #expect(healthy.ssh?.authKind == .password)
    }

    /// Pins that the read path never writes: a broken record is skipped in
    /// the RETURNED list on every load, not rewritten out of the file. A
    /// write on the read path would be a new failure mode for a problem
    /// nobody has, and would change the user's file without being asked.
    @Test func loadingDoesNotRewriteTheFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)
        let fileURL = dir.appendingPathComponent("sessions-v2.json")
        let before = try Data(contentsOf: fileURL)

        _ = try store.all()

        #expect(try Data(contentsOf: fileURL) == before)
    }

    /// Pins the deliberate asymmetry: an `.s3` record with no `s3` block is
    /// equally unusable but is NOT dropped here, because S3/WebDAV have no
    /// inventing accessors and their blockless case is already caught
    /// explicitly elsewhere (`StoredSessionConnectionConfig.build`). Widening
    /// the drop to those kinds later is a decision, not an oversight.
    @Test func aBlocklessS3RecordIsKept() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = """
        {
          "groups": [],
          "sessions": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "broken-s3",
              "kind": "s3"
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try store.all()
        #expect(sessions.contains { $0.name == "broken-s3" })
    }

    /// Same asymmetry as `aBlocklessS3RecordIsKept`, for the other backend
    /// with no inventing accessors: a blockless `.webdav` record is equally
    /// unusable but stays, because `SessionStore.load()`'s drop rule
    /// (`SessionStore.dropsOnLoad`) targets `.ssh` only.
    @Test func aBlocklessWebDAVRecordIsKept() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = """
        {
          "groups": [],
          "sessions": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "name": "broken-webdav",
              "kind": "webdav"
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try store.all()
        #expect(sessions.contains { $0.name == "broken-webdav" })
    }

    /// A record with no `"kind"` key at all -- not the `"kind": "ssh"` shape
    /// `blocklessSSHFixture` covers, but the shape a genuinely pre-M23 file
    /// (or a hand-edit that drops the key) would carry: the flat
    /// host/port/username/authKind columns `StoredSession` decoding never
    /// reads into anything since M23, still sitting at the top level.
    /// `StoredSession.init(from:)` defaults a missing `kind` to `.ssh`
    /// (`StoredSessionTests
    /// .aLegacyPayloadDecodedAsStoredSessionIsSilentlyBlockLess` pins the
    /// decode side of this), so this record is `.ssh` with `ssh == nil` just
    /// like the explicit-`"kind"` case, and the load-time drop rule catches
    /// it the same way -- this is the one dropped shape that still carries
    /// the user's original flat columns, unread, in the file.
    @Test func aRecordWithNoKindKeyDecodesAsSSHAndIsDroppedWhenLoading() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = """
        {
          "groups": [],
          "sessions": [
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "name": "no-kind-key",
              "host": "legacy.example.com",
              "port": 22,
              "username": "legacyuser",
              "authKind": "password"
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try store.all()
        #expect(!sessions.contains { $0.name == "no-kind-key" })
    }

    // MARK: - Legacy jump secret ids (M27/T1)
    //
    // Hand-written fixtures, same reasoning as `blocklessSSHFixture` above:
    // no save path in the app still writes the pre-M23 legacy shape, so the
    // only way to exercise this reader is a fixture built by hand.

    /// The session records shared by both legacy fixture shapes below.
    /// `nil` in `ids` means a session without a jump.
    ///
    /// `kinds` is positional against `ids` and may be shorter or empty. A
    /// record with no entry, or a `nil` entry, is written with NO `kind` key
    /// at all -- the shape of a file saved before that key existed, which
    /// `LegacyStoredSession.upgraded()` resolves to `.ssh`. Naming a kind
    /// matters for exactly one thing, and it is the thing M27 exists for:
    /// `upgraded()` carries a jump into the new file for `.ssh` and drops it
    /// for every other kind.
    static func legacyRecords(
        withJumpSecretIDs ids: [UUID?], kinds: [ConnectionKind?] = []
    ) -> [String] {
        ids.enumerated().map { index, secretID -> String in
            let kind = (index < kinds.count ? kinds[index] : nil)
                .map { #","kind":"\#($0.rawValue)""# } ?? ""
            let jump = secretID.map {
                """
                ,"jump":{"host":"bastion.example.com","port":22,\
                "username":"tim","authKind":"password","secretID":"\($0.uuidString)"}
                """
            } ?? ""
            return """
            {"id":"\(UUID().uuidString)","name":"legacy-\(index)",\
            "host":"example.com","port":22,"username":"tim",\
            "authKind":"password"\(kind)\(jump)}
            """
        }
    }

    /// A pre-M23 `sessions.json` in the older BARE ARRAY shape, from before
    /// groups existed. Hand-written for the same reason the blockless
    /// fixtures above are: nothing in the app writes this shape any more.
    static func legacyFixture(withJumpSecretIDs ids: [UUID?]) -> Data {
        Data("[\(Self.legacyRecords(withJumpSecretIDs: ids).joined(separator: ","))]".utf8)
    }

    /// A pre-M23 `sessions.json` in the CONTAINER shape --
    /// `{"groups": [...], "sessions": [...]}` -- the shape every install has
    /// carried since groups shipped, which was before 1.0 released and so is
    /// what nearly every real install has on disk. Same object shape as
    /// `blocklessSSHFixture` above, wrapping the same hand-written legacy
    /// records `legacyFixture` uses for the bare-array shape.
    static func legacyContainerFixture(
        withJumpSecretIDs ids: [UUID?], kinds: [ConnectionKind?] = []
    ) -> Data {
        let records = Self.legacyRecords(withJumpSecretIDs: ids, kinds: kinds)
            .joined(separator: ",")
        return Data(#"{"groups":[],"sessions":[\#(records)]}"#.utf8)
    }

    /// The sweep's candidate source. A jump's `secretID` is the only thing
    /// M23 left behind, so this reads exactly that -- and nothing else about
    /// the legacy shape leaks out of the store.
    @Test func legacyJumpSecretIDsReadsEveryJumpFromTheOldFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = UUID(), b = UUID()
        try Self.legacyFixture(withJumpSecretIDs: [a, b]).write(
            to: dir.appendingPathComponent("sessions.json"))
        #expect(try store.legacyJumpSecretIDs() == [a, b])
    }

    /// The container shape is what nearly every real pre-M23 install
    /// actually carries (fix round 1): groups shipped before 1.0 released,
    /// so the bare-array shape above is the rarer case in practice, and this
    /// is the one that must work for the sweep to find real orphans at all.
    @Test func legacyJumpSecretIDsReadsEveryJumpFromTheContainerShapedOldFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = UUID(), b = UUID()
        try Self.legacyContainerFixture(withJumpSecretIDs: [a, b]).write(
            to: dir.appendingPathComponent("sessions.json"))
        #expect(try store.legacyJumpSecretIDs() == [a, b])
    }

    @Test func legacyJumpSecretIDsIsEmptyWhenTheOldFileIsGone() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.legacyJumpSecretIDs().isEmpty)
    }

    /// An unreadable file must NOT read as "no candidates". Everything in
    /// M27 hangs on this: a silent empty result here is the one shape that
    /// cannot be distinguished from a clean install.
    @Test func legacyJumpSecretIDsThrowsOnAnUnreadableFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(
            to: dir.appendingPathComponent("sessions.json"))
        #expect(throws: (any Error).self) { try store.legacyJumpSecretIDs() }
    }

    /// A file that is valid JSON but matches NEITHER legacy shape -- not the
    /// container's `groups`/`sessions` keys, not a top-level array -- must
    /// still throw (fix round 1). This is the case the container decode's
    /// `try?` must NOT swallow: only the array decode after it is allowed to
    /// be the one that actually reports the failure.
    @Test func legacyJumpSecretIDsThrowsWhenTheFileMatchesNeitherLegacyShape() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"unrelated":true}"#.utf8).write(
            to: dir.appendingPathComponent("sessions.json"))
        #expect(throws: (any Error).self) { try store.legacyJumpSecretIDs() }
    }

    /// A session without a jump contributes nothing, and the same secretID
    /// appearing twice contributes once.
    @Test func legacyJumpSecretIDsSkipsJumplessRecordsAndDeduplicates() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = UUID()
        try Self.legacyFixture(withJumpSecretIDs: [a, nil, a]).write(
            to: dir.appendingPathComponent("sessions.json"))
        #expect(try store.legacyJumpSecretIDs() == [a])
    }

    /// M23 keeps sessions.json as the downgrade snapshot. Reading it must
    /// not touch it.
    @Test func readingLegacyJumpSecretIDsLeavesTheFileByteIdentical() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.json")
        try Self.legacyFixture(withJumpSecretIDs: [UUID()]).write(to: url)
        let before = try Data(contentsOf: url)
        _ = try store.legacyJumpSecretIDs()
        #expect(try Data(contentsOf: url) == before)
    }
}
