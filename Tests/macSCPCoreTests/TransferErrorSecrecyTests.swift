import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// A failed transfer never shows a raw error, so no endpoint credential
/// reaches the queue (fix round 1 of Task 1, 2026-09-19 small follow-ups).
///
/// `String(describing:)` of an `NSError` prints its whole `userInfo`, and a
/// `URLSession` failure carries the failing URL there
/// (`NSURLErrorFailingURLStringErrorKey`) — userinfo and all, for an
/// endpoint typed as `https://KEY:SECRET@host`. The queue's catch-all used to
/// render exactly that, and an S3 download that lost its connection mid-body
/// reached it.
///
/// Every value that must not leak lives in a named constant, and every
/// expectation reads a `Bool` computed before it: `#expect` prints the source
/// text of what it checks, so a secret spelled inside one would leak through
/// its own failure message (CLAUDE.md, "A value a test must not leak has two
/// exits").
@Suite("A failed transfer shows no raw error", .timeLimit(.minutes(2)))
struct TransferErrorSecrecyTests {
    // MARK: - The values that must not leak

    static let credentialUser = "sentinel-queue-access-key-7c1d"
    static let credentialSecret = "sentinel-queue-secret-key-4b8e"
    static let credentialURL =
        "https://\(credentialUser):\(credentialSecret)@s3.example.test/macscp-seed/remote.bin"

    /// A lost connection as `URLSession` reports one: the failing URL in
    /// both of the keys it fills.
    static let lostConnectionCarryingTheCredential = URLError(
        .networkConnectionLost,
        userInfo: [
            NSURLErrorFailingURLStringErrorKey: credentialURL,
            NSURLErrorFailingURLErrorKey: URL(string: credentialURL) as Any,
        ])

    /// Whether `text` carries any part of the credential, or the URL that
    /// holds it.
    static func leaks(_ text: String) -> Bool {
        text.contains(credentialSecret) || text.contains(credentialUser)
            || text.contains(credentialURL)
    }

    // MARK: - Through the queue

    /// The case that was live: an S3 download losing its connection in the
    /// body. It reads as a lost connection — `.interrupted`, the same as
    /// WebDAV's — and nothing the item holds names the credential.
    @Test(arguments: HTTPTransferCancelTests.Backend.allCases)
    @MainActor func aDownloadThatLosesItsConnectionMidBodyShowsNoCredential(
        _ backend: HTTPTransferCancelTests.Backend
    ) async throws {
        let testCase = HTTPTransferCancelTests.Case(
            backend: backend, leg: .downloadBody, failure: .networkConnectionLostWithCredentialURL)
        let endpoint = ParkingHTTPEndpoint(
            backend: testCase.backend, leg: testCase.leg, failure: testCase.failure)
        let queue = TransferQueueViewModel()
        try await testCase.enqueueAndWait(on: queue, through: endpoint)

        let status = queue.items.first?.status
        let statusLeaks = Self.leaks(String(describing: status))
        let readsLost = status == .interrupted
        #expect(statusLeaks == false, "the item's text carries the credential")
        #expect(readsLost, "the item does not read as a lost connection")
    }

    // MARK: - The mapping itself

    /// A raw lost connection — one a backend forgot to wrap — reads
    /// "Connection lost", and carries neither the credential nor the URL.
    @Test @MainActor func aRawLostConnectionReadsConnectionLost() {
        let text = TransferQueueViewModel.message(for: Self.lostConnectionCarryingTheCredential)
        let textLeaks = Self.leaks(text)
        let readsLost = text == CoreL10n.string("core.transfer.connectionLost")
        #expect(textLeaks == false)
        #expect(readsLost)
    }

    /// A reset at the socket is a lost connection too.
    @Test @MainActor func aConnectionResetReadsConnectionLost() {
        let reset = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        #expect(
            TransferQueueViewModel.message(for: reset)
                == CoreL10n.string("core.transfer.connectionLost"))
    }

    /// Any other foreign error reads the fixed "Transfer failed" sentence;
    /// its detail is its localized sentence with every URL's userinfo cut
    /// out, never its description — a URL may sit in either.
    @Test @MainActor func anyOtherForeignErrorReadsTransferFailedWithASanitizedDetail() {
        let foreign = NSError(
            domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "no answer from \(Self.credentialURL)",
                NSURLErrorFailingURLStringErrorKey: Self.credentialURL,
            ])
        let text = TransferQueueViewModel.message(for: foreign)
        let textLeaks = Self.leaks(text)
        let expected = String(
            format: CoreL10n.string("core.transfer.failed %@"),
            "no answer from https://s3.example.test/macscp-seed/remote.bin")
        let readsFailed = text == expected
        #expect(textLeaks == false)
        #expect(readsFailed)
    }

    /// The two cases whose text a backend composes: their reason reaches the
    /// user through the same filter.
    @Test @MainActor func aBackendsOwnReasonIsShownWithoutUserinfo() {
        let reason = "S3 request failed at \(Self.credentialURL)"
        for error in [
            RemoteFSError.connectionFailed(reason: reason), .protocolError(reason: reason),
        ] {
            let textLeaks = Self.leaks(TransferQueueViewModel.message(for: error))
            #expect(textLeaks == false)
        }
    }

    // MARK: - The guard: no queue message path renders a raw error

    /// Read with comments blanked and strings KEPT (`SourceCorpus
    /// .commentFree`): an interpolated `\(error)` is inside a string
    /// literal, and the code-only view blanks it.
    ///
    /// The negative checks stand beside positive ones: the file must still
    /// declare the mapping and still route details through
    /// `URLText.withoutUserinfo`, so a renamed or moved mapping turns this
    /// red instead of leaving the negatives matching nothing.
    @Test func noQueueMessagePathRendersARawError() throws {
        let source = try SourceCorpus.commentFree(of: Self.root.appendingPathComponent(
            "Sources/macSCPCore/Presentation/TransferQueueViewModel.swift"))
        #expect(source.contains(Self.mappingDeclaration), "the mapping moved — rename?")
        #expect(
            source.contains(Self.causeDeclaration),
            "the cause mapping moved — rename? it is where the filtering lives since 2026-09-25")
        #expect(source.contains(Self.filter), "the mapping no longer filters its details")
        let found = Self.violations(in: source)
        #expect(found.isEmpty, "\(found)")
    }

    /// The guard is not blind to what it forbids: each spelling planted in a
    /// synthetic source is found.
    @Test func theGuardSeesEachRawRendering() {
        let planted = """
            let a = String(describing: error)
            let b = "failed: \\(error)"
            let c = error.localizedDescription
            let d = URLText.withoutUserinfo(error.localizedDescription)
            """
        #expect(Self.violations(in: planted).count == 3)
    }

    static let mappingDeclaration = "static func message(for error: Error) -> String"
    /// The second positive beside the negatives: since 2026-09-25 the
    /// rendering is one line (`failureKind(for: error).message`) and the
    /// switch that touches a backend's free text — the one the filter has to
    /// run in — is this one. Without naming it, a guard that only required
    /// `message(for:)` would go on passing over a `failureKind(for:)` that
    /// had quietly dropped the filter.
    static let causeDeclaration =
        "static func failureKind(for error: Error) -> TransferFailureKind"
    static let filter = "URLText.withoutUserinfo("

    /// Every raw rendering of an error in `source`: a description, an
    /// interpolation of the error itself, and a localized sentence that
    /// does not go through the userinfo filter on the same line.
    static func violations(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n") {
            if line.contains("String(describing:") { found.append(String(line)) }
            else if line.contains("\\(error") { found.append(String(line)) }
            else if line.contains("localizedDescription"), !line.contains(filter) {
                found.append(String(line))
            }
        }
        return found
    }

    /// The body of the function whose declaration is `declaration` in `url`
    /// — from its opening brace to the matching closing one — in the
    /// comment-free view (strings kept), or `nil` when no such declaration
    /// is there. The braces are matched in the code view, where comments
    /// and strings are blanked, so a brace inside either cannot end the
    /// body early; the two views are the same length (`SourceCorpus`), so
    /// the span found in one is the span in the other.
    ///
    /// For guards over one function of a large file (`CLIErrorMapping`'s
    /// and `RemoteBrowserViewModel`'s `message(for:…)`), so the rest of the
    /// file is not what they read.
    static func body(opening declaration: String, in url: URL) throws -> String? {
        let commentFree = try SourceCorpus.commentFree(of: url)
        let code = Array(try SourceCorpus.code(of: url))
        guard let found = commentFree.range(of: declaration) else { return nil }
        let text = Array(commentFree)
        var index = commentFree.distance(from: commentFree.startIndex, to: found.upperBound)
        while index < code.count, code[index] != "{" { index += 1 }
        let start = index
        var depth = 0
        while index < code.count {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index += 1
        }
        return nil
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
