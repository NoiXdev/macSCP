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
                results.append(S3AccessResult(call: call, answer: .notSent("cancelled")))
                continue
            }
            results.append(S3AccessResult(call: call, answer: await answer(for: call)))
        }
        return results
    }

    private func answer(for call: S3AccessCall) async -> S3AccessAnswer {
        do {
            let (_, response) = try await transport.send(try request(for: call))
            return .answered(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-amz-request-id"))
        } catch {
            // The same one-line mapping every dial uses, which reduces a
            // foreign error to its localized sentence rather than printing
            // its stored properties — a transport error carries the
            // configuration it was dialling with.
            return .failed(DialSupport.reason(for: error))
        }
    }

    /// One signed request per call, built through `S3FileSystem`'s own URL
    /// builders and `S3RequestSigning` — never a second copy of either. A
    /// probe that assembled its own URL would be measuring a request this app
    /// does not send.
    private func request(for call: S3AccessCall) throws -> URLRequest {
        switch call {
        case .headBucket:
            // An empty key addresses the BUCKET itself, which is what makes
            // this `HeadBucket` rather than a HEAD on an object with no name
            // (`S3FileSystem.canonicalKeyPath` states the same rule for
            // `DeleteObjects`).
            let url = try S3FileSystem.keyRequestURL(
                config: config, bucket: config.bucket, key: "", queryPairs: [])
            return try S3RequestSigning.signedRequest(
                url: url, method: "HEAD",
                canonicalPath: S3FileSystem.canonicalKeyPath(
                    config: config, bucket: config.bucket, key: ""),
                query: [], extraHeaders: [:], body: nil,
                payloadHash: SigV4Signer.emptyPayloadHash, config: config)
        case .listObjectsV2:
            // `max-keys=1`: the question is whether the key may read the
            // bucket's contents, not what is in it. One key is the smallest
            // answer that is still an answer, and a diagnosis has no business
            // pulling a page of somebody's object names into a report.
            let query = [
                (name: "list-type", value: "2"),
                (name: "max-keys", value: "1"),
            ]
            let url = try S3FileSystem.requestURL(
                config: config, bucket: config.bucket, queryPairs: query)
            return try S3RequestSigning.signedRequest(
                url: url, method: "GET", canonicalPath: url.path.isEmpty ? "/" : url.path,
                query: query, extraHeaders: [:], body: nil,
                payloadHash: SigV4Signer.emptyPayloadHash, config: config)
        case .listBuckets:
            let url = try S3FileSystem.bucketListURL(config: config)
            return try S3RequestSigning.signedRequest(
                url: url, method: "GET", canonicalPath: "/", query: [], extraHeaders: [:],
                body: nil, payloadHash: SigV4Signer.emptyPayloadHash, config: config)
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
    static func outcome(of results: [S3AccessResult]) -> DiagnosticOutcome {
        var firstFailure: String?
        for result in results {
            switch result.answer {
            case .answered: return .ok
            case .failed(let reason): firstFailure = firstFailure ?? reason
            case .notSent: continue
            }
        }
        return .failed(firstFailure ?? DiagnosticReason.nothingToProbe)
    }
}
