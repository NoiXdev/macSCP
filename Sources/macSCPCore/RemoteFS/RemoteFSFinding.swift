import Foundation

/// A finding this project NAMED, rather than a sentence it wrote.
///
/// The sixteen sites the 2026-09-28 spec counted threw
/// `RemoteFSError.protocolError(reason:)` with macSCP's own English prose
/// in the `reason` — prose that then travelled, untranslated, inside a
/// translated frame (`core.transfer.failed %@`). That is the
/// `docs/BACKLOG.md` row "Transfer failure reasons are English inside a
/// localized frame", and a case with a catalogue key is what closes it:
/// the frame stays, the sentence inside it becomes the reader's language.
///
/// ## The key is derived, so a renamed case carries it
///
/// `messageKey(for:)` builds `core.finding.<name>` out of the `Name`'s
/// `rawValue`, the way
/// `RemoteFSError.BucketLevelOperation.refusalMessageKey` does. No mapper
/// spells a key, so renaming a case moves its key with it — and
/// `LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence` is what
/// makes a finding without catalogue entries red, since the lookup itself
/// cannot fail loudly (`CoreL10n.string` falls back to the key text).
///
/// ## A finding never carries an endpoint or a server's words
///
/// The only payloads here are an HTTP status code and a path the CALLER
/// asked about — this project's own strings both. Nothing a backend
/// composed out of a typed endpoint, and nothing a server wrote, may enter
/// a finding: that is precisely the text `URLText.withoutUserinfo` exists
/// to filter, and a finding is handed to readers (the queue's typed cause,
/// the browse banner, the diagnostic log, the CLI) WITHOUT a filter
/// because it is this module's own text. `RemoteFSFindingTests
/// .noFindingCarriesForeignText` is what holds the property.
///
/// ## Two texts, on purpose
///
/// `message` is the user's language, from Core's catalogue.
/// `logSentence` is fixed English for the diagnostic log and the CLI,
/// neither of which is localized — the arrangement `TunnelFailureKind`
/// already uses, where the state carries the kind, the App translates and
/// the log keeps the English.
///
/// `readsAsConnectionFailure` is what `RemoteFSError.isConnectionFailure`
/// reads for `RemoteFSError.finding`, so the transfer queue classifies a
/// finding mid-transfer as resumable or not without asking anything else.
public enum RemoteFSFinding: Equatable, Sendable {
    /// A ranged `GET` was answered with the whole object, so the resume was
    /// abandoned rather than the partial file corrupted.
    case resumeRangeIgnored
    /// The object changed on the server since the interrupted download, so
    /// nothing was appended to the partial file.
    case sourceChangedSinceInterruption
    /// The server answered with a status this backend has no reading for.
    case unexpectedStatus(code: Int)
    /// A directory could not be created because something is already there.
    case directoryAlreadyExists
    /// A move or copy was refused because its destination exists.
    case destinationAlreadyExists
    /// The server reported that it has no room left.
    case outOfStorage
    /// The upload's body stream could not be opened.
    case uploadStreamUnavailable
    /// A directory was expected at `path` and something else is there.
    case pathExistsAndIsNotADirectory(path: String)
    /// The answer was not an HTTP response at all.
    case nonHTTPResponse
    /// A directory listing arrived in a shape this backend could not read.
    case listingUnparsable
    /// A redirect was refused: its new target could not be read.
    case redirectUnreadable
    /// A redirect was refused: the request's body cannot be sent twice.
    case redirectBodyNotResendable
    /// A redirect was refused: the new target could not be signed.
    case redirectNotResignable

    /// The payload-free name of a finding: what a catalogue key is derived
    /// from, and what a guard iterates when it has to reach every finding.
    ///
    /// `CaseIterable` so the list is the compiler's, never a hand-kept one;
    /// `name` below is an exhaustive switch, so a case added above without
    /// a name here does not compile.
    public enum Name: String, CaseIterable, Sendable {
        case resumeRangeIgnored, sourceChangedSinceInterruption, unexpectedStatus
        case directoryAlreadyExists, destinationAlreadyExists, outOfStorage
        case uploadStreamUnavailable, pathExistsAndIsNotADirectory
        case nonHTTPResponse, listingUnparsable
        case redirectUnreadable, redirectBodyNotResendable, redirectNotResignable
    }

    public var name: Name {
        switch self {
        case .resumeRangeIgnored: return .resumeRangeIgnored
        case .sourceChangedSinceInterruption: return .sourceChangedSinceInterruption
        case .unexpectedStatus: return .unexpectedStatus
        case .directoryAlreadyExists: return .directoryAlreadyExists
        case .destinationAlreadyExists: return .destinationAlreadyExists
        case .outOfStorage: return .outOfStorage
        case .uploadStreamUnavailable: return .uploadStreamUnavailable
        case .pathExistsAndIsNotADirectory: return .pathExistsAndIsNotADirectory
        case .nonHTTPResponse: return .nonHTTPResponse
        case .listingUnparsable: return .listingUnparsable
        case .redirectUnreadable: return .redirectUnreadable
        case .redirectBodyNotResendable: return .redirectBodyNotResendable
        case .redirectNotResignable: return .redirectNotResignable
        }
    }

    /// The catalogue key for a name. A `Name` rather than a case, so a guard
    /// that iterates `allCases` can ask for the key without inventing a
    /// payload.
    ///
    /// The two names that interpolate carry the format specifier in the key,
    /// as this project's other argument-taking keys do
    /// (`core.transfer.notFound %@`).
    public static func messageKey(for name: Name) -> String {
        switch name {
        case .unexpectedStatus, .pathExistsAndIsNotADirectory:
            return "core.finding.\(name.rawValue) %@"
        default:
            return "core.finding.\(name.rawValue)"
        }
    }

    public var messageKey: String { Self.messageKey(for: name) }

    /// The finding as one sentence, in the reader's language.
    public var message: String {
        switch self {
        case .unexpectedStatus(let code):
            return String(format: CoreL10n.string(messageKey), String(code))
        case .pathExistsAndIsNotADirectory(let path):
            return String(format: CoreL10n.string(messageKey), path)
        default:
            return CoreL10n.string(messageKey)
        }
    }

    /// The same finding as fixed English, for the diagnostic log and the
    /// CLI — neither of which is localized. Written here rather than read
    /// out of the `en` catalogue: a log line is not read through a
    /// catalogue, and the log's sentences are lower-case phrases that a
    /// `reason=` field completes.
    ///
    /// Exhaustive, so a finding added later must say its English too.
    public var logSentence: String {
        switch self {
        case .resumeRangeIgnored:
            return "S3 did not answer with the byte range asked for, "
                + "so the download was not resumed"
        case .sourceChangedSinceInterruption:
            return "the file changed on the server since the interrupted download, "
                + "so nothing was added to the partial file"
        case .unexpectedStatus(let code):
            return "the server answered with status \(code)"
        case .directoryAlreadyExists:
            return "a file or folder with that name already exists"
        case .destinationAlreadyExists:
            return "the destination already exists"
        case .outOfStorage:
            return "the server is out of storage"
        case .uploadStreamUnavailable:
            return "the upload stream could not be created"
        case .pathExistsAndIsNotADirectory(let path):
            return "something is already at \(path) and it is not a folder"
        case .nonHTTPResponse:
            return "the server's answer was not an HTTP response"
        case .listingUnparsable:
            return "the folder listing the server sent could not be read"
        case .redirectUnreadable:
            return "the server redirected the request somewhere that could not be read, "
                + "so it was refused"
        case .redirectBodyNotResendable:
            return "the server redirected an upload, and its data cannot be sent a second time, "
                + "so the redirect was refused"
        case .redirectNotResignable:
            return "the server redirected the request, and the new target could not be signed, "
                + "so the redirect was refused"
        }
    }

    /// Whether this finding reads as the connection having failed — what
    /// `RemoteFSError.isConnectionFailure` answers for
    /// `RemoteFSError.finding`, and therefore what decides whether the
    /// transfer queue classifies a mid-transfer failure as resumable.
    ///
    /// The three redirect refusals are the ones that are: the request never
    /// reached a server that answered it. Everything else is a remote-side
    /// fact about the object or the request, which a retry would meet
    /// again.
    ///
    /// No `default:` — a finding added later has to decide.
    public var readsAsConnectionFailure: Bool {
        switch self {
        case .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable:
            return true
        case .resumeRangeIgnored, .sourceChangedSinceInterruption, .unexpectedStatus,
            .directoryAlreadyExists, .destinationAlreadyExists, .outOfStorage,
            .uploadStreamUnavailable, .pathExistsAndIsNotADirectory,
            .nonHTTPResponse, .listingUnparsable:
            return false
        }
    }
}
