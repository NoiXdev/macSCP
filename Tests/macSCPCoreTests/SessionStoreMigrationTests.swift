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

    /// Migrating twice must not double anything, and the second read must come
    /// from v2 rather than re-running the upgrade.
    @Test func migrationIsIdempotent() throws {
        let directory = try stagedDirectory()
        let store = SessionStore(directory: directory)
        #expect(try store.all().count == 3)
        #expect(try store.all().count == 3)
    }
}
