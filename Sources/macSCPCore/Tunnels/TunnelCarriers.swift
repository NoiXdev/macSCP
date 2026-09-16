import Foundation

/// Which connection kinds can carry a port forwarding, and what a session
/// that cannot is told.
///
/// One place, because the answer is needed at more than one moment: before
/// anything is dialled, while it is dialled, and after. Recounted 2026-09-06
/// with `grep -rn "TunnelCarriers\." Sources/`, THREE call sites hold it —
/// `TunnelConnection.connect`, which throws `refusalError`'s value
/// (`TunnelConnection.swift:82` since 2026-09-16), `SessionRowTunnelMenuPlan.build`, which
/// hides the session row's forwarding submenu when there is one
/// (`SessionSidebar.swift:185`), and
/// `TunnelTargetOptions.requireItCanCarryAForwarding`, which is `tunnels
/// add`'s refusal before anything is written
/// (`Sources/MacSCPCLI/TunnelsCommand.swift:263`). The third one had been
/// named here as planned rather than present; it arrived with the `tunnels`
/// subcommand on the same day, and its line number here said 252 until
/// 2026-09-07, when the same grep was run again: still three call sites,
/// the first two still on the lines named above, the third on 263.
///
/// The sidebar's was a second copy of the three predicates until 2026-09-06,
/// and the copy was silent rather than merely redundant: with
/// `carries(.s3)` mutated to `true`, `TunnelMenuWiringGuardTests` stayed
/// green through all 16 of its tests. A rule this small drifts by wording
/// long before it drifts by outcome, and a refusal that words itself
/// differently in three places reads as three different rules.
public enum TunnelCarriers {
    /// Whether a forwarding can be carried over a connection of this kind.
    ///
    /// Exhaustive on purpose — no `default`. There is no `direct-tcpip` over
    /// S3 or WebDAV, and a fourth backend must answer this question here
    /// rather than inherit `false` from a wildcard nobody revisits.
    public static func carries(_ kind: ConnectionKind) -> Bool {
        switch kind {
        case .ssh: return true
        case .s3, .webdav: return false
        }
    }

    /// Why this stored session cannot carry a forwarding, or `nil` when it
    /// can.
    ///
    /// The three rules, and the order they are asked in, are
    /// `TunnelConnection.connect`'s — which throws exactly this refusal
    /// rather than deciding the same rules a second time. The order is the
    /// one `StoredSessionConnectionConfig.build` enforces (login set, then
    /// jump), with the protocol rule last because it is the one `build` does
    /// not answer; a session can trip more than one, and the refusal must
    /// name the rule the dial would actually stop at.
    ///
    /// Contains no secret: a session's name, its protocol, and the fact that
    /// it has a login set or a jump host. Not the jump's host name, not a
    /// login set's contents.
    public static func refusalError(for session: StoredSession) -> TunnelRefusal? {
        if session.loginSetID != nil {
            return .loginSet(session: session.name)
        }
        if session.jump != nil {
            return .jumpHost(session: session.name)
        }
        guard carries(session.kind) else {
            return .notSSH(session: session.name, connectionKind: session.kind)
        }
        return nil
    }

    /// The same refusal as its English sentence — `DialSupport.reason(for:)`
    /// of it, which is what the diagnostic log writes when the dial throws
    /// it, so the command line's refusal before anything is written and the
    /// log line of a failed dial cannot word the same rule differently.
    public static func refusal(for session: StoredSession) -> String? {
        refusalError(for: session).map { DialSupport.reason(for: $0) }
    }
}
