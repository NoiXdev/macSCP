import Observation
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

    /// The wording of an undetermined row's reason.
    ///
    /// **Known, and left as it is:** `algorithmUnavailable`'s advice to choose
    /// a different algorithm in Settings is unhelpful in one combination that
    /// exists. With SHA-256 chosen, S3 on one side and an SSH host without
    /// `md5sum` on the other, the pair is first `algorithmsDiffer`, and the
    /// retry with MD5 can then end in `algorithmUnavailable(.md5)` — where no
    /// choice in Settings changes the answer.
    ///
    /// `unsupportedKind` is worded for what the listing could tell, not for
    /// what the entry is: `.other` is also what a listing answers when a type
    /// was not reported at all, so an ordinary file can land here.
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
                    "Not compared: at least one side offered only the ETag of a multipart upload, which is not a checksum of the file's contents."
            )
        case .unsupportedKind:
            Wording(
                key: "compare.reason.unsupportedKind",
                english:
                    "Not compared: macSCP could not tell that this is an ordinary file. It is a link or a special entry, or its type was not reported."
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

    static let settlePending = Wording(
        key: "compare.settle.pending",
        english: "Fetching both files to compare their contents…")
    static let settleSessionClosed = Wording(
        key: "compare.settle.sessionClosed",
        english: "The session was closed, so these files can no longer be fetched. Nothing was compared.")
    static let settleNotPossible = Wording(
        key: "compare.settle.notPossible",
        english: "These entries cannot be compared by their contents.")
    static let settleRowMoved = Wording(
        key: "compare.settle.rowMoved",
        english: "This row is no longer in the list as it was, so nothing was compared.")
    static let settleStopped = Wording(
        key: "compare.settle.stopped",
        english: "Fetching the files was stopped, so nothing was compared.")
    static let settleFailed = Wording(
        key: "compare.settle.failed %@",
        english: "The contents could not be compared. %@")

    /// The wordings above that are not a state and not a reason.
    static let otherWordings: [Wording] = [
        compareAnyway, progress, cancel, empty, failureNotFound, failureReported,
        failureNoDetail, failureInterrupted, settlePending, settleSessionClosed,
        settleNotPossible, settleRowMoved, settleStopped, settleFailed,
    ]

    static var otherKeys: [String] { otherWordings.map(\.key) }

    /// The count of entries found so far, shown while the walk runs.
    ///
    /// The number is the ROWS HELD, the same ones the counts above it are
    /// made from — never `ComparisonProgress.rowsProduced`. The walk reports
    /// progress once per directory, after its whole pair loop, while rows
    /// arrive one by one, so a line fed from progress reads 0 above counts
    /// that already total hundreds. It claims nothing about how many remain.
    static func progressText(entriesFound: Int) -> String {
        String(format: Self.progress.text, entriesFound)
    }

    // MARK: - What is drawn at all

    /// Whether the window draws the overview for a comparison of this kind.
    /// A file pair has no walk and no rows (`Comparison.start()` finishes it
    /// at once with none), so an overview of it would report zero of
    /// everything and, on a completed outcome, "no files and no differences"
    /// about two files somebody chose. Its diff is Task 11's.
    static func showsOverview(for kind: Comparison.Kind) -> Bool {
        switch kind {
        case .folders: true
        case .filePair: false
        }
    }

    /// Whether the "found no files and no differences" sentence may be shown.
    /// Only for a walk that ENDED NORMALLY with no row: while it runs, after
    /// a stop, or after a failure the list is empty because it is
    /// incomplete, and that sentence would then be a false result.
    static func showsEmptyNotice(rowCount: Int, outcome: Comparison.Outcome?) -> Bool {
        guard rowCount == 0 else { return false }
        switch outcome {
        case .completed?: return true
        case .cancelled?, .failed?, nil: return false
        }
    }

    // MARK: - What the view maps over

    /// One figure above the list: a state, how many rows are in it, and its
    /// label. Everything the view draws for a figure comes from this value.
    struct Figure: Equatable, Sendable {
        /// A representative of the bucket: for `undetermined` the bucket and
        /// the label are the state's, not any one reason's.
        let state: ComparisonState
        let number: Int
        let label: String

        /// Stable across redraws: the catalogue key, or the marker for the
        /// state that has none.
        var id: String { ComparisonOverviewPresentation.key(for: state) ?? "unexpected" }
    }

    /// The figures, in the order they are drawn. One per state a row can
    /// carry, `unexpected` only when something is in it. **The view draws
    /// exactly this list and nothing else**, so "the figures account for every
    /// row" is a property of THIS function (`figures.map(\.number)` sums to
    /// `counts.total`), stated once and tested once, and not a property of a
    /// sequence of calls written out in a view.
    static func summaryFigures(_ counts: Counts) -> [Figure] {
        var states: [ComparisonState] = [
            .onlyLeft, .onlyRight, .differs, .typeMismatch, .undetermined(.unreadable), .same,
        ]
        if counts.unexpected > 0 { states.append(.bothDirectories) }
        return states.map { state in
            Figure(state: state, number: counts.count(for: state), label: label(for: state))
        }
    }

    /// One row of the list as the view draws it: the path, the label of the
    /// row's OWN state, and — only for an undetermined row — why.
    struct RowEntry: Equatable, Sendable {
        let path: String
        let label: String
        let reason: String?
        /// Whether the row is a match, which the view sets in a quieter
        /// colour. A property of the row's state, not of its label.
        let isMatch: Bool
        /// The row's position in the comparison's rows: what
        /// `Comparison.settleUndetermined(rowAt:)` is given.
        let index: Int
        /// "Compare contents anyway", or `nil` for a row that does not offer
        /// it. See `rowEntries`.
        let settleButton: SettleButton?
        /// What the row says about a settling: that one is under way, or why
        /// the last one did not happen. `nil` when there is nothing to say.
        let settleNote: String?
    }

    struct SettleButton: Equatable, Sendable {
        let title: String
        /// `false` while that row's bytes are being fetched.
        let isEnabled: Bool
    }

    /// What is under way and what failed, per row path. A value, so the
    /// transitions are decidable without a view; the model below holds one.
    struct SettleTracker: Equatable, Sendable {
        private(set) var pending: Set<String> = []
        private(set) var failures: [String: String] = [:]

        func isPending(_ path: String) -> Bool { pending.contains(path) }

        mutating func begin(_ path: String) {
            pending.insert(path)
            failures[path] = nil
        }

        mutating func succeed(_ path: String) {
            pending.remove(path)
            failures[path] = nil
        }

        mutating func fail(_ path: String, text: String) {
            pending.remove(path)
            failures[path] = text
        }
    }

    /// Whether anything that needs the connection can still be done. A
    /// released comparison has no file systems and no queue, and an action
    /// that would only fail is not offered; the window already says why.
    @MainActor
    static func canFetch(_ comparison: Comparison) -> Bool {
        comparison.fileSystems != nil && comparison.transferQueue != nil
    }

    /// What a settling that did not happen says. Exhaustive over
    /// `ComparisonFetchError`; a cancellation is its own sentence and any
    /// other error goes through `failureCause(for:)`, so a credential is
    /// filtered and a foreign error is its sentence. **The row is as it was**
    /// in every one of these cases, and each text says nothing was compared.
    @MainActor
    static func settleFailureText(for error: any Error) -> String {
        if let fetch = error as? ComparisonFetchError {
            switch fetch {
            case .sessionClosed: return settleSessionClosed.text
            case .wrongKind, .noContentToCompare: return settleNotPossible.text
            case .rowOutOfRange: return settleRowMoved.text
            }
        }
        if error is CancellationError { return settleStopped.text }
        return String(format: settleFailed.text, failureCause(for: error))
    }

    /// The list, in the order the walk produced it, one entry per row. **The
    /// view draws exactly this list**: it holds no row to rebind and no
    /// collection to slice, so "every row shows its own state, none is
    /// hidden" is a property of THIS function and is tested here.
    ///
    /// **Which rows offer "compare anyway":** an undetermined row whose
    /// reason `canBeSettledByBytes` says bytes can settle — the line is that
    /// property's, not re-decided here — and only while `canFetch` holds. A
    /// row that cannot be settled shows its reason and no button.
    static func rowEntries(
        _ rows: [ComparisonRow], settle: SettleTracker, canFetch: Bool
    ) -> [RowEntry] {
        rows.enumerated().map { index, row in
            let reason: String?
            var button: SettleButton?
            var note: String?
            switch row.state {
            case .undetermined(let why):
                reason = text(for: why)
                let pending = settle.isPending(row.relativePath)
                if why.canBeSettledByBytes && canFetch {
                    button = SettleButton(title: compareAnyway.text, isEnabled: !pending)
                }
                note = pending ? settlePending.text : settle.failures[row.relativePath]
            case .onlyLeft, .onlyRight, .same, .differs, .typeMismatch, .bothDirectories:
                reason = nil
            }
            return RowEntry(
                path: row.relativePath, label: label(forRow: row), reason: reason,
                isMatch: row.state == .same, index: index, settleButton: button,
                settleNote: note)
        }
    }

    /// The label of one row: its OWN state's. One function taking the row,
    /// so the view has no state argument to get wrong and a source scan can
    /// pin the single call (`ComparisonOverviewTests`).
    static func label(forRow row: ComparisonRow) -> String {
        label(for: row.state)
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

// MARK: - Settling a row

/// Carries "compare anyway" from a row's button to
/// `Comparison.settleUndetermined(rowAt:)` and back: the pending state while
/// the bytes are fetched, and the failure when it did not happen. It holds
/// no comparison — the comparison is an argument of each call — so it keeps
/// nothing alive, and the views hold no logic of their own.
@MainActor
@Observable
final class ComparisonSettleModel {
    private(set) var tracker = ComparisonOverviewPresentation.SettleTracker()

    /// Settles the row `entry` stands for, and never throws: the row takes
    /// the state that comes back, or stays as it was with the reason beside
    /// it. The row is checked BEFORE anything is fetched, by index and by
    /// path, because settling another row's index would write an answer
    /// onto a file nobody asked about.
    func settle(_ entry: ComparisonOverviewPresentation.RowEntry, on comparison: Comparison) async {
        guard !tracker.isPending(entry.path) else { return }
        tracker.begin(entry.path)
        guard comparison.rows.indices.contains(entry.index),
            comparison.rows[entry.index].relativePath == entry.path
        else {
            tracker.fail(entry.path, text: ComparisonOverviewPresentation.settleRowMoved.text)
            return
        }
        do {
            _ = try await comparison.settleUndetermined(rowAt: entry.index)
            tracker.succeed(entry.path)
        } catch {
            tracker.fail(
                entry.path, text: ComparisonOverviewPresentation.settleFailureText(for: error))
        }
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
    @State private var settler = ComparisonSettleModel()

    var body: some View {
        let rows = comparison.rows
        let counts = ComparisonOverviewPresentation.counts(of: rows)
        let figures = ComparisonOverviewPresentation.summaryFigures(counts)
        let entries = ComparisonOverviewPresentation.rowEntries(
            rows, settle: settler.tracker,
            canFetch: ComparisonOverviewPresentation.canFetch(comparison))
        VStack(alignment: .leading, spacing: 0) {
            summary(figures)
            Divider()
            if entries.isEmpty {
                placeholder(rowCount: rows.count)
            } else {
                List {
                    ForEach(entries, id: \.path) { entry in
                        ComparisonOverviewRow(entry: entry) {
                            Task { await settler.settle(entry, on: comparison) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func summary(_ figures: [ComparisonOverviewPresentation.Figure]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if comparison.isRunning {
                HStack(spacing: 8) {
                    Text(ComparisonOverviewPresentation.progressText(entriesFound: comparison.rows.count))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(ComparisonOverviewPresentation.cancel.text) { comparison.cancel() }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(figures, id: \.id) { figure in
                    ComparisonOverviewFigure(figure: figure)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A walk still running has found nothing yet; a walk that finished and
    /// produced no row found no files. Neither is worded as a result about
    /// the folders' contents when the walk did not complete.
    @ViewBuilder
    private func placeholder(rowCount: Int) -> some View {
        if ComparisonOverviewPresentation.showsEmptyNotice(
            rowCount: rowCount, outcome: comparison.outcome)
        {
            Text(ComparisonOverviewPresentation.empty.text)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Spacer(minLength: 0)
    }
}

/// One figure, drawn from the value the presentation made.
private struct ComparisonOverviewFigure: View {
    let figure: ComparisonOverviewPresentation.Figure

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(figure.number))
                .font(.title3.monospacedDigit())
            Text(figure.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One row, drawn from the value the presentation made. It holds no
/// `ComparisonRow` and calls no label function: there is nothing here to
/// rebind to a different state.
private struct ComparisonOverviewRow: View {
    let entry: ComparisonOverviewPresentation.RowEntry
    let onSettle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = entry.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = entry.settleNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let button = entry.settleButton {
                Button(button.title) { onSettle() }
                    .disabled(!button.isEnabled)
            }
            Text(entry.label)
                .foregroundStyle(entry.isMatch ? .secondary : .primary)
        }
        .textSelection(.enabled)
    }
}
