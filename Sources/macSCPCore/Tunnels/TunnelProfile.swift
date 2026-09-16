import Foundation

/// A stored port-forwarding profile: what to forward, from where, and when
/// to start it without being asked. Belongs to a session (`sessionID`) the
/// way a `StoredSession.JumpSpec` belongs to one — contains NO secret. A
/// running tunnel's SSH connection is authenticated through the session's
/// own stored login at connect time, through the existing
/// `SecretSource`/`SecretResolver` path, never through anything stored
/// here.
public struct TunnelProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var name: String
    public var kind: Kind
    public var autoStart: AutoStart
    /// Exponential backoff (`BackoffPlan`: 2 s doubling, capped at 60 s) on
    /// connection loss when true; a lost connection is reported `.failed`
    /// once, with no retry, when false.
    public var reconnects: Bool

    public init(
        id: UUID = UUID(), sessionID: UUID, name: String, kind: Kind,
        autoStart: AutoStart = .off, reconnects: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.kind = kind
        self.autoStart = autoStart
        self.reconnects = reconnects
    }

    /// The three forwarding shapes, in the user's own words from the
    /// design's table:
    ///
    /// | Kind | Listener | Per accepted connection |
    /// |---|---|---|
    /// | `local` (`-L`) | on this Mac, `bind:localPort` (default `127.0.0.1`) | a `direct-tcpip` child channel to `host:remotePort` behind the server; bytes pumped both ways |
    /// | `remote` (`-R`) | on the server, `bind:remotePort` (default `127.0.0.1` there; `0.0.0.0` needs the server's `GatewayPorts`) | the server's `forwarded-tcpip` channel is connected to `localHost:localPort` on this Mac |
    /// | `dynamic` (`-D`) | on this Mac, a SOCKS5 server (no auth; CONNECT; IPv4, IPv6, domain) at `bind:localPort` | a `direct-tcpip` channel to the destination the SOCKS client named |
    ///
    /// `Codable` is the compiler-synthesized conformance — an
    /// enum-with-associated-values, every case fully labeled, encodes as a
    /// single-key object keyed by the case name, its payload a NESTED
    /// KEYED object with one key per parameter label (not an array):
    /// `.local(bind: "127.0.0.1", localPort: 8080, host: "internal",
    /// remotePort: 80)` encodes as `{"local":{"bind":"127.0.0.1",
    /// "host":"internal","localPort":8080,"remotePort":80}}` (key order
    /// alphabetical only because the encoder that produced this example
    /// asked for `.sortedKeys`). `TunnelProfileTests
    /// .localKindJSONShapeIsPinned` pins the exact shape, so a future
    /// change to this enum — a renamed case, a renamed or dropped
    /// parameter label — is a visible, reviewed decision rather than a
    /// silent format break.
    public enum Kind: Codable, Hashable, Sendable {
        /// Local → remote (`-L`): this Mac listens on `bind:localPort` and
        /// forwards each accepted connection, through the server, to
        /// `host:remotePort` as the server reaches it.
        case local(bind: String, localPort: Int, host: String, remotePort: Int)
        /// Remote → local (`-R`): the SERVER listens on `bind:remotePort`
        /// and forwards each connection it accepts back to
        /// `localHost:localPort` on this Mac.
        case remote(bind: String, remotePort: Int, localHost: String, localPort: Int)
        /// Dynamic (`-D`): this Mac runs a SOCKS5 server on `bind:localPort`;
        /// each accepted connection is forwarded, through the server, to
        /// whatever destination the SOCKS client named.
        case dynamic(bind: String, localPort: Int)
    }

    /// When a profile is started without anyone asking for it that moment.
    public enum AutoStart: String, Codable, CaseIterable, Sendable {
        /// Never started automatically — only from the context menu.
        case off
        /// Started once, when the app launches.
        case appStart
        /// Started at login, independent of the app's own launch (ties into
        /// the login-item toggle in the App layer; Core only records the
        /// choice).
        case login
    }
}

/// The live state of a tunnel — the value `TunnelStatePlan.next(_:on:)`
/// computes transitions between. Pure data: nothing here starts, stops, or
/// observes anything by itself.
public enum TunnelState: Sendable, Equatable {
    case stopped
    case connecting
    case active(connections: Int)
    case reconnecting(attempt: Int)
    /// Why, as a value: the kind and the data a sentence needs, never the
    /// sentence. The App translates it (`TunnelProfilesSheet.stateLabel`);
    /// the diagnostic log writes the English sentence from the same switch
    /// (`DialSupport.failureKind(for:)` / `reason(for:)`). No raw error's
    /// description and no secret — see `TunnelFailureKind`.
    ///
    /// Not persisted: `TunnelState` is not `Codable`, and `TunnelStore`
    /// writes profiles only.
    case failed(TunnelFailureKind)
    /// Autostart met an unknown host key or a session with no stored secret
    /// and refused rather than prompt (the `.refusing` host-key decider).
    /// Resolved only by connecting the session once, by hand, in a window.
    case needsConfirmation
}
