import Foundation
import Testing

@testable import macSCPCore

/// What one line diff costs in time.
///
/// **This suite measures; it does not assert a figure.** Every number it
/// produces reaches the log through `report(_:)`, and nothing compares one to
/// a threshold, because a figure asserted on one machine is a test that fails
/// on another (CLAUDE.md, "A wall-clock ceiling in a test measures the
/// runner"). The only expectations are positive controls — that the diff
/// really ran and really found the differences the fixture planted — so a
/// case that silently did no work cannot be reported as a cheap one.
///
/// **GATED behind `MACSCP_DIFF_COST=1` and skipped by default.** The largest
/// case it runs allocates a table of about 2.4 GB; a suite that did that on
/// every `swift test` would be a denial of service against whoever ran it.
/// `.serialized` because two cases of this size beside each other measure the
/// machine's paging rather than the diff.
///
/// Run it, in the form this comment commits it:
///
/// ```
/// MACSCP_DIFF_COST=1 swift test -c release --filter FileDiffCostTests
/// ```
///
/// Release matters: the LCS fill is a tight double loop over a nested
/// `[[Int]]`, and a debug build measures the bounds checks. `-c release` is
/// what `swift test` accepts here; note that `swift build --build-tests -c
/// release` does NOT build this package at all, and has not for reasons that
/// predate this file — it fails in `AdHocAuditTests.swift:3` and
/// `AgentAuthTests.swift:18` with "unable to resolve Swift module dependency
/// to a compatible module", naming `macSCPCore` and `NIOSSH`. Measured
/// 2026-10-13; `swift test -c release` on the same tree builds and runs.
///
/// **This suite reports TIME; peak MEMORY belongs to
/// `scripts/measure-diff-cost`, which runs the same grid one process per
/// case.** The division is not a preference, it is a limit: `phys_footprint`
/// counts pages the process holds mapped and dirty, and the allocator does
/// not hand a freed 2 GB table back between cases, so a per-case delta
/// measured inside one long-lived test process is a floor and not a peak. An
/// earlier draft of this suite sampled the footprint anyway and the figures
/// said so — in its release run of 2026-10-13, `ladder/5792` reported a delta
/// of 409,600 bytes while allocating a 268,470,792-byte table, because the
/// grid case before it had left the allocator holding about 440 MB; the
/// script's figure for that same case is 284,606,704 bytes. The sampler is
/// gone rather than annotated: a column nobody may quote is a column that
/// will be quoted.
///
/// The TIME figures agree between the two within about 10%
/// (`ladder/16384`, one line differing: 2.297442875 s here against
/// 2.468680542 s in the script — 7.5% apart), which is what makes the
/// division safe.
///
/// The figures both produced on 2026-10-13 are in `DiffEligibility`'s own doc
/// comments, beside the constants they settled, and in the design spec's
/// "Too large" bullet.
@Suite(
    "The line diff's cost", .serialized, .timeLimit(.minutes(10)),
    .enabled(
        if: ProcessInfo.processInfo.environment["MACSCP_DIFF_COST"] == "1",
        "allocates gigabytes; run alone with MACSCP_DIFF_COST=1"))
struct FileDiffCostTests {

    // MARK: - The budget, and why a case is abandoned rather than attempted

    /// The largest LCS table this suite will allocate, in bytes.
    ///
    /// A case whose table exceeds it is **not run**: its arithmetic is
    /// reported, the case is recorded as abandoned, and the ladder reads as
    /// one series with a stated cut in it rather than as a list that stops
    /// for no given reason. That is deliberate — the measurement exists to
    /// choose a bound, not to find the machine's breaking point, so the
    /// ladder stops a rung above the largest figure anybody would accept
    /// rather than at the rung that kills the process.
    ///
    /// 2.5 GB admits a 16,384-line square pair (2,147,745,800 bytes of
    /// table) and refuses a 32,768-line one (8,590,458,888). Both figures
    /// are `tableBytes(_:_:)` below, and both are reported by the run.
    static let tableBudgetBytes = 2_500_000_000

    /// What `FileDiff.editScript` allocates for a pair of line counts:
    /// `(L + 1)` rows of `(R + 1)` `Int`s, eight bytes each.
    ///
    /// Arithmetic, not a measurement, and it is reported for every case so
    /// that the budget decision below can be read rather than trusted. It is
    /// not the peak either: `scripts/measure-diff-cost` measured the peak at
    /// between 1.03 and 2.13 times this figure on 2026-10-13, the high end on
    /// a tall, thin table whose per-row heap allocations outweigh its
    /// entries.
    static func tableBytes(_ left: Int, _ right: Int) -> Int {
        (left + 1) * (right + 1) * 8
    }

    // MARK: - 1. The grid the byte ceiling admits

    /// Size against line shape, at the three sizes and three shapes the plan
    /// named, with both difference densities.
    ///
    /// Every cell is a pair `DiffEligibility.refusal(forBytes:)` admits on
    /// size alone, because every side is at or under `ceilingBytes`. Two of
    /// the nine are affordable. The nine-cell shape is the point: the two
    /// that run are both the longest-line shape, and the densest cell —
    /// 4 MiB of one-byte lines on each side — is the 35 TB table the spec's
    /// own arithmetic names.
    @Test func theByteCeilingAdmitsPairsWhoseTableTheMachineCannotHold() {
        let sizes: [(label: String, bytes: Int)] = [
            ("256KiB", 256 * 1024),
            ("1MiB", 1024 * 1024),
            ("4MiB", 4 * 1024 * 1024),
        ]
        // One content byte and a newline is the densest a line can be, which
        // is why the last shape is 1 and not 2: it is the shape that turns
        // the byte ceiling into its largest possible line count.
        let shapes = [80, 8, 1]

        for size in sizes {
            for lineBytes in shapes {
                let lines = size.bytes / (lineBytes + 1)
                for density in DifferenceDensity.allCases {
                    runOrAbandon(
                        name: "grid/\(size.label)/\(lineBytes)B/\(density.label)",
                        leftLines: lines, rightLines: lines,
                        lineBytes: lineBytes, density: density)
                }
            }
        }
    }

    // MARK: - 2. Bytes are not the axis

    /// The same line count at five byte sizes, then three asymmetric pairs.
    ///
    /// The first five cells hold the LINE count fixed and vary the byte size
    /// by forty — a line costs its content plus a newline, so 1 and 80 content
    /// bytes make sides of 8,192 and 331,776. The three after them are long
    /// thin tables, which a per-side line bound would refuse and whose cost is
    /// nothing like a square pair's at the same per-side count.
    @Test func theCostFollowsTheLineCountsAndNotTheByteSize() {
        for lineBytes in [1, 2, 8, 40, 80] {
            runOrAbandon(
                name: "fixedLines/4096/\(lineBytes)B",
                leftLines: 4096, rightLines: 4096,
                lineBytes: lineBytes, density: .everyTenth)
        }

        runOrAbandon(
            name: "asymmetric/100000x20", leftLines: 100_000, rightLines: 20,
            lineBytes: 40, density: .oneLine)
        runOrAbandon(
            name: "asymmetric/500000x20", leftLines: 500_000, rightLines: 20,
            lineBytes: 40, density: .oneLine)
        runOrAbandon(
            name: "asymmetric/2097152x20", leftLines: 2_097_152, rightLines: 20,
            lineBytes: 2, density: .oneLine)
    }

    // MARK: - 3. The ladder the bound is read off

    /// Square pairs at rising line counts, at both densities so the bound is
    /// not read off one of them.
    ///
    /// 5792 is here because `DiffEligibility.maxLineProduct` admits exactly
    /// that square and no larger one, and 8192 / 10000 / 11585 because they
    /// are what it refuses — the report names them as the cost of the choice.
    @Test func theLadderOfSquarePairs() {
        for lines in [1024, 2048, 4096, 5792, 8192, 10_000, 11_585, 16_384] {
            for density in DifferenceDensity.allCases {
                runOrAbandon(
                    name: "ladder/\(lines)/\(density.label)",
                    leftLines: lines, rightLines: lines,
                    lineBytes: 40, density: density)
            }
        }
    }

    // MARK: - 4. The pathological shape, started well below the ceiling

    /// One-byte lines, from a sixty-fourth of `ceilingBytes` upwards.
    ///
    /// This is the shape that exposed the hole, so it starts at 8 KiB per
    /// side — 1/512 of what the byte ceiling admits — and the ladder records
    /// which rung it had to be abandoned at rather than being pushed to the
    /// rung that kills the process.
    @Test func thePathologicalShapeWellBelowTheByteCeiling() {
        for kibPerSide in [8, 16, 32, 64] {
            let lines = kibPerSide * 1024 / 2
            for density in DifferenceDensity.allCases {
                runOrAbandon(
                    name: "pathological/\(kibPerSide)KiB/\(density.label)",
                    leftLines: lines, rightLines: lines,
                    lineBytes: 1, density: density)
            }
        }
    }

    // MARK: - 5. The two corners of the chosen bound

    /// Both corners of what `maxLineProduct` and `ceilingBytes` admit
    /// together, and they are exact integers rather than nearby round ones.
    ///
    /// - the largest square pair: 5792 × 5792, product 33,547,264, where
    ///   5793 × 5793 = 33,558,849 is over the bound;
    /// - the most asymmetric pair: 2,097,152 × 16 at product 33,554,432,
    ///   exactly the bound, where 2,097,152 is the largest line count
    ///   `ceilingBytes` can hold.
    ///
    /// The four expectations are the only assertions in this suite that are
    /// not positive controls, and none of them is a figure: each is a fact
    /// about `maxLineProduct` and `ceilingBytes` that holds on any machine.
    /// The two timings are reported and nothing is asserted about them —
    /// `scripts/measure-diff-cost` is what the constant's doc comment quotes
    /// for the memory at these corners.
    @Test func theCornersOfTheChosenBound() {
        #expect(5792 * 5792 <= DiffEligibility.maxLineProduct)
        #expect(5793 * 5793 > DiffEligibility.maxLineProduct)
        #expect(2_097_152 * 16 <= DiffEligibility.maxLineProduct)
        #expect(DiffEligibility.ceilingBytes / 2 == 2_097_152)

        for density in DifferenceDensity.allCases {
            runOrAbandon(
                name: "corner/square/5792x5792/\(density.label)",
                leftLines: 5792, rightLines: 5792,
                lineBytes: 40, density: density)
        }
        runOrAbandon(
            name: "corner/thin/2097152x16/1line", leftLines: 2_097_152,
            rightLines: 16, lineBytes: 1, density: .oneLine)
    }

    // MARK: - Fixtures

    enum DifferenceDensity: CaseIterable {
        /// Exactly one line differs, in the middle.
        case oneLine
        /// Every tenth line differs.
        case everyTenth

        var label: String {
            switch self {
            case .oneLine: "1line"
            case .everyTenth: "every10th"
            }
        }
    }

    /// A line of `bytes` ASCII characters, distinct from its neighbours as
    /// far as `bytes` allows.
    ///
    /// At one byte it cannot stay distinct — base 36 gives 36 single-character
    /// stems — and that repetition belongs to the pathological shape rather
    /// than being a flaw in the fixture: a file of one-character lines really
    /// does repeat itself.
    private static func line(at index: Int, bytes: Int) -> String {
        let stem = String(index, radix: 36)
        if stem.count >= bytes { return String(stem.suffix(bytes)) }
        return stem + String(repeating: "x", count: bytes - stem.count)
    }

    /// The left side, and the right side with `density`'s lines altered.
    private static func pair(
        leftLines: Int, rightLines: Int, lineBytes: Int,
        density: DifferenceDensity
    ) -> (left: [String], right: [String], plantedChanges: Int) {
        let left = (0..<leftLines).map { line(at: $0, bytes: lineBytes) }
        var right = (0..<rightLines).map { line(at: $0, bytes: lineBytes) }

        var planted = 0
        switch density {
        case .oneLine:
            if rightLines > 0 {
                right[rightLines / 2] = "~" + right[rightLines / 2]
                planted = 1
            }
        case .everyTenth:
            for index in stride(from: 0, to: rightLines, by: 10) {
                right[index] = "~" + right[index]
                planted += 1
            }
        }
        return (left, right, planted)
    }

    // MARK: - Running one case

    private func runOrAbandon(
        name: String, leftLines: Int, rightLines: Int, lineBytes: Int,
        density: DifferenceDensity
    ) {
        let table = Self.tableBytes(leftLines, rightLines)
        let leftBytes = leftLines * (lineBytes + 1)
        let rightBytes = rightLines * (lineBytes + 1)
        let shape =
            "\(name) L=\(leftLines) R=\(rightLines) lineBytes=\(lineBytes) "
            + "leftBytes=\(leftBytes) rightBytes=\(rightBytes) "
            + "product=\(leftLines * rightLines) "
            + "tableEntries=\((leftLines + 1) * (rightLines + 1)) tableBytes=\(table)"

        guard table <= Self.tableBudgetBytes else {
            report("ABANDONED \(shape) over the \(Self.tableBudgetBytes)-byte budget, not run")
            return
        }

        let fixture = Self.pair(
            leftLines: leftLines, rightLines: rightLines, lineBytes: lineBytes,
            density: density)

        // Everything expensive about the FIXTURE happened above. The clock
        // encloses the diff and nothing else.
        let started = ContinuousClock.now
        let hunks = FileDiff.hunks(left: fixture.left, right: fixture.right, context: 3)
        let elapsed = ContinuousClock.now - started

        let changedLines = hunks.reduce(0) { total, hunk in
            total + hunk.lines.filter { $0.kind != .context }.count
        }

        report(
            "MEASURED \(shape) elapsed=\(elapsed) "
                + "hunks=\(hunks.count) changedLines=\(changedLines)")

        // Positive controls, so a case that did no work cannot be reported as
        // a fast one. Counts the fixture planted, not figures the run
        // produced: a slow machine cannot defeat either.
        #expect(!hunks.isEmpty)
        #expect(changedLines >= fixture.plantedChanges)
    }

    /// One figure, one line, in both places a reader looks.
    ///
    /// `print` puts it in the build log, which is how a CI run is read;
    /// the warning-severity issue puts it in the test report, which is how a
    /// local run is read. A warning does not fail the test — an
    /// unconditional `Issue.record` would, and a measurement that reds its
    /// own suite every time it runs is an artifact nobody keeps.
    private func report(_ text: String) {
        print("diffcost: " + text)
        Issue.record(Comment(rawValue: text), severity: .warning)
    }
}
