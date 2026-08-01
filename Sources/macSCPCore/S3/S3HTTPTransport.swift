import Foundation

/// Thin seam between `S3FileSystem` and the network: a single `send` call
/// that takes a fully-built, already-signed `URLRequest` and returns the
/// response. Exists so unit tests can inject a fake transport and exercise
/// `S3FileSystem`'s request-building, pagination, and error-mapping logic
/// without touching the network (M12/T5).
public protocol S3HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Streams a (large) response body instead of buffering it — for object
    /// downloads. The response headers/status are available immediately; the
    /// body arrives as `TransferChunk.size` chunks. Non-2xx statuses are the
    /// CALLER's to map (see `S3FileSystem.readStream`) — this only transports.
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
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

    public func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFSError.protocolError(reason: "S3 transport received a non-HTTP response")
        }
        // Pull-based: `AsyncThrowingStream(unfolding:)` only invokes this
        // closure when the CONSUMER asks for the next element (each `for
        // try await` iteration), so the network is read exactly as fast as
        // the sink (e.g. a disk write) drains it — no read-ahead buffer for
        // a slow sink to fall behind on.
        var iterator = bytes.makeAsyncIterator()
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            var buffer = Data(); buffer.reserveCapacity(TransferChunk.size)
            while buffer.count < TransferChunk.size {
                guard let byte = try await iterator.next() else {
                    return buffer.isEmpty ? nil : buffer
                }
                buffer.append(byte)
            }
            return buffer
        })
        return (stream, http)
    }
}
