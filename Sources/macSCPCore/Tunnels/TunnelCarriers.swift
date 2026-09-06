import Foundation

/// Which connection kinds can carry a port forwarding, and what a session
/// that cannot is told.
///
/// One place, because the answer is needed at more than one moment: before
/// anything is dialled, while it is dialled, and after. Recounted 2026-09-06
/// with `grep -rn "TunnelCarriers\." Sources/`, THREE call sites hold it —
/// `TunnelConnection.connect`, which throws `refusal`'s sentence
/// (`TunnelConnection.swift:79`), `SessionRowTunnelMenuPlan.build`, which
/// hides the session row's forwarding submenu when there is one
/// (`SessionSidebar.swift:185`), and
/// `TunnelTargetOptions.requireItCanCarryAForwarding`, which is `tunnels
/// add`'s refusal before anything is written
/// (`Sources/MacSCPCLI/TunnelsCommand.swift:252`). The third one had been
/// named here as planned rather than present; it arrived with the `tunnels`
/// subcommand on the same day.
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
    /// `TunnelConnection.connect`'s — which now throws exactly this sentence
    /// rather than wording the same refusals a second time. The order is the
    /// one `StoredSessionConnectionConfig.build` enforces (login set, then
    /// jump), with the protocol rule last because it is the one `build` does
    /// not answer; a session can trip more than one, and the sentence must
    /// name the rule the dial would actually stop at.
    ///
    /// Contains no secret: a session's name, its protocol, and the fact that
    /// it has a login set or a jump host. Not the jump's host name, not a
    /// login set's contents.
    public static func refusal(for session: StoredSession) -> String? {
        if session.loginSetID != nil {
            return "session \(session.name) belongs to a login set; "
                + "forwardings dial with the session's own login"
        }
        if session.jump != nil {
            return "session \(session.name) uses a jump host; "
                + "forwardings cannot dial through one"
        }
        guard carries(session.kind) else {
            return "session \(session.name) is \(namedWithArticle(session.kind)) session; "
                + "forwardings need SSH"
        }
        return nil
    }

    /// The backend's own English name with the article that fits it.
    ///
    /// The name comes from the descriptor — the one place each backend is
    /// spelled in English — and only the article is decided here. It follows
    /// PRONUNCIATION rather than spelling: "S3" is said "ess-three", so it
    /// takes "an" though it begins with a consonant letter, while "WebDAV"
    /// takes "a". A rule over the first letter would get one of those two
    /// wrong whichever way it was written, so this is an exhaustive switch:
    /// a fourth backend's label needs the judgement made by a person, and
    /// the compiler is what asks for it.
    private static func namedWithArticle(_ kind: ConnectionKind) -> String {
        let label = BackendDescriptor.descriptor(for: kind).badgeLabelDefault
        switch kind {
        case .ssh, .s3: return "an \(label)"
        case .webdav: return "a \(label)"
        }
    }
}
