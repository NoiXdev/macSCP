import Foundation
import Testing
@testable import macSCPCore

/// Canned-response transport (M12/T5): returns the next queued
/// `(Data, HTTPURLResponse)` pair for each `send`, in order, and records
/// every request it was asked to send. An `actor` because the queue is
/// mutated across concurrent `await`s — `S3HTTPTransport` requires
/// `Sendable`, and this is the simplest way to satisfy that honestly for a
/// stateful fake (no `@unchecked` needed).
actor FakeS3Transport: S3HTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RemoteFSError.protocolError(reason: "FakeS3Transport ran out of canned responses")
        }
        return responses.removeFirst()
    }
}

/// Always throws a raw (non-`RemoteFSError`) error from `send`, so tests can
/// exercise `S3FileSystem`'s network-failure → `.connectionFailed` mapping
/// (`fetchPage`'s `catch` clause), which `FakeS3Transport` cannot reach since
/// it only ever returns canned responses or a `RemoteFSError` of its own.
struct ThrowingS3Transport: S3HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

@Suite("S3FileSystem")
struct S3FileSystemTests {
    private let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)

    /// An empty-but-valid ListObjectsV2 response, used purely to satisfy
    /// `connect`'s probe request in tests that want to control the response
    /// to the SUBSEQUENT `list` call independently of the connect probe.
    private let emptyListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
    </ListBucketResult>
    """

    private let rootListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
        <Contents>
            <Key>a.txt</Key>
            <LastModified>2024-01-02T03:04:05.000Z</LastModified>
            <Size>12</Size>
        </Contents>
        <CommonPrefixes>
            <Prefix>sub/</Prefix>
        </CommonPrefixes>
    </ListBucketResult>
    """

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9000/macscp-seed")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func connect(responses: [(Data, HTTPURLResponse)]) async throws -> (S3FileSystem, FakeS3Transport) {
        let transport = FakeS3Transport(responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))] + responses)
        let fs = try await S3FileSystem.connect(config, transport: transport)
        return (fs, transport)
    }

    @Test func listMapsCannedXMLIntoItems() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        let items = try await fs.list(path: "/")

        #expect(items.count == 2)
        #expect(items.first { $0.name == "a.txt" }?.kind == .file)
        #expect(items.first { $0.name == "a.txt" }?.size == 12)
        #expect(items.first { $0.name == "sub" }?.kind == .directory)
    }

    @Test func requestCarriesTheExpectedQueryAndAuthorizationHeader() async throws {
        let (fs, transport) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        _ = try await fs.list(path: "/")

        let requests = await transport.requests
        let listRequest = try #require(requests.last)
        let url = try #require(listRequest.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try #require(components.queryItems)

        #expect(queryItems.contains(URLQueryItem(name: "list-type", value: "2")))
        #expect(queryItems.contains(URLQueryItem(name: "prefix", value: "")))
        #expect(queryItems.contains(URLQueryItem(name: "delimiter", value: "/")))
        #expect(listRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
    }

    @Test func forbiddenResponseThrowsAuthenticationFailed() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 403))])

        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await fs.list(path: "/")
        }
    }

    @Test func connectItselfMapsForbiddenToAuthenticationFailed() async throws {
        let transport = FakeS3Transport(responses: [(Data(), httpResponse(status: 403))])
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await S3FileSystem.connect(config, transport: transport)
        }
    }

    @Test func notFoundResponseThrowsNotFound() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 404))])

        do {
            _ = try await fs.list(path: "/missing")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// `connect` performs a `ListObjectsV2` probe request itself, so a
    /// transport that throws a raw (non-`RemoteFSError`) error surfaces the
    /// `.connectionFailed` mapping there — there is no successfully-connected
    /// `S3FileSystem` to call `list` on in this scenario.
    @Test func networkFailureMapsToConnectionFailed() async throws {
        do {
            _ = try await S3FileSystem.connect(config, transport: ThrowingS3Transport())
            Issue.record("expected connect to throw")
        } catch let error as RemoteFSError {
            guard case .connectionFailed = error else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func truncatedListingPaginatesAndConcatenatesBothPages() async throws {
        let page1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>tok-1</NextContinuationToken>
            <Contents>
                <Key>a.txt</Key>
                <Size>12</Size>
            </Contents>
        </ListBucketResult>
        """
        let page2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>z.txt</Key>
                <Size>3</Size>
            </Contents>
        </ListBucketResult>
        """
        let (fs, transport) = try await connect(responses: [
            (Data(page1.utf8), httpResponse(status: 200)),
            (Data(page2.utf8), httpResponse(status: 200)),
        ])

        let items = try await fs.list(path: "/")

        #expect(items.map(\.name).sorted() == ["a.txt", "z.txt"])

        let requests = await transport.requests
        // probe + page1 + page2 = 3 requests; the second page's request
        // must carry the continuation token from the first.
        #expect(requests.count == 3)
        let page2Request = requests[2]
        let page2URL = try #require(page2Request.url)
        let page2Query = try #require(URLComponents(url: page2URL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(page2Query.contains(URLQueryItem(name: "continuation-token", value: "tok-1")))
    }

    @Test func statFindsAFileByListingItsParent() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        let item = try await fs.stat(path: "/a.txt")
        #expect(item.kind == .file)
        #expect(item.size == 12)
    }

    @Test func statThrowsNotFoundWhenTheEntryIsMissing() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        do {
            _ = try await fs.stat(path: "/does-not-exist.txt")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func homeDirectoryPathIsRoot() async throws {
        let (fs, _) = try await connect(responses: [])
        #expect(try await fs.homeDirectoryPath() == "/")
    }

    @Test func disconnectIsANoOp() async throws {
        let (fs, _) = try await connect(responses: [])
        await fs.disconnect()
    }

    // MARK: - M13 stubs: every mutating method throws protocolError

    /// Runs `operation` and asserts it throws specifically
    /// `RemoteFSError.protocolError`, not just some `RemoteFSError`.
    private func expectProtocolError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func readStreamThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            _ = try await fs.readStream(path: "/a.txt", fromOffset: 0)
        }
    }

    @Test func writeThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        let stream = AsyncThrowingStream<Data, Error> { $0.finish() }
        await expectProtocolError {
            try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream)
        }
    }

    @Test func deleteThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.delete(path: "/a.txt")
        }
    }

    @Test func createDirectoryThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.createDirectory(at: "/new")
        }
    }

    @Test func renameThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }
    }

    @Test func setPermissionsThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.setPermissions(path: "/a.txt", permissions: 0o644)
        }
    }

    @Test func deleteTreeThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.deleteTree(at: "/sub")
        }
    }
}
