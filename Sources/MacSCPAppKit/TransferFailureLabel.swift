import Foundation
import macSCPCore

/// A transfer failure's cause in the app's language.
///
/// The App-layer reader of `TransferFailureKind`, the typed cause a failed
/// queue item has carried since 2026-09-25. It closes the `docs/BACKLOG.md`
/// row "Transfer failure reasons are English inside a localized frame",
/// whose finding was stated precisely: the frame (`core.transfer.failed
/// %@`) is translated and the `reason` formatted into it is not.
///
/// ## What this maps, and what it deliberately does not
///
/// Counted 2026-09-25 over `Sources/macSCPCore/Resources/*.lproj`: Core's
/// catalogue already carries every sentence `TransferFailureKind.message`
/// looks up in all four languages — `en`, `de`, `fr`, `pl` — for eleven of
/// the fourteen kinds. Those eleven are read here, not copied: `label(_:)`
/// returns `cause.message` for them, so the transfer row and the audit
/// line (`AuditRecorder`, which renders the same cause) cannot say two
/// different things, and no sentence exists twice in four languages.
///
/// The three that remain are exactly the row's finding —
/// `connectionFailed(detail:)`, `protocolError(detail:)` and
/// `unknown(detail:)`, the only kinds whose payload is free text a backend
/// or Foundation wrote. For those the App says the sentence itself, from
/// its own catalogue, and keeps the detail behind it.
///
/// ## Why the detail is kept (maintainer-facing decision, 2026-09-25)
///
/// Dropping it for a fixed translated sentence was the alternative. It was
/// rejected on what a reader can DO with the text:
///
/// - `protocolError`'s detail is the server's own answer — an S3 error code
///   such as `AccessDenied` or `NoSuchBucket`, a WebDAV status. It names
///   the thing the user or their administrator has to change.
/// - `connectionFailed`'s detail is what separates a timeout from a refusal
///   from an unknown host, and those have three different fixes.
/// - `unknown`'s detail is, by construction, the only information there is;
///   without it the row says "The transfer failed." and a bug report cannot
///   be written.
///
/// So the detail stays, as a suffix that is MARKED as technical
/// (`transfers.failure.detail %1$@ %2$@`, translated in all four
/// languages), behind prose that is translated and comes first. A reader
/// who does not read English still learns what failed; the row's
/// `lineLimit(1)` truncates the tail, so the translated half is the half
/// that survives, and the hover hint carries the whole line.
///
/// ## What is safe to interpolate
///
/// A `detail` arrives already filtered: `TransferQueueViewModel
/// .failureKind(for:)` runs every one through `URLText.withoutUserinfo` at
/// CONSTRUCTION, so a `scheme://KEY:SECRET@host` endpoint composed into a
/// backend's `reason` cannot reach the value, let alone this rendering
/// (`TransferFailureKindTests.noCausesDataCarriesACredential`). The other
/// payloads a kind carries — the two paths and the bucket-level operation
/// — are never interpolated HERE at all: their sentences are Core's, and
/// Core shows a path because it is the queue's own path, which the row
/// names beside the message anyway.
enum TransferFailureLabel {
    /// Where one kind's sentence comes from.
    enum Sentence: Equatable {
        /// Core's catalogue, in all four languages, read through
        /// `TransferFailureKind.message`.
        case core
        /// The App's own catalogue, under `transfers.failure.<name>`, with
        /// the English source text that seeds `en.lproj` and that
        /// `L10n.string` falls back to when the bundle cannot be found.
        case app(key: String, english: String)
    }

    /// The catalogue key of the frame that marks a technical detail. One
    /// spelling, so "what a detail looks like" is decided in one place per
    /// language rather than three times.
    static let detailFrameKey = "transfers.failure.detail %1$@ %2$@"
    static let detailFrameEnglish = "%1$@ (technical detail: %2$@)"

    /// Which catalogue answers for a kind.
    ///
    /// Exhaustive over `TransferFailureKind.Name`, so a kind added in Core
    /// does not compile here until someone has decided whether it says its
    /// own sentence or reads Core's;
    /// `TransferFailureLabelGuardTests.everyKindIsClassifiedAndTranslated`
    /// then holds the answer to the four catalogues.
    static func sentence(for name: TransferFailureKind.Name) -> Sentence {
        switch name {
        case .connectionFailed:
            return .app(
                key: "transfers.failure.connectionFailed",
                english: "The connection to the server failed.")
        case .protocolError:
            return .app(
                key: "transfers.failure.protocolError",
                english: "The server sent an answer that could not be used.")
        case .unknown:
            return .app(key: "transfers.failure.unknown", english: "The transfer failed.")
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName:
            return .core
        }
    }

    /// The free text a cause carries, or `nil` for the eleven that carry
    /// none. The three listed here are the three `sentence(for:)` answers
    /// `.app` for, and `everyAppOwnedKindCarriesADetail` holds the two
    /// lists to each other.
    static func technicalDetail(of cause: TransferFailureKind) -> String? {
        switch cause {
        case .connectionFailed(let detail), .protocolError(let detail), .unknown(let detail):
            return detail.isEmpty ? nil : detail
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName:
            return nil
        }
    }

    /// One cause, as one line, in the app's language.
    static func label(_ cause: TransferFailureKind) -> String {
        switch sentence(for: cause.name) {
        case .core:
            return cause.message
        case .app(let key, let english):
            let prose = L10n.string(key, english)
            guard let detail = technicalDetail(of: cause) else { return prose }
            return String(
                format: L10n.string(detailFrameKey, detailFrameEnglish), prose, detail)
        }
    }

    /// The same sentence for a surface that still holds the raw error — the
    /// path bar's failed listing and the editor's open-failed banner, both
    /// of which format it into a localized frame of their own and would
    /// otherwise put an English `reason` inside it.
    @MainActor static func text(for error: any Error) -> String {
        label(TransferQueueViewModel.failureKind(for: error))
    }
}
