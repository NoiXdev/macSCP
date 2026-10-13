public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffHunk: Equatable, Sendable {
    /// Zero-based index into the left lines of the first left line this hunk
    /// covers. For a hunk that opens with an addition there is no such line
    /// yet, and this is the index of the left line the addition lands in
    /// front of (the left line count, for an append at the end).
    public let leftStart: Int
    /// The same, for the right lines: for a hunk that opens with a removal,
    /// the index of the right line that now sits where the removed one was.
    public let rightStart: Int
    public let lines: [DiffLine]

    public init(leftStart: Int, rightStart: Int, lines: [DiffLine]) {
        self.leftStart = leftStart
        self.rightStart = rightStart
        self.lines = lines
    }

    /// How many left lines the hunk covers: its context and its removals.
    public var leftCount: Int { lines.filter { $0.kind != .added }.count }
    /// How many right lines the hunk covers: its context and its additions.
    public var rightCount: Int { lines.filter { $0.kind != .removed }.count }
}

public enum FileDiff {
    /// A line diff over two already-local files, as line arrays.
    ///
    /// Lines are compared as exact strings: a line that keeps a trailing
    /// carriage return differs from the same line without one. How a file is
    /// cut into lines is the caller's decision.
    ///
    /// Within a block of changes the removals come before the additions.
    /// A `context` below zero is treated as zero.
    ///
    /// Pure: no file system, no connection, no UI. Everything expensive
    /// about comparing two files happened before this was called, which is
    /// why the size ceiling lives in `DiffEligibility` and not here.
    public static func hunks(
        left: [String], right: [String], context: Int
    ) -> [DiffHunk] {
        let script = editScript(left: left, right: right)
        return group(script, context: context)
    }

    /// One entry per output line, carrying the index it came from on each
    /// side so `group` can compute a hunk's start without a second pass.
    ///
    /// For a context line both indices are that line's own. For a removed
    /// line `leftIndex` is its own and `rightIndex` is the right line that
    /// follows the removal; for an added line the roles swap.
    private struct Step {
        let line: DiffLine
        let leftIndex: Int
        let rightIndex: Int
    }

    private static func editScript(left: [String], right: [String]) -> [Step] {
        // Classic LCS length table, held FLAT: one `[Int]` of
        // `(left.count + 1) * width` entries, where the cell for `(i, j)` is
        // at `i * width + j`. Rows are left, columns are right, and the cell
        // is the length of the longest common subsequence of `left[i...]` and
        // `right[j...]`, filled from the ends backwards so the walk below can
        // start at the front.
        //
        // **Flat rather than `[[Int]]`, and the reason is measured.** An
        // array of row arrays pays a COW uniqueness check on every element
        // write, and each row is its own heap allocation rounded up to a
        // malloc bucket — so the table cost more than its entries, and by a
        // factor that depended on the pair's SHAPE rather than on its size.
        // Measured 2026-10-13 by `scripts/measure-diff-cost` on an Apple
        // M1 Max, release, the same grid run against each version: 37 cases
        // ran against both. Across the **33** square and pathological ones
        // the peak footprint fell from between 1.0301 and 1.5103 times the
        // bare eight-bytes-per-entry arithmetic to between **1.0005 and
        // 1.0058**; the **four** long thin ones fell from 1.9142-2.1282 to
        // 1.6257-1.9489 and no further, because what is left over there is
        // the edit script rather than the table. The whole diff got faster
        // on 36 of the 37 cases, by 7.8% to 39.9% (the exception,
        // `grid/256KiB/80B` with one line differing, came back 3.3% slower,
        // inside the day's own 10.1% run-to-run spread).
        // `DiffEligibility.maxLineProduct` is the bound this makes honest:
        // the product now predicts the table to within six thousandths
        // instead of to within half.
        //
        // The product `(left.count + 1) * width` is what
        // `DiffEligibility.refusal(leftLines:rightLines:)` exists to bound,
        // with the two counts bounded in turn by `ceilingBytes`. The one
        // caller, `Comparison.diff(leftPath:rightPath:)`, makes both checks
        // where the files are split; this comment said "**nothing calls that
        // check yet**: Task 8 of the diff-view plan wires it where the files
        // are split" until Task 8 did. This function is pure and enforces
        // neither bound; a caller that skips both asks the allocator for the
        // answer, exactly as the nested version did.
        let width = right.count + 1
        var table = [Int](repeating: 0, count: (left.count + 1) * width)
        if !left.isEmpty && !right.isEmpty {
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                let row = i * width
                let rowBelow = row + width
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    table[row + j] = left[i] == right[j]
                        ? table[rowBelow + j + 1] + 1
                        : max(table[rowBelow + j], table[row + j + 1])
                }
            }
        }

        var steps: [Step] = []
        var i = 0, j = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] {
                steps.append(Step(
                    line: DiffLine(kind: .context, text: left[i]),
                    leftIndex: i, rightIndex: j))
                i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                steps.append(Step(
                    line: DiffLine(kind: .removed, text: left[i]),
                    leftIndex: i, rightIndex: j))
                i += 1
            } else {
                steps.append(Step(
                    line: DiffLine(kind: .added, text: right[j]),
                    leftIndex: i, rightIndex: j))
                j += 1
            }
        }
        while i < left.count {
            steps.append(Step(
                line: DiffLine(kind: .removed, text: left[i]),
                leftIndex: i, rightIndex: j))
            i += 1
        }
        while j < right.count {
            steps.append(Step(
                line: DiffLine(kind: .added, text: right[j]),
                leftIndex: i, rightIndex: j))
            j += 1
        }
        return steps
    }

    /// Groups the script into hunks. A run of more than `2 * context`
    /// unchanged lines separates two hunks; a shorter run stays inside one,
    /// because splitting there would show the same lines twice.
    private static func group(_ steps: [Step], context: Int) -> [DiffHunk] {
        let changed = steps.indices.filter { steps[$0].line.kind != .context }
        guard !changed.isEmpty else { return [] }

        // Clamped on both sides: a negative context would make a range
        // shorter than its own change, and one near `Int.max` would
        // overflow the addition below. Beyond the script's length it
        // reaches nothing more.
        let context = min(max(context, 0), steps.count)

        var ranges: [(start: Int, end: Int)] = []
        for index in changed {
            let start = max(0, index - context)
            let end = min(steps.count - 1, index + context)
            if var last = ranges.last, last.end >= start - 1 {
                last.end = max(last.end, end)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append((start, end))
            }
        }

        return ranges.map { range in
            let slice = Array(steps[range.start...range.end])
            return DiffHunk(
                leftStart: slice[0].leftIndex,
                rightStart: slice[0].rightIndex,
                lines: slice.map(\.line))
        }
    }
}
