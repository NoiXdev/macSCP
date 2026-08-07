import Foundation
import Testing
@testable import macSCPCore

/// The only test that proves nobody loses their connections, and the only one
/// reasoning cannot replace.
@Suite struct SessionStoreMigrationTests {
    /// Addressed by `#filePath`, NOT `Bundle.module`: `Package.swift` excludes
    /// `Fixtures` from the test target's resources, because these files must
    /// be copied to disk under the names the stores look for rather than
    /// bundled. Same mechanism as `LegacyStoreCompatibilityTests`.
    private func stagedDirectory() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m23-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("legacy-sessions-pre-m23.json"),
            to: directory.appendingPathComponent("sessions.json"))
        return directory
    }

    @Test func everySSHFieldSurvivesTheMigration() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let prod = try #require(try store.all().first { $0.name == "Prod" })
        #expect(prod.ssh?.host == "prod.example.com")
        #expect(prod.ssh?.port == 2222)
        #expect(prod.ssh?.username == "deploy")
        #expect(prod.ssh?.authKind == .privateKey)
        #expect(prod.ssh?.keyPath == "/keys/prod")
        #expect(prod.groupID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    @Test func theJumpHostSurvivesWithItsOwnSecretSlot() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let prod = try #require(try store.all().first { $0.name == "Prod" })
        let jump = try #require(prod.ssh?.jump)
        #expect(jump.host == "bastion.example.com")
        #expect(jump.port == 2022)
        #expect(jump.username == "hop")
        // The Keychain slot is the one thing a regenerated id would silently
        // orphan, taking the stored jump password with it.
        #expect(jump.secretID == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    }

    @Test func theS3AndWebDAVBlocksSurviveAndTheirPlaceholdersDoNot() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let archive = try #require(try store.all().first { $0.name == "Archive" })
        #expect(archive.s3?.bucket == "archive")
        #expect(archive.s3?.usePathStyle == true)
        #expect(archive.loginSetID == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        // A non-SSH session gets NO ssh block — that is the whole point.
        #expect(archive.ssh == nil)

        let cloud = try #require(try store.all().first { $0.name == "Cloud" })
        #expect(cloud.webdav?.username == "tim")
        #expect(cloud.webdav?.useNextcloudPath == true)
        #expect(cloud.ssh == nil)
    }

    /// A jump in "session" mode (`sessionID`) or bound to a login set
    /// (`loginSetID`) must survive with BOTH references intact. Neither field
    /// existed in the original frozen fixture, so the one artefact reasoning
    /// cannot replace was not proving anything about them (fix round 1).
    ///
    /// `loginSetID` and `sessionID` are the two fields that make a jump point
    /// at something else rather than carry its own values: lose either and the
    /// hop silently falls back to the inert host/username kept beside them,
    /// which is a DIFFERENT bastion, not a missing one.
    @Test func aSessionModeAndSetBoundJumpSurvivesWithBothReferences() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let staging = try #require(try store.all().first { $0.name == "Staging" })
        let jump = try #require(staging.ssh?.jump)
        #expect(jump.sessionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(jump.loginSetID == UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        #expect(jump.secretID == UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        // The inert data-carrier fields ride along too — they are what a
        // delete-restoration turns back into a concrete hop.
        #expect(jump.host == "old-bastion.example.com")
        #expect(jump.username == "carried")
    }

    /// A pre-M23 S3/WebDAV session could carry a jump — the old save path
    /// passed `jump:` for every kind — and the new shape has nowhere to put
    /// one, because a hop is an SSH concept.
    ///
    /// This asserts the drop is INTENTIONAL, not incidental: the session
    /// survives with everything else intact and simply has no jump, rather
    /// than the migration growing an `ssh` block just to hold it. See
    /// `LegacyStoredSession.upgraded()` for the cost that is knowingly
    /// accepted here — the jump's `secretID` names a Keychain entry that
    /// becomes an orphan.
    @Test func aJumpOnANonSSHSessionIsDeliberatelyDropped() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let archive = try #require(try store.all().first { $0.name == "Archive" })
        // No SSH block was invented to house the hop...
        #expect(archive.ssh == nil)
        // ...so there is no jump, via the convenience the readers use.
        #expect(archive.jump == nil)
        // The rest of the session is untouched by the drop.
        #expect(archive.s3?.bucket == "archive")
        #expect(archive.loginSetID == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
    }

    @Test func groupsSurviveTheMigration() throws {
        let store = SessionStore(directory: try stagedDirectory())
        #expect(try store.allGroups().map(\.name) == ["Production"])
    }

    /// A downgrade must not crash. The old file stays exactly where the old
    /// version looks for it, byte for byte.
    @Test func theOldFileIsLeftUntouched() throws {
        let directory = try stagedDirectory()
        let old = directory.appendingPathComponent("sessions.json")
        let before = try Data(contentsOf: old)
        _ = try SessionStore(directory: directory).all()
        #expect(try Data(contentsOf: old) == before)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sessions-v2.json")
                .path(percentEncoded: false)))
    }

    /// A migration that cannot WRITE must still READ (fix round 1, M1).
    ///
    /// `migrateFromLegacy` persists with `try?` on purpose: `load()` is a read
    /// path, and on a read-only or full volume a write failure would otherwise
    /// surface as an error and an empty sidebar on the first launch after the
    /// update — hiding connections that were perfectly readable the whole time.
    /// Redoing the upgrade next launch is the strictly better failure.
    ///
    /// The directory is made read-only to provoke a real write failure rather
    /// than a mocked one, since the guarantee is about the filesystem saying no.
    @Test func aFailedMigrationWriteStillReturnsTheSessions() throws {
        let directory = try stagedDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false))

        let sessions = try SessionStore(directory: directory).all()

        #expect(sessions.count == 4)
        #expect(sessions.first { $0.name == "Prod" }?.ssh?.host == "prod.example.com")
        // Nothing was written, so the upgrade simply runs again next launch.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sessions-v2.json")
                .path(percentEncoded: false)))
    }

    /// Migrating twice must not double anything, and the second read must come
    /// from v2 rather than re-running the upgrade.
    ///
    /// The legacy file is DELETED between the two reads (fix round 1). Two
    /// identical counts prove nothing on their own — the upgrade is
    /// deterministic, so re-running it every read would produce the same
    /// number and the test would pass while asserting only that a pure
    /// function is pure. With `sessions.json` gone, a second read that still
    /// sees the sessions can only be reading `sessions-v2.json`.
    @Test func migrationIsIdempotent() throws {
        let directory = try stagedDirectory()
        let store = SessionStore(directory: directory)
        #expect(try store.all().count == 4)

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("sessions.json"))

        #expect(try store.all().count == 4)
        // Not just the count: the migrated content is what v2 now holds.
        let prod = try #require(try store.all().first { $0.name == "Prod" })
        #expect(prod.ssh?.host == "prod.example.com")
        #expect(prod.ssh?.jump?.secretID
            == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        // And v2 is the live file a write lands in, not a one-shot artefact.
        try store.upsert(sshSession(name: "Added", host: "new.example.com", username: "u"))
        #expect(try store.all().count == 5)
    }
}
