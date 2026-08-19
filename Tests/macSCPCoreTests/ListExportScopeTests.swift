import Foundation
import Testing
@testable import macSCPCore

@Suite("ListExportScope")
struct ListExportScopeTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
    }

    @Test func aSelectionThatIsOnScreenNarrowsTheScopeToIt() {
        let rows = [Row(id: 1), Row(id: 2), Row(id: 3)]
        #expect(ListExportScope.resolve(selectedID: 2, from: rows) == [Row(id: 2)])
    }

    @Test func noSelectionMeansEverythingOnScreen() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ListExportScope.resolve(selectedID: nil, from: rows) == rows)
    }

    /// The membership check is the whole point: a row the search has
    /// filtered away is still `selectedID`, and letting it through would
    /// export something the user cannot see.
    @Test func aSelectionFilteredOffScreenDoesNotNarrowTheScope() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ListExportScope.resolve(selectedID: 99, from: rows) == rows)
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(ListExportScope.resolve(selectedID: 1, from: [Row]()) == [])
    }
}
