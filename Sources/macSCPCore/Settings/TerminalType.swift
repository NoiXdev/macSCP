import Foundation

/// The terminal type a shell is opened with: the name the server is told in
/// the SSH pty request, which it exports as `TERM`.
///
/// The name only tells the server what to send. The emulator stays
/// SwiftTerm's, an xterm-class emulator, whatever is chosen here — so only
/// names whose terminfo entries SwiftTerm honours are offered. The reading
/// behind this list is recorded in the Task 4 report of the plan of
/// 2026-09-19 ("Diagnostics and terminal wishes"): `linux`, `screen` and
/// `tmux` were read and left out, because their terminfo entries expect key
/// sequences SwiftTerm does not send (Home, End, F1–F5) and, for `linux`, a
/// palette sequence SwiftTerm's parser would read as an unterminated OSC.
///
/// The raw value is the name itself, so it is what `settings.json` and a
/// stored session's SSH block carry.
public enum TerminalType: String, Codable, CaseIterable, Sendable {
    /// 256 colours. What every shell opened with before this setting
    /// existed, and still the default.
    case xterm256Color = "xterm-256color"
    /// Eight colours; otherwise the same capabilities as `xterm256Color`.
    case xterm
    /// No colours and a VT100's reduced capability set.
    case vt100

    /// The type used when neither the session nor the settings name one.
    public static let `default`: TerminalType = .xterm256Color

    /// The type a shell opens with: the session's own override when it has
    /// one, otherwise the global setting, otherwise `default`.
    public static func resolved(
        sessionOverride: TerminalType?, global: TerminalType?
    ) -> TerminalType {
        sessionOverride ?? global ?? .default
    }

    /// The override of the stored session `id` names, or `nil` — "use the
    /// global setting" — when `id` is `nil`, names no session in
    /// `sessions`, or names one without an override. What the app feeds
    /// `resolved(sessionOverride:global:)` from a tab's connected session.
    public static func sessionOverride(
        of id: UUID?, in sessions: [StoredSession]
    ) -> TerminalType? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }?.ssh?.terminalType
    }
}
