import Foundation
import Testing
@testable import macSCPCore

/// `CyberduckBookmarkSource` reads Cyberduck's `.duck` property lists
/// (measured 2026-09-03, `docs/superpowers/specs/2026-09-03-cyberduck-import-design.md`
/// §1/§6). Fixtures live under `Tests/macSCPCoreTests/Fixtures/Cyberduck/`,
/// with synthetic `*.example.net` hosts — never the maintainer's real
/// bookmark folder.
@Suite("CyberduckBookmarkSource")
struct CyberduckBookmarkSourceTests {
    private var fixturesFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cyberduck", isDirectory: true)
    }

    private func bookmark(_ bookmarks: [ExternalBookmark], fileName: String) throws -> ExternalBookmark {
        let match = bookmarks.first { $0.fileName == fileName }
        return try #require(match)
    }

    // MARK: - Field-by-field, per fixture

    @Test func sftpBookmarkWithPrivateKeyFile() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "sftp-key.duck")

        #expect(row.id == "11111111-1111-1111-1111-111111111111")
        #expect(row.source == "cyberduck")
        #expect(row.nickname == "Key Box")
        #expect(row.protocol == .sftp)
        #expect(row.host == "sftp-key.example.net")
        #expect(row.port == 22)
        #expect(row.username == "deploy")
        #expect(row.keyPath == "/Users/tester/.ssh/id_ed25519")
        #expect(row.path == nil)
        #expect(row.labels == [])
        #expect(row.unreadable == nil)
    }

    @Test func sftpBookmarkWithPasswordAuth() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "sftp-password.duck")

        #expect(row.id == "22222222-2222-2222-2222-222222222222")
        #expect(row.nickname == "Password Box")
        #expect(row.protocol == .sftp)
        #expect(row.host == "sftp-password.example.net")
        #expect(row.port == 2222)
        #expect(row.username == "webadmin")
        #expect(row.keyPath == nil)
        #expect(row.unreadable == nil)
    }

    @Test func s3BookmarkWithBucket() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "s3-bucket.duck")

        #expect(row.id == "33333333-3333-3333-3333-333333333333")
        #expect(row.nickname == "Assets Bucket")
        #expect(row.protocol == .s3)
        #expect(row.host == "s3.amazonaws.com")
        #expect(row.port == 443)
        #expect(row.username == "AKIAEXAMPLE")
        #expect(row.path == "example-assets-bucket")
        #expect(row.unreadable == nil)
    }

    @Test func s3BookmarkWithoutBucket() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "s3-nobucket.duck")

        #expect(row.id == "44444444-4444-4444-4444-444444444444")
        #expect(row.nickname == "No Bucket Yet")
        #expect(row.protocol == .s3)
        #expect(row.host == "s3.example-region.example.net")
        #expect(row.path == "")
        #expect(row.unreadable == nil)
    }

    @Test func ftpBookmarkIsUnsupported() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "ftp.duck")

        #expect(row.id == "55555555-5555-5555-5555-555555555555")
        #expect(row.nickname == "Old FTP")
        #expect(row.protocol == .unsupported("ftp"))
        #expect(row.host == "ftp.example.net")
        #expect(row.unreadable == nil)
    }

    @Test func davsBookmarkIsUnsupported() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "davs.duck")

        #expect(row.id == "66666666-6666-6666-6666-666666666666")
        #expect(row.nickname == "WebDAV Share")
        #expect(row.protocol == .unsupported("davs"))
        #expect(row.host == "webdav.example.net")
        #expect(row.unreadable == nil)
    }

    @Test func bookmarkWithLabels() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "labels.duck")

        #expect(row.id == "77777777-7777-7777-7777-777777777777")
        #expect(row.nickname == "Labeled Box")
        #expect(row.protocol == .sftp)
        #expect(row.labels == ["staging", "team-blue"])
        #expect(row.unreadable == nil)
    }

    @Test func bookmarkWithoutNicknameYieldsNil() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "noname.duck")

        #expect(row.id == "88888888-8888-8888-8888-888888888888")
        #expect(row.nickname == nil)
        #expect(row.host == "noname.example.net")
        #expect(row.unreadable == nil)
    }

    @Test func invalidPortParsesAsNil() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "bad-port.duck")

        #expect(row.nickname == "Zzz Bad Port")
        #expect(row.port == nil)
        #expect(row.unreadable == nil)
    }

    @Test func malformedFileYieldsUnreadableBookmark() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        let row = try bookmark(bookmarks, fileName: "malformed.duck")

        #expect(row.id == "malformed.duck")
        #expect(row.source == "cyberduck")
        #expect(row.nickname == nil)
        #expect(row.host == "")
        #expect(row.port == nil)
        #expect(row.username == nil)
        #expect(row.keyPath == nil)
        #expect(row.path == nil)
        #expect(row.labels == [])
        let unreadable = try #require(row.unreadable)
        #expect(unreadable.contains("malformed.duck"))
    }

    // MARK: - Sort order: nickname (case-insensitive), then host

    @Test func readSortsByNicknameThenHost() throws {
        let source = CyberduckBookmarkSource()
        let bookmarks = try source.read(from: fixturesFolder)
        #expect(bookmarks.count == 10)

        let order = bookmarks.map(\.fileName)
        #expect(order == [
            "malformed.duck",
            "noname.duck",
            "s3-bucket.duck",
            "sftp-key.duck",
            "labels.duck",
            "s3-nobucket.duck",
            "ftp.duck",
            "sftp-password.duck",
            "davs.duck",
            "bad-port.duck",
        ])
    }

    // MARK: - locate(home:)

    @Test func locateReturnsTheDefaultFolderWhenItExists() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cyberduck-locate-\(UUID().uuidString)", isDirectory: true)
        let bookmarksFolder = home
            .appendingPathComponent("Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks",
                                     isDirectory: true)
        try FileManager.default.createDirectory(at: bookmarksFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let located = CyberduckBookmarkSource().locate(home: home)
        #expect(located?.path == bookmarksFolder.path)
    }

    @Test func locateReturnsNilWhenTheFolderIsAbsent() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cyberduck-locate-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(CyberduckBookmarkSource().locate(home: home) == nil)
    }

    // MARK: - Source identity

    @Test func sourceIdentity() {
        #expect(CyberduckBookmarkSource.id == "cyberduck")
        #expect(!CyberduckBookmarkSource.displayNameKey.isEmpty)
    }
}
