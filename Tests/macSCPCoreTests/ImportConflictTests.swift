import Foundation
import Testing
@testable import macSCPCore

// Reuses the module-level `Counter` actor already declared in
// TerminalPanelViewModelTests.swift rather than adding a second one.
@Suite("ImportConflictArbiter")
struct ImportConflictTests {
    @Test func asksOncePerConflictWithoutApplyToAll() async {
        let asked = Counter()
        let arbiter = ImportConflictArbiter { _ in
            await asked.increment()
            return (.skip, false)
        }
        _ = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        _ = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(await asked.value == 2)
    }

    @Test func applyToAllAnswersEveryFurtherConflictWithoutAsking() async {
        let asked = Counter()
        let arbiter = ImportConflictArbiter { _ in
            await asked.increment()
            return (.replace, true)
        }
        let first = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        let second = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(first == .replace)
        #expect(second == .replace)
        #expect(await asked.value == 1)
    }

    @Test func nilCancelsAndStaysCancelled() async {
        let arbiter = ImportConflictArbiter { _ in nil }
        #expect(await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set")) == nil)
        #expect(await arbiter.isCancelled)
    }
}
