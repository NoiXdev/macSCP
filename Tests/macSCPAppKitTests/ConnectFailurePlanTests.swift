import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `ConnectFailurePlan.content(hasStoredSession:)`
/// (planned failed-connect surface, Task 2) — the plain, testable decision
/// behind what a failed connect attempt says and which actions it offers.
/// Nothing in this project renders SwiftUI, so this cannot prove what lands
/// on screen; what it CAN prove, and does, is the mapping itself: the
/// general message stays fixed, and exactly one of the four actions
/// (`editSessionButton`) toggles on the one fact the caller supplies.
///
/// Mirrors `ReconnectPlanTests`' "LostConnectionPlan" section for the same
/// reason: a value that decides which actions appear can be wrong by
/// offering too many just as easily as too few, so both directions of
/// `hasStoredSession` are checked, plus the exhaustive catalog-key sweep
/// that pins the surface's structural safety (`ConnectFailureContent` has
/// no field a host name, a server message, or a form value could occupy —
/// see that type's own doc comment).
@Suite("Connect failure plan")
struct ConnectFailurePlanTests {
    /// All four actions appear when the failed attempt started from a
    /// stored session. A test that only checked `editSessionButton` here
    /// would not catch a mutation that also dropped one of the other three
    /// under this same condition — so every button's key is asserted.
    @Test func allFourActionsAppearWithAStoredSession() {
        let content = ConnectFailurePlan.content(hasStoredSession: true)
        #expect(content.retryButton.key == "connection.failed.retry")
        #expect(content.editButton.key == "connection.failed.edit")
        #expect(content.editSessionButton?.key == "connection.failed.editSession")
        #expect(content.closeButton.key == "connection.failed.close")
    }

    /// The other direction: an ad-hoc connection, never saved, has nothing
    /// stored to edit for good — `editSessionButton` is absent — while the
    /// three actions that make sense regardless are still there. Checked
    /// together with the test above, a mutation that swapped which
    /// `hasStoredSession` value turns `editSessionButton` on would fail
    /// exactly one of the two.
    @Test func editSessionIsAbsentForAnAdHocConnection() {
        let content = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(content.editSessionButton == nil)
        #expect(content.retryButton.key == "connection.failed.retry")
        #expect(content.editButton.key == "connection.failed.edit")
        #expect(content.closeButton.key == "connection.failed.close")
    }

    /// The design spec's own point (§ "Die Fläche"): the surface carries
    /// one general message, not one text per case. Whether the attempt
    /// started from a stored session must not change the title or body —
    /// only which actions are offered changes.
    @Test(arguments: [true, false])
    func theGeneralMessageDoesNotDependOnWhetherASessionIsStored(hasStoredSession: Bool) {
        let content = ConnectFailurePlan.content(hasStoredSession: hasStoredSession)
        #expect(content.title.key == "connection.failed.title")
        #expect(content.body.key == "connection.failed.body")
    }

    /// The structural safety property, checked the same way
    /// `ReconnectPlanTests.everyReachableMessageComesFromTheFixedCatalogKeySet`
    /// checks it for `LostConnectionContent`: every message this plan can
    /// produce, across both `hasStoredSession` values, must be one of a
    /// fixed, enumerated set of catalog keys. A future edit that
    /// interpolated a host name or a raw error string into any of them
    /// would have to invent a key outside this set, or change one of these
    /// strings, and either fails here.
    ///
    /// Six keys, counted while writing this sentence: title, body, and the
    /// four action labels.
    @Test func everyReachableMessageComesFromTheFixedCatalogKeySet() {
        let allowedKeys: Set<String> = [
            "connection.failed.title",
            "connection.failed.body",
            "connection.failed.retry",
            "connection.failed.edit",
            "connection.failed.editSession",
            "connection.failed.close",
        ]
        var seen: Set<String> = []
        for hasStoredSession in [true, false] {
            let content = ConnectFailurePlan.content(hasStoredSession: hasStoredSession)
            let messages =
                [content.title, content.body, content.retryButton, content.editButton, content.closeButton]
                + [content.editSessionButton].compactMap { $0 }
            for message in messages {
                #expect(allowedKeys.contains(message.key), """
                    `\(message.key)` is not one of the keys this surface is allowed \
                    to show. Every string on the failed-connect surface must be a fixed \
                    catalog entry, matching the design spec's rule for the surface's \
                    sibling (`LostConnectionContent`).
                    """)
                #expect(!message.fallback.isEmpty)
                seen.insert(message.key)
            }
        }
        #expect(seen == allowedKeys, """
            the enumerated key set and the keys actually reachable from \
            `ConnectFailurePlan.content` have diverged: only \(seen.sorted()) were produced.
            """)
    }
}
