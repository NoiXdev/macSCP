import Foundation
import Testing

/// The two spans a source-scanning guard reads out of a file: the body of a
/// function, and one arm of a `switch`. Both END AT A BRACE, not at the next
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
/// The text handed in should be the string-and-comment-blanked view
/// (`SourceCorpus.code(of:)`), so a brace inside a literal or a comment does not
/// count. Both helpers return `nil` rather than a span they could not bound.
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
}
