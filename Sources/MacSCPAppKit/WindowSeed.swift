import Foundation
import macSCPCore

/// What a window opens with — ONE type with TWO uses (Detachable Tabs
/// plan, Tasks 2 and 5).
///
/// SwiftUI's `WindowGroup(for:)` keys each window instance on a value, and
/// `openWindow(value:)` is what opens a second one. This is that value,
/// and the two things a window can be opened FOR are described by two
/// different halves of it:
///
/// **A move (Task 2) fills `tabIDs`.** Those ids name LIVE `SessionTab`
/// objects, parked in `TabRegistry` by the window they are leaving and
/// claimed by the window that appears for this seed
/// (`ContentView.claimSeededTabs()`). The tab keeps its connection, its
/// queue and its terminal across the move because the OBJECT moves; the
/// seed only says which. Those ids mean nothing outside the process that
/// made them.
///
/// **A restoration (Task 5) fills `tabs`.** A `TabSeed` DESCRIBES a tab —
/// the stored session it was showing and the pane visibility it was
/// showing it with — so a later launch can build a NEW, disconnected tab
/// from the description (`ContentView.restoreDescribedWindow()`). Nothing
/// live is referenced, which is exactly why this half survives a quit and
/// the other half cannot.
///
/// The two halves are never both filled, and the code reads that rather
/// than a flag: a claim over an empty `tabIDs` comes back empty, and the
/// restoration step is skipped for an empty `tabs`. A seed carries
/// identifiers and booleans and nothing else — it is written to disk
/// (`WindowRestorationStore`) and persisted by SwiftUI, and a persisted
/// `SessionTab` would be a connection written to a file.
///
/// **`id` exists to defeat window reuse.** A value-keyed `WindowGroup`
/// raises the window it already opened for an EQUAL value instead of
/// opening a new one. A seed is consumed the moment its window appears, so
/// two seeds must never be equal — the second would raise the first window
/// and its tabs would go nowhere. A fresh `id` per seed makes equality
/// per-seed, and it is what the registry parks under
/// (`TabRegistry.park(_:for:from:onClaimed:)` / `claim(seedID:into:)`), so
/// a claim can only ever pick up what THIS move parked. Restoration opens
/// several windows in one pass, where the same rule does the same work.
///
/// The struct body holds stored properties and nothing else — every
/// initializer is in the extension below. That is deliberate:
/// `WindowRestorationWiringGuardTests` reads this body and checks every
/// stored property's TYPE against the identifier-and-boolean set a seed
/// may hold, and a body with function bodies in it could not be read that
/// strictly.
struct WindowSeed: Codable, Hashable, Sendable {
    /// Unique per seed — see the type's doc comment for why equality must
    /// be per-seed rather than per-content.
    let id: UUID
    /// THE MOVE HALF: the live tabs this window takes over from another
    /// one, in the order it should show them. Empty for a restoration.
    var tabIDs: [UUID]
    /// THE RESTORATION HALF: the tabs this window is to rebuild from
    /// scratch, disconnected, in the order it should show them. Empty for
    /// a move.
    var tabs: [TabSeed]
    /// Whether the window floated above the others when it was described
    /// (Task 4's per-window "Keep on Top"). Only a restoration writes it;
    /// a moved tab arrives in a window that has its own answer.
    var keepOnTop: Bool
    /// Whether this description belongs to the window SwiftUI opens by
    /// itself at launch — the seedless one (`ContentView.isPrimaryWindow`).
    ///
    /// A marker is needed because the primary window cannot be opened with
    /// a seed: carrying one is what MAKES a window non-primary, and the
    /// what's-new sheet, the update alert and the frame autosave name all
    /// hang off that. So the primary window's description travels beside
    /// the seed mechanism (`WindowRestorationLaunch`) rather than through
    /// it, and this is how the launch tells which description is its.
    var isPrimary: Bool
}

extension WindowSeed {
    /// A seed for a MOVE: live tab ids, nothing described.
    init(tabIDs: [UUID], id: UUID = UUID()) {
        self.id = id
        self.tabIDs = tabIDs
        self.tabs = []
        self.keepOnTop = false
        self.isPrimary = false
    }

    /// A seed for a RESTORATION: described tabs, no live ids.
    init(tabs: [TabSeed], keepOnTop: Bool, isPrimary: Bool, id: UUID = UUID()) {
        self.id = id
        self.tabIDs = []
        self.tabs = tabs
        self.keepOnTop = keepOnTop
        self.isPrimary = isPrimary
    }

    /// Written by hand so that a seed from BEFORE Task 5 still decodes.
    ///
    /// Two writers persist these: SwiftUI, which keeps the values its
    /// `WindowGroup` was opened with, and `windows.json`, which outlives
    /// upgrades by design. A decode that threw on a missing field would
    /// not be a compatibility wrinkle — it would be a launch that loses
    /// every window it was asked to restore. So the three fields Task 5
    /// added are optional on the wire and default to "a move seed that
    /// floats nowhere and is not the primary window", which is exactly
    /// what a pre-Task-5 seed was.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabIDs = try container.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        tabs = try container.decodeIfPresent([TabSeed].self, forKey: .tabs) ?? []
        keepOnTop = try container.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? false
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }
}

/// One tab, described rather than referenced (Detachable Tabs plan,
/// Task 5).
///
/// This is what a restored tab is built from, and what it may not contain
/// is as much of the design as what it does: no host, no username, no
/// path, and above all no secret. The stored session's id is enough —
/// the session itself is read back out of `sessions-v2.json` at launch, so
/// a description that outlives an edited or deleted session degrades to a
/// plain empty tab instead of resurrecting stale connection details.
///
/// The struct body holds stored properties and nothing else, for the same
/// reason `WindowSeed`'s does.
struct TabSeed: Codable, Hashable, Sendable {
    /// The stored session this tab was showing, or `nil` for a tab that
    /// was on an ad-hoc connection or on an empty form. An ad-hoc
    /// connection is deliberately NOT described any further: it exists
    /// only in the form the user typed it into, and reconstructing it from
    /// a file is how a host and username nobody chose to save would end up
    /// on disk.
    var sessionID: UUID?
    /// Which halves the tab was showing. A restored tab is disconnected
    /// and therefore has no panes yet, so this cannot be applied when the
    /// tab is built; it rides along on the tab
    /// (`SessionTab.restoredPaneVisibility`) until the tab connects, which
    /// is the first moment there is anything to apply it to.
    var paneVisibility: PaneVisibility = .filesOnly
}

extension TabSeed {
    /// Same compatibility rule as `WindowSeed.init(from:)`: a description
    /// missing a field decodes to the default rather than failing the
    /// whole launch. `.filesOnly` is what a session with no recorded
    /// preference already resolves to (`PaneVisibility.filesOnly`), so a
    /// description written before this field existed restores what such a
    /// session would have opened with anyway.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        paneVisibility = try container.decodeIfPresent(
            PaneVisibility.self, forKey: .paneVisibility) ?? .filesOnly
    }
}
