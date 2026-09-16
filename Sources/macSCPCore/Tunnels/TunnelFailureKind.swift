import Foundation

/// Why a forwarding failed, as a value: the case and the data a sentence
/// about it needs, never the sentence itself.
///
/// `TunnelState.failed` carries this rather than text (maintainer decision,
/// 2026-09-16: "the state carries the failure kind, the App translates in
/// four languages, the log keeps the English sentence"). Before, the state
/// carried `DialSupport.reason(for:)`'s rendered English, and the App had
/// nothing left to translate: the case identity was gone by the time the
/// sentence reached it.
///
/// **What a payload may hold**: a host name, a file path, an algorithm
/// name, a session name, a connection kind, a port — each one something the
/// diagnostic log already carries in the same sentence. Never a secret,
/// never a host-key fingerprint (the pem-private-keys design, "Decisions
/// 2026-09-16" (d)), and never a foreign error's description: that text is
/// exactly what `DialSupport.reason(for:)` falls back to for an error it
/// does not know, and it is why `TunnelFailure`, whose four `reason:`
/// payloads can hold it, is not what the state carries.
///
/// Built by `DialSupport.failureKind(for:)`, from the same switch that
/// renders the log's `reason=` sentence — so the log line and the state
/// cannot describe two different failures.
public enum TunnelFailureKind: Sendable, Equatable {
    /// The server presented a key that differs from the recorded one. The
    /// TOFU hard stop; never a confirmation.
    case hostKeyMismatch(host: String)
    /// The host key is unknown and was not accepted.
    case hostKeyNotAccepted
    /// The server refused every credential offered.
    case authenticationFailed
    /// The session's key file is not there.
    case keyFileNotFound(path: String)
    /// The key is encrypted and no passphrase was available.
    case keyPassphraseRequired
    /// The key's passphrase was wrong.
    case keyPassphraseRejected
    /// The key file does not parse.
    case keyUnparsable
    /// The key parses, but this app cannot load a key of its type.
    case keyTypeNotLoadable(algorithm: String)
    /// A PEM key uses a feature this app does not read.
    case keyPEMNotReadable
    /// No ssh-agent answered.
    case agentUnavailable
    /// The ssh-agent holds no identities.
    case agentHasNoIdentities
    /// The ssh-agent holds no identity of a type this app can offer.
    case agentHasNoUsableIdentity
    /// The server refused every identity the ssh-agent offered.
    case agentRefusedEveryIdentity
    /// The ssh-agent connection misbehaved.
    case agentMisbehaved
    /// The Keychain answered the secret lookup with an error.
    case keychainUnreadable
    /// The connection to the server failed — refused, timed out,
    /// unreachable. One case, because the dial reports all three as the same
    /// `RemoteFSError.connectionFailed` with free text, and the text is not
    /// a channel.
    case connectionFailed
    /// The server answered something this app could not use.
    case serverAnswerUnusable
    /// The session is bound to a login set; a forwarding dials with the
    /// session's own login.
    case sessionUsesLoginSet(session: String)
    /// The session dials through a jump host, which a forwarding cannot.
    case sessionUsesJumpHost(session: String)
    /// The session is not an SSH session.
    case sessionIsNotSSH(session: String, connectionKind: ConnectionKind)
    /// The session this forwarding belongs to no longer exists.
    case sessionMissing
    /// The local port the forward wants is taken.
    case portInUse(port: Int)
    /// The forward could not start listening — locally, or on the server for
    /// a remote forward whose failure has no case of its own below.
    case bindFailed
    /// The server could not open the channel for a forwarded connection.
    case channelOpenFailed
    /// A connection this machine made for the forward failed.
    case connectFailed
    /// A forwarded connection was opened and could not be wired up.
    case pumpFailed
    /// A forward was started twice. Not a condition a user can be in.
    case alreadyStarted
    /// A remote forward named port `0`, which this client refuses.
    case remotePortZeroRefused
    /// The server refused to listen for a remote forward. `needsGatewayPorts`
    /// is true when the bind address is not loopback — the server then needs
    /// its `GatewayPorts` setting. No server text is carried.
    case remoteBindRefused(needsGatewayPorts: Bool)
    /// The server did not answer the remote forward's request.
    case remoteForwardUnanswered
    /// The forwarding's connection dropped on a profile that does not
    /// reconnect.
    case connectionLost
    /// Anything else. The log line carries what is known about it.
    case unknown

    /// The payload-free name of a kind: what a catalogue key is derived
    /// from, and what a test iterates when it has to reach every kind.
    ///
    /// `CaseIterable` so the list is the compiler's, never a hand-kept one;
    /// `name` below is an exhaustive switch, so a case added above without a
    /// name here does not compile.
    public enum Name: String, CaseIterable, Sendable {
        case hostKeyMismatch, hostKeyNotAccepted, authenticationFailed
        case keyFileNotFound, keyPassphraseRequired, keyPassphraseRejected, keyUnparsable
        case keyTypeNotLoadable, keyPEMNotReadable
        case agentUnavailable, agentHasNoIdentities, agentHasNoUsableIdentity
        case agentRefusedEveryIdentity, agentMisbehaved
        case keychainUnreadable, connectionFailed, serverAnswerUnusable
        case sessionUsesLoginSet, sessionUsesJumpHost, sessionIsNotSSH, sessionMissing
        case portInUse, bindFailed, channelOpenFailed, connectFailed, pumpFailed
        case alreadyStarted, remotePortZeroRefused, remoteBindRefused, remoteForwardUnanswered
        case connectionLost, unknown
    }

    public var name: Name {
        switch self {
        case .hostKeyMismatch: return .hostKeyMismatch
        case .hostKeyNotAccepted: return .hostKeyNotAccepted
        case .authenticationFailed: return .authenticationFailed
        case .keyFileNotFound: return .keyFileNotFound
        case .keyPassphraseRequired: return .keyPassphraseRequired
        case .keyPassphraseRejected: return .keyPassphraseRejected
        case .keyUnparsable: return .keyUnparsable
        case .keyTypeNotLoadable: return .keyTypeNotLoadable
        case .keyPEMNotReadable: return .keyPEMNotReadable
        case .agentUnavailable: return .agentUnavailable
        case .agentHasNoIdentities: return .agentHasNoIdentities
        case .agentHasNoUsableIdentity: return .agentHasNoUsableIdentity
        case .agentRefusedEveryIdentity: return .agentRefusedEveryIdentity
        case .agentMisbehaved: return .agentMisbehaved
        case .keychainUnreadable: return .keychainUnreadable
        case .connectionFailed: return .connectionFailed
        case .serverAnswerUnusable: return .serverAnswerUnusable
        case .sessionUsesLoginSet: return .sessionUsesLoginSet
        case .sessionUsesJumpHost: return .sessionUsesJumpHost
        case .sessionIsNotSSH: return .sessionIsNotSSH
        case .sessionMissing: return .sessionMissing
        case .portInUse: return .portInUse
        case .bindFailed: return .bindFailed
        case .channelOpenFailed: return .channelOpenFailed
        case .connectFailed: return .connectFailed
        case .pumpFailed: return .pumpFailed
        case .alreadyStarted: return .alreadyStarted
        case .remotePortZeroRefused: return .remotePortZeroRefused
        case .remoteBindRefused: return .remoteBindRefused
        case .remoteForwardUnanswered: return .remoteForwardUnanswered
        case .connectionLost: return .connectionLost
        case .unknown: return .unknown
        }
    }

    /// The kind as one English sentence — the paste-artifact language of the
    /// diagnostic log, never shown in the App, which translates the kind
    /// itself (`TunnelProfilesSheet.failureLabel`).
    ///
    /// For every kind whose payload is all its sentence needs, this IS the
    /// log's `reason=` text: `DialSupport.reason(for:)` reads it from here
    /// rather than spelling it a second time. For the four `TunnelFailure`
    /// free-text kinds and `unknown` it is a fixed summary, and the log keeps
    /// the fuller sentence the error carried.
    public var sentence: String {
        switch self {
        case .hostKeyMismatch(let host):
            // Names the host, never the fingerprints (maintainer decision,
            // 2026-09-16) — see `DialSupport.reason(for:)`'s mismatch arm.
            return "host key MISMATCH for \(host): the presented key differs from the recorded one"
        case .hostKeyNotAccepted:
            return "the host key is not known to this app and was not accepted"
        case .authenticationFailed:
            return "authentication failed"
        case .keyFileNotFound(let path):
            return "no key file at \(path)"
        case .keyPassphraseRequired:
            return "the key is encrypted and no passphrase was available"
        case .keyPassphraseRejected:
            return "the key's passphrase was rejected"
        case .keyUnparsable:
            return "the key file could not be parsed"
        case .keyTypeNotLoadable(let algorithm):
            return "this app cannot load a key of type \(algorithm)"
        case .keyPEMNotReadable:
            return "the key is a PEM file with a feature this app does not read"
        case .agentUnavailable:
            return "no ssh-agent answered on SSH_AUTH_SOCK"
        case .agentHasNoIdentities:
            return "the ssh-agent holds no identities"
        case .agentHasNoUsableIdentity:
            return "the ssh-agent holds no identity of a type this app can offer"
        case .agentRefusedEveryIdentity:
            return "the ssh-agent refused every identity it offered"
        case .agentMisbehaved:
            return "the ssh-agent connection misbehaved"
        case .keychainUnreadable:
            return "the keychain could not be read"
        case .connectionFailed:
            return "the connection failed"
        case .serverAnswerUnusable:
            return "the server answered something this app could not use"
        case .sessionUsesLoginSet(let session):
            return "session \(session) belongs to a login set; "
                + "forwardings dial with the session's own login"
        case .sessionUsesJumpHost(let session):
            return "session \(session) uses a jump host; "
                + "forwardings cannot dial through one"
        case .sessionIsNotSSH(let session, let connectionKind):
            return "session \(session) is \(Self.namedWithArticle(connectionKind)) session; "
                + "forwardings need SSH"
        case .sessionMissing:
            return "the connection this forwarding belongs to no longer exists"
        case .portInUse(let port):
            // The port is the whole finding: it is what the user has to free,
            // or change in the profile.
            return "port \(port) is already in use"
        case .bindFailed:
            return "the forward could not start listening"
        case .channelOpenFailed:
            return "the server did not open a channel for the forward"
        case .connectFailed:
            return "a connection made for the forward failed"
        case .pumpFailed:
            return "a forwarded connection could not be wired up"
        case .alreadyStarted:
            // Not a condition a user can be in: every forward type is
            // single-use by contract and a reconnect builds a new one. A
            // sentence rather than a case index, because if it ever does
            // reach a person it should say what happened.
            return "this forward has already been started"
        case .remotePortZeroRefused:
            return "a remote forward must name the port the server listens on; "
                + "letting the server choose it is not supported by this client"
        case .remoteBindRefused(let needsGatewayPorts):
            return "the server refused to listen for the remote forward"
                + (needsGatewayPorts ? Self.gatewayPortsClause : "")
        case .remoteForwardUnanswered:
            return "the server did not answer the forwarding request"
        case .connectionLost:
            return "connection lost"
        case .unknown:
            return "the forwarding failed"
        }
    }

    /// The clause a refused non-loopback remote bind appends to its
    /// sentence — one spelling, for the kind's sentence and for the log's
    /// (`DialSupport.reason(for:)` of `TunnelFailure.remoteBindRefused`).
    static let gatewayPortsClause =
        " (a bind address other than loopback needs the server's GatewayPorts)"

    /// The per-connection mapping: what a listener's or a remote forward's
    /// `TunnelFailure` is as a kind. The same switch
    /// `DialSupport.failureKind(for:)` runs for any error.
    public init(_ failure: TunnelFailure) {
        self = DialSupport.failureKind(for: failure)
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

/// Why a stored session cannot carry a forwarding — thrown by the dial
/// before anything is connected.
///
/// A type of its own rather than `TunnelFailure.connectFailed(reason:)`,
/// which is what these were until 2026-09-16: a sentence cannot be turned
/// back into a `TunnelFailureKind` without matching its prose, and the
/// refusal is the one failure a user fixes by editing the session rather
/// than by waiting. Neither case is a `TunnelState.needsConfirmation`
/// (`TunnelRunner.needsAPerson` reads `.secretRequired` and
/// `HostKeyError.rejectedByUser` and nothing else).
///
/// Carries a session NAME and a connection kind — no secret, not a jump's
/// host, not a login set's contents.
public enum TunnelRefusal: Error, Sendable, Equatable {
    /// The session is bound to a login set.
    case loginSet(session: String)
    /// The session dials through a jump host.
    case jumpHost(session: String)
    /// The session is not SSH.
    case notSSH(session: String, connectionKind: ConnectionKind)
    /// The profile's session has been deleted.
    case sessionMissing
}
