import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `LivenessDotPlan.appearance(for:)` (connection-liveness
/// plan, Task 5) — the plain, testable mapping the tab strip's liveness dot
/// draws from. No SwiftUI rendering harness exists in this project, so
/// nothing here can prove what actually lands on screen; what it CAN prove,
/// and does, is that every one of the four `ConnectionLiveness` cases maps
/// to a distinct `DesignTokens` color and to its own help/accessibility
/// key, and that `nil` — a real state, not an unreachable one, per
/// `SessionTab.liveness`'s own doc comment — produces no appearance at all.
@Suite("Liveness dot plan")
struct LivenessDotPlanTests {
    @Test func aNilLivenessShowsNoDot() {
        #expect(LivenessDotPlan.appearance(for: nil) == nil)
    }

    @Test func connectingIsAmber() throws {
        let appearance = try #require(LivenessDotPlan.appearance(for: .connecting))
        #expect(appearance.color == DesignTokens.statusAmber)
        #expect(appearance.helpKey == "tabs.liveness.connectingHelp")
        #expect(appearance.accessibilityLabelKey == "tabs.liveness.connectingA11y")
    }

    @Test func connectedIsPhosphor() throws {
        let appearance = try #require(LivenessDotPlan.appearance(for: .connected))
        #expect(appearance.color == DesignTokens.statusPhosphor)
        #expect(appearance.helpKey == "tabs.liveness.connectedHelp")
        #expect(appearance.accessibilityLabelKey == "tabs.liveness.connectedA11y")
    }

    /// `degraded` shares its color with `connecting` — both mean "macSCP
    /// does not know yet" (decision doc, connection-liveness plan) — but
    /// keeps its OWN help/accessibility keys, since "not responding, trying
    /// again" is a different fact from "connecting for the first time" even
    /// when the dot looks the same.
    @Test func degradedSharesConnectingsColorButNotItsText() throws {
        let degraded = try #require(LivenessDotPlan.appearance(for: .degraded))
        let connecting = try #require(LivenessDotPlan.appearance(for: .connecting))
        #expect(degraded.color == connecting.color)
        #expect(degraded.helpKey != connecting.helpKey)
        #expect(degraded.accessibilityLabelKey != connecting.accessibilityLabelKey)
        #expect(degraded.helpKey == "tabs.liveness.degradedHelp")
        #expect(degraded.accessibilityLabelKey == "tabs.liveness.degradedA11y")
    }

    @Test func lostIsRed() throws {
        let appearance = try #require(LivenessDotPlan.appearance(for: .lost))
        #expect(appearance.color == DesignTokens.statusLost)
        #expect(appearance.helpKey == "tabs.liveness.lostHelp")
        #expect(appearance.accessibilityLabelKey == "tabs.liveness.lostA11y")
    }

    /// Every non-nil state's help/accessibility default resolves through the
    /// real catalog rather than falling back silently — the same "known key"
    /// shape `L10nTests.aKnownKeyResolvesInsteadOfFallingBackToTheDefault`
    /// checks for one key at a time, run here across all four states so a
    /// key present in `LivenessDotPlan` but missing from the catalog fails
    /// here instead of only showing up as English text in the running app.
    @Test(arguments: [
        ConnectionLiveness.connecting, .connected, .degraded, .lost,
    ])
    func everyStatesKeysResolveInTheRealCatalog(liveness: ConnectionLiveness) throws {
        let appearance = try #require(LivenessDotPlan.appearance(for: liveness))
        #expect(L10n.string(appearance.helpKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(L10n.string(appearance.accessibilityLabelKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }
}
