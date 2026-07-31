import Testing
@testable import macSCPCore

@Suite("TerminalCursorStyle")
struct TerminalCursorStyleTests {
    @Test func rawValuesAreStable() {
        #expect(TerminalCursorStyle.block.rawValue == "block")
        #expect(TerminalCursorStyle.bar.rawValue == "bar")
        #expect(TerminalCursorStyle.underline.rawValue == "underline")
        #expect(TerminalCursorStyle.allCases.count == 3)
    }

    @Test func sixCursorCombinationsAreDistinct() {
        // The (style, blink) pair is the app-layer's mapping input to
        // SwiftTerm's six cursor modes — pin that all six pairs exist and
        // are distinguishable.
        var seen = Set<String>()
        for style in TerminalCursorStyle.allCases {
            for blink in [true, false] {
                seen.insert("\(style.rawValue)-\(blink)")
            }
        }
        #expect(seen.count == 6)
    }
}
