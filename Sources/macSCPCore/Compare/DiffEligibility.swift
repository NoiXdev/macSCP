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
/// because what it refuses is a cost neither side carries alone. The fifth,
/// `.notAnOrdinaryFile`, is about one side again and names it — and it is the
/// one case `DiffEligibility` does not produce, because the kind of an entry
/// is not a property of its bytes: `Comparison.diffUnmapped(leftPath:
/// rightPath:)` returns it from what each side's `stat` reported.
public enum DiffRefusal: Error, Equatable, Sendable {
    /// Which side of a pair a refusal is about, for the cases that are about
    /// one side and can say which. `.binary` and `.notUTF8` could carry this
    /// too and deliberately do not: their sentences say "at least one of the
    /// two files", and widening them is a wording decision nobody has made.
    public enum Side: String, Equatable, Sendable {
        case left
        case right
    }

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
    /// One side is not an ordinary file: a directory, a link, a device node,
    /// or an entry whose type the backend did not report. Carries the side
    /// and its PATH, and the sentence prints the path — which says which side
    /// precisely, and in words no catalogue has to inflect.
    ///
    /// **What this case cannot see, stated here because a refusal that
    /// silently misses the case it names is worse than one that says so.**
    /// The kind it is given comes from `RemoteFileSystem.stat`, and over SFTP
    /// that is `SSH_FXP_STAT`, which FOLLOWS a symbolic link: Citadel's
    /// `getAttributes(at:)` sends `.stat`, and the type bits
    /// `SFTPAttributeMapper.kind(fromPermissions:)` reads are therefore the
    /// TARGET's. Measured 2026-10-15 by reading
    /// `.build/checkouts/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift`
    /// — `SFTPMessage.LStat` and `SSH_FXP_LSTAT` exist in that package's
    /// message layer and its SERVER handler, and its client exposes no method
    /// that sends one. So on a remote pane this case catches a link to a
    /// DIRECTORY (the target's bits say directory) and does NOT catch a link
    /// to a regular file: that one is compared, and what is compared is the
    /// target's bytes under the link's path. The LOCAL side has no such gap —
    /// `LocalFileSystem.stat` checks `isSymbolicLinkKey` first and reports
    /// `.symlink` even for a dangling link — and neither S3 nor WebDAV has
    /// links to report. Closing the remote half needs an `lstat`-shaped
    /// requirement on `RemoteFileSystem`, which is a design change and not
    /// this case.
    case notAnOrdinaryFile(side: Side, path: String)
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
    /// **Re-measured in full later the same day**, after `FileDiff.editScript`'s
    /// LCS table was flattened from `[[Int]]` to one `[Int]`. The figures this
    /// comment first carried were from the morning's run against the nested
    /// table and are superseded, not mixed in. Peak memory below is the probe's
    /// `peakFootprintDelta` unless it says ABSOLUTE; the two differ by up to
    /// 34% on a long thin pair, and the budget argument under
    /// `maxLineProduct` uses the absolute.
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
    /// - **Not the differences — the effect is at the measurement's own noise
    ///   floor.** Across the thirteen cases measured at both densities, in
    ///   both of the day's runs, going from one differing line to every tenth
    ///   moved elapsed time by between −8.8% and +16.3%, and **re-running the
    ///   same case with nothing changed moved it by up to 10.1%**
    ///   (`asymmetric/100000x20`: 0.019921083 s against 0.021927041 s). Four
    ///   of the thirteen were faster with ten times the differences. A term
    ///   that cannot be told apart from the noise is not the dominant term.
    /// - **Not the bytes, for memory.** At a fixed 4096 lines per side,
    ///   lines of 1, 2, 8, 40 and 80 bytes — a fortyfold spread in file size,
    ///   8,192 to 331,776 bytes per side, since a line costs its content plus
    ///   a newline — all five peaked at **134,398,048 bytes, identical to the
    ///   byte**, against a table of 134,283,272.
    /// - **Partly the bytes, for time**, and this is the one place the old
    ///   clause was not simply wrong. The same five cases took 0.082902833,
    ///   0.081726583, 0.08023775, 0.137315875 and 0.1406075 s — the 40-
    ///   and 80-byte lines are about 1.75 times slower than the 1-, 2- and
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
    /// Measured 2026-10-13, same machine, same build, same command as
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
    /// that product measured **271,696,544 bytes absolute**. Rejected:
    /// `1 << 24` (16,777,216), which measured 137,151,040 absolute but whose
    /// largest square is 4096 × 4096 — it would refuse two copies of the
    /// longest Swift file under `Sources` and `Tests`, named below; and
    /// `1 << 26` (67,108,864), whose square corner is 8192 × 8192 at
    /// 540,853,088 absolute, well over twice the budget. A power of two is
    /// chosen over a round decimal so that the entry count, the byte count
    /// and the square side are all exact.
    ///
    /// **Flattening the table did not move this number.** `FileDiff`'s LCS
    /// table became a flat `[Int]` on 2026-10-13 and the whole grid was
    /// re-measured; `1 << 26`'s square corner came back at 540,853,088 bytes
    /// absolute, still well over twice the budget. What the flattening bought
    /// is the PRECISION of this bound rather than room inside it — see the
    /// imprecision paragraph at the end.
    ///
    /// **Why a product and not a line count per side.** `FileDiff.editScript`
    /// allocates `(L + 1)` rows of `(R + 1)` `Int`s, so the two line counts
    /// multiplied are what the table costs — and a long thin table is cheap
    /// where a per-side bound would have called it expensive: 500,000 lines
    /// against 20 diffed in 0.103297833 s at a 199,770,760-byte absolute
    /// peak. Any per-side line bound low enough to make a SQUARE pair safe
    /// (about 5,800) refuses that pair, and refuses it by a factor of
    /// eighty-six.
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
    ///   = 33,558,849 is over). One line differing: 0.251779 s, peak
    ///   268,648,640 delta and **271,696,544 absolute**. Every tenth line:
    ///   0.279697208 s, 269,402,328 delta and **272,450,232 absolute**.
    /// - The most ASYMMETRIC pair this and `ceilingBytes` admit together:
    ///   2,097,152 × 16, product exactly 33,554,432, where 2,097,152 is the
    ///   largest line count `ceilingBytes` can hold. 0.273847708 s,
    ///   555,860,400 delta and **591,348,648 absolute**.
    ///
    /// **So nothing admitted cost more than about a third of a second or
    /// 591 MB there** — and the two corners differ by a factor of 2.2 in
    /// memory at the same product, which is the bound's own known
    /// imprecision rather than a surprise. Across the 33 SQUARE and
    /// pathological cases the peak delta now sits between **1.0005 and
    /// 1.0058** times the bare eight-bytes-per-entry arithmetic, where the
    /// nested `[[Int]]` table ran from 1.0301 to 1.5103; the four long thin
    /// pairs are the only ones above that, at 1.6257 to 1.9489, and the
    /// paragraph at the end of this comment says what the remaining term
    /// is. The figures above are what this constant was chosen against, and
    /// the arithmetic is not.
    ///
    /// **What it refuses that this machine could have managed**, named here
    /// because the cost of a bound belongs beside it: two 8,192-line files
    /// (0.506114958 s, 540,853,088 bytes absolute), two 10,000-line ones
    /// (0.762755458 s, 804,422,664) and two 11,585-line ones (1.014219375 s,
    /// 1,078,625,504). Those are real files — generated sources, long logs,
    /// minified bundles — and they are refused for about a second and half a
    /// gigabyte and upwards of transient memory on a machine that had both to
    /// spare. The refusal is the deliberate price of not asking an 8 GB Mac
    /// for that to show a diff. Two copies of the longest
    /// Swift file under `Sources` and `Tests` are admitted with room left:
    /// 4,633 lines, product 21,464,689. Counted 2026-10-13 from the
    /// repository root with
    /// `find Sources Tests -name '*.swift' -exec wc -l {} + | sort -rn | head -3`,
    /// whose first row is `wc`'s own `total` and whose second is
    /// `4633 Tests/macSCPCoreTests/SessionListViewModelTests.swift`.
    ///
    /// **What a different algorithm would buy, measured rather than assumed.**
    /// Hirschberg's linear-space LCS removes the table term and leaves the
    /// time term, which came out at 7.998 ns per table entry (2.14717925 s
    /// over 268,468,225 entries): a 100,000-line square pair is
    /// 10,000,200,001 entries, so about 80 s before Hirschberg's own constant
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
    /// work, not a tidy-up of this constant. Flattening the table was taken
    /// instead, and it is the cheap half of what Hirschberg offered: it did
    /// not change the table's asymptotic size, it made the table cost
    /// exactly its entries.
    ///
    /// **The one term this bound still does not predict, and it is not the
    /// term this comment named before.** Until the flattening, on 2026-10-13, the paragraph above
    /// attributed the high end to "a row of 17 `Int`s costs more in its own
    /// heap allocation than in its entries". That was half the story, and it
    /// is the half the flattening deleted. What remains is the EDIT SCRIPT
    /// and the HUNKS — the `[Step]` array and the `DiffLine`s the result
    /// holds — and it is a term in **L + R**, not in L · R, so neither
    /// flattening nor Hirschberg would touch it. Measured at **105 to 131
    /// bytes per step** on all four long thin cases (peak delta minus table
    /// bytes, over `L + R` steps: 10,511,984/100,020; 65,503,976/500,020;
    /// 272,204,088/2,097,172; 270,647,592/2,097,168), against 33.5 bytes per
    /// step on a square case whose hunks hold almost nothing
    /// (1,099,256/32,768 at 16,384 lines per side). It is why the thin corner
    /// still sits at 1.949 times its table: 285,212,808 bytes of table and
    /// 270,647,592 bytes of output.
    ///
    /// **That term is bounded by `ceilingBytes` and not by this constant.**
    /// Four MiB per side caps each line count at 2,097,152, so `L + R` cannot
    /// exceed 4,194,304 steps, which at 131 bytes each is at most
    /// 549,453,824 bytes of output. The product bound alone does not bound
    /// it; the byte ceiling does. That is the clearest statement of why this
    /// design needs both numbers rather than either.
    ///
    /// **Three limits of the whole record**, stated here rather than left for
    /// a crash to teach: every figure is from one ten-core, 64 GiB machine and
    /// **none from a slow or memory-constrained Mac**, which is the machine
    /// the budget argument above reasons about; the measured peak is the
    /// DIFF's and excludes both the `[String]` arrays the caller splits the
    /// files into and whatever the UI builds from the hunks, so **the app's
    /// real peak for an admitted comparison is above every figure here**; and
    /// the probe samples every 2 ms, so the 1,024-line rung is measured from
    /// about four samples and is the least trustworthy figure in the record —
    /// nothing in this decision rests on a case under 0.1 s.
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
        if let tooLarge = refusal(forByteCount: bytes.count) { return tooLarge }
        if bytes.prefix(nulWindowBytes).contains(0x00) { return .binary }
        if String(validating: bytes, as: UTF8.self) == nil { return .notUTF8 }
        return nil
    }

    /// The size check of `refusal(forBytes:)` on its own, for a caller that
    /// knows a file's length before it has fetched a single byte of it: a
    /// listing or a `stat` says how large a file is, and fetching a gigabyte
    /// to refuse it afterwards would spend exactly what the ceiling exists to
    /// save. `refusal(forBytes:)` calls this, so the two cannot disagree about
    /// where the boundary is: `ceilingBytes` is admitted, one more is not.
    public static func refusal(forByteCount count: Int) -> DiffRefusal? {
        count > ceilingBytes ? .tooLarge(bytes: count, ceiling: ceilingBytes) : nil
    }

    /// Why this PAIR cannot be shown as a line diff, or `nil` when it can.
    ///
    /// **This is the check `refusal(forBytes:)` cannot make.** That one sees
    /// bytes and cannot know how many lines they hold; this one belongs where
    /// the line counts are first known, which is after both sides have been
    /// split.
    ///
    /// **One caller, and the order it keeps.** `Comparison.diffUnmapped(
    /// leftPath:rightPath:)` in the App target splits both sides into lines
    /// and then calls this. Before that it asks `refusal(forByteCount:)` about
    /// each side's `stat` and again about the length of each fetched file, and
    /// `refusal(forBytes:)` about each side's fetched bytes; the first reason
    /// to come back is the one shown. `diff(forRowAt:)` and `diffFilePair()` both
    /// go through it. This paragraph replaces one that opened "**Nothing
    /// calls it yet.**" and described the caller as the code Task 8 of the
    /// diff-view plan was to write, which Task 8 did.
    ///
    /// The multiplication is checked for overflow rather than performed and
    /// trusted. `Int` multiplication traps in Swift, and a trap is the
    /// loudest possible way of telling the user nothing — the whole premise
    /// of this subsystem is that it answers with a reason. Both line counts
    /// will be bounded by `ceilingBytes` on the path above, so the overflow
    /// branch is unreachable from there; it is here because this is a public
    /// function and the next caller is not promised to be that one.
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
