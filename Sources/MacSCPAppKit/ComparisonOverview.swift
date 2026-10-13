import SwiftUI
import macSCPCore

/// What the folder overview SAYS (diff view, Task 10): the name of each
/// state, the reason an undetermined row is undetermined, how many rows sit
/// in each state, and what a comparison that failed says failed.
///
/// Pure functions of a value, so the words are decidable without drawing
/// anything (`ComparisonOverviewTests`). This is the surface where every
/// distinction the Core types make becomes a sentence, and the one rule is
/// the subsystem's: **a label never claims more than was measured.**
///
/// - `same` is worded as "the contents are the same". It is the only state
///   that says so, and an `undetermined` row never reaches that wording: the
///   state has its own key, and its reason a second key of its own.
/// - `undetermined` is "not determined", never "not different". Its reason
///   says what was NOT done ("Not compared: …") or, for `unreadable`, the one
///   thing that is not about comparing at all — macSCP could not read the
///   path.
/// - `bothDirectories` has no wording. See `wording(for:)`.
///
/// **Exhaustive on purpose.** Every `switch` over `ComparisonState` and over
/// `UndeterminedReason` below names every case and has no `default:`. A case
/// added in Core stops this file compiling until somebody has decided what it
/// is called, which is the only acceptable way to find out.
enum ComparisonOverviewPresentation {

    /// A catalogue key together with the English source text it is seeded
    /// from. One value, so the key and its fallback cannot drift apart, and
    /// `ComparisonOverviewTests` holds the English half to `en.lproj`.
    struct Wording: Equatable, Sendable {
        let key: String
        let english: String

        /// The text in the active language. The fallback is the English
        /// source text, never the key: a missing catalogue entry must read as
        /// a sentence, not as an identifier.
        var text: String { L10n.string(key, english) }
    }

    // MARK: - States

    /// The wording of a row's state, or `nil` for the one state that never
    /// reaches a row.
    ///
    /// **`.bothDirectories` is deliberately not given a key.**
    /// `FolderComparison.walk` descends into a directory pair and emits its
    /// children instead of a row for it, so that state cannot arrive here. A
    /// `default:` arm would hand it a label anyway, and the day the walk
    /// started to emit it, a folder nobody looked inside would appear under
    /// somebody else's wording. It is named, and answered with `nil`.
    static func wording(for state: ComparisonState) -> Wording? {
        switch state {
        case .onlyLeft: Wording(key: "compare.state.onlyLeft", english: "Only on the left")
        case .onlyRight: Wording(key: "compare.state.onlyRight", english: "Only on the right")
        case .same: Wording(key: "compare.state.same", english: "Same contents")
        case .differs: Wording(key: "compare.state.differs", english: "Different")
        case .typeMismatch:
            Wording(key: "compare.state.typeMismatch", english: "Different types")
        // The reason is a second line of its own (`text(for:)`): the state
        // says only that nothing could be settled.
        case .undetermined:
            Wording(key: "compare.state.undetermined", english: "Not determined")
        case .bothDirectories: nil
        }
    }

    /// The catalogue key a state is spelled by, or `nil` for `.bothDirectories`.
    static func key(for state: ComparisonState) -> String? {
        wording(for: state)?.key
    }

    /// What is shown for a state that cannot arrive. Marked as internal so a
    /// reader who ever sees it knows the walk changed under the view, and
    /// worded as nothing the user could take for a result. Not a catalogue
    /// entry on purpose.
    static let unexpectedLabel = "[internal: folder pair — not expected in this list]"

    static func label(for state: ComparisonState) -> String {
        wording(for: state)?.text ?? unexpectedLabel
    }

    // MARK: - Reasons

    static func wording(for reason: UndeterminedReason) -> Wording {
        switch reason {
        case .checksumUnavailable:
            Wording(
                key: "compare.reason.checksumUnavailable",
                english: "Not compared: at least one side could not provide a checksum for this file.")
        case .algorithmUnavailable:
            Wording(
                key: "compare.reason.algorithmUnavailable %@",
                english:
                    "Not compared: a side could not compute a %@ checksum. A different checksum algorithm can be chosen in Settings."
            )
        case .algorithmsDiffer:
            Wording(
                key: "compare.reason.algorithmsDiffer",
                english:
                    "Not compared: the two sides answered with different checksum algorithms, which say nothing about each other."
            )
        case .etagIsNotAFileHash:
            Wording(
                key: "compare.reason.etagIsNotAFileHash",
                english:
                    "Not compared: one side offered only the ETag of a multipart upload, which is not a checksum of the file's contents."
            )
        case .unsupportedKind:
            Wording(
                key: "compare.reason.unsupportedKind",
                english:
                    "Not compared: this is a link or a special entry, and macSCP does not compare those."
            )
        // The one reason that is not about comparing. It says what could not
        // be read; "nothing here was compared" is its consequence, and for a
        // folder it means nothing INSIDE it was compared either.
        case .unreadable:
            Wording(
                key: "compare.reason.unreadable",
                english: "macSCP could not read this path, so nothing here was compared.")
        }
    }

    static func key(for reason: UndeterminedReason) -> String {
        wording(for: reason).key
    }

    /// The sentence for a reason, with the algorithm's name filled in where
    /// the reason carries one.
    static func text(for reason: UndeterminedReason) -> String {
        let text = wording(for: reason).text
        switch reason {
        case .algorithmUnavailable(let algorithm):
            return String(format: text, algorithm.displayName)
        case .checksumUnavailable, .algorithmsDiffer, .etagIsNotAFileHash, .unsupportedKind,
            .unreadable:
            return text
        }
    }

    // MARK: - Counts

    /// How many rows sit in each state.
    ///
    /// Every row lands in exactly one bucket and `total` is their sum, so a
    /// row that was dropped shows up as `total` falling short of the input.
    /// `unexpected` exists for the state that cannot arrive: counting it
    /// there is louder than ignoring it, and cannot inflate a real bucket.
    struct Counts: Equatable, Sendable {
        var onlyLeft = 0
        var onlyRight = 0
        var same = 0
        var differs = 0
        var typeMismatch = 0
        /// All six reasons together. A row that could not be settled is not a
        /// `same` row however it is counted.
        var undetermined = 0
        var unexpected = 0

        var total: Int {
            onlyLeft + onlyRight + same + differs + typeMismatch + undetermined + unexpected
        }

        /// The bucket a state is counted in.
        func count(for state: ComparisonState) -> Int {
            switch state {
            case .onlyLeft: onlyLeft
            case .onlyRight: onlyRight
            case .same: same
            case .differs: differs
            case .typeMismatch: typeMismatch
            case .undetermined: undetermined
            case .bothDirectories: unexpected
            }
        }
    }

    static func counts(of rows: [ComparisonRow]) -> Counts {
        var counts = Counts()
        for row in rows {
            switch row.state {
            case .onlyLeft: counts.onlyLeft += 1
            case .onlyRight: counts.onlyRight += 1
            case .same: counts.same += 1
            case .differs: counts.differs += 1
            case .typeMismatch: counts.typeMismatch += 1
            case .undetermined: counts.undetermined += 1
            case .bothDirectories: counts.unexpected += 1
            }
        }
        return counts
    }

    // MARK: - Everything else the overview says

    static let compareAnyway = Wording(
        key: "compare.action.compareAnyway", english: "Compare contents anyway")
    static let progress = Wording(
        key: "compare.progress %lld", english: "Entries found so far: %lld")
    static let cancel = Wording(key: "compare.cancel", english: "Stop")
    static let empty = Wording(
        key: "compare.overview.empty", english: "The comparison found no files and no differences.")
    static let failureNotFound = Wording(
        key: "compare.failure.notFound %@", english: "Folder not found: %@")
    static let failureReported = Wording(
        key: "compare.failure.reported %@", english: "Reported cause: %@")
    static let failureNoDetail = Wording(
        key: "compare.failure.noDetail", english: "No cause was reported.")
    static let failureInterrupted = Wording(
        key: "compare.failure.interrupted",
        english: "The comparison was interrupted although nobody stopped it.")

    /// The wordings above that are not a state and not a reason.
    static let otherWordings: [Wording] = [
        compareAnyway, progress, cancel, empty, failureNotFound, failureReported,
        failureNoDetail, failureInterrupted,
    ]

    static var otherKeys: [String] { otherWordings.map(\.key) }

    /// The count of entries found so far, shown while the walk runs. The
    /// number is the rows produced — entries the walk has reported, whatever
    /// state they ended in — and claims nothing about how many remain.
    static func progressText(_ progress: ComparisonProgress) -> String {
        String(format: Self.progress.text, progress.rowsProduced)
    }

    // MARK: - A failed comparison says what failed

    /// What a comparison that ended in `.failed` says failed.
    ///
    /// Mapped through `TransferQueueViewModel.failureKind(for:)`, the
    /// project's one classifier of a raw error: it filters a credential out of
    /// an endpoint before the text exists, and it turns a foreign error into
    /// its localized sentence instead of Foundation's "couldn't be completed"
    /// description. Nothing here prints an error with `localizedDescription` or
    /// `String(describing:)` itself.
    ///
    /// **A cancellation is its own sentence.** `Comparison` writes
    /// `.cancelled` from `cancel()` alone, so a `CancellationError` that
    /// arrives as a FAILURE is one a backend threw that nobody asked for; the
    /// classifier would show it as an unknown error with a type name in it.
    @MainActor
    static func failureCause(for error: any Error) -> String {
        if error is CancellationError { return failureInterrupted.text }
        return failureCause(of: TransferQueueViewModel.failureKind(for: error))
    }

    /// The sentence for a classified failure. Exhaustive over
    /// `TransferFailureKind`; the groups are decided one by one, not by a
    /// `default:`.
    static func failureCause(of kind: TransferFailureKind) -> String {
        switch kind {
        // The failure that reaches here is a listing of a chosen root, so a
        // missing path is a folder; Core's sentence for the same kind says
        // "File not found".
        case .notFound(let path):
            return String(format: failureNotFound.text, path)
        // Core's own sentences, each complete without a frame and none of
        // them about a transfer.
        case .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .connectionFailed, .connectionLost:
            return kind.message
        // Text a backend or the system wrote. Core frames it as "Transfer
        // failed: …", which would be a false statement about a comparison, so
        // it appears under this view's own frame — or, with nothing to show,
        // as the plain statement that no cause came with it.
        case .protocolError(let detail), .unknown(let detail):
            return reported(detail)
        case .finding(let finding):
            return finding.readsAsConnectionFailure
                ? kind.message : reported(finding.message)
        // None of these comes out of listing a folder or classifying a pair.
        // They are answered anyway, with Core's sentence under the reported
        // frame, so that none is a blank and none claims to be this view's.
        case .interrupted, .noFreeName, .bucketLevelRefused, .crossBucketRenameRefused:
            return reported(kind.message)
        }
    }

    private static func reported(_ detail: String) -> String {
        detail.isEmpty
            ? failureNoDetail.text : String(format: failureReported.text, detail)
    }
}

// MARK: - The view

/// The upper half of the comparison window: a count per state, then one row
/// per relative path with its state.
///
/// It holds the `Comparison` and nothing it borrows (the wiring guard for the
/// window reads that rule). Reading `rows`, `progress` and `state` in `body`
/// is what makes it follow a walk that is still running.
///
/// The counts are the answer to "how different are these two folders" without
/// reading the list, so they are a count of what the walk has PRODUCED: while
/// it runs they are partial, and the line above them says so.
struct ComparisonOverviewView: View {
    let comparison: Comparison

    var body: some View {
        let rows = comparison.rows
        let counts = ComparisonOverviewPresentation.counts(of: rows)
        VStack(alignment: .leading, spacing: 0) {
            summary(counts)
            Divider()
            if rows.isEmpty {
                placeholder
            } else {
                List {
                    ForEach(rows, id: \.relativePath) { row in
                        ComparisonOverviewRow(row: row)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func summary(_ counts: ComparisonOverviewPresentation.Counts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if comparison.isRunning {
                HStack(spacing: 8) {
                    Text(ComparisonOverviewPresentation.progressText(comparison.progress))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(ComparisonOverviewPresentation.cancel.text) { comparison.cancel() }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                countFigure(.onlyLeft, counts)
                countFigure(.onlyRight, counts)
                countFigure(.differs, counts)
                countFigure(.typeMismatch, counts)
                countFigure(.undetermined(.unreadable), counts)
                countFigure(.same, counts)
                if counts.unexpected > 0 {
                    countFigure(.bothDirectories, counts)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One figure: the number and the state's own label under it. The
    /// `undetermined` argument is a representative: the bucket and the label
    /// are the state's, not the reason's.
    private func countFigure(
        _ state: ComparisonState, _ counts: ComparisonOverviewPresentation.Counts
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(counts.count(for: state))")
                .font(.title3.monospacedDigit())
            Text(ComparisonOverviewPresentation.label(for: state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A walk still running has found nothing yet; a walk that finished and
    /// produced no row found no files. Neither is worded as a result about
    /// the folders' contents when the walk did not complete.
    @ViewBuilder
    private var placeholder: some View {
        if case .completed? = comparison.outcome {
            Text(ComparisonOverviewPresentation.empty.text)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Spacer(minLength: 0)
    }
}

private struct ComparisonOverviewRow: View {
    let row: ComparisonRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.relativePath)
                    .lineLimit(1).truncationMode(.middle)
                if case .undetermined(let reason) = row.state {
                    Text(ComparisonOverviewPresentation.text(for: reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(ComparisonOverviewPresentation.label(for: row.state))
                .foregroundStyle(row.state == .same ? .secondary : .primary)
        }
        .textSelection(.enabled)
    }
}
