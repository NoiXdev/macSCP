import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// `WindowSeed`'s two uses and its wire format (Detachable Tabs plan,
/// Task 5).
///
/// The seed is ONE type with two jobs, and the tests below are written so
/// that neither job can quietly take the other's data:
///
/// - **The move path** fills `tabIDs` and leaves `tabs` empty. Those ids
///   name LIVE `SessionTab` objects parked in `TabRegistry`; they mean
///   nothing outside the process that made them.
/// - **The restoration path** fills `tabs` and leaves `tabIDs` empty. A
///   `TabSeed` DESCRIBES a tab — a stored session's id and the pane
///   visibility it was showing — so that a later launch can build a new,
///   disconnected tab from the description.
///
/// The old-shape decode case is the compatibility pin: a `windows.json`
/// or a SwiftUI-persisted value written before this task carries neither
/// `tabs` nor `keepOnTop` nor `isPrimary`, and must still decode.
@Suite("WindowSeed — the seed's two uses and its wire format")
struct WindowSeedTests {
    private static func roundTrip(_ seed: WindowSeed) throws -> WindowSeed {
        let data = try JSONEncoder().encode(seed)
        return try JSONDecoder().decode(WindowSeed.self, from: data)
    }

    // MARK: - The two uses

    @Test func aMoveSeedCarriesLiveTabIDsAndDescribesNothing() {
        let ids = [UUID(), UUID()]
        let seed = WindowSeed(tabIDs: ids)
        #expect(seed.tabIDs == ids)
        #expect(seed.tabs.isEmpty, """
            a seed built for a MOVE must describe no tabs — a described tab \
            is rebuilt from scratch at launch, and rebuilding one whose live \
            object is being handed over would duplicate it
            """)
        #expect(seed.keepOnTop == false)
        #expect(seed.isPrimary == false)
    }

    @Test func aRestorationSeedDescribesTabsAndNamesNoLiveOnes() {
        let sessionID = UUID()
        let seed = WindowSeed(
            tabs: [TabSeed(sessionID: sessionID, paneVisibility: .bothVisible)],
            keepOnTop: true, isPrimary: true)
        #expect(seed.tabIDs.isEmpty, """
            a seed built for RESTORATION must name no live tab ids — those \
            ids belong to a process that has ended, and a window claiming \
            them would claim whatever a later process gave the same id
            """)
        #expect(seed.tabs.count == 1)
        #expect(seed.tabs[0].sessionID == sessionID)
        #expect(seed.tabs[0].paneVisibility == PaneVisibility.bothVisible)
        #expect(seed.keepOnTop)
        #expect(seed.isPrimary)
    }

    // MARK: - Round trip

    @Test func aRestorationSeedRoundTripsThroughJSON() throws {
        let seed = WindowSeed(
            tabs: [
                TabSeed(sessionID: UUID(), paneVisibility: .terminalOnly),
                TabSeed(sessionID: nil, paneVisibility: .filesOnly),
            ],
            keepOnTop: true, isPrimary: true)
        #expect(try Self.roundTrip(seed) == seed)
    }

    @Test func aMoveSeedRoundTripsThroughJSON() throws {
        let seed = WindowSeed(tabIDs: [UUID(), UUID()])
        #expect(try Self.roundTrip(seed) == seed)
    }

    // MARK: - The old shape still decodes

    /// A value written before Task 5 has `id` and `tabIDs` and nothing
    /// else. SwiftUI persists `WindowSeed`s of its own accord and this
    /// task's own `windows.json` will outlive several versions of this
    /// struct, so a decode that threw here would not be a compatibility
    /// wrinkle — it would be a launch that loses every window it was
    /// asked to restore.
    @Test func aSeedWrittenBeforeThisTaskStillDecodesWithDefaults() throws {
        let id = UUID()
        let tabID = UUID()
        let json = """
            {"id":"\(id.uuidString)","tabIDs":["\(tabID.uuidString)"]}
            """
        let decoded = try JSONDecoder().decode(WindowSeed.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.tabIDs == [tabID])
        #expect(decoded.tabs.isEmpty)
        #expect(decoded.keepOnTop == false)
        #expect(decoded.isPrimary == false)
    }

    /// The other half of the same compatibility question: a `TabSeed`
    /// written without a pane visibility (a field a later version could
    /// add beside it) resolves to the same default a session with no
    /// recorded preference gets.
    @Test func aTabSeedWithoutAPaneVisibilityDecodesToFilesOnly() throws {
        let sessionID = UUID()
        let json = """
            {"sessionID":"\(sessionID.uuidString)"}
            """
        let decoded = try JSONDecoder().decode(TabSeed.self, from: Data(json.utf8))
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.paneVisibility == PaneVisibility.filesOnly)
    }

    // MARK: - Equality still defeats window reuse

    /// `WindowSeed.id` is why a value-keyed `WindowGroup` opens a second
    /// window instead of raising the first — see the type's doc comment.
    /// Restoration opens several windows in one pass, so this matters more
    /// here than it did for a single move.
    @Test func twoSeedsDescribingTheSameTabsAreNotEqual() {
        let described = [TabSeed(sessionID: UUID(), paneVisibility: .filesOnly)]
        let first = WindowSeed(tabs: described, keepOnTop: false, isPrimary: false)
        let second = WindowSeed(tabs: described, keepOnTop: false, isPrimary: false)
        #expect(first != second)
    }
}
