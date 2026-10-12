import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the confirmation sheet shows is the user's only check on what a
/// server's file names became, so a name must not be able to show less (or
/// something other) than it is. A NUL inside a SwiftUI `Text` may end the
/// string there, which would display a shorter command than the one that
/// runs; a bidirectional override reorders what is drawn around it.
@Suite("File action plan display")
struct FileActionPlanDisplayTests {
    private func plain(_ runs: [FileActionPlanDisplay.Run]) -> String {
        runs.map(\.text).joined()
    }

    @Test func aNulIsShownAsAVisibleMarkerAndNeverPassedThrough() {
        let runs = FileActionPlanDisplay.runs(of: "cat 'a\u{0}b'")
        let shown = plain(runs)
        #expect(shown == "cat 'a<U+0000>b'")
        #expect(shown.unicodeScalars.contains("\u{0}") == false)
    }

    @Test func theMarkerIsItsOwnRunSoTheSheetCanHighlightIt() {
        let runs = FileActionPlanDisplay.runs(of: "a\u{0}b")
        #expect(runs.map(\.text) == ["a", "<U+0000>", "b"])
        #expect(runs.map(\.isEscape) == [false, true, false])
    }

    @Test func aNameThatSpellsTheMarkerItselfIsNotHighlighted() {
        let runs = FileActionPlanDisplay.runs(of: "<U+0000>")
        #expect(runs.count == 1)
        #expect(runs.allSatisfy { $0.isEscape == false })
    }

    @Test func lineBreaksAndBidirectionalOverridesAreMadeVisibleToo() {
        let shown = plain(FileActionPlanDisplay.runs(of: "a\nb\r\u{202E}c\u{2028}d\u{7F}"))
        #expect(shown == "a<U+000A>b<U+000D><U+202E>c<U+2028>d<U+007F>")
    }

    @Test func ordinaryTextIsOneRunAndUnchanged() {
        let runs = FileActionPlanDisplay.runs(of: "gzip 'Überraschung 日本語.txt'")
        #expect(runs.count == 1)
        #expect(plain(runs) == "gzip 'Überraschung 日本語.txt'")
    }

    /// A joined emoji is an ordinary name. The family below is three emoji
    /// joined by U+200D; the second name carries variation selectors (U+FE0F
    /// asks for the emoji form, U+FE0E for the text form).
    @Test func aJoinedEmojiAndItsVariationSelectorsAreNotMarked() {
        let family = "cat 'a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.txt'"
        let variants = "cat 'x\u{2764}\u{FE0F}y\u{2764}\u{FE0E}.txt'"
        for text in [family, variants] {
            let runs = FileActionPlanDisplay.runs(of: text)
            #expect(runs.count == 1)
            #expect(runs.allSatisfy { $0.isEscape == false })
            #expect(plain(runs) == text)
        }
    }

    /// Every bidirectional control reorders what the user reads and stays
    /// marked, and so do the zero-width space and non-joiner, which hide a
    /// difference between names. The positive beside the emoji case above:
    /// the joiner's neighbours in the same block are still caught.
    @Test func everyBidirectionalControlAndTheHidingZeroWidthsAreStillMarked() throws {
        let marked: [UInt32] =
            [0x200B, 0x200C, 0x200E, 0x200F]
            + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for value in marked {
            let scalar = try #require(Unicode.Scalar(value))
            let runs = FileActionPlanDisplay.runs(of: "a\(Character(scalar))b")
            let hex = String(value, radix: 16, uppercase: true)
            #expect(
                runs.map(\.text) == ["a", "<U+\(hex)>", "b"], "U+\(hex) was not marked")
            #expect(runs.map(\.isEscape) == [false, true, false])
        }
    }

    @Test func aRightToLeftOverrideInsideAJoinedEmojiNameIsStillMarked() {
        let runs = FileActionPlanDisplay.runs(of: "\u{1F468}\u{200D}\u{1F469}\u{202E}gpj.exe")
        #expect(runs.map(\.isEscape) == [false, true, false])
        #expect(runs[1].text == "<U+202E>")
    }

    @Test func shellLinesAreShownOnePerLine() {
        let lines = FileActionPlanDisplay.lines(for: .shellLines(["wc -l 'a'", "wc -l 'b'"]))
        #expect(lines.map(plain) == ["wc -l 'a'", "wc -l 'b'"])
    }

    @Test func anInvocationIsShownWithEveryArgumentQuotedSoABoundaryCannotBlur() {
        let plan = FileActionPlan.invocations([
            FileActionInvocation(executable: "gzip", arguments: ["a b", "it's"])
        ])
        let lines = FileActionPlanDisplay.lines(for: plan)
        #expect(lines.map(plain) == ["gzip 'a b' 'it'\\''s'"])
    }

    @Test func aNulInAnArgumentIsMadeVisibleInAnInvocationToo() {
        let plan = FileActionPlan.invocations([
            FileActionInvocation(executable: "gzip", arguments: ["a\u{0}b"])
        ])
        #expect(FileActionPlanDisplay.lines(for: plan).map(plain) == ["gzip 'a<U+0000>b'"])
    }

    @Test func theRefusalSentenceCarriesNoValueFromTheSelection() {
        let hostile = "-evil\u{0}name"
        let refusals: [FileActionPlanner.Refusal] = [
            .valueWouldBeReadAsAnOption(name: "NAME", value: hostile),
            .valueHoldsANulCharacter(name: "NAME", value: hostile),
        ]
        for refusal in refusals {
            let sentence = FileActionPlanDisplay.refusalSentence(for: refusal)
            #expect(sentence.contains("evil") == false)
            #expect(sentence.unicodeScalars.contains("\u{0}") == false)
            #expect(sentence.isEmpty == false)
        }
    }
}
