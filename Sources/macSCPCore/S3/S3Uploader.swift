import Foundation
import Synchronization

/// The seam `S3Uploader` needs from `S3FileSystem` to sign and send a
/// request — exactly the two operations `buildSignedRequest` +
/// `transport.send` provide, exposed as thin wrappers so the uploader is
/// unit-testable with a fake builder and never needs to know about
/// `S3ConnectionConfig`, `HTTPTransport`, or pagination (M13/T5) — plus
/// where a multipart abort goes out.
public protocol S3RequestBuilder: Sendable {
    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// A way out to the network for ONE multipart abort, of its own: the
    /// builder's `disconnect()` neither cancels it nor waits for it (final
    /// review I1 of the 2026-09-19 plan). The abort is still signed through
    /// `signedRequest`. The uploader asks for one per abort and finishes it
    /// once the abort was answered or given up.
    func abortChannel() -> any S3AbortChannel
}

/// One multipart abort's way out to the network (`S3RequestBuilder`).
public protocol S3AbortChannel: Sendable {
    /// Sends the abort, with the error mapping `S3RequestBuilder.perform`
    /// applies.
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Lets the channel go once whatever it still carries has finished —
    /// never cancelling it. Called once, after the abort was answered or
    /// its bound gave up on it.
    func finish()
}

/// A multipart upload failed — or was cancelled — and its abort is running.
/// Until the server confirms it, the server may still hold the upload's
/// parts as an INCOMPLETE upload, which no object listing shows, no
/// `DeleteObject` removes, and the account is billed for until a lifecycle
/// rule or a later abort ends it.
///
/// Thrown by `S3Uploader` in place of the original error, which it carries,
/// the moment the abort is LAUNCHED — never after waiting for it (Task 2 fix
/// round 2 of the 2026-09-19 plan, N1). `confirmation` is the abort itself:
/// `true` once the server confirmed it, `false` when it refused or did not
/// answer inside `S3Uploader.abortBoundSeconds` — in which case the
/// uploader has already written its log line. `S3FileSystem.write` keeps
/// this error for `incompleteUploadMayRemain(at:)` and
/// `awaitUnconfirmedAborts()` and throws the original on, so every caller
/// keeps seeing the error it always saw.
public struct S3MultipartAbortInFlight: Error {
    /// The object key the upload was for.
    public let key: String
    /// What ended the upload.
    public let underlying: any Error
    /// The abort, running: `true` once the server confirmed it.
    public let confirmation: Task<Bool, Never>
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
/// on the server. The abort runs detached, on a channel of its own that the
/// connection's `disconnect()` does not cancel, and is never waited for
/// here; it travels in the thrown `S3MultipartAbortInFlight`, and one that
/// is not confirmed is noted rather than swallowed.
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

    /// Told the object key of an upload whose abort did not confirm.
    let noteUnconfirmedAbort: @Sendable (_ objectKey: String) -> Void

    /// How long this uploader's abort may take before it is given up, in
    /// seconds — `abortBoundSeconds` everywhere but the suites.
    let abortBound: Int

    public init() {
        self.init(noteUnconfirmedAbort: S3Uploader.logUnconfirmedAbort)
    }

    /// The same, with the note and the bound injected — the suites' seam. A
    /// case that must see a caller that waits for the abort HANG, rather
    /// than return once the bound gives up on it, passes a bound no runner
    /// reaches and lets its time limit turn the hang red.
    init(
        noteUnconfirmedAbort: @escaping @Sendable (_ objectKey: String) -> Void,
        abortBound: Int = S3Uploader.abortBoundSeconds
    ) {
        self.noteUnconfirmedAbort = noteUnconfirmedAbort
        self.abortBound = abortBound
    }

    /// The production note: one diagnostic-log line naming the object key
    /// and what may remain. The key is the object's path in its bucket —
    /// no credential, no endpoint, no upload id.
    static func logUnconfirmedAbort(_ objectKey: String) {
        DiagnosticLog.shared.log(
            .error, "transfer",
            "s3 multipart abort not confirmed key=\(objectKey); "
                + "an incomplete multipart upload may remain")
    }

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
            // multipart upload sitting on the server.
            //
            // The abort is sent OUTSIDE this task: after a cancellation this
            // task is cancelled, and a request made from a cancelled task may
            // be refused for that alone — which, sent from here as the
            // `try?` it used to be, left a billed incomplete upload behind
            // with nothing said (Task 2 fix round 1 of the 2026-09-19 plan,
            // I3).
            //
            // And it is NOT WAITED FOR here (fix round 2, N1). This throw is
            // what ends a transfer the queue cancelled, and `cancelAll`
            // awaits that — a tab's teardown and the quit watchdog rest on it
            // returning at once (`TabTeardown.run`). An abort to an endpoint
            // that stopped answering would hold all three for its whole
            // backstop. So it runs detached under its own bound, notes an
            // unconfirmed answer itself, and travels inside the error as a
            // `confirmation` only a caller that asks awaits
            // (`S3FileSystem.incompleteUploadMayRemain(at:)`).
            //
            // And it goes out on a channel of its OWN (final review I1 of the
            // 2026-09-19 plan): the connection's `disconnect()` follows a
            // failure within milliseconds — a tab's teardown, the command
            // line's exit — and cancelled an abort sent on the connection's
            // channel, leaving the upload behind. The channel is finished,
            // not cancelled, once the abort was answered or given up.
            let note = noteUnconfirmedAbort
            let bound = abortBound
            let confirmation = Task.detached {
                let channel = builder.abortChannel()
                let confirmed = await Self.abortConfirmed(
                    key: key, uploadID: uploadID, signedBy: builder, sentOn: channel,
                    boundSeconds: bound)
                channel.finish()
                if !confirmed { note(key) }
                return confirmed
            }
            throw S3MultipartAbortInFlight(
                key: key, underlying: error, confirmation: confirmation)
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

    /// How long the detached abort may take before it is given up — a
    /// backstop for an endpoint that stopped answering. Nothing on a
    /// transfer's cancel path waits this long: the upload throws before the
    /// abort answers. Only a caller that asks for the confirmation can.
    static let abortBoundSeconds = 30

    /// Sends the abort in a task the caller's cancellation does not reach
    /// (`BoundedClose.run`, the way the throughput test's removal runs), and
    /// answers whether the server confirmed it inside `boundSeconds`.
    private static func abortConfirmed(
        key: String, uploadID: String, signedBy builder: any S3RequestBuilder,
        sentOn channel: any S3AbortChannel, boundSeconds: Int
    ) async -> Bool {
        let confirmed = Mutex(false)
        let finished = await BoundedClose.run(boundSeconds: boundSeconds) {
            do {
                try await abort(key: key, uploadID: uploadID, signedBy: builder, sentOn: channel)
                confirmed.withLock { $0 = true }
            } catch {
                // Unconfirmed; the caller says so.
            }
        }
        return finished && confirmed.withLock { $0 }
    }

    /// Sends `DELETE ?uploadId={id}` to abort a multipart upload — called
    /// through `abortConfirmed` from the catch-and-rethrow in
    /// `uploadMultipart` so a failed or cancelled upload never leaves
    /// storage (and the bill) sitting on an incomplete multipart upload.
    private static func abort(
        key: String, uploadID: String, signedBy builder: any S3RequestBuilder,
        sentOn channel: any S3AbortChannel
    ) async throws {
        let request = try builder.signedRequest(
            method: "DELETE", key: key, query: [(name: "uploadId", value: uploadID)],
            extraHeaders: [:], body: nil, payloadHash: SigV4Signer.emptyPayloadHash)
        let (_, response) = try await channel.perform(request)
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
