import Foundation
import NIOCore

/// A tunnel's own SSH connection.
///
/// A tunnel does not borrow a tab's connection — it needs none open, it
/// survives the tab's close, and it can start before any window exists
/// (`docs/superpowers/specs/2026-09-06-port-forwarding-design.md`, "What a
/// forwarding is"). So it dials for itself, from the STORED session, exactly
/// the way the command line does for a session named on its own command
/// line: resolve the secret through the `SecretSource` chain the caller
/// supplies, map the stored session to a `ConnectionConfig`, dial.
///
/// The mapping is not re-implemented here. `StoredSessionConnectionConfig
/// .build(for:secret:)` already lives in Core (it was put there, rather than
/// in the command-line target, precisely so it stays testable), and this is
/// its second caller — `MacSCPCLI/SessionConnecting.swift`'s `connect(to:
/// options:)` is the first. Nothing moved for this task.
///
/// What that mapping refuses, it refuses here too — a session bound to a
/// login set, and a session that dials through a jump host — plus the one
/// refusal that is the tunnel's own: a session that is not SSH. All three are
/// `TunnelCarriers.refusalError(for:)`'s `TunnelRefusal`, asked once at the
/// top of `connect` rather than decided again here, so the text the command
/// line prints before dialling and the text a failed dial reports cannot say
/// different things about the same rule. Lifting the first two needs
/// `LoginResolver` plus the stores the App layer holds, which is a decision
/// for the task that wires the App up, not a silent guess made here.
public enum TunnelConnection {
    /// Resolves the session's secret and connects.
    ///
    /// Errors are NOT flattened into `TunnelFailure`. A missing secret comes
    /// back as `StoredSessionConnectionError.secretRequired`, an unknown or
    /// mismatched host key as `HostKeyError` — the App needs those apart
    /// from a transport failure, because the first two mean
    /// `TunnelState.needsConfirmation` (connect this session once, by hand)
    /// while a transport failure means `.failed`.
    ///
    /// - Parameters:
    ///   - secrets: the chain to walk for this session's secret, in
    ///     precedence order — what `secretSources(for:passwordCommand:)`
    ///     builds. An empty chain resolves to no secret, which the mapping
    ///     then refuses or accepts according to the session's auth kind.
    ///   - decider: the host-key decider for UNKNOWN keys. A tunnel started
    ///     from a window hands in the window's (it may prompt); an autostart
    ///     hands in `.refusing`. A key MISMATCH never reaches it — that stays
    ///     a hard stop inside the dial.
    ///
    /// The connection comes back authenticated and with no child channel
    /// open — no SFTP — which is what `SSHForwardingConnection` is. Its dial
    /// is the tab's own up to and including user authentication, so the
    /// mismatch hard stop `decider` names is the tab's code, not a copy.
    public static func connect(
        session: StoredSession,
        secrets: [any SecretSource],
        knownHosts: KnownHostsStore,
        decider: HostKeyDecider,
        connectTimeoutSeconds: Int = SettingsStore.defaultConnectTimeoutSeconds
    ) async throws -> any TunnelSSHConnection {
        // Before the secret is even resolved: none of the three rules depends
        // on one, and refusing first keeps a Keychain prompt off a session
        // that could not carry a forwarding anyway.
        //
        // A `TunnelRefusal` raised before any transport exists — typed, so
        // `TunnelState.failed` carries which rule refused rather than a
        // sentence the App could not translate. It was a
        // `TunnelFailure.connectFailed(reason:)` until 2026-09-16. Two of the
        // three rules would otherwise come back from
        // `StoredSessionConnectionConfig.build` as
        // `StoredSessionConnectionError`, whose sentences say "the CLI does
        // not resolve this yet" — true of the session-connect path that owns
        // them, and the wrong reason on this one, where a forwarding dials
        // with the session's own login by design. Neither is a
        // `TunnelState.needsConfirmation` (`TunnelRunner.needsAPerson` reads
        // `.secretRequired` and `HostKeyError.rejectedByUser`, and nothing
        // else), so nothing downstream loses an answer by their arriving
        // typed as a `TunnelRefusal`.
        //
        // ONE case did change answer, and deliberately: a session that is
        // refused here AND has no stored secret used to reach `build`'s
        // `.secretRequired` first and land on `needsConfirmation` — "connect
        // this session once, by hand". Reachable from autostart and the
        // autostart sheet. It is now `.failed`, which is the true answer:
        // connecting a WebDAV session by hand, or resolving a jump host's
        // login, does not make it able to carry a forwarding, so inviting
        // the user to try was inviting a loop.
        if let refusal = TunnelCarriers.refusalError(for: session) {
            throw refusal
        }
        let secret = try SecretResolver(sources: secrets).resolve(for: session.id)
        let config = try StoredSessionConnectionConfig.build(for: session, secret: secret?.value)
        guard case .ssh(let ssh) = config else {
            // Unreachable while `TunnelCarriers.carries` agrees with the
            // `ConnectionConfig` case each kind builds: the refusal above
            // already turned away every kind but `.ssh`. The arm stays
            // because `build` answers with a `ConnectionConfig` and the SSH
            // payload has to come out of it either way — and it says what
            // reaching it would actually mean rather than repeating the
            // refusal's sentence.
            throw TunnelFailure.connectFailed(
                reason: "session \(session.name) built a non-SSH connection although "
                    + "its kind says a forwarding can be carried")
        }
        do {
            return try await SSHForwardingConnection.connect(
                config: ssh,
                connectTimeout: .seconds(Int64(connectTimeoutSeconds)),
                knownHosts: knownHosts,
                onUnknownHostKey: decider)
        } catch {
            // A key that needed a passphrase the chain could not supply
            // because `managed_keys.json` would not read is named as that,
            // not as a missing passphrase — the chain's managed-key link is
            // the one that saw it.
            throw ManagedKeyPassphraseSecretSource.namingUnreadableStore(error, in: secrets)
        }
    }
}
