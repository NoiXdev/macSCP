/// Why one side's content cannot be shown as a line diff.
///
/// This refuses the CONTENT diff only. The folder comparison does not consult
/// it: a binary, oversized or too-many-lines pair is still classified by size
/// and checksum, and telling the user that two binaries differ is exactly
/// what that is for. (This sentence read "a binary or oversized pair is still
/// classified by size and checksum" before 2026-10-13, when `.tooManyLines`
/// was added below. The rule did not change; the list did.)
///
/// **Not every case is about one side.** The first three are: each answers
/// for the bytes of one file, and `refusal(forBytes:)` returns them. The
/// fourth is about the PAIR, and `refusal(leftLines:rightLines:)` returns it,
/// because what it refuses is a cost neither side carries alone.
public enum DiffRefusal: Equatable, Sendable {
    /// The first `DiffEligibility.nulWindowBytes` bytes contain a NUL. This
    /// case carries that one cause and nothing else: content that is merely
    /// not valid UTF-8 is `.notUTF8`, because a Latin-1 or Windows-1252 text
    /// file is text and must not be described to the user as binary.
    case binary
    /// The content is not valid UTF-8 and has no NUL in the leading window:
    /// typically text in another encoding, but this case does not claim to
    /// know which. It says only that the bytes cannot be read as UTF-8 lines.
    case notUTF8
    /// The content is larger than `ceiling` bytes. See
    /// `DiffEligibility.ceilingBytes` for what that bound does and does not
    /// bound.
    case tooLarge(bytes: Int, ceiling: Int)
    /// The two sides' line counts multiply to more than `ceilingProduct`,
    /// which is what the line diff's working table costs. See
    /// `DiffEligibility.maxLineProduct`.
    ///
    /// It carries BOTH counts, because the pair is what was refused and
    /// neither side alone explains it: a 20-line file is refused against a
    /// 2,097,152-line one (product 41,943,040) and admitted against a
    /// 1,000,000-line one (20,000,000). A message that named one side would
    /// be telling the user something false about their own file, which is
    /// the same mistake `.binary` and `.notUTF8` exist to avoid.
    ///
    /// The user-facing text names the two line counts and must NOT name the
    /// product: the product is this implementation's cost and not something
    /// anybody can act on.
    case tooManyLines(leftLines: Int, rightLines: Int, ceilingProduct: Int)
}

public enum DiffEligibility {
    /// 4 MiB per side. **The number survives the measurement; its account
    /// of itself does not.**
    ///
    /// Measured 2026-10-13 on an Apple M1 Max (10 cores, 64 GiB, macOS
    /// 27.0.1 build 26A434, Swift 6.4), against a RELEASE build, by
    /// `scripts/measure-diff-cost` — run from the repository root, one
    /// process per case, which is what makes its peak-memory figures a peak
    /// rather than a floor. `FileDiffCostTests` runs the same grid inside
    /// `swift test -c release` and reports only time; both doc comments say
    /// why memory is the script's and not the suite's. The full table is in
    /// the design spec's "Too large" bullet.
    ///
    /// This doc comment opened, until that measurement existed, with:
    /// "**A STARTING VALUE, NOT A MEASUREMENT.** Nothing in this tree set a
    /// precedent for it, and a line diff's cost is dominated by the number
    /// of DIFFERENCES rather than by the file size, so this number is
    /// expected to move once the plan's own measurement exists. Until then,
    /// no comment, document or catalogue text here describes it as
    /// measured." Both halves are withdrawn, and the second is withdrawn as
    /// **false of this diff**.
    ///
    /// - **Not the differences.** Going from one differing line to every
    ///   tenth moved the elapsed time by at most 11% at any rung measured;
    ///   the largest was 10,000 lines per side, 0.864224583 s against
    ///   0.959617166 s, at peaks of 824,263,280 and 824,328,816 bytes. One
    ///   rung was faster with ten times the differences (16,384 one-byte
    ///   lines: 1.612165458 s against 1.56624075 s), which is the noise
    ///   floor of the thing the clause claimed to be the dominant term.
    /// - **Not the bytes, for memory.** At a fixed 4096 lines per side,
    ///   lines of 1, 2, 8, 40 and 80 bytes — a fortyfold spread in file size,
    ///   8,192 to 331,776 bytes per side, since a line costs its content plus
    ///   a newline — peaked at 200,294,544, 200,294,544, 201,146,512,
    ///   202,703,016 and 202,801,320 bytes: a spread of 1.25% against
    ///   forty times the input.
    /// - **Partly the bytes, for time**, and this is the one place the old
    ///   clause was not simply wrong. The same five cases took 0.106928667,
    ///   0.107052541, 0.10468875, 0.167267875 and 0.170179458 s — the 40-
    ///   and 80-byte lines are about 1.6 times slower than the 1-, 2- and
    ///   8-byte ones, because a Swift `String` of 15 bytes or fewer compares
    ///   inline and a longer one dereferences. It is a constant factor on
    ///   the comparison, not a change in what the cost grows with.
    ///
    /// Cost follows the two LINE COUNTS, multiplied, and `maxLineProduct`
    /// below is the bound in that dimension.
    ///
    /// **What this constant does bound, now stated rather than assumed.** It
    /// is the only thing that bounds one side's LINE count, because the
    /// densest a line can be is one content byte and a newline: 4 MiB admits
    /// at most 2,097,152 lines, which is `FileDiff`'s table's row count. It
    /// also bounds the UTF-8 scan below, and the bytes a comparison fetches
    /// before any of this runs.
    ///
    /// **What it does not bound is the table**, and that is why
    /// `maxLineProduct` exists. Two sides at this ceiling with one-byte lines
    /// give a table of 4,398,050,705,409 entries. Derived with this command,
    /// which is on one line so that it runs in the form it is committed:
    ///
    /// ```
    /// /usr/bin/python3 -I -c "c=4*1024*1024; n=c//2; e=(n+1)*(n+1); print(f'{n:,} lines, {e:.3e} entries, {e*8/1e12:.1f} TB')"
    /// ```
    ///
    /// It prints `2,097,152 lines, 4.398e+12 entries, 35.2 TB`.
    public static let ceilingBytes = 4 * 1024 * 1024

    /// The largest `leftLines * rightLines` a line diff is attempted for:
    /// `1 << 25`, or 33,554,432.
    ///
    /// Measured 2026-10-13, same machine, same build, same commands as
    /// `ceilingBytes` above.
    ///
    /// **Why this value and not another.** The ladder is smooth — peak memory
    /// and elapsed time both track the product linearly, with no knee to put
    /// a bound at — so the number comes from a budget, not from the data
    /// finding its own edge. The budget chosen is about **300 MB of transient
    /// peak for a square pair**, which is what a desktop app may ask of an
    /// 8 GB Mac for one explicitly requested comparison. `1 << 25` is the
    /// largest power of two that stays inside it: 33,554,432 entries is
    /// exactly 256 MiB of table at eight bytes each, and the square pair at
    /// that product measured 285,425,880 bytes. Rejected: `1 << 24`
    /// (16,777,216), which measured 200,016,016 bytes but whose largest
    /// square is 4096 × 4096 — it would refuse two copies of the longest
    /// Swift file under `Sources` and `Tests`, named below; and `1 << 26`
    /// (67,108,864), whose
    /// square corner is 8192 × 8192 at 675,021,304 bytes, over twice the
    /// budget. A power of two is chosen over a round decimal so that the
    /// entry count, the byte count and the square side are all exact.
    ///
    /// **Why a product and not a line count per side.** `FileDiff.editScript`
    /// allocates `(L + 1)` rows of `(R + 1)` `Int`s, so the two line counts
    /// multiplied are what the table costs — and a long thin table is cheap
    /// where a per-side bound would have called it expensive: 500,000 lines
    /// against 20 diffed in 0.153434875 s at a 162,119,824-byte peak. Any
    /// per-side line bound low enough to make a SQUARE pair safe (about 5,800)
    /// refuses that pair, and refuses it by a factor of eighty-six.
    ///
    /// The bound is on `leftLines * rightLines`, where the table holds
    /// `(L + 1) * (R + 1)` entries. The two differ by `L + R + 1`, at most
    /// about 2.1 million entries here — 17 MB beside a 256 MiB table — and
    /// the simpler product is what a reader can check by hand.
    ///
    /// **Both corners of the admissible set are exact integers, and both were
    /// measured.**
    ///
    /// - The largest SQUARE pair: 5792 × 5792, product 33,547,264 (5793 × 5793
    ///   = 33,558,849 is over). One line differing: 0.289843041 s, peak
    ///   285,425,880 bytes. Every tenth line: 0.312620667 s, peak
    ///   285,671,640 bytes.
    /// - The most ASYMMETRIC pair this and `ceilingBytes` admit together:
    ///   2,097,152 × 16, product exactly 33,554,432, where 2,097,152 is the
    ///   largest line count `ceilingBytes` can hold. 0.455469583 s, peak
    ///   606,978,504 bytes.
    ///
    /// So nothing admitted cost more than half a second or 610 MB there — and
    /// the two corners differ by a factor of 2.1 in memory at the same
    /// product, which is the bound's own known imprecision rather than a
    /// surprise. The measured peak ran between 1.03 and 2.13 times the bare
    /// eight-bytes-per-entry arithmetic across every shape measured (low:
    /// 10,000 × 10,000, 824,263,280 against 800,160,008; high: the thin
    /// corner, 606,978,504 against 285,212,808), the high end where a row of
    /// 17 `Int`s costs more in its own heap allocation than in its entries.
    /// That is why the figures above are what this constant was chosen
    /// against, and the arithmetic is not.
    ///
    /// **What it refuses that this machine could have managed**, named here
    /// because the cost of a bound belongs beside it: two 8,192-line files
    /// (0.590658333 s, peak 675,021,304 bytes), two 10,000-line ones
    /// (0.864224583 s, 824,263,280) and two 11,585-line ones (1.163917958 s,
    /// 1,145,471,840). Those are real files — generated sources, long logs,
    /// minified bundles — and they are refused for about a second and a
    /// gigabyte of transient memory on a machine that had both to spare. The
    /// refusal is the deliberate price of not asking an 8 GB Mac for a
    /// gigabyte to show a diff. Two copies of the longest
    /// Swift file under `Sources` and `Tests` are admitted with room left:
    /// 4,633 lines, product 21,464,689. Counted 2026-10-13 from the
    /// repository root with
    /// `find Sources Tests -name '*.swift' -exec wc -l {} + | sort -rn | head -3`,
    /// whose first row is `wc`'s own `total` and whose second is
    /// `4633 Tests/macSCPCoreTests/SessionListViewModelTests.swift`.
    ///
    /// **What a different algorithm would buy, measured rather than assumed.**
    /// Hirschberg's linear-space LCS removes the memory term and leaves the
    /// time term, which came out at 9.195 ns per table entry (2.468680542 s
    /// over 268,468,225 entries): a 100,000-line square pair is
    /// 10,000,200,001 entries, so about 92 s before Hirschberg's own constant
    /// and roughly twice that after it. The bound would move from memory to
    /// time, not
    /// disappear — and `FileDiff` is correct today, pinned by 29 cases in
    /// `FileDiffTests`, three of them properties over generated inputs, so
    /// replacing it buys a wider admissible set at the price of re-earning
    /// that. Counted 2026-10-13, one command per figure, each run from the
    /// repository root in the form written here:
    /// `grep -o '@Test' Tests/macSCPCoreTests/FileDiffTests.swift | wc -l`
    /// prints 29, and
    /// `grep -o '@Test(.timeLimit' Tests/macSCPCoreTests/FileDiffTests.swift | wc -l`
    /// prints 3 — the three properties are inside the 29, not beside them.
    /// What would actually widen it is a diff whose
    /// cost follows the DIFFERENCES — Myers — and that is its own piece of
    /// work, not a tidy-up of this constant.
    public static let maxLineProduct = 1 << 25

    /// How many leading bytes are searched for a NUL. This is git's own
    /// heuristic, adopted by name rather than invented here.
    static let nulWindowBytes = 8000

    /// Why this content cannot be shown as a line diff, or `nil` when it can.
    ///
    /// The checks run in this order, and the first to fire decides:
    ///
    /// 1. **Size.** An oversized file reports `.tooLarge` even when it is also
    ///    binary. The size is the cheaper fact (no byte is read to learn it),
    ///    it is the one the user can act on, and it keeps a huge buffer from
    ///    being scanned at all.
    /// 2. **A NUL byte** in the first `nulWindowBytes` bytes, reported as
    ///    `.binary`. A NUL later in the file does not make it binary by this
    ///    rule; it is valid UTF-8 and the third check lets it through.
    /// 3. **Not valid UTF-8**, anywhere in the content, reported as
    ///    `.notUTF8` and not as `.binary`. This is strict: a lone
    ///    continuation byte, a sequence cut off at the end of the buffer, an
    ///    overlong encoding and a surrogate half are all refused. A byte
    ///    order mark is valid and is not refused. Content with both a
    ///    leading NUL and invalid bytes is `.binary`, by the order.
    ///
    /// An empty buffer is eligible.
    public static func refusal(forBytes bytes: [UInt8]) -> DiffRefusal? {
        if bytes.count > ceilingBytes {
            return .tooLarge(bytes: bytes.count, ceiling: ceilingBytes)
        }
        if bytes.prefix(nulWindowBytes).contains(0x00) { return .binary }
        if String(validating: bytes, as: UTF8.self) == nil { return .notUTF8 }
        return nil
    }

    /// Why this PAIR cannot be shown as a line diff, or `nil` when it can.
    ///
    /// **This is the check `refusal(forBytes:)` cannot make.** That one sees
    /// bytes and cannot know how many lines they hold; this one is called
    /// where the line counts are first known, which is after both sides have
    /// been split. The caller runs `refusal(forBytes:)` on each side first
    /// and this second, and shows whichever reason comes back.
    ///
    /// The multiplication is checked for overflow rather than performed and
    /// trusted. `Int` multiplication traps in Swift, and a trap is the
    /// loudest possible way of telling the user nothing — the whole premise
    /// of this subsystem is that it answers with a reason. Both line counts
    /// are bounded by `ceilingBytes` on the path this is called from, so the
    /// overflow branch is unreachable there; it is here because this is a
    /// public function and the next caller is not promised to be that one.
    public static func refusal(leftLines: Int, rightLines: Int) -> DiffRefusal? {
        let (product, overflowed) = leftLines.multipliedReportingOverflow(by: rightLines)
        if overflowed || product > maxLineProduct {
            return .tooManyLines(
                leftLines: leftLines, rightLines: rightLines,
                ceilingProduct: maxLineProduct)
        }
        return nil
    }
}
