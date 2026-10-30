import Testing

@testable import macSCPCore

@Suite struct FileDiffTests {
    /// One compact line per diff line: a space for context, `-` for removed,
    /// `+` for added. Keeps the order assertions readable.
    private func render(_ hunk: DiffHunk) -> [String] {
        hunk.lines.map { line in
            switch line.kind {
            case .context: " " + line.text
            case .removed: "-" + line.text
            case .added: "+" + line.text
            }
        }
    }

    private func numbered(_ range: ClosedRange<Int>) -> [String] {
        range.map(String.init)
    }

    // MARK: - The floor from the brief

    @Test func identicalFilesProduceNoHunks() {
        #expect(FileDiff.hunks(left: ["a", "b"], right: ["a", "b"], context: 3).isEmpty)
    }

    @Test func anInsertIsOneAddedLine() {
        let hunks = FileDiff.hunks(left: ["a", "c"], right: ["a", "b", "c"], context: 3)
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.filter { $0.kind == .added }.map(\.text) == ["b"])
        #expect(hunks[0].lines.filter { $0.kind == .removed }.isEmpty)
    }

    @Test func aDeleteIsOneRemovedLine() {
        let hunks = FileDiff.hunks(left: ["a", "b", "c"], right: ["a", "c"], context: 3)
        #expect(hunks[0].lines.filter { $0.kind == .removed }.map(\.text) == ["b"])
    }

    @Test func aChangeIsARemovalAndAnAddition() {
        let hunks = FileDiff.hunks(left: ["a", "b"], right: ["a", "B"], context: 3)
        #expect(hunks[0].lines.filter { $0.kind == .removed }.map(\.text) == ["b"])
        #expect(hunks[0].lines.filter { $0.kind == .added }.map(\.text) == ["B"])
    }

    @Test func anEmptySideAgainstContent() {
        let hunks = FileDiff.hunks(left: [], right: ["a", "b"], context: 3)
        #expect(hunks[0].lines.filter { $0.kind == .added }.count == 2)
    }

    @Test func distantChangesAreSeparateHunks() {
        let left = (1...40).map(String.init)
        var right = left
        right[0] = "x"
        right[39] = "y"
        #expect(FileDiff.hunks(left: left, right: right, context: 3).count == 2)
    }

    // MARK: - Empty sides

    @Test func bothSidesEmptyProduceNoHunks() {
        #expect(FileDiff.hunks(left: [], right: [], context: 3).isEmpty)
    }

    @Test func anEmptyRightSideIsEveryLineRemoved() {
        let hunks = FileDiff.hunks(left: ["a", "b"], right: [], context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == ["-a", "-b"])
        #expect(hunks[0].leftStart == 0)
        #expect(hunks[0].rightStart == 0)
    }

    // MARK: - Line endings
    //
    // The function compares the strings it is given, exactly. How a file is
    // cut into lines is the caller's decision, so these pin what the diff
    // does with the shapes a cut can produce.

    /// Cut on "\n", "a\nb" is ["a", "b"] and "a\nb\n" is ["a", "b", ""]: the
    /// final newline is a final empty line, and the diff says so.
    @Test func aTrailingNewlineIsAnAddedEmptyLine() {
        let hunks = FileDiff.hunks(left: ["a", "b"], right: ["a", "b", ""], context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == [" a", " b", "+"])
    }

    @Test func aMissingTrailingNewlineIsARemovedEmptyLine() {
        let hunks = FileDiff.hunks(left: ["a", "b", ""], right: ["a", "b"], context: 3)
        #expect(render(hunks[0]) == [" a", " b", "-"])
    }

    /// A CRLF file cut on "\n" keeps the "\r" on every line, so against its
    /// LF twin every line differs: the bytes do differ, and a diff that said
    /// nothing would contradict the folder view, which saw different sizes.
    @Test func crlfAgainstLfDiffersOnEveryLine() {
        let hunks = FileDiff.hunks(
            left: ["a\r", "b\r"], right: ["a", "b"], context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == ["-a\r", "-b\r", "+a", "+b"])
    }

    /// A mixed file: only the line whose ending changed is reported.
    @Test func onlyTheLineWhoseEndingChangedIsReported() {
        let hunks = FileDiff.hunks(
            left: ["a", "b\r", "c"], right: ["a", "b", "c"], context: 1)
        #expect(render(hunks[0]) == [" a", "-b\r", "+b", " c"])
    }

    // MARK: - Bytes, not canonical equivalence

    /// Swift's `String` equality is canonical equivalence, so a precomposed
    /// and a decomposed spelling of the same text are `==` while their bytes
    /// differ. The folder view reaches `.differs` through a checksum over
    /// bytes, so the content diff has to see the difference too; the
    /// alternative is a row that says "these differ" over a diff that shows
    /// nothing. Lines are compared by their UTF-8 views.
    @Test func twoSpellingsOfOneTextAreDifferentLines() {
        let composed = "\u{00E4}"
        let decomposed = "a\u{0308}"
        // Positive control: they ARE equal as Strings and DO differ as bytes,
        // so the case below cannot pass because the fixture was not what it
        // looks like (two identical literals, or two that already differ).
        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))

        let hunks = FileDiff.hunks(left: [composed], right: [decomposed], context: 3)

        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == ["-" + composed, "+" + decomposed])
        // And in the middle of a file, between lines that agree.
        let inContext = FileDiff.hunks(
            left: ["a", composed, "c"], right: ["a", decomposed, "c"], context: 1)
        #expect(inContext.count == 1)
        #expect(render(inContext[0]) == [" a", "-" + composed, "+" + decomposed, " c"])
        // The same spelling on both sides is still no difference at all.
        #expect(FileDiff.hunks(left: [decomposed], right: [decomposed], context: 3).isEmpty)
    }

    // MARK: - Edges of the file and of the grouping

    @Test func aChangeAtTheFirstLine() {
        var right = numbered(1...10)
        right[0] = "x"
        let hunks = FileDiff.hunks(left: numbered(1...10), right: right, context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == ["-1", "+x", " 2", " 3", " 4"])
        #expect(hunks[0].leftStart == 0)
        #expect(hunks[0].rightStart == 0)
    }

    @Test func aChangeAtTheLastLine() {
        var right = numbered(1...10)
        right[9] = "y"
        let hunks = FileDiff.hunks(left: numbered(1...10), right: right, context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == [" 7", " 8", " 9", "-10", "+y"])
        #expect(hunks[0].leftStart == 6)
        #expect(hunks[0].rightStart == 6)
    }

    /// Two changes separated by exactly `2 * context` unchanged lines share
    /// one hunk (splitting there would show the same lines twice); one more
    /// unchanged line and they part. The pair pins the boundary from both
    /// sides, so neither a `>=` nor a `>` slip can pass.
    @Test func twoChangesTwiceTheContextApartShareAHunk() {
        let left = numbered(1...20)
        var right = left
        right[0] = "x"
        right[7] = "y"  // six unchanged lines between: 2 * 3
        let hunks = FileDiff.hunks(left: left, right: right, context: 3)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == [
            "-1", "+x", " 2", " 3", " 4", " 5", " 6", " 7",
            "-8", "+y", " 9", " 10", " 11",
        ])
        #expect(hunks[0].leftStart == 0)
        #expect(hunks[0].rightStart == 0)
    }

    @Test func twoChangesMoreThanTwiceTheContextApartAreSeparateHunks() {
        let left = numbered(1...20)
        var right = left
        right[0] = "x"
        right[8] = "y"  // seven unchanged lines between: 2 * 3 + 1
        let hunks = FileDiff.hunks(left: left, right: right, context: 3)
        #expect(hunks.count == 2)
        #expect(render(hunks[0]) == ["-1", "+x", " 2", " 3", " 4"])
        #expect(render(hunks[1]) == [" 6", " 7", " 8", "-9", "+y", " 10", " 11", " 12"])
        #expect(hunks[1].leftStart == 5)
        #expect(hunks[1].rightStart == 5)
    }

    @Test func zeroContextMergesAdjacentChangesOnly() {
        let adjacent = FileDiff.hunks(left: ["a", "b"], right: ["a", "B"], context: 0)
        #expect(adjacent.count == 1)
        #expect(render(adjacent[0]) == ["-b", "+B"])

        // One unchanged line between two changes: 1 > 2 * 0, so two hunks.
        let apart = FileDiff.hunks(
            left: ["a", "b", "c"], right: ["A", "b", "C"], context: 0)
        #expect(apart.count == 2)
        // And the same input with context 1: 1 <= 2 * 1, so one hunk.
        let near = FileDiff.hunks(
            left: ["a", "b", "c"], right: ["A", "b", "C"], context: 1)
        #expect(near.count == 1)
        #expect(render(near[0]) == ["-a", "+A", " b", "-c", "+C"])
    }

    @Test func aNegativeContextIsTreatedAsZero() {
        let left = numbered(1...10)
        var right = left
        right[4] = "x"
        let zero = FileDiff.hunks(left: left, right: right, context: 0)
        // Positive control: the zero-context diff is not vacuously equal.
        #expect(zero.count == 1)
        #expect(render(zero[0]) == ["-5", "+x"])
        #expect(FileDiff.hunks(left: left, right: right, context: -5) == zero)
    }

    @Test func aContextBeyondTheFileIsOneWholeFileHunk() {
        let left = numbered(1...6)
        var right = left
        right[0] = "x"
        right[5] = "y"
        let hunks = FileDiff.hunks(left: left, right: right, context: Int.max)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == ["-1", "+x", " 2", " 3", " 4", " 5", "-6", "+y"])
        #expect(hunks[0].leftStart == 0)
    }

    // MARK: - What the starts mean

    @Test func startsAreZeroBasedIndicesOfTheFirstLineOfTheHunk() {
        // Inserted after "5", one line of context each way.
        let left = numbered(1...10)
        let right = numbered(1...5) + ["new"] + numbered(6...10)
        let hunks = FileDiff.hunks(left: left, right: right, context: 1)
        #expect(hunks.count == 1)
        #expect(render(hunks[0]) == [" 5", "+new", " 6"])
        #expect(hunks[0].leftStart == 4)
        #expect(hunks[0].rightStart == 4)
    }

    /// The two starts move independently: an addition above shifts the right
    /// side only, so a hunk below it starts at different indices.
    @Test func theTwoStartsAreNotTheSameNumber() {
        let hunks = FileDiff.hunks(
            left: ["a", "b", "c", "d", "e"],
            right: ["X", "a", "b", "c", "E"],
            context: 0)
        #expect(hunks.count == 2)
        #expect(render(hunks[0]) == ["+X"])
        #expect(hunks[0].leftStart == 0)
        #expect(hunks[0].rightStart == 0)
        #expect(render(hunks[1]) == ["-d", "-e", "+E"])
        #expect(hunks[1].leftStart == 3)
        #expect(hunks[1].rightStart == 4)
    }

    /// A hunk that opens with an addition starts, on the left, at the line
    /// the addition lands in front of; one that opens with a removal starts,
    /// on the right, at the line that now sits where the removed one was.
    @Test func aHunkOpeningOnAnAdditionOrARemovalStartsWhereItLands() {
        let left = numbered(1...10)

        let inserted = FileDiff.hunks(
            left: left, right: numbered(1...5) + ["new"] + numbered(6...10), context: 0)
        #expect(render(inserted[0]) == ["+new"])
        #expect(inserted[0].leftStart == 5)  // in front of "6"
        #expect(inserted[0].rightStart == 5)

        let removed = FileDiff.hunks(
            left: left, right: numbered(1...5) + numbered(7...10), context: 0)
        #expect(render(removed[0]) == ["-6"])
        #expect(removed[0].leftStart == 5)
        #expect(removed[0].rightStart == 5)  // "7" now sits at index 5
    }

    @Test func anAppendAtTheEndStartsOnePastTheLeftSide() {
        let hunks = FileDiff.hunks(left: ["a"], right: ["a", "b"], context: 0)
        #expect(render(hunks[0]) == ["+b"])
        #expect(hunks[0].leftStart == 1)
        #expect(hunks[0].rightStart == 1)
    }

    @Test func aHunkReportsHowManyLinesItCoversOnEachSide() {
        let change = FileDiff.hunks(left: ["a", "b", "c"], right: ["a", "B", "c"], context: 3)
        #expect(change[0].leftCount == 3)
        #expect(change[0].rightCount == 3)

        let insert = FileDiff.hunks(left: ["a", "c"], right: ["a", "b", "c"], context: 3)
        #expect(insert[0].leftCount == 2)
        #expect(insert[0].rightCount == 3)

        let delete = FileDiff.hunks(left: ["a", "b", "c"], right: ["a", "c"], context: 3)
        #expect(delete[0].leftCount == 3)
        #expect(delete[0].rightCount == 2)
    }

    // MARK: - Shapes the backtracking can get wrong

    /// Every line equal to every other: the table is all ties, and the walk
    /// has to take them without inventing or losing a line.
    @Test func identicalLinesOfDifferentCounts() {
        let longer = FileDiff.hunks(left: ["a", "a", "a"], right: ["a", "a"], context: 3)
        #expect(longer.count == 1)
        #expect(longer[0].lines.filter { $0.kind == .removed }.count == 1)
        #expect(longer[0].lines.filter { $0.kind == .added }.isEmpty)
        #expect(longer[0].lines.filter { $0.kind == .context }.count == 2)
        #expect(longer[0].leftCount == 3)
        #expect(longer[0].rightCount == 2)

        let shorter = FileDiff.hunks(left: ["a", "a"], right: ["a", "a", "a"], context: 3)
        #expect(shorter.count == 1)
        #expect(shorter[0].lines.filter { $0.kind == .added }.count == 1)
        #expect(shorter[0].lines.filter { $0.kind == .removed }.isEmpty)
        #expect(shorter[0].lines.filter { $0.kind == .context }.count == 2)

        #expect(FileDiff.hunks(left: ["a", "a", "a"], right: ["a", "a", "a"], context: 3).isEmpty)
    }

    /// In a block of several changes, the removals come first and the
    /// additions after, each in file order.
    @Test func aChangedBlockListsRemovalsBeforeAdditions() {
        let hunks = FileDiff.hunks(
            left: ["a", "b", "c", "d"], right: ["a", "X", "Y", "d"], context: 1)
        #expect(render(hunks[0]) == [" a", "-b", "-c", "+X", "+Y", " d"])
    }

    // MARK: - Properties over many small inputs

    /// A reference answer by exhaustive recursion, with no table: the
    /// length of the longest common subsequence, for inputs short enough
    /// that it finishes at once.
    private func lcsLength(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Int {
        guard let x = a.first, let y = b.first else { return 0 }
        if x == y { return 1 + lcsLength(a.dropFirst(), b.dropFirst()) }
        return max(lcsLength(a.dropFirst(), b), lcsLength(a, b.dropFirst()))
    }

    /// A small deterministic generator, so a failure names an input that can
    /// be reproduced rather than one that depended on a seed nobody wrote down.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func randomLines(_ rng: inout Lcg, alphabet: Int) -> [String] {
        (0..<rng.next(8)).map { _ in String(rng.next(alphabet)) }
    }

    /// With a context wider than the file there is one hunk, and it IS the
    /// pair: the left side is its context and removals, the right side its
    /// context and additions, and it spends no more edits than the
    /// shortest edit script does. Run over a two-letter alphabet, which is
    /// where the ties live.
    @Test(.timeLimit(.minutes(5)))
    func aWholeFileHunkReconstructsBothSidesWithAMinimalScript() {
        var rng = Lcg(state: 20_261_013)
        var differing = 0
        for _ in 0..<2000 {
            let left = randomLines(&rng, alphabet: 2)
            let right = randomLines(&rng, alphabet: 2)
            let hunks = FileDiff.hunks(left: left, right: right, context: 100)

            if left == right {
                #expect(hunks.isEmpty, "left \(left) right \(right)")
                continue
            }
            differing += 1
            #expect(hunks.count == 1, "left \(left) right \(right)")
            guard let hunk = hunks.first else { continue }

            #expect(hunk.lines.filter { $0.kind != .added }.map(\.text) == left,
                    "left \(left) right \(right)")
            #expect(hunk.lines.filter { $0.kind != .removed }.map(\.text) == right,
                    "left \(left) right \(right)")

            let shared = lcsLength(left[...], right[...])
            let edits = hunk.lines.filter { $0.kind != .context }.count
            #expect(edits == left.count + right.count - 2 * shared,
                    "left \(left) right \(right)")
        }
        // Positive control: the loop reached the interesting branch.
        #expect(differing > 1000)
    }

    /// With a narrow context, every hunk still points at its own lines: the
    /// slice of each side starting at the hunk's start is what the hunk says
    /// it was, and the hunks are in order and do not overlap. And nothing is
    /// lost between them: `expectEveryChangeIsShownOnce` checks, against the
    /// whole-file script, that no change falls outside the hunks.
    @Test(.timeLimit(.minutes(5)))
    func everyHunkPointsAtItsOwnLinesOnBothSides() {
        var rng = Lcg(state: 20_261_014)
        var multiHunk = 0
        var coverage = Coverage()
        for _ in 0..<2000 {
            var left: [String] = []
            for _ in 0..<(rng.next(30)) { left.append(String(rng.next(4))) }
            var right: [String] = []
            for _ in 0..<(rng.next(30)) { right.append(String(rng.next(4))) }
            let context = rng.next(3)
            let hunks = FileDiff.hunks(left: left, right: right, context: context)
            if hunks.count > 1 { multiHunk += 1 }

            var leftEnd = 0
            var rightEnd = 0
            for hunk in hunks {
                let fromLeft = hunk.lines.filter { $0.kind != .added }.map(\.text)
                let fromRight = hunk.lines.filter { $0.kind != .removed }.map(\.text)
                #expect(hunk.leftCount == fromLeft.count)
                #expect(hunk.rightCount == fromRight.count)
                #expect(hunk.leftStart >= leftEnd, "left \(left) right \(right)")
                #expect(hunk.rightStart >= rightEnd, "left \(left) right \(right)")
                #expect(hunk.leftStart + fromLeft.count <= left.count)
                #expect(hunk.rightStart + fromRight.count <= right.count)
                #expect(
                    Array(left[hunk.leftStart..<(hunk.leftStart + fromLeft.count)]) == fromLeft,
                    "left \(left) right \(right) context \(context)")
                #expect(
                    Array(right[hunk.rightStart..<(hunk.rightStart + fromRight.count)]) == fromRight,
                    "left \(left) right \(right) context \(context)")
                leftEnd = hunk.leftStart + fromLeft.count
                rightEnd = hunk.rightStart + fromRight.count
            }
            expectEveryChangeIsShownOnce(
                left: left, right: right, context: context, hunks: hunks,
                coverage: &coverage)
        }
        // Positive control: the separation between hunks was exercised.
        #expect(multiHunk > 100)
        // Positive controls for the coverage checks, each of which would
        // otherwise pass vacuously on inputs that never reach its branch.
        #expect(coverage.changes > 1000)
        #expect(coverage.gaps > 100)
        #expect(coverage.mergedRuns > 100)
        #expect(coverage.truncatedHunks > 100)
        #expect(coverage.mixedBlocks > 100)
    }

    /// What `expectEveryChangeIsShownOnce` reached, so the test can assert
    /// that each of its checks ran on real inputs.
    private struct Coverage {
        var changes = 0
        /// Pairs of neighbouring hunks whose separation was checked.
        var gaps = 0
        /// Pairs of neighbouring changes inside one hunk whose distance was checked.
        var mergedRuns = 0
        /// Hunks whose context was shortened by the start or end of the file.
        var truncatedHunks = 0
        /// Blocks of changes holding both removals and additions.
        var mixedBlocks = 0
    }

    /// The properties that make the hunks a complete account of the diff,
    /// stated against the whole-file script (the single hunk a context
    /// wider than the file produces) rather than against the grouper's own
    /// output:
    ///
    /// 1. Every changed line of the script lies inside exactly one hunk, and
    ///    each hunk is a contiguous slice of the script. A grouper that
    ///    dropped a hunk would still pass every other check in this suite
    ///    that looks only at the hunks it returned.
    /// 2. A change has `context` lines of context on each side, shortened
    ///    only by the start or end of the file; a hunk has no more than that.
    /// 3. Two neighbouring changes are more than `2 * context` unchanged
    ///    lines apart exactly when they are in different hunks.
    ///
    /// And the claim `FileDiff.hunks` documents: within a block of changes,
    /// every removal comes before every addition.
    private func expectEveryChangeIsShownOnce(
        left: [String], right: [String], context: Int, hunks: [DiffHunk],
        coverage: inout Coverage
    ) {
        let note = "left \(left) right \(right) context \(context)"
        let whole = FileDiff.hunks(left: left, right: right, context: left.count + right.count + 1)
        let script = whole.first?.lines ?? []
        let count = script.count

        // Where each script line came from on each side. The pair is unique
        // per position, since every step consumes at least one side.
        var origin: [(left: Int, right: Int)] = []
        var consumedLeft = 0
        var consumedRight = 0
        for line in script {
            origin.append((consumedLeft, consumedRight))
            if line.kind != .added { consumedLeft += 1 }
            if line.kind != .removed { consumedRight += 1 }
        }

        // The ordering claim, on the script.
        var sawAddition = false
        var blockHasRemoval = false
        for line in script + [DiffLine(kind: .context, text: "")] {
            switch line.kind {
            case .context:
                if sawAddition && blockHasRemoval { coverage.mixedBlocks += 1 }
                sawAddition = false
                blockHasRemoval = false
            case .removed:
                #expect(!sawAddition, "an addition precedes a removal: \(note)")
                blockHasRemoval = true
            case .added:
                sawAddition = true
            }
        }

        // Which script positions each hunk covers.
        var shown = [Int](repeating: 0, count: count)
        var spans: [Range<Int>] = []
        for hunk in hunks {
            guard let start = origin.firstIndex(where: {
                $0.left == hunk.leftStart && $0.right == hunk.rightStart
            }), start + hunk.lines.count <= count else {
                Issue.record("a hunk starts nowhere in the script: \(note)")
                continue
            }
            let span = start..<(start + hunk.lines.count)
            #expect(Array(script[span]) == hunk.lines, "\(note)")
            for position in span { shown[position] += 1 }
            spans.append(span)
        }

        let changed = script.indices.filter { script[$0].kind != .context }
        coverage.changes += changed.count

        // 1. Every change is in exactly one hunk.
        for position in changed {
            #expect(shown[position] == 1, "change \(position) shown \(shown[position]) times: \(note)")
        }
        #expect(shown.allSatisfy { $0 <= 1 }, "hunks overlap: \(note)")

        // 2. The context around each change, and nothing beyond it.
        for position in changed {
            for near in max(0, position - context)...min(count - 1, position + context) {
                #expect(shown[near] == 1, "line \(near) beside change \(position) hidden: \(note)")
            }
        }
        for span in spans {
            let inside = span.filter { script[$0].kind != .context }
            guard let first = inside.first, let last = inside.last else {
                Issue.record("a hunk with no change in it: \(note)")
                continue
            }
            #expect(first - span.lowerBound == min(context, first), "leading context: \(note)")
            #expect(span.upperBound - 1 - last == min(context, count - 1 - last), "trailing context: \(note)")
            if first - span.lowerBound < context || span.upperBound - 1 - last < context {
                coverage.truncatedHunks += 1
            }

            // 3, inside a hunk: neighbouring changes are close.
            for (a, b) in zip(inside, inside.dropFirst()) {
                #expect(b - a - 1 <= 2 * context, "split too eagerly: \(note)")
                coverage.mergedRuns += 1
            }
        }
        // 3, between hunks: the unchanged run is longer than twice the context.
        for (before, after) in zip(spans, spans.dropFirst()) {
            let lastBefore = before.last { script[$0].kind != .context }
            let firstAfter = after.first { script[$0].kind != .context }
            if let lastBefore, let firstAfter {
                #expect(firstAfter - lastBefore - 1 > 2 * context, "split too early: \(note)")
                coverage.gaps += 1
            }
        }
    }

    /// Swapping the sides swaps the kinds: what one direction removes the
    /// other adds, and the same number of lines is touched.
    @Test(.timeLimit(.minutes(5)))
    func swappingTheSidesSwapsAddedAndRemoved() {
        var rng = Lcg(state: 20_261_015)
        var touched = 0
        for _ in 0..<500 {
            let left = randomLines(&rng, alphabet: 3)
            let right = randomLines(&rng, alphabet: 3)
            let forward = FileDiff.hunks(left: left, right: right, context: 100)
                .flatMap(\.lines)
            let backward = FileDiff.hunks(left: right, right: left, context: 100)
                .flatMap(\.lines)
            let removedForward = forward.filter { $0.kind == .removed }.count
            let addedBackward = backward.filter { $0.kind == .added }.count
            #expect(removedForward == addedBackward, "left \(left) right \(right)")
            #expect(
                forward.filter { $0.kind == .added }.count
                    == backward.filter { $0.kind == .removed }.count,
                "left \(left) right \(right)")
            touched += removedForward
        }
        #expect(touched > 0)
    }
}
