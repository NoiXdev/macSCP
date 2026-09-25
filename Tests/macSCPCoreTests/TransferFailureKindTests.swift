import Foundation
import Testing

@testable import macSCPCore

/// `TransferQueueViewModel.failureKind(for:)` and `message(for:)` read one
/// switch: the kind a failed queue ITEM carries, and the sentence the row,
/// the audit log and the editor banner show.
///
/// Every row pins the composition — which catalogue key, with which
/// argument — that produced the text before the kind existed
/// (BASE `918c721c`). A row that goes red here is churn in a user-visible
/// message, which this change was not allowed to cause: the rendering is
/// Task 6's business, the model is this one's.
@Suite struct TransferFailureKindTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let label: String
        let error: any Error & Sendable
        let kind: TransferFailureKind
        let message: String
        var testDescription: String { label }
    }

    /// The endpoint shape `URLText.withoutUserinfo` exists for: a reason a
    /// backend composed out of a URL the user typed, which may carry
    /// `KEY:SECRET@`. Written as two halves so neither the value nor its
    /// spelling can reach a failure message from this file
    /// (`CLAUDE.md`, "A value a test must not leak has two exits").
    static let credential = "AKIAEXAMPLE" + ":" + "s3cr3t"
    static var endpointReason: String { "dial failed for https://\(credential)@example.invalid/b" }

    static let rows: [Row] = [
        Row(
            label: "not found", error: RemoteFSError.notFound(path: "/srv/x"),
            kind: .notFound(path: "/srv/x"),
            message: String(format: CoreL10n.string("core.transfer.notFound %@"), "/srv/x")),
        Row(
            label: "permission denied", error: RemoteFSError.permissionDenied(path: "/srv/x"),
            kind: .permissionDenied(path: "/srv/x"),
            message: String(format: CoreL10n.string("core.error.permissionDenied %@"), "/srv/x")),
        Row(
            label: "connection failed",
            error: RemoteFSError.connectionFailed(reason: "the server hung up"),
            kind: .connectionFailed(detail: "the server hung up"),
            message: String(
                format: CoreL10n.string("core.error.connectionLost %@"), "the server hung up")),
        Row(
            label: "protocol error", error: RemoteFSError.protocolError(reason: "bad XML"),
            kind: .protocolError(detail: "bad XML"),
            message: String(format: CoreL10n.string("core.transfer.failed %@"), "bad XML")),
        Row(
            label: "authentication", error: RemoteFSError.authenticationFailed,
            kind: .authenticationFailed, message: CoreL10n.string("core.connect.authFailed")),
        Row(
            label: "jump authentication", error: RemoteFSError.jumpAuthenticationFailed,
            kind: .jumpAuthenticationFailed,
            message: CoreL10n.string("core.connect.jumpAuthFailed")),
        Row(
            label: "bucket list forbidden", error: RemoteFSError.bucketListForbidden,
            kind: .bucketListForbidden,
            message: CoreL10n.string("core.connect.s3BucketListForbidden")),
        Row(
            label: "bucket list empty", error: RemoteFSError.bucketListEmpty,
            kind: .bucketListEmpty, message: CoreL10n.string("core.connect.s3BucketListEmpty")),
        Row(
            label: "bucket-level refusal",
            error: RemoteFSError.bucketLevelRefused(operation: .rename, path: "/bucket"),
            kind: .bucketLevelRefused(operation: .rename),
            message: CoreL10n.string(RemoteFSError.BucketLevelOperation.rename.refusalMessageKey)),
        Row(
            label: "cross-bucket rename",
            error: RemoteFSError.crossBucketRenameRefused(from: "/a/x", to: "/b/x"),
            kind: .crossBucketRenameRefused,
            message: CoreL10n.string("core.connect.s3CrossBucketRename")),
        Row(
            label: "a foreign error that is a lost connection",
            error: NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue),
            kind: .connectionLost, message: CoreL10n.string("core.transfer.connectionLost")),
    ]

    @MainActor @Test(arguments: rows)
    func theErrorMapsToItsKindAndKeepsItsMessage(_ row: Row) {
        #expect(TransferQueueViewModel.failureKind(for: row.error) == row.kind)
        #expect(TransferQueueViewModel.message(for: row.error) == row.message)
        #expect(row.kind.message == row.message)
    }

    /// The three kinds no error maps to, because the queue raises them
    /// itself: a job the queue will not resume, the rename probe running
    /// out of candidates, and a sweep after the connection dropped.
    @Test func theKindsTheQueueRaisesItselfRenderTheirOwnSentence() {
        #expect(TransferFailureKind.interrupted.message == CoreL10n.string("core.transfer.interrupted"))
        #expect(TransferFailureKind.noFreeName.message == CoreL10n.string("core.transfer.noFreeName"))
        #expect(
            TransferFailureKind.connectionLost.message
                == CoreL10n.string("core.transfer.connectionLost"))
    }

    /// A foreign error keeps the text it had: its localized sentence,
    /// filtered, never `String(describing:)`. The positive pins what the
    /// detail IS, the negative beside it what it is not.
    @MainActor @Test func aForeignErrorIsUnknownAndKeepsItsFilteredDescription() {
        let error = NSError(domain: "test.domain", code: 7)
        let kind = TransferQueueViewModel.failureKind(for: error)
        #expect(kind == .unknown(detail: error.localizedDescription))
        #expect(kind.name == .unknown)
        let describesTheError = kind.message.contains(String(describing: error))
        #expect(describesTheError == false)
    }

    /// The cause is built ALREADY filtered, so nothing downstream has to
    /// remember to filter it — the property the App's reader (Task 6) will
    /// depend on. Before the kind existed the filter sat at the rendering
    /// step, so a reader of the raw error got the credential; now the
    /// credential cannot reach the value at all.
    ///
    /// Both exits, per `CLAUDE.md`: the `Bool` is computed before the
    /// expectation and the credential lives in a named constant, so neither
    /// the value nor its spelling reaches a failure message.
    @MainActor @Test func noCausesDataCarriesACredential() {
        let errors: [any Error] = [
            RemoteFSError.connectionFailed(reason: Self.endpointReason),
            RemoteFSError.protocolError(reason: Self.endpointReason),
            NSError(
                domain: NSURLErrorDomain, code: URLError.badURL.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Self.endpointReason]),
        ]
        for error in errors {
            let kind = TransferQueueViewModel.failureKind(for: error)
            let leaksInTheCause = String(describing: kind).contains(Self.credential)
            let leaksInTheMessage = kind.message.contains(Self.credential)
            #expect(leaksInTheCause == false)
            #expect(leaksInTheMessage == false)
        }
    }

    /// Every kind renders a sentence, and `name` round-trips — reached
    /// through `Name.allCases`, so a new kind is covered without an edit
    /// here beyond the compiler's demand in `TransferFailureKindSamples`.
    @Test(arguments: TransferFailureKind.Name.allCases)
    func everyKindHasANameAndASentence(_ name: TransferFailureKind.Name) {
        let kind = TransferFailureKindSamples.sample(name)
        #expect(kind.name == name)
        #expect(!kind.message.isEmpty)
    }

    /// The rows reach every kind an ERROR can produce; the three the queue
    /// raises itself are named beside them, so the union is the whole enum
    /// and a new case is a red here rather than an untested one.
    @Test func theRowsReachEveryKindAnErrorCanProduce() {
        let reached = Set(Self.rows.map(\.kind.name))
            .union([.interrupted, .noFreeName, .connectionLost, .unknown])
        #expect(reached == Set(TransferFailureKind.Name.allCases))
    }
}

/// One value per `TransferFailureKind.Name`, by an exhaustive switch: a name
/// added to the enum does not compile here until it has a sample.
enum TransferFailureKindSamples {
    static func sample(_ name: TransferFailureKind.Name) -> TransferFailureKind {
        switch name {
        case .notFound: return .notFound(path: "/srv/x")
        case .permissionDenied: return .permissionDenied(path: "/srv/x")
        case .connectionFailed: return .connectionFailed(detail: "the server hung up")
        case .protocolError: return .protocolError(detail: "bad XML")
        case .authenticationFailed: return .authenticationFailed
        case .jumpAuthenticationFailed: return .jumpAuthenticationFailed
        case .bucketListForbidden: return .bucketListForbidden
        case .bucketListEmpty: return .bucketListEmpty
        case .bucketLevelRefused: return .bucketLevelRefused(operation: .rename)
        case .crossBucketRenameRefused: return .crossBucketRenameRefused
        case .connectionLost: return .connectionLost
        case .interrupted: return .interrupted
        case .noFreeName: return .noFreeName
        case .unknown: return .unknown(detail: "something else")
        }
    }
}
