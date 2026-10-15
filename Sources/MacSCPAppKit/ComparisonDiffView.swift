import Observation
import SwiftUI
import macSCPCore

/// What the content diff SAYS and SHOWS (diff view, Task 11): the lines of a
/// hunk as they are drawn, a hunk's header, what each refusal reads as, what
/// a fetch that did not happen reads as, and what to show while nothing has
/// arrived.
///
/// Pure functions of a value, so every word and every shape is decidable
/// without drawing anything (`ComparisonDiffViewTests`). The division of
/// labour is `ComparisonOverviewPresentation`'s: **the view draws what these
/// functions return and gains no judgement of its own**, so the residual
/// source scan pins only that the view iterates each function's output.
///
/// The one rule is the subsystem's: **nothing here tells the user something
/// nothing measured.**
///
/// - A refusal ("no line comparison was made") is not an empty diff ("no line
///   differs"). They are different `Screen` values with different styles and
///   different words, and only a diff that WAS computed and came back empty
///   says the files have the same contents.
/// - A failure (a fetch that did not happen) is neither of those. The four
///   refusals and the failures each read as a different thing, and every
///   failure says that nothing was compared.
/// - A line that changed never reads as one that did not, and a changed line
///   whose two sides would look identical says what differs (`runs(of:kind:)`).
///
/// **Exhaustive on purpose.** Every `switch` over `DiffRefusal`,
/// `ComparisonFetchError`, `ComparisonState` and `DiffLine.Kind` below names
/// every case and has no `default:`. A case added in Core stops this file
/// compiling until somebody has decided what it is called.
enum ComparisonDiffPresentation {
    typealias Wording = ComparisonOverviewPresentation.Wording
    typealias Run = FileActionPlanDisplay.Run

    // MARK: - What the lower half is about

    /// What the lower half shows a diff of: the selected row of a folder
    /// comparison, or the one pair of a file-pair comparison.
    enum Target: Hashable, Sendable {
        /// A row, by its POSITION in `Comparison.rows`, which is a row's
        /// identity here.
        ///
        /// **It used to be the path, and a path is not an identity.** Two
        /// genuinely distinct files — U+00E4 and `a` + U+0308 — are two
        /// correctly classified rows, because `ComparisonPairing.pairs` keys
        /// pass 1 on the UTF-8 bytes and refuses a pass-2 key two items
        /// share; `String` equality is Unicode canonical equivalence, so
        /// selecting the `.differs` row showed the `.same` row's diff and
        /// reported "no line differs" about a file that differs. Measured
        /// 2026-10-15.
        ///
        /// A position is stable here, which is what makes it usable: the
        /// walk only ever APPENDS to `Comparison.rows`, and the one other
        /// writer, `settleUndetermined(rowAt:)`, replaces a row in place with
        /// the same two paths. Nothing reorders and nothing removes.
        case row(index: Int)
        case filePair
    }

    /// The target of a comparison of this kind with this selection, or `nil`
    /// when there is nothing to diff yet. A file pair has no rows, so a
    /// selection means nothing to it.
    static func target(kind: Comparison.Kind, selection: Int?) -> Target? {
        switch kind {
        case .folders: selection.map { Target.row(index: $0) }
        case .filePair: .filePair
        }
    }

    /// The position a target names, or `nil` when the list does not hold it:
    /// asking for a diff by position without checking would diff whatever
    /// sits there now.
    ///
    /// **A bounds check and no search.** This used to take a path and return
    /// the first position whose row compared equal to it — a comparison of
    /// two `String`s, so it folded two canonically equivalent paths together
    /// and answered with the earlier row; see `Target.row(index:)`. There is
    /// nothing to search for any more: a row's identity IS its position, so
    /// there is no second spelling of it to match, and no first-versus-last
    /// to get wrong.
    ///
    /// The sentence above describes that old line in PROSE and does not quote
    /// it, deliberately. The first draft of this comment did quote it, and a
    /// mutation plant aimed at the old search found the quotation instead of
    /// any code: it edited this comment, the suite stayed green, and the
    /// verdict said the guard was insensitive when nothing had been planted.
    /// `CLAUDE.md`'s "Source-scanning guards read comments too" is about a
    /// guard reading a comment; this is the same collision with the PROBE on
    /// the other end, and the same answer — prose near a scanner.
    static func index(of position: Int, in rows: [ComparisonRow]) -> Int? {
        rows.indices.contains(position) ? position : nil
    }

    // MARK: - What arrived

    /// What asking for a diff came to: hunks (possibly none), a refusal with
    /// its reason, or a thrown error. `Result.failure` is a REFUSAL; a throw
    /// is a fetch that did not happen, and the two are never one case.
    enum Outcome: Sendable {
        case hunks([DiffHunk])
        case refused(DiffRefusal)
        case threw(any Error)
    }

    static func outcome(of result: Result<[DiffHunk], DiffRefusal>) -> Outcome {
        switch result {
        case .success(let hunks): .hunks(hunks)
        case .failure(let refusal): .refused(refusal)
        }
    }

    /// An outcome together with the target it was fetched for. Held by the
    /// model, and checked against the CURRENT target by `screen(target:loaded:)`
    /// before anything of it is shown.
    struct Loaded: Sendable {
        let target: Target
        let outcome: Outcome
    }

    // MARK: - Words

    // MARK: Refusals

    /// The wording of a refusal. Each of the four is its own key and its own
    /// sentence, and none of them says the files are the same.
    ///
    /// - `.binary` is about the FILE: it holds a NUL byte near its start.
    /// - `.notUTF8` is about the ENCODING: it has no NUL and is not valid
    ///   UTF-8, which a Latin-1 or Windows-1252 text file is. It must not call
    ///   the file binary, and it does not claim to know the encoding.
    /// - `.tooLarge` carries the size and the ceiling, and the sentence shows
    ///   both.
    /// - `.tooManyLines` carries both line counts and the sentence shows both;
    ///   the product the case also carries is this implementation's cost and
    ///   nothing a user can act on, so it is never printed.
    /// - `.notAnOrdinaryFile` is about one side and names it by PATH, which
    ///   is how the sentence says which side without any catalogue having to
    ///   inflect a word for "left". It does not name the KIND it saw: over
    ///   SFTP a link is reported as its target, so a sentence that said
    ///   "this is a folder" would sometimes be telling the user something
    ///   false about their own file — the mistake `.binary` and `.notUTF8`
    ///   exist to avoid.
    static func wording(for refusal: DiffRefusal) -> Wording {
        switch refusal {
        case .binary:
            Wording(
                key: "compare.refusal.binary",
                english:
                    "No line comparison was made: at least one of the two files contains binary data, so it cannot be shown as lines of text."
            )
        case .notUTF8:
            Wording(
                key: "compare.refusal.notUTF8",
                english:
                    "No line comparison was made: at least one of the two files is not valid UTF-8, so it cannot be read as lines. It may be text in another encoding, such as Latin-1 or Windows-1252."
            )
        case .tooLarge:
            Wording(
                key: "compare.refusal.tooLarge %@ %@",
                english:
                    "No line comparison was made: one of the two files is %@ bytes, and the largest file that can be compared line by line is %@ bytes."
            )
        case .tooManyLines:
            Wording(
                key: "compare.refusal.tooManyLines %@ %@",
                english:
                    "No line comparison was made: the left file has %@ lines and the right file has %@ lines, which is too many to compare together."
            )
        case .notAnOrdinaryFile:
            Wording(
                key: "compare.refusal.notAnOrdinaryFile %@",
                english:
                    "No line comparison was made: “%@” is not an ordinary file, so there is no content to compare. It is a folder or a link."
            )
        }
    }

    /// The sentence for a refusal, with its numbers in the locale they are
    /// shown in. Takes the refusal whole, so a call site cannot ask for a
    /// sentence of one kind with the numbers of another.
    static func refusalText(_ refusal: DiffRefusal, locale: Locale = .current) -> String {
        let text = wording(for: refusal).text
        switch refusal {
        case .binary, .notUTF8:
            return text
        case .tooLarge(let bytes, let ceiling):
            return String(
                format: text, locale: locale, grouped(bytes, locale: locale),
                grouped(ceiling, locale: locale))
        case .tooManyLines(let leftLines, let rightLines, _):
            return String(
                format: text, locale: locale, grouped(leftLines, locale: locale),
                grouped(rightLines, locale: locale))
        case .notAnOrdinaryFile(_, let path):
            // The path, not the side's name and not the kind: a path is data
            // and travels through every catalogue unchanged.
            return String(format: text, locale: locale, path)
        }
    }

    /// A count with the locale's grouping, exactly: a size one byte over its
    /// ceiling must not print as the same figure (a rounded "4 MB" twice).
    private static func grouped(_ number: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    // MARK: Failures

    /// Why a row has no contents to compare, by the state the row is in.
    /// Reached when a diff is asked of a row that is not a pair of files; the
    /// row's own label already says what it is, and this says what that means
    /// for a diff.
    ///
    /// The states that cannot reach it are answered with the general
    /// sentence anyway, so that none is blank.
    ///
    /// **An undetermined row reaches it for two reasons only.**
    /// `Comparison.diff(forRowAt:)` refuses a row unless its state says both
    /// sides are files, and for an undetermined one that is
    /// `UndeterminedReason.canBeSettledByBytes`. So `.linkOnASide` and
    /// `.unreadable` arrive here, and the sentence written for them
    /// ("macSCP could not tell that both sides are ordinary files") is true
    /// of exactly those two. The reasons bytes CAN settle are the four that
    /// describe two ordinary files whose checksums could not be had, which
    /// that sentence would be false of, and `.kindNotReported`, an entry a
    /// fetch will settle; they never arrive, and take the general sentence
    /// so that, if one ever did, nothing false is said.
    /// (This paragraph used to read "So `.unsupportedKind` and `.unreadable`
    /// arrive here" and "The four reasons bytes CAN settle".)
    /// `ComparisonDiffViewTests` holds this split to `canBeSettledByBytes`.
    static func wording(forNoContentIn state: ComparisonState) -> Wording {
        switch state {
        case .onlyLeft:
            Wording(
                key: "compare.diff.failure.onlyLeft",
                english: "This entry exists only on the left, so there is nothing to compare it with.")
        case .onlyRight:
            Wording(
                key: "compare.diff.failure.onlyRight",
                english: "This entry exists only on the right, so there is nothing to compare it with.")
        case .typeMismatch:
            Wording(
                key: "compare.diff.failure.typeMismatch",
                english: "The two sides are different kinds of entry, so their contents cannot be compared.")
        case .undetermined(let reason):
            switch reason {
            case .linkOnASide, .unreadable:
                Wording(
                    key: "compare.diff.failure.notKnownFiles",
                    english:
                        "macSCP could not tell that both sides are ordinary files, so their contents were not compared."
                )
            case .checksumUnavailable, .algorithmUnavailable, .algorithmsDiffer,
                .etagIsNotAFileHash, .kindNotReported:
                notPossible
            }
        // `.same` and `.differs` cannot reach a refusal (both are pairs of
        // files). `.bothDirectories` cannot reach a row at all, and, as in
        // the overview, is given no wording of its own: the day the walk
        // emitted it, a folder pair nobody looked inside would otherwise be
        // described in words written for this view.
        case .same, .differs, .bothDirectories:
            notPossible
        }
    }

    static let sessionClosed = Wording(
        key: "compare.diff.failure.sessionClosed",
        english:
            "The session was closed, so these files can no longer be fetched. Nothing was compared.")
    static let notPossible = Wording(
        key: "compare.diff.failure.notPossible",
        english: "These entries cannot be compared by their contents.")
    static let rowMoved = Wording(
        key: "compare.diff.failure.rowMoved",
        english: "This row is no longer in the list as it was, so nothing was compared.")
    static let stopped = Wording(
        key: "compare.diff.failure.stopped",
        english: "Fetching the files was stopped, so nothing was compared.")
    static let failed = Wording(
        key: "compare.diff.failure.failed %@",
        english: "The files could not be compared. %@")

    /// What a fetch that did not happen says. Exhaustive over
    /// `ComparisonFetchError`; a cancellation is its own sentence and any
    /// other error goes through `ComparisonOverviewPresentation.failureCause`,
    /// so a credential is filtered and a foreign error is its sentence.
    /// **Every one says that nothing was compared**, which is the one thing a
    /// failure and a refusal must not leave open.
    @MainActor
    static func failureText(for error: any Error) -> String {
        if let fetch = error as? ComparisonFetchError {
            switch fetch {
            case .sessionClosed: return sessionClosed.text
            case .wrongKind: return notPossible.text
            case .rowOutOfRange: return rowMoved.text
            case .noContentToCompare(let state): return wording(forNoContentIn: state).text
            }
        }
        if error is CancellationError { return stopped.text }
        return String(
            format: failed.text, ComparisonOverviewPresentation.failureCause(for: error))
    }

    // MARK: Everything else the diff says

    static let pickRow = Wording(
        key: "compare.diff.pickRow",
        english: "Select a file in the list to compare its contents line by line.")
    static let pending = Wording(
        key: "compare.diff.pending",
        english: "Fetching both files and comparing them line by line…")
    /// Said only of a diff that was computed and came back with no hunk. A
    /// refusal never reaches it.
    static let identical = Wording(
        key: "compare.diff.identical",
        english: "The two files have the same contents: no line differs.")
    static let legend = Wording(
        key: "compare.diff.legend",
        english:
            "A line marked “-” is only in the left file, a line marked “+” only in the right file. Lines without a mark are the same in both."
    )
    static let lineRemoved = Wording(
        key: "compare.diff.line.removed", english: "Only in the left file")
    static let lineAdded = Wording(
        key: "compare.diff.line.added", english: "Only in the right file")
    static let lineUnchanged = Wording(
        key: "compare.diff.line.unchanged", english: "The same in both files")

    /// The wordings above that are not a refusal and not a no-content reason.
    static let otherWordings: [Wording] = [
        sessionClosed, notPossible, rowMoved, stopped, failed, pickRow, pending, identical,
        legend, lineRemoved, lineAdded, lineUnchanged,
    ]

    // MARK: - Screens

    /// What the lower half shows: one notice, or the hunks. A refusal, a
    /// failure and an empty diff are NOTICES of different styles; the view
    /// draws a notice where the hunks would be, never as a dialog.
    enum Screen: Hashable {
        case notice(Notice)
        case listing(Listing)
    }

    struct Notice: Hashable {
        enum Style: Hashable {
            /// Nothing is selected.
            case idle
            /// The files are being fetched and compared.
            case pending
            /// A diff was computed and holds no hunk.
            case identical
            /// The pair cannot be shown as a line diff, for a reason.
            case refusal
            /// The fetch did not happen.
            case failure
        }

        let style: Style
        let text: String

        /// Whether a progress indicator accompanies the text.
        var showsProgress: Bool { style == .pending }

        /// The colour of the text: a failure is the one style that is set
        /// apart.
        var emphasis: Color {
            switch style {
            case .failure: .orange
            case .idle, .pending, .identical, .refusal: .secondary
            }
        }
    }

    /// The screen for `target`, given what was last loaded. **A result is
    /// shown only for the target it was fetched for**: anything else is
    /// "fetching", never another row's lines.
    @MainActor
    static func screen(target: Target?, loaded: Loaded?) -> Screen {
        guard let target else {
            return .notice(Notice(style: .idle, text: pickRow.text))
        }
        guard let loaded, loaded.target == target else {
            return .notice(Notice(style: .pending, text: pending.text))
        }
        switch loaded.outcome {
        case .hunks(let hunks):
            if hunks.isEmpty {
                return .notice(Notice(style: .identical, text: identical.text))
            }
            return .listing(listing(for: hunks))
        case .refused(let refusal):
            return .notice(Notice(style: .refusal, text: refusalText(refusal)))
        case .threw(let error):
            return .notice(Notice(style: .failure, text: failureText(for: error)))
        }
    }

    // MARK: - The listing

    /// What a line is, for drawing it: a copy of the core kind, so the view
    /// holds no `DiffLine`.
    enum Tone: Hashable, Sendable {
        case context, removed, added

        /// The line's background: none for an unchanged line, a red one for a
        /// removal and a green one for an addition. The sign beside the line
        /// carries the same distinction without colour.
        var tint: Color {
            switch self {
            case .context: Color.clear
            case .removed: Color.red.opacity(0.16)
            case .added: Color.green.opacity(0.16)
            }
        }
    }

    /// One line as the view draws it: its numbers, its sign, its text as runs
    /// and its background. Everything the view draws for a line comes from
    /// this value; it holds no `DiffLine`.
    struct LineEntry: Hashable {
        let tone: Tone
        /// `-`, `+` or a space.
        let sign: String
        /// The sign in words, for a screen reader.
        let kindLabel: String
        /// One-based, on the side the line belongs to; empty on the other.
        let leftNumber: String
        let rightNumber: String
        let runs: [Run]
        let tint: Color
    }

    /// One thing the listing draws, with its place in it. The listing is ONE
    /// ordered sequence of these, so the order a view draws them in is the
    /// order they are in: there is no header-and-lines container whose parts
    /// a view could place the wrong way round, and no second collection to
    /// walk. (Source scans of the view bought one spelling of such a swap
    /// after another, six times in this plan; this is the structural answer.)
    struct Row: Hashable, Identifiable {
        /// The position in the listing, from 0 and without a gap.
        let id: Int
        let kind: Kind

        enum Kind: Hashable {
            /// What `-`, `+` and an unmarked line mean. Always the first row.
            case legend(String)
            /// A hunk's `@@ -a,b +c,d @@`, directly before that hunk's lines.
            case header(String)
            case line(LineEntry)
        }
    }

    struct Listing: Hashable {
        /// The width of the widest line number shown, in digits.
        let numberDigits: Int
        let rows: [Row]
    }

    /// The header of a hunk: `@@ -a,b +c,d @@`, both counts always spelled
    /// out. **A start is the line's one-based number only when the side has
    /// lines in the hunk**: a zero-count side names the line BEFORE, which is
    /// the zero-based start itself. `start + 1` unconditionally is off by one
    /// for every pure insertion and every pure deletion at context 0.
    static func header(for hunk: DiffHunk) -> String {
        let leftCount = hunk.leftCount
        let rightCount = hunk.rightCount
        let leftFirst = leftCount > 0 ? hunk.leftStart + 1 : hunk.leftStart
        let rightFirst = rightCount > 0 ? hunk.rightStart + 1 : hunk.rightStart
        return "@@ -\(leftFirst),\(leftCount) +\(rightFirst),\(rightCount) @@"
    }

    /// The hunks as the view draws them, in one pass and in order, none
    /// dropped: the legend, then for each hunk its header and its lines. The
    /// numbers are counted from each hunk's starts: a context line advances
    /// both sides, a removal the left one and an addition the right one.
    static func listing(for hunks: [DiffHunk]) -> Listing {
        var largest = 0
        var kinds: [Row.Kind] = [.legend(legend.text)]
        for hunk in hunks {
            var left = hunk.leftStart
            var right = hunk.rightStart
            kinds.append(.header(header(for: hunk)))
            for line in hunk.lines {
                var leftNumber = ""
                var rightNumber = ""
                switch line.kind {
                case .context:
                    left += 1
                    right += 1
                    leftNumber = String(left)
                    rightNumber = String(right)
                case .removed:
                    left += 1
                    leftNumber = String(left)
                case .added:
                    right += 1
                    rightNumber = String(right)
                }
                largest = max(largest, left, right)
                let tone = tone(of: line.kind)
                kinds.append(
                    .line(
                        LineEntry(
                            tone: tone, sign: sign(of: line.kind),
                            kindLabel: kindLabel(of: line.kind), leftNumber: leftNumber,
                            rightNumber: rightNumber, runs: runs(of: line.text, kind: line.kind),
                            tint: tone.tint)))
            }
        }
        let rows = kinds.enumerated().map { Row(id: $0.offset, kind: $0.element) }
        return Listing(numberDigits: String(largest).count, rows: rows)
    }

    private static func tone(of kind: DiffLine.Kind) -> Tone {
        switch kind {
        case .context: .context
        case .removed: .removed
        case .added: .added
        }
    }

    private static func sign(of kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .removed: "-"
        case .added: "+"
        }
    }

    private static func kindLabel(of kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: lineUnchanged.text
        case .removed: lineRemoved.text
        case .added: lineAdded.text
        }
    }

    // MARK: - What a line looks like

    /// A line's text as runs, with every scalar that would not be drawn
    /// faithfully drawn as its `<U+XXXX>` marker, the way the file-actions
    /// sheet draws one (`FileActionPlanDisplay`, which is where the marker's
    /// spelling and the base decision live).
    ///
    /// **Why this is more than the sheet's rule.** A byte order mark is kept
    /// by the fetch on purpose, because stripping it would show an EMPTY diff
    /// for two files that differ by exactly those three bytes. The price is a
    /// changed line whose two sides look identical, and a BOM is only one of
    /// the scalars that does that. So, on top of the sheet's rule (control and
    /// format characters, line and paragraph separators — a NUL after byte
    /// 8000 is eligible and reaches here, and may end a `Text` where it
    /// stands):
    ///
    /// - every space separator except U+0020 is marked, in every line: a
    ///   no-break or ideographic space is not a space;
    /// - in a CHANGED line, every tab and every trailing space is marked, so a
    ///   tab against spaces, or a trailing space, does not read as no change.
    ///   An unchanged line is the same on both sides by definition, and
    ///   marking each tab of a tab-indented file would teach the reader to
    ///   ignore markers.
    ///
    /// **Not marked, as in the sheet:** the zero-width joiner and the
    /// variation selectors, which emoji are built from; and two lines that
    /// differ only in Unicode normalisation form, which are drawn as the text
    /// they are. The diff compares bytes, so such a pair is shown as a change
    /// whose two sides can look alike. Both are pinned by tests
    /// (`theScalarsAnEmojiIsBuiltFromPassThroughAsTheFileActionsSheetDoes`,
    /// `twoLinesDifferingOnlyInNormalisationFormAreAChangeWhoseSidesLookAlike`).
    static func runs(of text: String, kind: DiffLine.Kind) -> [Run] {
        let changed = kind != .context
        let scalars = Array(text.unicodeScalars)
        var trailingFrom = scalars.count
        while trailingFrom > 0, scalars[trailingFrom - 1] == " " || scalars[trailingFrom - 1] == "\t" {
            trailingFrom -= 1
        }
        return FileActionPlanDisplay.runs(of: text) { scalar, offset in
            isMarked(scalar, changed: changed, trailing: offset >= trailingFrom)
        }
    }

    private static func isMarked(_ scalar: Unicode.Scalar, changed: Bool, trailing: Bool) -> Bool {
        if scalar == "\t" { return changed }
        if scalar == " " { return changed && trailing }
        if FileActionPlanDisplay.needsMarker(scalar) { return true }
        return scalar.properties.generalCategory == .spaceSeparator
    }
}

// MARK: - Fetching

/// Carries the selected target to the comparison's diff entry points and
/// back. Holds the last result and the target it is for, and nothing else:
/// no comparison, so it keeps nothing alive, and the views hold no logic of
/// their own.
@MainActor
@Observable
final class ComparisonDiffModel {
    private(set) var loaded: ComparisonDiffPresentation.Loaded?

    /// Fetches and diffs `target`, and never throws: what comes back, a
    /// refusal and a failure included, is the result.
    ///
    /// **What keeps a late answer off the screen is the cancel guard below,
    /// together with the view's `.task(id: target)`, which cancels the
    /// previous load when the target changes.** A load that was cancelled
    /// writes nothing: the selection has moved on. The `await` is a
    /// suspension point, and another load can complete across it, so this is
    /// the guard that matters; do not move it believing the write of `nil`
    /// protects what follows. That write drops the previous result at the
    /// start, so a result of the old target is not held while the new one is
    /// on its way, and `screen(target:loaded:)` checks the target again
    /// before showing anything. Each load stamps its result with ITS OWN
    /// target (`ComparisonDiffViewTests.twoLoadsThatOverlapEachWriteTheirOwnTarget`).
    func load(_ target: ComparisonDiffPresentation.Target?, on comparison: Comparison) async {
        loaded = nil
        guard let target else { return }
        let outcome = await outcome(for: target, on: comparison)
        guard !Task.isCancelled else { return }
        loaded = ComparisonDiffPresentation.Loaded(target: target, outcome: outcome)
    }

    /// The row is found by position, and a position the list does not hold
    /// is not diffed as whatever sits at some other one.
    private func outcome(
        for target: ComparisonDiffPresentation.Target, on comparison: Comparison
    ) async -> ComparisonDiffPresentation.Outcome {
        do {
            switch target {
            case .filePair:
                return ComparisonDiffPresentation.outcome(of: try await comparison.diffFilePair())
            case .row(let position):
                guard let index = ComparisonDiffPresentation.index(of: position, in: comparison.rows)
                else { throw ComparisonFetchError.rowOutOfRange(position) }
                return ComparisonDiffPresentation.outcome(
                    of: try await comparison.diff(forRowAt: index))
            }
        } catch {
            return .threw(error)
        }
    }
}

// MARK: - The views

/// The whole body of the comparison window: for two folders the overview
/// above and the diff of the selected row below, for a file pair the diff
/// alone. Holds the selection, which is a row's position — its identity;
/// see `ComparisonDiffPresentation.Target.row(index:)`.
struct ComparisonResultView: View {
    let comparison: Comparison
    @State private var selection: Int?

    var body: some View {
        let diff = ComparisonDiffView(
            comparison: comparison,
            target: ComparisonDiffPresentation.target(kind: comparison.kind, selection: selection))
        if ComparisonOverviewPresentation.showsOverview(for: comparison.kind) {
            VSplitView {
                ComparisonOverviewView(comparison: comparison, selection: $selection)
                    .frame(minHeight: 140)
                diff
                    .frame(minHeight: 140)
            }
        } else {
            diff
        }
    }
}

/// The lower half of the comparison window: the hunks of the target, or the
/// reason there are none, in the same place.
///
/// It draws `ComparisonDiffPresentation.screen(target:loaded:)` and nothing
/// it decides itself. The fetch starts when the target changes and is
/// cancelled when it changes again.
struct ComparisonDiffView: View {
    let comparison: Comparison
    let target: ComparisonDiffPresentation.Target?
    @State private var model = ComparisonDiffModel()

    var body: some View {
        content(ComparisonDiffPresentation.screen(target: target, loaded: model.loaded))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: target) { await model.load(target, on: comparison) }
    }

    @ViewBuilder
    private func content(_ screen: ComparisonDiffPresentation.Screen) -> some View {
        switch screen {
        case .notice(let notice):
            ComparisonDiffNoticeView(notice: notice)
        case .listing(let listing):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.rows) { row in
                        switch row.kind {
                        case .legend(let text):
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        case .header(let text):
                            ComparisonDiffHeaderView(text: text)
                        case .line(let entry):
                            ComparisonDiffLineView(entry: entry, digits: listing.numberDigits)
                        }
                    }
                }
            }
        }
    }
}

/// A hunk's header. It holds the text and nothing else: where it stands is
/// the listing's order. The space before it is what separates one hunk from
/// the one above.
struct ComparisonDiffHeaderView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.top, 8)
    }
}

/// One line, drawn from the value the presentation made. It holds no
/// `DiffLine` and calls no presentation function: there is nothing here to
/// rebind to a different kind.
struct ComparisonDiffLineView: View {
    let entry: ComparisonDiffPresentation.LineEntry
    let digits: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(entry.leftNumber)
                .frame(width: CGFloat(digits) * 9 + 8, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(entry.rightNumber)
                .frame(width: CGFloat(digits) * 9 + 8, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(entry.sign)
                .frame(width: 20)
                .accessibilityLabel(entry.kindLabel)
            Text(FileActionPlanDisplay.attributed(entry.runs))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
        .background(entry.tint)
        .accessibilityElement(children: .combine)
    }
}

/// A refusal, a failure, an empty diff, "fetching" or "select a file": one
/// text, in the place the hunks would be.
struct ComparisonDiffNoticeView: View {
    let notice: ComparisonDiffPresentation.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if notice.showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(notice.text)
                .foregroundStyle(notice.emphasis)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
