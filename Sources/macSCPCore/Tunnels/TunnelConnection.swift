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
/// What that mapping refuses, it refuses here too: a session bound to a login
/// set, and a session that dials through a jump host, both throw
/// `StoredSessionConnectionError`. Lifting either needs `LoginResolver` plus
/// the stores the App layer holds, which is a decision for the task that
/// wires the App up, not a silent guess made here.
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
    public static func connect(
        session: StoredSession,
        secrets: [any SecretSource],
        knownHosts: KnownHostsStore,
        decider: HostKeyDecider,
        connectTimeoutSeconds: Int = SettingsStore.defaultConnectTimeoutSeconds
    ) async throws -> CitadelFileSystem {
        let secret = try SecretResolver(sources: secrets).resolve(for: session.id)
        let config = try StoredSessionConnectionConfig.build(for: session, secret: secret?.value)
        guard case .ssh(let ssh) = config else {
            // The one place a `TunnelFailure` is raised outside the transport
            // itself. There is no `direct-tcpip` over S3 or WebDAV, and the
            // App must be able to say so without reading an error's text.
            throw TunnelFailure.connectFailed(reason: "port forwarding needs an SSH session")
        }
        return try await CitadelFileSystem.connect(
            config: ssh,
            connectTimeout: .seconds(Int64(connectTimeoutSeconds)),
            knownHosts: knownHosts,
            onUnknownHostKey: decider)
    }
}
