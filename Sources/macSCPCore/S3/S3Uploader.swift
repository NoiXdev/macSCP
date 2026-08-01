import Foundation

/// The seam `S3Uploader` needs from `S3FileSystem` to sign and send a
/// request — exactly the two operations `buildSignedRequest` +
/// `transport.send` provide, exposed as thin wrappers so the uploader is
/// unit-testable with a fake builder and never needs to know about
/// `S3ConnectionConfig`, `S3HTTPTransport`, or pagination (M13/T5).
public protocol S3RequestBuilder: Sendable {
    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Uploads an object to S3 from a chunk stream (M13/T5).
///
/// For now this only implements the SINGLE-PUT path: the whole stream is
/// buffered in memory, and once it ends at or below `singlePutThreshold` the
/// buffer goes out as one signed PUT with a REAL content SHA-256 (never
/// `UNSIGNED-PAYLOAD` — some S3-compatible servers, including MinIO, reject
/// or mishandle unsigned payloads on certain configurations, and a real hash
/// is strictly more portable). A stream that grows past the threshold before
/// ending currently throws — multipart upload (initiate/uploadPart/complete)
/// lands in M13/T6 and will replace that arm, slotting in right where the
/// buffering loop below notices the threshold was exceeded.
public struct S3Uploader: Sendable {
    /// Objects at or below this size go out as a single PUT. AWS's own
    /// single-PUT limit is 5 GiB, but buffering the whole object in memory
    /// makes a much smaller threshold the practical choice here; 8 MiB keeps
    /// memory use modest while covering the overwhelming majority of files
    /// transferred through this client.
    public static let singlePutThreshold = 8 * 1024 * 1024

    public init() {}

    public func upload(
        key: String, contents: AsyncThrowingStream<Data, Error>, using builder: any S3RequestBuilder
    ) async throws {
        var buffer = Data()
        for try await chunk in contents {
            buffer.append(chunk)
            if buffer.count > Self.singlePutThreshold {
                // Multipart upload lands in M13/T6; until then a large
                // object simply cannot be written through this uploader.
                throw RemoteFSError.protocolError(
                    reason: "large S3 uploads (multipart) land in M13 Task 6")
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
