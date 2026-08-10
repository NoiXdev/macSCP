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

    /// When both reasons hold, the active-transfers line reads first and the
    /// incoming-transfers line second — the user-visible order the caller
    /// relies on. `bothReasonsAreNamedWhenBothHold` only counts the lines,
    /// so it would stay green even if the two `lines.append` calls in
    /// `TabCloseWarning.message` were swapped; this pins the order those two
    /// calls produce.
    @Test func activeTransfersLineComesBeforeIncomingTransfersLine() {
        let text = TabCloseWarning.message(activeTransfers: true, incomingTransfers: true)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        let activeLine = L10n.string(
            "tabs.close.activeTransfers", "Active transfers in this tab will be canceled.")
        let incomingLine = L10n.string(
            "tabs.close.incomingTransfers",
            "Other tabs are streaming to this session; closing cancels those transfers.")

        #expect(lines.count == 2)
        #expect(lines.first.map(String.init) == activeLine)
        #expect(lines.last.map(String.init) == incomingLine)
    }
}
