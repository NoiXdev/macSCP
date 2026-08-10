import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("TabCloseWarning")
struct TabCloseWarningTests {
    /// Both reasons can hold at once, and when they do the user sees both —
    /// one per line. A message that named only the first would leave them
    /// guessing which of the two applied.
    @Test func bothReasonsAreNamedWhenBothHold() {
        let text = TabCloseWarning.message(activeTransfers: true, incomingTransfers: true)

        #expect(text.split(separator: "\n").count == 2)
    }

    /// Neither reason holds: the message is empty, not a stray newline. The
    /// caller decides whether to show a dialog at all; an "empty" message
    /// that is actually "\n" makes an empty dialog look like a real warning.
    @Test func noReasonMeansNoText() {
        #expect(TabCloseWarning.message(activeTransfers: false, incomingTransfers: false).isEmpty)
    }

    /// One reason each, in isolation — proves the two lines are independent
    /// rather than one string that happens to contain both.
    @Test func eachReasonStandsAlone() {
        let active = TabCloseWarning.message(activeTransfers: true, incomingTransfers: false)
        let incoming = TabCloseWarning.message(activeTransfers: false, incomingTransfers: true)

        #expect(!active.isEmpty)
        #expect(!incoming.isEmpty)
        #expect(active != incoming)
    }
}
