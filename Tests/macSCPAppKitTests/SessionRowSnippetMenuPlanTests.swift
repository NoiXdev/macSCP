import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// Pins `SessionRowSnippetMenuPlan.build`, the routing decision behind a
/// session row's "Snippet" context-menu entry (Terminal-Snippets milestone,
/// Task 7): a sidebar row is not necessarily the active tab, and this type
/// decides what the row is allowed to act on. See its own doc comment for
/// the full reasoning — this suite only proves `build`'s three outcomes
/// (`.backendHasNoShell`, `.notTheActiveTab`, `.active`) map to the right
/// inputs, not what `SessionRow` draws for each (view code, no pixel harness
/// in this project).
@Suite("SessionRowSnippetMenuPlan")
struct SessionRowSnippetMenuPlanTests {
    private func snippet(_ name: String) -> Snippet {
        Snippet(name: name, command: "echo \(name)")
    }

    @Test func aShellLessBackendWinsRegardlessOfTabState() {
        let storeOrder = [snippet("a")]

        let whileActive = SessionRowSnippetMenuPlan.build(
            snippets: storeOrder, isActiveTab: true, supportsShell: false)
        let whileInactive = SessionRowSnippetMenuPlan.build(
            snippets: storeOrder, isActiveTab: false, supportsShell: false)

        #expect(whileActive == .backendHasNoShell)
        #expect(whileInactive == .backendHasNoShell)
    }

    /// The exact routing decision this task had to make: a session that CAN
    /// have a shell but is not the tab on screen right now must not silently
    /// resolve to `.active` — that would be the "wrong host" risk the task
    /// brief calls out. It must land on the explicit, disabled reason.
    @Test func aShellCapableBackendThatIsNotTheActiveTabIsDisabledWithAReason() {
        let plan = SessionRowSnippetMenuPlan.build(
            snippets: [snippet("a")], isActiveTab: false, supportsShell: true)

        #expect(plan == .notTheActiveTab)
    }

    @Test func theActiveConnectedTabRendersTheSharedModel() {
        let storeOrder = [snippet("a"), snippet("b")]

        let plan = SessionRowSnippetMenuPlan.build(
            snippets: storeOrder, isActiveTab: true, supportsShell: true)

        let expected = SnippetMenuModel.build(
            snippets: storeOrder, isConnected: true, supportsShell: true)
        #expect(plan == .active(expected))
    }

    /// Nothing about `.active`'s payload should itself carry a disabled
    /// reason: the row IS the active, connected tab and the backend HAS a
    /// shell, so `SnippetMenuModel.build`'s own `isConnected`/`supportsShell`
    /// inputs must both be `true` — never re-derived from `isActiveTab`
    /// alone in a way that could drop this.
    @Test func theActivePlansModelCarriesNoDisabledReason() {
        guard case .active(let model) = SessionRowSnippetMenuPlan.build(
            snippets: [snippet("a")], isActiveTab: true, supportsShell: true)
        else {
            Issue.record("expected .active")
            return
        }
        #expect(model.disabledReason == nil)
    }

    @Test func isBackendHasNoShellIsTrueOnlyForThatCase() {
        #expect(SessionRowSnippetMenuPlan.backendHasNoShell.isBackendHasNoShell)
        #expect(!SessionRowSnippetMenuPlan.notTheActiveTab.isBackendHasNoShell)
        let model = SnippetMenuModel.build(snippets: [], isConnected: true, supportsShell: true)
        #expect(!SessionRowSnippetMenuPlan.active(model).isBackendHasNoShell)
    }

    // MARK: - Catalog resolution

    /// The two new keys this task adds — a missing key would render as its
    /// own literal string in the menu rather than fail a build, same guard
    /// shape as `SnippetsPresentationTests.theTerminalMenuNoticesResolveFromTheCatalog`.
    @Test func theSnippetSubmenuNoticesResolveFromTheCatalog() {
        #expect(L10n.string("sidebar.snippets", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(
            L10n.string("sidebar.snippets.onlyActiveTab", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }
}
