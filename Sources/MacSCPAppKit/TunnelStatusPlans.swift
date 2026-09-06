import SwiftUI
import macSCPCore

/// The colour a set of forwardings is drawn in, as a NAME rather than a
/// `Color` (port-forwarding plan, Task 7).
///
/// The plans below decide the name; the views map it to a token. Two reasons
/// for the split, and the second is the one that made it a type:
///
/// - a `Color` built from `NSColor(name:)` is a dynamic value whose equality
///   is not the thing a test wants to assert about, while `.red == .red` is;
/// - the design's rule is "colour never alone", so every surface that reads a
///   tint also reads a TEXT beside it (`TunnelGlyphPlan.Glyph.text`, the Dock
///   badge's label). Keeping the tint symbolic makes it obvious at every call
///   site that the colour is the second channel, not the only one.
enum TunnelStatusTint: Equatable, Sendable {
    /// Nothing is running and nothing is wrong — every forwarding stopped.
    case grey
    /// At least one forwarding is up and nothing worse is happening.
    case green
    /// Something is on its way, or is waiting for the user: `.connecting`,
    /// `.reconnecting`, `.needsConfirmation`.
    case amber
    /// At least one forwarding failed.
    case red

    /// The design token this tint draws as. `DesignTokens.statusPhosphor` is
    /// the same green the sidebar's own "this row is the active tab" dot
    /// uses, so a running forwarding reads as the same kind of "live" mark.
    var color: Color {
        switch self {
        case .grey: return DesignTokens.inkTertiary
        case .green: return DesignTokens.statusPhosphor
        case .amber: return DesignTokens.statusAmber
        case .red: return DesignTokens.statusLost
        }
    }
}

/// What the sidebar row draws beside a session's name: a tint and the text
/// that carries the same fact without colour.
///
/// `nil` means NOTHING is drawn, and that case is exactly "this session has
/// no forwarding profile at all" — the design's "no glyph when the session
/// has no profile". A session whose profiles are all stopped is a different
/// answer: grey, with no count, because there is something to say.
///
/// **The transient `.connecting` is coalesced with `.reconnecting`**, and
/// that is the whole reason both map to `.amber`. A successful reconnect
/// publishes `.reconnecting(k)` → `.connecting` → `.active(0)`; if the middle
/// state had a colour of its own the row would flash a third colour for one
/// main-actor turn on every recovery. The count does not flash either: a
/// `.connecting` tunnel is not `.active`, and neither is a `.reconnecting`
/// one, so the number is the same across the pair.
enum TunnelGlyphPlan {
    struct Glyph: Equatable, Sendable {
        var tint: TunnelStatusTint
        /// The count of active forwardings, `"!"` when any failed, or `nil`
        /// when there is no number worth drawing (everything stopped, or
        /// everything still on its way).
        var text: String?
    }

    /// The glyph for one session's forwardings, or `nil` when it has none.
    ///
    /// The precedence is `TunnelManager.Aggregate`'s, not a second copy of
    /// it: `worst` is the design's "red > amber > green" order and `active`
    /// is the count both this and the Dock badge are drawn from, so a row
    /// and the Dock can never disagree about how many tunnels are up.
    static func glyph(states: [TunnelState]) -> Glyph? {
        guard !states.isEmpty else { return nil }
        let aggregate = TunnelManager.Aggregate.of(states)
        return Glyph(
            tint: tint(worst: aggregate.worst),
            text: DockBadgePlan.label(
                activeCount: aggregate.active, failedCount: failedCount(states)))
    }

    /// How many of these forwardings are `.failed`. `.needsConfirmation` is
    /// deliberately NOT counted here: it is a question waiting for the user,
    /// not a failure, and it draws amber rather than the red `!`.
    static func failedCount(_ states: [TunnelState]) -> Int {
        states.count(where: { if case .failed = $0 { return true } else { return false } })
    }

    private static func tint(worst: TunnelState?) -> TunnelStatusTint {
        guard let worst else { return .grey }
        switch worst {
        case .stopped: return .grey
        case .active: return .green
        case .connecting, .reconnecting, .needsConfirmation: return .amber
        case .failed: return .red
        }
    }
}

/// The Dock tile's badge text, and nothing else — no AppKit, no `NSApp`.
///
/// `nil` is "no badge at all", which is what the design asks for when
/// nothing is running and nothing failed. The `"!"` outranks the count on
/// purpose: a badge that read `"2"` while a third forwarding was down would
/// be reporting the good news over the bad one.
///
/// **The badge is drawn red by AppKit itself.** `NSDockTile.badgeLabel`
/// renders in the system's own red badge; there is no API to tint it and no
/// custom `contentView` is needed to satisfy the mockup's red `!`. The count
/// therefore sits in the same red badge, which is why the TEXT — a numeral
/// versus `"!"` — is the channel that separates the two states.
enum DockBadgePlan {
    /// `"!"` on any failure, otherwise the active count, otherwise `nil`.
    static func label(activeCount: Int, failedCount: Int) -> String? {
        if failedCount > 0 { return "!" }
        guard activeCount > 0 else { return nil }
        return String(activeCount)
    }

    /// The same label, derived from states — the form both the controller and
    /// the sidebar glyph use, so the two counts come from one reading.
    static func label(states: [TunnelState]) -> String? {
        label(
            activeCount: TunnelManager.Aggregate.of(states).active,
            failedCount: TunnelGlyphPlan.failedCount(states))
    }
}

/// Which autostart moments this launch is allowed to run.
///
/// `.appStart` always: "at app start" means every launch, a login launch
/// included. `.login` only when the launch was a login launch — see
/// `LoginLaunchDetector` for how that is asked and what it cannot answer.
enum LaunchAutoStartPlan {
    static func moments(launchedAsLoginItem: Bool) -> [TunnelProfile.AutoStart] {
        launchedAsLoginItem ? [.appStart, .login] : [.appStart]
    }
}

/// The forwarding block both menus that have no session in front of them —
/// the Dock menu and the menu-bar item — draw.
///
/// It lists a profile on three grounds: it is RUNNING, it asks to start on its
/// own, or it NEEDS ATTENTION. A profile on none of them is reachable from its
/// own session's row, and a Dock menu that listed every profile in the app
/// would be a list of everything the user has ever configured.
///
/// **The third ground came from fix round 1** (review finding I-5), and the
/// hole it closes is one the first two could not see. `DockBadgePlan` counts
/// failures over EVERY profile, so a forwarding started by hand, with
/// `autoStart == .off`, that then failed put `"!"` on the Dock — while this
/// block answered "No forwardings set up" and a header of zero. The badge sent
/// the user to a menu that denied the thing it was shouting about existed.
/// `TunnelStatusPlanTests.everyStateTheBadgeShoutsAboutIsListedInTheBlock`
/// holds the two sides together over every `TunnelState`, rather than over
/// the cases anyone happened to think of.
enum TunnelMenuBlockPlan {
    struct Entry: Equatable, Identifiable, Sendable {
        let profile: TunnelProfile
        let isRunning: Bool
        var id: UUID { profile.id }
    }

    /// Whether this state is one the user has to be told about: a failure, or
    /// a question waiting for them. Neither is running, and both are exactly
    /// what a row in a session-less menu exists to lead to.
    ///
    /// An exhaustive `switch` rather than a two-case `if`: a seventh
    /// `TunnelState` then has to be decided about here instead of silently
    /// falling on the "nothing to see" side.
    static func needsAttention(_ state: TunnelState) -> Bool {
        switch state {
        case .failed, .needsConfirmation: return true
        case .stopped, .connecting, .active, .reconnecting: return false
        }
    }

    static func entries(
        profiles: [TunnelProfile], state: (UUID) -> TunnelState
    ) -> [Entry] {
        profiles.compactMap { profile in
            let current = state(profile.id)
            let running = TunnelManager.Aggregate.isRunning(current)
            guard running || needsAttention(current) || profile.autoStart != .off
            else { return nil }
            return Entry(profile: profile, isRunning: running)
        }
    }
}
