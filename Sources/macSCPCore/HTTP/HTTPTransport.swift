import Foundation

/// Thin seam between a backend and the network: a single `send` call that
/// takes a fully-built `URLRequest` and returns the response. Exists so unit
/// tests can inject a fake transport and exercise request-building,
/// pagination and error-mapping logic without touching the network.
///
/// Shared by S3 (which builds SigV4-signed requests) and WebDAV (M21). The
/// seam deliberately knows nothing about either: whatever authenticates the
/// request has already happened by the time it arrives here, or happens in
/// the session's delegate below it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Streams a (large) response body instead of buffering it — for object
    /// downloads. The response headers/status are available immediately; the
    /// body arrives as `TransferChunk.size` chunks. Non-2xx statuses are the
    /// CALLER's to map (see `S3FileSystem.readStream`) — this only transports.
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
}

/// Default transport: wraps `URLSession`. Used by `S3FileSystem.connect` and
/// `WebDAVFileSystem.connect` unless a test injects a fake one.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    /// The session is required, deliberately: there is no default.
    ///
    /// It used to default to `URLSession.shared`, and S3 was the one caller
    /// that took the default. `URLSession.shared` reads and writes
    /// `URLCache.shared` — 20 MB of disk under `~/Library/Caches`, shared by
    /// every process on the machine — so a 301 or 308 an endpoint answered
    /// once was replayed to a later run without the endpoint being asked
    /// again (measured cross-process on loopback, 2026-08-29; see
    /// `S3SessionIsolationTests`). A default naming process-wide shared
    /// state is the kind where omitting it compiles and quietly reaches the
    /// real thing, which is why `SessionListViewModel.init` lost its own.
    /// Every caller now says which session it is on.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFSError.protocolError(reason: "HTTP transport received a non-HTTP response")
        }
        return (data, httpResponse)
    }

    public func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFSError.protocolError(reason: "HTTP transport received a non-HTTP response")
        }
        // Pull-based: `AsyncThrowingStream(unfolding:)` only invokes this
        // closure when the CONSUMER asks for the next element (each `for
        // try await` iteration), so the network is read exactly as fast as
        // the sink (e.g. a disk write) drains it — no read-ahead buffer for
        // a slow sink to fall behind on.
        //
        // `nonisolated(unsafe)`: the iterator is stateful and not
        // `Sendable`, and the `unfolding:` closure that advances it is
        // `@Sendable`, so the compiler must assume several tasks could call
        // `next()` at once. Why that cannot happen here: the iterator is
        // made by this call, is never stored or handed out, and the
        // `unfolding:` closure is the only code that touches it. That
        // closure produces `stream`, which this method returns to a single
        // caller, and an `AsyncSequence` has one consumer pulling
        // sequentially — so the iterator is confined to one reader for its
        // whole life, and each call has its own.
        //
        // What would break it: a consumer that split the returned stream
        // across concurrent readers. That already violates the
        // `AsyncSequence` single-consumer contract and would scramble the
        // byte order long before the annotation became the problem.
        nonisolated(unsafe) var iterator = bytes.makeAsyncIterator()
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
