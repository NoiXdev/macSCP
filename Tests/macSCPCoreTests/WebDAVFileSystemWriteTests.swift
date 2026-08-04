import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVFileSystem writes")
struct WebDAVFileSystemWriteTests {
    private let config = WebDAVConnectionConfig(
        stored: StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "u", useNextcloudPath: false),
        password: "p")

    private func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        }
    }

    @Test func writeIssuesPut() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream("hello"))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/a.txt")
    }

    /// There is no partial PUT in WebDAV. Accepting `.append` would silently
    /// overwrite the file from byte zero and destroy the part already there.
    @Test func appendModeIsRefused() async throws {
        let transport = FakeHTTPTransport(replies: [])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.self) {
            try await fs.write(path: "/a.txt", mode: .append, contents: stream("more"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func createDirectoryIssuesMkcolOnACollectionURL() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.createDirectory(at: "/sub")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "MKCOL")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/sub/")
    }

    @Test func mkcolOn405ReportsAlreadyExists() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 405, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.self) {
            try await fs.createDirectory(at: "/sub")
        }
    }

    /// MOVE with Overwrite: F is what makes rename atomic AND non-destructive.
    /// Without the header a server replaces the destination silently.
    @Test func renameIssuesMoveWithOverwriteFalse() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.rename(from: "/a.txt", to: "/b.txt")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "MOVE")
        #expect(request.value(forHTTPHeaderField: "Overwrite") == "F")
        #expect(request.value(forHTTPHeaderField: "Destination")
            == "https://dav.example.com/dav/b.txt")
    }

    @Test func renameOn412ReportsDestinationConflict() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 412, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }
    }

    /// The headline difference from S3: one DELETE, not a recursive listing
    /// and batched deletes.
    @Test func deleteTreeIsASingleDeleteOnTheCollection() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 204, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.deleteTree(at: "/sub")

        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/sub/")
    }

    @Test func deleteIssuesDeleteOnTheFileURL() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 204, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.delete(path: "/a.txt")

        #expect(transport.requests.first?.url?.absoluteString
            == "https://dav.example.com/dav/a.txt")
    }

    /// permissionModel is .none — the capability says so, and the call must
    /// agree rather than pretending to succeed.
    @Test func setPermissionsIsRefused() async throws {
        let fs = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        await #expect(throws: RemoteFSError.self) {
            try await fs.setPermissions(path: "/a.txt", permissions: 0o644)
        }
    }
}
