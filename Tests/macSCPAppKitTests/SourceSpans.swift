import Foundation
import MacSCPTestSupport
import Testing

/// The spans a source-scanning guard reads out of a file: the body of a
/// function, one arm of a `switch`, and the block an arbitrary anchor opens
/// (`Views.block(openedBy:)`). All of them END AT A BRACE, not at the next
/// thing that looks like a sibling.
///
/// **Why this exists.** `ConnectionActionRouteTests` and `CreateBucketSheetTests`
/// each read these spans by searching for "the next `\n    func `" or "the next
/// `case .`", and when the thing read is the LAST function of a file or the
/// LAST arm of a `switch`, no such text follows and the span runs to the end of
/// the file. That is silent in the worst direction: anything appended after
/// `handleConnectionAction` (a `private func`, a struct) joins the span, so a
/// dead `.cors` arm whose store was parked in a function after it still
/// satisfied "the arm assigns its state" (measured 2026-11-04, plants Q10 and
/// Q15 of the third round of `SidebarNewBucketTests`). A span that reads too
/// much cannot go quiet by matching nothing; it is satisfied by something that
/// is not the thing it is named for.
///
/// The text handed to `functionBody` and `switchArm` should be the
/// string-and-comment-blanked view (`SourceCorpus.code(of:)`), so a brace
/// inside a literal or a comment does not count — nothing here checks that it
/// is, which is why `Views` below takes BOTH views and leaves the choice to
/// neither caller nor chance. Every helper here returns `nil` rather than a
/// span it could not bound.
enum SourceSpans {
    /// From `func <name>(` to its matching closing brace, inclusive.
    static func functionBody(named name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)(") else { return nil }
        guard let open = source[declaration.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[declaration.lowerBound...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// From just after `label` (for example `case .createBucket:`) to the line
    /// before the next arm of the same `switch`, or to the `switch`'s closing
    /// brace when the arm is the last. An arm is the next line that, at the
    /// arm's own nesting depth, starts with `case ` or `default:`.
    static func switchArm(_ label: String, in source: String) -> String? {
        guard let start = source.range(of: label) else { return nil }
        let lines = source[start.upperBound...].components(separatedBy: "\n")
        var collected: [String] = []
        var depth = 0
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The first line is the rest of the label's own line.
            if offset > 0, depth == 0, trimmed.hasPrefix("case ") || trimmed.hasPrefix("default:") {
                break
            }
            for character in line {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
            }
            if depth < 0 { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    /// One file's two blanked views, side by side in one indexing: `content`
    /// is what an anchor is searched in and what a span hands back, `code` is
    /// where every brace that bounds that span is counted.
    ///
    /// **Why both.** `code` (`SourceCorpus.code(of:)`) blanks comments AND
    /// string literals, so a brace inside a literal cannot decide where a span
    /// ends — which is the defect this type exists for. `content`
    /// (`SourceCorpus.commentFree(of:)`) keeps literals, which some anchors and
    /// some checks are written in: `Button(L10n.string("tabs.alreadyOpen.openAnyway"`
    /// is an anchor that does not occur in `code` at all, and a guard that
    /// scans for a type name a doc comment may legitimately mention needs the
    /// literals its subject spells. So the two views are not interchangeable
    /// and the brace counting is what moves, not the content matching.
    ///
    /// Measured 2026-11-04, plants R1 and R2b of the third re-review:
    /// `SidebarNewBucketTests` counted braces over `commentFree`, a
    /// `private let bracePad = "{"` planted in the create-bucket runner and in
    /// the sheet item raised the depth, each span ran past its own closing
    /// brace to the end of the file, and both guards were GREEN on a violation
    /// parked there.
    ///
    /// **One indexing, and it is a `Character` offset, never a `String.Index`.**
    /// Both views are blanked in place, so they hold the same number of
    /// `Character`s and offset *n* addresses the same character in both;
    /// `SourceCorpus.lengthCheckedView` refuses a view that is not as long as
    /// the text it came from, on every read of every file. Their UTF-8 lengths
    /// can differ — a multi-byte character kept inside a literal in `content`
    /// is a one-byte space in `code` — so a `String.Index` of one view means
    /// nothing in the other, and every position here is an offset into a
    /// `[Character]`.
    struct Views {
        /// Comments blanked, string literals kept.
        let content: String
        /// Comments and string literals blanked.
        let code: String
        private let contentCharacters: [Character]
        private let codeCharacters: [Character]

        /// `nil` when the two views are not the same length in `Character`s —
        /// two views of different files, or a stripper that stopped preserving
        /// length — rather than a read of one view by the other's offsets.
        init?(content: String, code: String) {
            let contentCharacters = Array(content)
            let codeCharacters = Array(code)
            guard contentCharacters.count == codeCharacters.count else { return nil }
            self.content = content
            self.code = code
            self.contentCharacters = contentCharacters
            self.codeCharacters = codeCharacters
        }

        /// `content.contains(text)`. Every check a caller writes is about the
        /// view literals survive in; `code` exists to bound a span, not to be
        /// matched against.
        func contains(_ text: String) -> Bool { content.contains(text) }

        /// The brace-balanced block `anchor` opens: from the start of the first
        /// occurrence of `anchor` in `content`, to the `}` that balances the
        /// first `{` at or after it IN `code`, both ends included, as the same
        /// slice of both views — so the result nests (the `.onChange` block
        /// inside a view struct's block).
        ///
        /// `nil`, never an unbounded span, when `anchor` is not in `content`,
        /// when no `{` follows it in `code`, or when that brace never closes.
        func block(openedBy anchor: String) -> Views? {
            guard
                let start = SourceSpan.firstOffset(
                    of: Array(anchor), in: contentCharacters, from: 0),
                let open = codeCharacters[start...].firstIndex(of: "{"),
                let close = SourceSpan.closingOffset(
                    from: open, in: codeCharacters, open: "{", close: "}")
            else { return nil }
            return Views(
                content: String(contentCharacters[start...close]),
                code: String(codeCharacters[start...close]))
        }
    }
}

/// The controls for `SourceSpans`: each span is bounded where it should be, and
/// neither runs on into what follows. A helper that reads too much is the
/// failure these exist for, so every check here has the over-reading input as
/// its subject.
@Suite("SourceSpans")
struct SourceSpansTests {
    private static let source = """
        extension Thing {
            func first(a: Int) {
                switch a {
                case .one:
                    one = One()
                case .two:
                    if cond {
                        two = Two()
                    }
                case .three:
                    three = Three()
                }
            }

            private func after() {
                parked = Parked()
            }
        }

        struct Appended { let id = UUID() }
        """

    @Test func aFunctionBodyEndsAtItsMatchingBraceNotAtTheEndOfTheFile() throws {
        let body = try #require(SourceSpans.functionBody(named: "first", in: Self.source))
        #expect(body.hasPrefix("func first(a: Int) {"))
        #expect(body.hasSuffix("}"))
        #expect(body.contains("three = Three()"))
        // The over-reading inputs: a function after it, and a type after the extension.
        #expect(!body.contains("parked = Parked()"))
        #expect(!body.contains("Appended"))
    }

    @Test func aFunctionThatIsNotThereIsNilAndNotAnEmptySpan() {
        #expect(SourceSpans.functionBody(named: "missing", in: Self.source) == nil)
        #expect(SourceSpans.functionBody(named: "first", in: "func first(a: Int)") == nil)
    }

    @Test func aMiddleArmEndsAtTheNextArmAndKeepsItsNestedBraces() throws {
        let arm = try #require(SourceSpans.switchArm("case .two:", in: Self.source))
        #expect(arm.contains("two = Two()"))
        #expect(!arm.contains("one = One()"))
        #expect(!arm.contains("three = Three()"))
    }

    @Test func theLastArmEndsAtTheSwitchesClosingBrace() throws {
        let arm = try #require(SourceSpans.switchArm("case .three:", in: Self.source))
        #expect(arm.contains("three = Three()"))
        // The over-reading inputs, which the old "up to the next `case .`" read.
        #expect(!arm.contains("parked = Parked()"))
        #expect(!arm.contains("Appended"))
    }

    @Test func anArmThatIsNotThereIsNil() {
        #expect(SourceSpans.switchArm("case .four:", in: Self.source) == nil)
    }

    // MARK: - Two views, one indexing

    /// A `{` inside a string literal, in a block that is NOT the last thing in
    /// the text, and a `}` in a literal further down that balances it: plants
    /// R1 and R2b of the third re-review, in miniature. Counted over one view,
    /// the first block runs past its own closing brace to the end of
    /// `parked()`. It also carries an anchor spelled in a literal, which the
    /// blanked view does not hold at all.
    private static let literalBrace = """
        struct Inner {
            let pad = "{"
            func handle() {
                mark("inner")
            }

            func labelled() {
                button(key("inner.title")) {
                    mark("pressed")
                }
            }
        }

        func parked() {
            let closer = "}"
            mark("parked")
        }
        """

    private static func views(of source: String) throws -> SourceSpans.Views? {
        SourceSpans.Views(
            content: try SwiftSource.blankingComments(source),
            code: try SwiftSource.blankingCommentsAndStrings(source))
    }

    @Test func aBlockEndsAtItsBraceThoughAStringLiteralHoldsAnOpeningBrace() throws {
        let views = try #require(try Self.views(of: Self.literalBrace))
        let block = try #require(views.block(openedBy: "struct Inner {"))
        #expect(block.contains("mark(\"inner\")"))
        #expect(!block.contains("mark(\"parked\")"))
        // The positive control for that negative: the same walk with the
        // literal-keeping view in BOTH places — which is what this type
        // replaced — reads past the struct and down to the end of `parked()`,
        // so the check above can see an over-read when there is one.
        let oneView = try #require(SourceSpans.Views(content: views.content, code: views.content))
        let overRead = try #require(oneView.block(openedBy: "struct Inner {"))
        #expect(overRead.contains("mark(\"parked\")"))
    }

    @Test func anAnchorSpelledInAStringLiteralIsFoundAndTheBlankedViewHasNone() throws {
        let views = try #require(try Self.views(of: Self.literalBrace))
        let anchor = "button(key(\"inner.title\"))"
        let block = try #require(
            views.block(openedBy: anchor), "the anchor is not in the literal-keeping view")
        #expect(block.contains("mark(\"pressed\")"))
        #expect(!block.contains("mark(\"inner\")"))
        // Why the anchor is searched in `content` and not in `code`: the
        // blanked view does not hold it, so a walk handed only `code` could
        // not find this block at all.
        let blanked = try #require(SourceSpans.Views(content: views.code, code: views.code))
        #expect(blanked.block(openedBy: anchor) == nil)
    }

    @Test func twoViewsOfDifferentLengthsAreRefusedRatherThanReadByEachOthersOffsets() throws {
        #expect(SourceSpans.Views(content: "struct A { }", code: "struct A {}") == nil)
        // The control: the same pair, equal in length, is accepted and reads.
        let pair = try #require(SourceSpans.Views(content: "struct A { }", code: "struct A { }"))
        #expect(pair.block(openedBy: "struct A") != nil)
    }

    @Test func aBlockThatNeverClosesIsNilAndNotTheRestOfTheText() throws {
        let unclosed = "struct A {\n    let a = 1\n"
        let views = try #require(SourceSpans.Views(content: unclosed, code: unclosed))
        // The control: the text is there, and it is what an unbounded read
        // would have handed back.
        #expect(views.contains("let a = 1"))
        #expect(views.block(openedBy: "struct A") == nil)
        #expect(views.block(openedBy: "struct B") == nil)
    }
}
