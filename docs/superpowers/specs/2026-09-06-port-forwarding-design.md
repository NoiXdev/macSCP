# SSH port forwarding — design

**Status:** implemented 2026-09-06 (final commit `1a4b94b1`), through
`docs/superpowers/plans/2026-09-06-port-forwarding.md`'s eight tasks; the
record of what shipped, what is limited and the sight check is
`docs/BACKLOG.md`'s "Done" row for this entry.

**Date:** 2026-09-06. **Requested by the maintainer** (2026-09-06, in
their words): all three forwarding kinds, freely configurable, as
"mapping profiles" in an overlay per session like the login/host
overlays; started and stopped from the session's context menu;
optionally established automatically at app start or at login, in an
overlay of their own; the status shown in the session bar with an icon
and a colour, and in the Dock icon. Mockups approved 2026-09-06:
`https://claude.ai/code/artifact/01c2fd5f-adc6-4c63-868b-6a34848ccd76`
(sidebar + context menu, the profile overlay, the autostart overlay,
the Dock icon, the state table). The Dock badge is a count with a red
exclamation mark on failure, as mocked.

## Measured at HEAD (94e7ff82), before writing this

All three kinds are buildable on the pinned forks without a fork
change:

- `swift-nio-ssh` 0.3.10 (`Package.swift:54`): `SSHChannelType` carries
  `.directTCPIP` and `.forwardedTCPIP`
  (`Sources/NIOSSH/Child Channels/SSHChannelType.swift:29-38`);
  `NIOSSHHandler.sendTCPForwardingRequest(_:promise:)` (`:282`) sends
  `tcpip-forward`/`cancel-tcpip-forward`; inbound `forwardedTCPIP`
  channels reach the client's `inboundChildChannelInitializer`.
- Citadel `0.12.1-noix.3` (`Package.swift:30`):
  `SSHClient.createDirectTCPIPChannel(using:initialize:)` is public
  (`DirectTCPIP+Client.swift:39`) and already used by `jump(to:)`;
  `withRemotePortForward(host:port:onOpen:handleChannel:)`
  (`RemotePortForward+Client.swift:59`) sends the global request,
  returns the server's bound port, dispatches inbound channels, and
  cancels on task cancellation.
- The app holds the client privately (`CitadelFileSystem.swift:39`);
  `CitadelShell` opens its child channel through `client.withPTY`
  without ever tearing the connection down — the pattern a tunnel uses.
- Nothing in `Sources/` has a TCP listener (`ServerBootstrap` absent),
  sets `NSApp.dockTile`, or uses `SMAppService`. All three are new.
- The M24 login design says nothing about tunnels.

## What a forwarding is, in this app

A **profile** belongs to a stored session and describes one
forwarding. A **tunnel** is a running profile. A tunnel holds **its own
SSH connection** to the session's host — not a tab's — so it needs no
open tab, survives the tab's close, and can start at launch. That is a
documented exception to "connection state belongs to the window
scope": tunnels are not tabs; their owner is an app-wide
`TunnelManager` with an explicit lifecycle (start → connect → listen →
stop → disconnect), torn down in the quit sequence before the windows,
never in a `deinit`.

Three kinds, in the user's words on the form:

| Kind | Listener | Per accepted connection |
|---|---|---|
| Local → remote (`-L`) | on this Mac, `bind:port` (default `127.0.0.1`) | a `direct-tcpip` child channel to `host:port` behind the server; bytes pumped both ways |
| Remote → local (`-R`) | on the server, `bind:port` (default `127.0.0.1` there; `0.0.0.0` needs the server's `GatewayPorts`) | the server's `forwarded-tcpip` channel is connected to `localHost:localPort` on this Mac |
| Dynamic (`-D`) | on this Mac, a SOCKS5 server (no auth; CONNECT; IPv4, IPv6, domain) | a `direct-tcpip` channel to the destination the SOCKS client named |

Binding a local listener to anything but `127.0.0.1` shows one line
under the field: "reachable from your network".

## Model (Core, `Sources/macSCPCore/Tunnels/`)

```swift
public struct TunnelProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var name: String
    public var kind: Kind          // .local(bind:localPort:host:remotePort) | .remote(bind:remotePort:localHost:localPort) | .dynamic(bind:localPort)
    public var autoStart: AutoStart // .off | .appStart | .login
    public var reconnects: Bool     // exponential backoff 2 s → 60 s on connection loss
}
public enum TunnelState: Sendable, Equatable {
    case stopped
    case connecting
    case active(connections: Int)
    case reconnecting(attempt: Int)
    case failed(reason: String)     // the mapped reason, never a secret
    case needsConfirmation          // autostart met an unknown host key or a missing secret
}
```

`TunnelStore` writes `tunnels.json` beside `sessions-v2.json` — ids,
names, hosts, ports, flags; never a secret. Deleting a session deletes
its profiles (the store is told; pinned).

## Runtime (Core)

- `CitadelFileSystem` gains `openDirectTCPIP(host:port:) async throws
  -> Channel` and `withRemotePortForward(bind:port:handleChannel:)`,
  both thin wrappers over the client, so `SSHClient` stays private.
- `TunnelRunner` (one per running profile, an actor): builds the
  connection the way the CLI does for a stored session (the stored
  session + a `SecretSource` → `SSHConnectionConfig` →
  `CitadelFileSystem.connect`), with the host-key decider the caller
  hands in: a context-menu start uses the window's decider (may
  prompt); autostart uses `.refusing` and reports
  `.needsConfirmation`. Then, per kind: `LocalForwardListener`
  (`ServerBootstrap` on `bind:port`; each accepted channel gets a
  `direct-tcpip` channel and a `BytePump` — two handlers that forward
  bytes and propagate read/write backpressure and half-close),
  `SOCKS5Listener` (the same listener with a `SOCKS5Handshake`
  decoder in front), or `RemoteForward` (a long-lived task inside
  `withRemotePortForward`, each inbound channel connected with a
  `ClientBootstrap` to `localHost:localPort` and pumped).
- Connection loss: with `reconnects` on, `.reconnecting(attempt:)`
  with backoff 2, 4, 8 … 60 s, forever, until stopped; off → `.failed`.
- Stop: cancel the listener/task, close every pumped pair, disconnect.
- Diagnostic log: `tunnel <name> start|active port=… |failed reason=…
  |stop` at `info`; each accepted connection at `debug` with the
  destination and duration. Never a secret.

## App

- `TunnelManager` (`@MainActor`, App target, `shared`): profiles per
  session, states per profile, start/stop, `startAutoStart(.appStart)`
  at launch (after the diagnostic log is configured and the what's-new
  decision), `stopAll()` in the quit chain (before windows).
- Context menu of a session row: submenu "Port forwarding" — each
  profile with a checkmark when running (click toggles), "Start all",
  "Stop all", "Manage profiles…". The submenu appears only when the
  session is SSH.
- The profile overlay (a sheet from the row, like the edit sheet): the
  table (state dot, name, kind, local, target, autostart, start/stop
  button) and the form (name, kind segment, bind:port, target
  host:port, autostart segment, reconnect toggle). Save validates: port
  1–65535, host non-empty for local/remote, local port free at start
  (not at save — a port can be freed later; the start reports it).
- The autostart overlay (Window menu "Forwardings at launch…" and a
  button in Settings › General): "Open macSCP at login" (`SMAppService
  .mainApp`, status shown as the system reports it) and the table of
  every autostart profile across sessions with state, "when", "last",
  start/stop.
  **"Start in the background" was NOT built** (Task 7, 2026-09-06) and
  is struck from this list rather than left standing as a description
  of a control nobody can click; the Limits section below records why
  and what would have to be measured first.
  **"Last active" is not recorded; the column is deferred until the
  runner keeps a timestamp** (Task 7, 2026-09-06). Nothing in Core holds
  one — `TunnelState` carries no time and `TunnelStore` writes no
  history — so the column was left out rather than filled with a value
  invented at the App layer, which would have been a timestamp of when
  the sheet was opened rather than of when the forwarding last ran.
- Sidebar: the session row shows the forwarding glyph with the count
  of active tunnels; colour by the worst state among the session's
  tunnels (red > amber > green); grey with no count when all stopped;
  no glyph when the session has no profile; the tooltip carries the
  reason. Colour never alone — the glyph and the count/`!` are the
  shape.
- Dock: `NSApp.dockTile.badgeLabel` = the active count, `!` when any
  failed, nothing when none active; the Dock menu
  (`applicationDockMenu`) carries the same block as the context menu
  for every running, autostart, **or failed** profile. The menu-bar
  item, when the setting is on, gets the same block.
  **"Or failed" was added in Task 7's fix round 1** (2026-09-06): the
  badge counts failures over EVERY profile, so a forwarding started by
  hand with autostart off, which then failed, put `!` on the Dock while
  a running-or-autostart block answered "No forwardings set up". The
  membership rule is "running, autostart, or needing attention", where
  needing attention is `.failed` or `.needsConfirmation` — so whatever
  the badge shouts about always has a row behind it.

## Limits, stated

- Autostart never prompts: a profile whose session has no stored
  secret or an unknown host key stays `.needsConfirmation` until the
  user connects that session once in a window.
- **"Start in the background" is not shipped; "Open at login" ships
  alone** (outcome, 2026-09-06). The toggle would hide the main window
  at a login-item launch, and it is only correct if the app can tell a
  login launch from an ordinary one. That signal — the launch Apple
  event's `keyAELaunchedAsLogInItem` reason, read by
  `LoginLaunchDetector` — has its PARSING measured (`LoginItemTests`)
  and its ARRIVAL unmeasured: a real login launch needs a signed,
  registered `.app` opened by loginwindow, which neither `swift test`
  nor the dev build performs. Two hypotheses remain open and are
  indistinguishable from outside — (a) macOS 15 no longer sends that
  reason, (b) it is sent but a delegate installed by
  `@NSApplicationDelegateAdaptor` is in place too late to see it. The
  failure direction is the safe one (an unread flag starts nothing),
  which is why the `.login` moment shipped and the toggle did not: a
  wrong `true` would hide the window of an ordinary launch. The
  procedure that separates the two hypotheses is the Interface row
  `Forwardings "At login": the launch flag is unverified, and "Start in
  the background" is not shipped` in `docs/BACKLOG.md`; the sheet's
  footer states the limit to the user.
- Remote forwards bound to `0.0.0.0` on the server work only with the
  server's `GatewayPorts` allowing it; the failure reason names it.
- A remote forward must **name** the port the server listens on; `0` —
  "let the server choose" — is refused; the reason names the refusal, not
  a port (there is none yet).
  Measured 2026-09-06: the pinned Citadel registers its inbound handler
  under the REQUESTED `(host, port)` and dispatches on the BOUND one, so
  a server-chosen port binds and then swallows every connection inside
  the library. Recorded as a fork debt in
  `2026-08-20-backlog-dependencies.md`. The same mismatch could in
  principle come from the HOST half — a server echoing a different
  `listeningHost` for a non-loopback bind — which is **unverified**: the
  rig has `GatewayPorts` off, so it cannot be measured there.
- SOCKS5 without authentication, CONNECT only (no BIND, no UDP).
- A local port in use fails the start with the port in the reason.
- **The SOCKS5 handshake has no timeout** (recorded 2026-09-06 by the
  final review; a Task 3 hand-off that never reached Task 5's brief). A
  client that connects to a `-D` port and then stalls mid-greeting holds
  an accepted socket and a task parked on `SOCKS5RequestBox.value()`
  until the tunnel's `stop()`, and nothing caps how many such clients
  there may be. **Accepted for now: `ssh -D` behaves the same way**, so
  this is not a regression against the tool the feature imitates, and
  the port is a loopback bind by default. The fix shape, when it is
  wanted: a per-handshake deadline that closes the socket and resolves
  the box with a failure, plus a cap on how many handshakes may be
  parked at once. Written down as a row in `docs/BACKLOG.md` (Security
  and testability).
- **A failure reason reaches the user in English, on four localized
  surfaces** (recorded 2026-09-06 by the final review).
  `TunnelState.failed(reason:)` carries the sentence
  `DialSupport.reason(for:)` rendered — English by construction, and by
  design a paste artifact of the audited log line — and the App shows it
  verbatim in the profiles sheet's state column, the autostart sheet's
  state column, the Dock menu's tooltip and the sidebar glyph's tooltip.
  It is not fixable at the App layer as the state is written: the case
  identity is discarded when the sentence is rendered, so there is
  nothing left to map through `L10n`. The fix shape is a typed failure
  on the state (the case and its data, not its prose), mapped at the App
  layer — a Core change, recorded as a row in `docs/BACKLOG.md`
  (Interface).

## What the tests pin

- Core: the profile model round trip; the store never holds a secret
  (type-level scan + JSON keys); the state machine (a pure
  `TunnelStatePlan` for start/loss/backoff/stop); the backoff series;
  the SOCKS5 handshake decoder on byte fixtures (greeting, CONNECT by
  IPv4/domain/IPv6, refusals); the `BytePump` on `EmbeddedChannel`
  pairs (bytes both ways, half-close, backpressure); the local listener
  on an ephemeral loopback port with a fake direct-tcpip factory.
- Gated against the Docker rig (`MACSCP_ITEST=1`): a local forward to
  the rig's own sshd through the tunnel — connect an SFTP client
  through `127.0.0.1:<tunnel>` and list a directory; a dynamic forward
  driven by a hand-written SOCKS5 CONNECT to the same target; a remote
  forward reached from inside the container (`docker exec … nc` to the
  bound port) landing on a loopback listener in the test.
- App: source guards for the context-menu block, the overlay's keys in
  four catalogs, the sidebar glyph reading the manager's state, the
  Dock badge derived from a pure `DockBadgePlan`, the quit chain's
  `stopAll` before the windows; no view is rendered — the dev build is
  the sight check.
