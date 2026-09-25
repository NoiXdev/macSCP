import Foundation

/// Why a queued transfer failed, as a value: the case and the data a
/// sentence about it needs, never the sentence itself.
///
/// `TransferQueueViewModel.Item.Status.failed` carries this rather than text
/// (maintainer decision, 2026-09-24: rebuild the failure reasons as a typed
/// cause). Before, the status carried the rendered message, and the row
/// `docs/BACKLOG.md` keeps under "Transfer failure reasons are English
/// inside a localized frame" had nowhere left to go: the frame
/// (`core.transfer.failed %@`) was translated and the sentence inside it was
/// not, and by the time the text reached a reader the case identity was
/// gone. Task 6 of the answered-decisions plan is the reader to come; this
/// type is what it reads.
///
/// **What a payload may hold**: a remote or local PATH (the queue's own,
/// shown in the row beside the message anyway), a bucket-level operation,
/// and — for the three cases below that have one — a `detail` string.
/// Never a secret.
///
/// **`detail` is filtered at construction, not at rendering.** It is the one
/// payload that is text this module did not write: a backend's `reason` or a
/// foreign error's `localizedDescription`. Both can be composed out of an
/// endpoint the user typed, and that field takes
/// `scheme://KEY:SECRET@host` as ordinary input
/// (`ConnectFailureSecrecyTests`), so every `detail` is run through
/// `URLText.withoutUserinfo` by `TransferQueueViewModel.failureKind(for:)`
/// before it reaches a case. The filter used to sit one step later, at the
/// rendering; moving it to the construction is what makes the VALUE safe to
/// hand to a reader, rather than only the string that reader would have
/// printed. `noCausesDataCarriesACredential` holds it there.
///
/// Built by `TransferQueueViewModel.failureKind(for:)`, from the same switch
/// `TransferQueueViewModel.message(for:)` renders from — so an item's status
/// and the text beside it cannot describe two different failures.
public enum TransferFailureKind: Equatable, Sendable {
    /// Nothing at that path.
    case notFound(path: String)
    /// The far side refused the operation at that path.
    case permissionDenied(path: String)
    /// The backend could not reach the server, or lost it.
    case connectionFailed(detail: String)
    /// The server answered something the backend could not parse.
    case protocolError(detail: String)
    /// The server refused the credentials.
    case authenticationFailed
    /// The jump host refused the credentials.
    case jumpAuthenticationFailed
    /// The key may not list the account's buckets.
    case bucketListForbidden
    /// The account has no buckets.
    case bucketListEmpty
    /// An operation whose target IS a bucket rather than something inside
    /// one. The path is deliberately dropped: the refusal is the finding,
    /// the browser already knows where the user pointed, and the sentence
    /// per operation never named it.
    case bucketLevelRefused(operation: RemoteFSError.BucketLevelOperation)
    /// A rename across two buckets. Both paths dropped, for the reason
    /// `DialSupport.classify`'s own arm states.
    case crossBucketRenameRefused
    /// The connection went away — mid-transfer for a foreign error that says
    /// so, or under `cancelAll(reason: .connectionLost)`, which sweeps every
    /// queued and running item into this case rather than into `.cancelled`.
    case connectionLost
    /// The connection went away and this job is not resumable — an editor
    /// write-back, a cross-session job, or a destination that cannot append.
    case interrupted
    /// The rename probe walked its 999 candidates without finding a free
    /// name.
    case noFreeName
    /// Anything else, as the localized sentence the error carried — already
    /// filtered (see the type's own doc comment).
    case unknown(detail: String)

    /// The payload-free name of a kind: what a catalogue key is derived
    /// from, and what a test iterates when it has to reach every kind.
    ///
    /// `CaseIterable` so the list is the compiler's, never a hand-kept one;
    /// `name` below is an exhaustive switch, so a case added above without a
    /// name here does not compile.
    public enum Name: String, CaseIterable, Sendable {
        case notFound, permissionDenied, connectionFailed, protocolError
        case authenticationFailed, jumpAuthenticationFailed
        case bucketListForbidden, bucketListEmpty, bucketLevelRefused, crossBucketRenameRefused
        case connectionLost, interrupted, noFreeName, unknown
    }

    public var name: Name {
        switch self {
        case .notFound: return .notFound
        case .permissionDenied: return .permissionDenied
        case .connectionFailed: return .connectionFailed
        case .protocolError: return .protocolError
        case .authenticationFailed: return .authenticationFailed
        case .jumpAuthenticationFailed: return .jumpAuthenticationFailed
        case .bucketListForbidden: return .bucketListForbidden
        case .bucketListEmpty: return .bucketListEmpty
        case .bucketLevelRefused: return .bucketLevelRefused
        case .crossBucketRenameRefused: return .crossBucketRenameRefused
        case .connectionLost: return .connectionLost
        case .interrupted: return .interrupted
        case .noFreeName: return .noFreeName
        case .unknown: return .unknown
        }
    }

    /// The kind as one sentence, from Core's own catalogue.
    ///
    /// This is the text `TransferQueueViewModel.message(for:)` produced
    /// before the kind existed, composition for composition — the same key
    /// with the same argument — so making the status typed changed no
    /// message a user reads. The three `detail`-carrying cases still put
    /// English inside a localized frame; that is the row's remaining half,
    /// and Task 6 owns it.
    ///
    /// No filtering happens here: a `detail` arrives filtered (see above),
    /// and a path is the queue's own.
    public var message: String {
        switch self {
        case .notFound(let path):
            return String(format: CoreL10n.string("core.transfer.notFound %@"), path)
        case .permissionDenied(let path):
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        case .connectionFailed(let detail):
            return String(format: CoreL10n.string("core.error.connectionLost %@"), detail)
        case .protocolError(let detail):
            return String(format: CoreL10n.string("core.transfer.failed %@"), detail)
        case .authenticationFailed:
            return CoreL10n.string("core.connect.authFailed")
        case .jumpAuthenticationFailed:
            return CoreL10n.string("core.connect.jumpAuthFailed")
        case .bucketListForbidden:
            return CoreL10n.string("core.connect.s3BucketListForbidden")
        case .bucketListEmpty:
            return CoreL10n.string("core.connect.s3BucketListEmpty")
        case .bucketLevelRefused(let operation):
            // The key is DERIVED from the case, as at the other two mappers
            // that render this refusal — a renamed case carries its key
            // with it.
            return CoreL10n.string(operation.refusalMessageKey)
        case .crossBucketRenameRefused:
            return CoreL10n.string("core.connect.s3CrossBucketRename")
        case .connectionLost:
            return CoreL10n.string("core.transfer.connectionLost")
        case .interrupted:
            return CoreL10n.string("core.transfer.interrupted")
        case .noFreeName:
            return CoreL10n.string("core.transfer.noFreeName")
        case .unknown(let detail):
            return String(format: CoreL10n.string("core.transfer.failed %@"), detail)
        }
    }
}
