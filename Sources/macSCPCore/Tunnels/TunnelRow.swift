import Foundation

/// One forwarding profile as a LISTING row: what `tunnels list` prints, in
/// columns and as one JSON object per line.
///
/// In Core rather than in the command-line target because the row is a
/// rendering of `TunnelProfile` that has nothing command-line-specific in
/// it — a session's name instead of its id, a kind spelled as a word, a
/// spec in OpenSSH notation — and the app's own profile sheet renders the
/// same four things from the same profile today. It is `Codable` so the
/// `--json` shape is the type rather than a dictionary literal: a renamed
/// property is a visible break here, where a `[String: Any]` would simply
/// print a different key.
///
/// **No state column.** A tunnel's `TunnelState` belongs to whichever
/// process runs it, and the command line cannot see the app's runners (the
/// design's Limits: "A CLI-started tunnel is invisible to the app's glyph
/// and badge"). A column that could only ever print `stopped` would be a
/// claim about another process rather than about the store.
///
/// **No secret**, by the same argument `TunnelProfile` carries: a name, a
/// session's name, a bind address, a port and a host name.
public struct TunnelRow: Codable, Hashable, Sendable {
    /// The forwarding's own name — the handle `tunnels edit`/`rm` take.
    public let name: String
    /// The name of the session it belongs to, not its id: names are what a
    /// person types everywhere else in this tool. The id is on `id` below
    /// for a script that wants the identity.
    public let session: String
    /// `local`, `remote` or `dynamic` — `TunnelProfile.Kind.rowName`.
    public let kind: String
    /// OpenSSH notation, canonical: `TunnelSpec.render(_:)`, bind address
    /// always written out.
    public let spec: String
    /// `off`, `app-start` or `login` — `TunnelProfile.AutoStart.rowName`,
    /// which is the spelling `--autostart` takes, NOT the stored raw value
    /// (see that property).
    public let autostart: String
    public let reconnect: Bool
    /// The profile's own id, printed so a script has the identity the app
    /// stores by. A `String` rather than a `UUID` so the JSON carries the
    /// plain uppercase text `UUID.uuidString` produces, which is what the
    /// store file holds.
    public let id: String

    public init(
        name: String, session: String, kind: String, spec: String,
        autostart: String, reconnect: Bool, id: String
    ) {
        self.name = name
        self.session = session
        self.kind = kind
        self.spec = spec
        self.autostart = autostart
        self.reconnect = reconnect
        self.id = id
    }

    /// The row a stored profile makes, given the name of the session it
    /// belongs to. The session's name is a parameter because a profile
    /// carries only the id, and resolving it is a store read the caller has
    /// already done.
    public init(profile: TunnelProfile, sessionName: String) {
        self.init(
            name: profile.name,
            session: sessionName,
            kind: profile.kind.rowName,
            spec: TunnelSpec.render(profile.kind),
            autostart: profile.autoStart.rowName,
            reconnect: profile.reconnects,
            id: profile.id.uuidString)
    }
}

extension TunnelProfile.Kind {
    /// `local`, `remote` or `dynamic` — the three flag names without their
    /// dashes, and the `kind` column's value.
    ///
    /// Not `Codable`'s case names, though they agree today: those are the
    /// ON-DISK format, pinned by `TunnelProfileTests.localKindJSONShapeIsPinned`
    /// against a change to the enum, and a listing that read them would tie
    /// what a person sees to what a file holds. Exhaustive, so a fourth
    /// shape is spelled here by a person rather than inheriting a name from
    /// its case.
    public var rowName: String {
        switch self {
        case .local: return "local"
        case .remote: return "remote"
        case .dynamic: return "dynamic"
        }
    }
}

extension TunnelProfile.AutoStart {
    /// `off`, `app-start` or `login`: the spelling the command line takes on
    /// `--autostart` and prints in the `autostart` column.
    ///
    /// It DIVERGES from `rawValue` in exactly one case and on purpose:
    /// the raw values are the synthesized case names — `off`, `appStart`,
    /// `login`, read from `TunnelProfile.AutoStart` on 2026-09-06 — and
    /// `appStart` is not a word anybody types at a shell. The raw value is
    /// the on-disk format and stays as it is; this is the human one.
    /// Exhaustive rather than a transformation of the case name, so a
    /// fourth choice is a decision somebody makes rather than whatever
    /// hyphenating an identifier happens to produce.
    public var rowName: String {
        switch self {
        case .off: return "off"
        case .appStart: return "app-start"
        case .login: return "login"
        }
    }

    /// The choice `text` spells, or `nil` — derived from `rowName` over
    /// `allCases` rather than a second switch, so the two directions cannot
    /// disagree.
    public init?(rowName text: String) {
        guard let match = Self.allCases.first(where: { $0.rowName == text }) else { return nil }
        self = match
    }
}
