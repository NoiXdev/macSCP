import Foundation

/// Thin seam between `S3FileSystem` and the network: a single `send` call
/// that takes a fully-built, already-signed `URLRequest` and returns the
/// response. Exists so unit tests can inject a fake transport and exercise
/// `S3FileSystem`'s request-building, pagination, and error-mapping logic
/// without touching the network (M12/T5).
public protocol S3HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport: wraps `URLSession`. Used by `S3FileSystem.connect`
/// unless a test injects a fake one.
public struct URLSessionS3Transport: S3HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFSError.protocolError(reason: "S3 transport received a non-HTTP response")
        }
        return (data, httpResponse)
    }
}
