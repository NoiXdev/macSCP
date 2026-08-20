import Foundation

/// The seam `S3Uploader` needs from `S3FileSystem` to sign and send a
/// request — exactly the two operations `buildSignedRequest` +
/// `transport.send` provide, exposed as thin wrappers so the uploader is
/// unit-testable with a fake builder and never needs to know about
/// `S3ConnectionConfig`, `HTTPTransport`, or pagination (M13/T5).
public protocol S3RequestBuilder: Sendable {
    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Uploads an object to S3 from a chunk stream (M13/T5, multipart in M13/T6).
///
/// The whole stream is buffered in memory up to `singlePutThreshold`. If it
/// ends at or below that size, the buffer goes out as one signed PUT with a
/// REAL content SHA-256 (never `UNSIGNED-PAYLOAD` — some S3-compatible
/// servers, including MinIO, reject or mishandle unsigned payloads on
/// certain configurations, and a real hash is strictly more portable).
///
/// A stream that grows past the threshold before ending switches to the
/// MULTIPART path instead: initiate → upload `partSize`-sized parts (the
/// last part may be smaller) with `UNSIGNED-PAYLOAD` (streamed parts are too
/// large to buffer twice just to hash them) → complete with the collected
/// ETags. ANY failure during the part-upload/complete phase — including
/// cancellation — aborts the multipart upload so nothing is left orphaned
/// on the server.
public struct S3Uploader: Sendable {
    /// Objects at or below this size go out as a single PUT. AWS's own
    /// single-PUT limit is 5 GiB, but buffering the whole object in memory
    /// makes a much smaller threshold the practical choice here; 8 MiB keeps
    /// memory use modest while covering the overwhelming majority of files
    /// transferred through this client.
    public static let singlePutThreshold = 8 * 1024 * 1024

    /// Size of every multipart part except (possibly) the last one. Equal to
    /// `singlePutThreshold` and comfortably above S3's 5 MiB multipart-part
    /// minimum.
    private static let partSize = 8 * 1024 * 1024

    public init() {}

    public func upload(
        key: String, contents: AsyncThrowingStream<Data, Error>, using builder: any S3RequestBuilder
    ) async throws {
        var buffer = Data()
        var iterator = contents.makeAsyncIterator()
        while let chunk = try await iterator.next() {
            buffer.append(chunk)
            if buffer.count > Self.singlePutThreshold {
                try await uploadMultipart(key: key, buffered: buffer, iterator: &iterator, using: builder)
                return
            }
        }

        let payloadHash = SigV4Signer.hexSHA256(buffer)
        let request = try builder.signedRequest(
            method: "PUT", key: key, query: [], extraHeaders: [:], body: buffer, payloadHash: payloadHash)
        let (_, response) = try await builder.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapStatus(response.statusCode, key: key)
        }
    }

    /// Runs the full multipart handshake: initiate, stream `buffered` plus
    /// the rest of `iterator` out as `partSize`-sized parts, then complete.
    /// `buffered` is already known to exceed `singlePutThreshold` (== `partSize`),
    /// so it always yields a full first part with a remainder carried into
    /// the next one — the already-buffered bytes ARE part 1's start.
    private func uploadMultipart(
        key: String, buffered: Data, iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
        using builder: any S3RequestBuilder
    ) async throws {
        let initiateRequest = try builder.signedRequest(
            method: "POST", key: key, query: [(name: "uploads", value: "")],
            extraHeaders: [:], body: Data(), payloadHash: SigV4Signer.emptyPayloadHash)
        let (initiateData, initiateResponse) = try await builder.perform(initiateRequest)
        guard (200..<300).contains(initiateResponse.statusCode) else {
            throw Self.mapStatus(initiateResponse.statusCode, key: key)
        }
        let uploadID = try S3MultipartXML.parseUploadID(initiateData)

        do {
            var parts: [(number: Int, etag: String)] = []
            var pending = buffered
            var partNumber = 1
            var streamEnded = false

            while true {
                // Top up `pending` to at least `partSize` before cutting off
                // a part, unless the stream has already ended.
                while pending.count < Self.partSize, !streamEnded {
                    if let chunk = try await iterator.next() {
                        pending.append(chunk)
                    } else {
                        streamEnded = true
                    }
                }

                if pending.isEmpty {
                    break
                }

                let partData: Data
                if pending.count > Self.partSize {
                    partData = Data(pending.prefix(Self.partSize))
                    pending = Data(pending.dropFirst(Self.partSize))
                } else {
                    partData = pending
                    pending = Data()
                }

                try Task.checkCancellation()
                let etag = try await uploadPart(
                    key: key, uploadID: uploadID, partNumber: partNumber, body: partData, using: builder)
                parts.append((number: partNumber, etag: etag))
                partNumber += 1

                if streamEnded && pending.isEmpty {
                    break
                }
            }

            let completeBody = try S3MultipartXML.completeBody(parts: parts)
            let completeRequest = try builder.signedRequest(
                method: "POST", key: key, query: [(name: "uploadId", value: uploadID)],
                extraHeaders: [:], body: completeBody, payloadHash: SigV4Signer.hexSHA256(completeBody))
            let (_, completeResponse) = try await builder.perform(completeRequest)
            guard (200..<300).contains(completeResponse.statusCode) else {
                throw Self.mapStatus(completeResponse.statusCode, key: key)
            }
        } catch {
            // Any failure past this point — a failed part, a failed
            // complete, or a cancellation — must never leave an orphaned
            // multipart upload sitting on the server. Best-effort: the abort
            // itself failing must not mask the original error.
            try? await abort(key: key, uploadID: uploadID, using: builder)
            throw error
        }
    }

    /// Uploads one part with `UNSIGNED-PAYLOAD` (the signer treats this as
    /// the literal `x-amz-content-sha256` header value and canonical payload
    /// hash — hashing a multi-MiB part just to sign it would mean buffering
    /// it twice for no security benefit over TLS). Returns the `ETag` the
    /// server assigned this part, which `completeBody` must echo verbatim.
    private func uploadPart(
        key: String, uploadID: String, partNumber: Int, body: Data, using builder: any S3RequestBuilder
    ) async throws -> String {
        let request = try builder.signedRequest(
            method: "PUT", key: key,
            query: [(name: "partNumber", value: "\(partNumber)"), (name: "uploadId", value: uploadID)],
            extraHeaders: [:], body: body, payloadHash: "UNSIGNED-PAYLOAD")
        let (_, response) = try await builder.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapStatus(response.statusCode, key: key)
        }
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw RemoteFSError.protocolError(
                reason: "S3 UploadPart response for part \(partNumber) is missing an ETag header")
        }
        return etag
    }

    /// Sends `DELETE ?uploadId={id}` to abort a multipart upload — called
    /// from the catch-and-rethrow in `uploadMultipart` so a failed or
    /// cancelled upload never leaves storage (and the bill) sitting on an
    /// incomplete multipart upload.
    private func abort(key: String, uploadID: String, using builder: any S3RequestBuilder) async throws {
        let request = try builder.signedRequest(
            method: "DELETE", key: key, query: [(name: "uploadId", value: uploadID)],
            extraHeaders: [:], body: nil, payloadHash: SigV4Signer.emptyPayloadHash)
        let (_, response) = try await builder.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapStatus(response.statusCode, key: key)
        }
    }

    /// Maps a non-2xx HTTP status to the `RemoteFSError` it represents —
    /// deliberately the same mapping `S3FileSystem.mapErrorStatus` applies to
    /// every other request, kept as a small local copy since `S3Uploader`
    /// only sees the `S3RequestBuilder` seam, not `S3FileSystem` itself.
    private static func mapStatus(_ statusCode: Int, key: String) -> RemoteFSError {
        switch statusCode {
        case 403:
            return .authenticationFailed
        case 404:
            return .notFound(path: "/" + key)
        default:
            return .protocolError(reason: "S3 upload failed with HTTP status \(statusCode)")
        }
    }
}
