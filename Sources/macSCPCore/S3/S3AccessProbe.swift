import Foundation

/// The three calls that answer "what may this key do here?" — the S3 seam
/// contribution's whole content (design §3, and the maintainer's note of
/// 2026-09-02 about showing a key's access level).
///
/// Ordered from the narrowest question to the widest: may the key see this
/// one bucket, may it read what is in it, may it enumerate the account. Each
/// answer is independent — a key that lists objects but is refused the
/// account listing is an ordinary, correctly scoped key, and a diagnosis that
/// reported only the last of the three would call it broken.
///
/// The raw values are the AWS operation names, because that is what the row
/// prints and what a provider's own documentation and support call them.
enum S3AccessCall: String, Sendable, CaseIterable {
    case headBucket = "HeadBucket"
    case listObjectsV2 = "ListObjectsV2"
    case listBuckets = "ListBuckets"
}

/// What one of those three calls came back with.
///
/// `answered` is any HTTP status at all, 403 included: the status IS the
/// measurement here, and the whole point of the probe is to report a refusal
/// as a fact about the key rather than as a failure of the check. `failed` is
/// the transport never getting an answer, and `notSent` is a call this
/// session has no question for.
enum S3AccessAnswer: Sendable, Equatable {
    case answered(status: Int, requestID: String?)
    case failed(String)
    case notSent(String)
}

struct S3AccessResult: Sendable, Equatable {
    let call: S3AccessCall
    let answer: S3AccessAnswer

    /// This call's share of the step's one detail line.
    ///
    /// The request id is printed in full rather than shortened: it is the
    /// identifier a provider is handed when asked what happened to a request,
    /// and half of one identifies nothing. It is not a credential — servers
    /// send it precisely so it can be quoted.
    var text: String {
        switch answer {
        case .answered(let status, let requestID):
            guard let requestID, !requestID.isEmpty else { return "\(call.rawValue) \(status)" }
            return "\(call.rawValue) \(status) (req \(requestID))"
        case .failed(let reason):
            return "\(call.rawValue) failed (\(reason))"
        case .notSent(let reason):
            return "\(call.rawValue) skipped (\(reason))"
        }
    }
}

/// Issues the three calls above with the session's OWN credentials, through
/// the same signer every other S3 request in this app goes through.
///
/// The transport is injected rather than built here, for the same reason
/// `S3FileSystem` takes one: the contribution hands it an ephemeral session
/// (no process-wide cache, so a probe cannot be answered from one), and a
/// test hands it canned responses to measure the requests and the line.
///
/// Nothing here interprets a status. A row saying `ListBuckets 403` is the
/// answer; deciding what a user should do about it is the reader's job, and a
/// probe that guessed would be guessing about every provider at once — the
/// rig's MinIO already disagrees with AWS about this exact call
/// (`docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md`: a scoped
/// key gets a FILTERED list, not a refusal).
struct S3AccessProbe: Sendable {
    /// Why the two bucket-level calls are not sent when the connection's root
    /// is the account's bucket list: there is no one bucket to ask about, and
    /// `config.bucket` is unused in that mode (`S3ConnectionConfig
    /// .startsAtBucketList`). A constant rather than a literal at its one
    /// emission site, so the test that pins the line reads the sentence
    /// instead of spelling a second copy of it.
    static let bucketListSkipReason = "this connection starts at the bucket list"

    /// Why a call was not sent when the calling task was cancelled between
    /// calls. Its own sentence rather than a shared one: the row it reaches
    /// is discarded by the runner (a cancelled diagnosis reports the steps it
    /// finished), so what matters is that the reason describes THIS
    /// situation and no other.
    static let cancelledSkipReason = "cancelled"

    /// Why a call could not even be built: the configured endpoint is not a
    /// URL this app can address. See `answer(for:)` for why the underlying
    /// error's own sentence is dropped rather than printed.
    static let unusableEndpointReason = "the endpoint is not a usable URL"

    let config: S3ConnectionConfig
    let transport: any HTTPTransport

    func run() async -> [S3AccessResult] {
        var results: [S3AccessResult] = []
        for call in S3AccessCall.allCases {
            if config.startsAtBucketList, call != .listBuckets {
                results.append(
                    S3AccessResult(call: call, answer: .notSent(Self.bucketListSkipReason)))
                continue
            }
            // The runner's deadline cancels this probe from outside and drops
            // whatever it returns; stopping here means an abandoned step does
            // not keep signing and sending requests nobody will read.
            guard !Task.isCancelled else {
                results.append(
                    S3AccessResult(call: call, answer: .notSent(Self.cancelledSkipReason)))
                continue
            }
            results.append(S3AccessResult(call: call, answer: await answer(for: call)))
        }
        return results
    }

    private func answer(for call: S3AccessCall) async -> S3AccessAnswer {
        let request: URLRequest
        do {
            request = try self.request(for: call)
        } catch {
            // Deliberately NOT the error's own text. Every error on this path
            // is built by interpolating the configured endpoint — "Invalid S3
            // endpoint: \(config.endpoint)" in the URL builders, "S3 endpoint
            // has no host: \(config.endpoint)" in the signer — and that field
            // is ordinary input a credential travels in
            // (`https://KEY:SECRET@host`, which no schema here strips).
            //
            // Measured 2026-09-03: a password containing `/` makes the whole
            // string an invalid URL, so this arm is exactly the one such an
            // endpoint reaches, and `URLText.withoutUserinfo` cannot clean it
            // — its authority scan ends at the `/` before the `@`, the limit
            // its own doc comment states. Nothing a reader can act on is
            // lost: the endpoint cannot be turned into a request, which is
            // what the sentence says.
            return .failed(Self.unusableEndpointReason)
        }
        do {
            let (_, response) = try await transport.send(request)
            return .answered(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-amz-request-id"))
        } catch {
            // The same one-line mapping every dial uses, which reduces a
            // foreign error to its localized sentence rather than printing
            // its stored properties — a transport error carries the
            // configuration it was dialling with. What reaches here is a
            // `URLError` (localized sentence, no URL) or the transport's own
            // non-HTTP-response error; neither names the endpoint.
            return .failed(DialSupport.reason(for: error))
        }
    }

    /// One signed request per call, named as a RESOURCE and signed by
    /// `S3FileSystem.signedRequest(_:method:query:…)` — the same factory the
    /// file system's own calls go through.
    ///
    /// This probe cannot pair a URL with a canonical path, because there is
    /// no parameter here for a path: it names a shape and a method. That is
    /// deliberate. When this file carried its own copies of those pairings, a
    /// later correction landing in `S3FileSystem` alone would have left the
    /// probe signing the old path — 403 `SignatureDoesNotMatch`, reported as
    /// `ListObjectsV2 403`, which reads as a key that lacks a permission it
    /// actually has. Measured on 2026-09-03 by planting exactly that drift
    /// against the rig; the factory's doc comment carries the numbers.
    private func request(for call: S3AccessCall) throws -> URLRequest {
        switch call {
        case .headBucket:
            // The bucket resource, addressed as the empty key — the same
            // shape `DeleteObjects` uses.
            return try S3FileSystem.signedRequest(
                .objectKey(bucket: config.bucket, key: ""), method: "HEAD", config: config)
        case .listObjectsV2:
            // `max-keys=1`: the question is whether the key may read the
            // bucket's contents, not what is in it. One key is the smallest
            // answer that is still an answer, and a diagnosis has no business
            // pulling a page of somebody's object names into a report.
            return try S3FileSystem.signedRequest(
                .bucketRoot(bucket: config.bucket), method: "GET",
                query: [
                    (name: "list-type", value: "2"),
                    (name: "max-keys", value: "1"),
                ],
                config: config)
        case .listBuckets:
            return try S3FileSystem.signedRequest(.account, method: "GET", config: config)
        }
    }

    /// The step's one line: every call, in order, whatever became of it.
    ///
    /// ` · ` rather than `; `, because a reason can itself contain a
    /// semicolon (a server's own sentence) and the reader has to be able to
    /// see where one call ends and the next begins.
    static func detail(_ results: [S3AccessResult]) -> String {
        results.map(\.text).joined(separator: " · ")
    }

    /// `ok` when the server ANSWERED at least one of the three, whatever it
    /// answered — the rule the dials already follow (`DialProbes`): a 403 is a
    /// working server refusing a key, and calling it a failed check would
    /// point the user at their network for a question they never asked.
    ///
    /// A run where nothing was answered and nothing failed is a run where
    /// nothing was SENT, and it is reported as skipped with the first
    /// call's own reason — never with a sentence about name resolution,
    /// which is what `DiagnosticReason.nothingToProbe` says and which is
    /// true of no path through this probe.
    static func outcome(of results: [S3AccessResult]) -> DiagnosticOutcome {
        var firstFailure: String?
        var firstSkip: String?
        for result in results {
            switch result.answer {
            case .answered: return .ok
            case .failed(let reason): firstFailure = firstFailure ?? reason
            case .notSent(let reason): firstSkip = firstSkip ?? reason
            }
        }
        if let firstFailure { return .failed(firstFailure) }
        // `firstSkip` is set whenever `S3AccessCall` has a case at all, so
        // the fallback describes the empty walk and nothing else.
        return .skipped(firstSkip ?? "no call was sent")
    }
}
