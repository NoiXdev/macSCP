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
/// Counted 2026-09-25 over `Sources/macSCPCore/Resources/*.lproj`, and
/// recounted 2026-09-28 when `.finding` joined the enum: Core's catalogue
/// already carries every sentence `TransferFailureKind.message` looks up in
/// all four languages — `en`, `de`, `fr`, `pl` — for twelve of the fifteen
/// kinds. Those twelve are read here, not copied: `label(_:)` returns
/// `cause.message` for them, so the transfer row and the audit line
/// (`AuditRecorder`, which renders the same cause) cannot say two different
/// things, and no sentence exists twice in four languages.
///
/// The three that remain are exactly the row's finding —
/// `connectionFailed(detail:)`, `protocolError(detail:)` and
/// `unknown(detail:)`, the only kinds whose payload is a free-text
/// `reason` rather than a path or an enum. For those the App says the
/// sentence itself, from its own catalogue, and keeps the detail behind it.
///
/// ## What the detail actually is (corrected 2026-09-25, fix round 1)
///
/// The first version of this comment called it "free text a backend or
/// Foundation wrote". That was measured false. Counted over
/// `Sources/macSCPCore` on 2026-09-25: 68 construction sites of
/// `RemoteFSError.protocolError(reason:)` / `.connectionFailed(reason:)`.
/// Recounted 2026-09-28 (`docs/superpowers/specs/2026-09-28-typed-remote-fs-findings-design.md`,
/// at `bcbea4f4`): 69, not 68 — the two counts disagree by one and neither
/// is re-derivable from the other, so this comment no longer claims 68 was
/// right. **Recounted again 2026-09-28**, after Task 2 of the
/// typed-remote-fs-findings plan converted WebDAV's six sites to
/// `.finding(...)` (`4e20fc80`): **63**, exactly six fewer than 69. Recipe:
/// `grep -rn 'protocolError(reason:\|connectionFailed(reason:' Sources/macSCPCore`
/// (89 lines at this HEAD) minus 17 lines that belong to `AgentError` — an
/// unrelated SSH-agent error type whose `protocolError(reason:)` case
/// happens to share the name, counting both its call sites and its own
/// case declaration — minus `RemoteFSError`'s own 2 case declarations,
/// minus 7 lines that quote the pattern in a doc comment or `//` comment
/// rather than construct it (`DiagnosticLog.swift:266-267`,
/// `DialProbes.swift:164-165`, `ConnectionViewModel.swift:2333`,
/// `RemoteFSFinding.swift:6`, `CitadelFileSystem.swift:763`) — 89 − 17 − 2
/// − 7 = 63. **Recounted a third time 2026-09-28**, after Task 3 converted
/// S3's six sites (four in `S3FileSystem.swift`, one in `S3Uploader.swift`,
/// one in `S3ListParser.swift`) to `.finding(...)` too: the same recipe now
/// finds 83 raw lines, the same 17/2/7 subtract off it, 83 − 17 − 2 − 7 =
/// **57**, again exactly six fewer than 63.
///
/// **57 is what the recipe yields, not the number of construction sites
/// there are — it is a FLOOR** (Task 3 fix round 1, task review, 2026-09-28).
/// The recipe only matches a construction whose `reason:` argument sits on
/// the SAME line as `protocolError(`/`connectionFailed(`; a construction
/// split across two lines — `RemoteFSError.protocolError(\n    reason:
/// "…")`, which this project writes whenever the reason string is long — is
/// invisible to it. `grep -rnE '(protocolError|connectionFailed)\($'
/// Sources/macSCPCore` (the opening parenthesis alone at the end of the
/// line, no argument on it at all) finds 23 more lines; 2 belong to
/// `AgentError` (`AgentBackedPrivateKey.swift:351`, `SSHAgentClient.swift:196`),
/// leaving **21 more `RemoteFSError` construction sites the 57 above does
/// not include**: `S3MultipartXML.swift:20`, `S3FileSystem.swift:90`,
/// `:716`, `:898`, `:1118`, `S3ListParser.swift:90`, `S3Uploader.swift:276`,
/// `S3XMLText.swift:61`, `RemoteChecksumProvider.swift:329`,
/// `CitadelShell.swift:130`, `CitadelFileSystem.swift:397`, `:825`, `:837`,
/// `:1188`, `:1661`, `WebDAVPropfindParser.swift:83`,
/// `WebDAVFileSystem.swift:450`, `:587`, `:631`, `ThroughputProbe.swift:632`,
/// `:702`.
///
/// This gap is not new to this diff — it was already true of 68, of 69, and
/// of 63, all four numbers resting on the same single-line recipe, and of
/// `docs/BACKLOG.md`'s own "68" — this recount just inherited it rather than
/// closing it. So: **57 is a lower bound on how many `protocolError`/
/// `connectionFailed` construction sites `Sources/macSCPCore` has, not a
/// census of them**, and the same was true of every earlier number in this
/// paragraph.
///
/// **Corrected (Task 3 fix round 2, task review's independent census,
/// 2026-09-28):** this comment used to warn against simply adding 57 and
/// 21 "as if the two recipes' exclusions already lined up" — right in
/// spirit, wrong in arithmetic. For `Sources/macSCPCore`, they DO line up:
/// the second recipe's 23 lines are exactly 21 `RemoteFSError`
/// constructions plus the 2 `AgentError`'s already named above, with no
/// `RemoteFSError` case declaration and no comment-only mention among
/// them, so the two recipes' matches are disjoint and 57 + 21 = **78**
/// genuinely is `Sources/macSCPCore`'s construction-site count under both
/// recipes combined. The real blind spot was never the regex — it is the
/// search PATH: both recipes above are scoped to `Sources/macSCPCore`
/// only. Three more `RemoteFSError` construction sites of this same shape
/// live in `Sources/MacSCPAppKit/` — `ContentView+Lifecycle.swift:276`,
/// `ContentView.swift:1871`, `ContentView.swift:3434` — which neither
/// recipe's path ever reaches. **The whole-tree total is 81, not 78, and
/// not 57.**
///
/// What the single-line recipe's 57 lines DO show, unaffected by the count
/// being a floor: the great majority compose **macSCP's own English
/// prose**, not a server's words. The two sentences a user was most likely
/// to meet — `S3FileSystem.rangeIgnoredReason` and `sourceChangedReason` —
/// are no longer among the construction sites at all (neither single-line
/// nor multi-line): both constants stay in source as the English anchor for
/// their finding's catalogue entry (the user documentation still quotes
/// that English), but neither is read by the site that used to construct a
/// `protocolError(reason:)` from it. Genuinely foreign text is the minority
/// of what the recipe finds: a `localizedDescription` from Foundation or
/// NIO, an S3 error code parsed out of a response body.
///
/// So the honest statement is: the detail is a diagnostic string macSCP
/// mostly wrote in English, occasionally relayed from elsewhere, and in
/// neither case translated.
///
/// ## Why it is kept anyway (maintainer-facing decision, 2026-09-25)
///
/// Dropping it for a fixed translated sentence was the alternative, and the
/// decision to keep it survives the correction above — but on a narrower
/// argument than the one first written:
///
/// - It is strictly better than what it replaces. Before this type, the
///   WHOLE line was `core.transfer.failed %@` with the same English inside
///   it; now the finding is translated and only the diagnostic tail is not.
///   Nothing a reader could understand before was lost.
/// - It is the half a reader can act on. The resume refusals say which
///   resume was refused and that the partial file was left alone; an S3
///   error code names what the administrator has to change;
///   `connectionFailed`'s detail separates a timeout from a refusal from an
///   unknown host, three different fixes. `unknown`'s is by construction
///   the only information there is, and without it no bug report can be
///   written.
/// - It is the half that can be pasted. A support thread quotes it, and a
///   translated quotation is worth less there, not more.
///
/// The right END state is fewer details, not a different frame: each
/// macSCP-authored `reason` that a user really reads should become a typed
/// case with a catalogue key of its own, the way
/// `RemoteFSError.BucketLevelOperation.refusalMessageKey` already is. Two
/// were converted in fix round 1 (`S3FieldSchema.blankFieldRefusal`); the
/// rest is a `docs/BACKLOG.md` row, because each conversion is a new
/// `RemoteFSError` case with arms in three mappers.
///
/// So the detail stays for now, as a suffix that is MARKED as technical
/// (`transfers.failure.detail %1$@ %2$@`, translated in all four
/// languages), behind prose that is translated and comes first. The row's
/// `lineLimit(1)` truncates the tail, so the translated half is the half
/// that survives, and the hover hint carries the whole line.
///
/// ## What is safe to interpolate
///
/// A `detail` arrives already filtered: `TransferQueueViewModel
/// .failureKind(for:)` runs every one through `URLText.withoutUserinfo` at
/// CONSTRUCTION, so a `scheme://KEY:SECRET@host` endpoint composed into a
/// backend's `reason` cannot reach the value, let alone this rendering
/// (`TransferFailureKindTests.noCausesDataCarriesACredential`).
///
/// That filter removes userinfo; it does not shorten a dump. Five throws in
/// `LocalFileSystem` built their `reason` with `String(describing: error)`,
/// which on an `NSError` prints its domain, its code and the whole
/// `userInfo` — a local path and an `NSUnderlyingError` among it. Harmless
/// while the text was dropped again wherever it was shown, and no longer
/// harmless once this type began showing it; fixed in fix round 1 and held
/// by `LocalFileSystemErrorTextGuardTests`. The other
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
        // `.finding` is Core's (2026-09-28): a finding IS a catalogue key in
        // all four languages, which is the whole point of the type — so the
        // App has nothing of its own to say for it.
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName, .finding:
            return .core
        }
    }

    /// The free text a cause carries, or `nil` for the twelve that carry
    /// none. The three listed here are the three `sentence(for:)` answers
    /// `.app` for, and `everyAppOwnedKindCarriesADetail` holds the two
    /// lists to each other.
    static func technicalDetail(of cause: TransferFailureKind) -> String? {
        switch cause {
        case .connectionFailed(let detail), .protocolError(let detail), .unknown(let detail):
            return detail.isEmpty ? nil : detail
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName, .finding:
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
