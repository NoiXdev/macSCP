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
    case active(connections: Int, failedConnections: Int = 0, lastFailure: TunnelFailureKind? = nil)
    case reconnecting(attempt: Int)
    case failed(TunnelFailureKind)  // typed, never a secret or a raw error description
    case needsConfirmation          // autostart met an unknown host key or a missing secret
}
```

Updated 2026-09-17 by the technical-backlog plan's Tasks 6 and 7 (see "Changes
2026-09-17" below): `failed` carries a `TunnelFailureKind`, not a free-text
reason, and `active` carries a per-connection failure count and the last
failure's kind, both reset by the next successful connection.

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
  final review; a Task 3 hand-off that never reached Task 5's brief).
  **Closed 2026-09-17** by the technical-backlog plan's Task 3 — see
  "Changes 2026-09-17" below for the shape that shipped.
- **A failure reason reaches the user in English, on four localized
  surfaces** (recorded 2026-09-06 by the final review).
  **Closed 2026-09-17** by the technical-backlog plan's Task 6 — see
  "Changes 2026-09-17" below for the shape that shipped, and its own
  residual limit (local-bind errno/detail text still lost in the App).

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

## Changes 2026-09-17

Five follow-ups landed through
`docs/superpowers/plans/2026-09-16-technical-backlog.md` (ledger:
`.superpowers/sdd/2026-09-16-technical-backlog/progress.md`). Two close
this design's own "Limits, stated" bullets above (the SOCKS5 timeout,
the English-only failure reason); the other three extend the runtime
this design describes beyond what it originally limited (the
connection-failure counter, the SFTP-less connect, the store refusal).
What shipped, task by task; the residual gaps each left are their own
rows in `docs/BACKLOG.md`, not repeated here.

### Typed failure (Task 6, `ab4a2c4c`, `8c9289a5`)

`TunnelState.failed`/`TunnelEvent.failed` carry a new
`public enum TunnelFailureKind` (`Sources/macSCPCore/Tunnels/
TunnelFailureKind.swift`) instead of a free-text `reason: String`. A kind
carries the data its sentence needs — a host, a path, an algorithm name,
a session name, a `ConnectionKind`, a port — and never a secret, a
fingerprint or a foreign error's raw text. `DialSupport.classify(_:)` is
the one switch both `DialSupport.reason(for:)` (the English sentence, the
log and CLI keep it byte-identical to before) and the new
`DialSupport.failureKind(for:)` read from, so the two can never disagree.

The App maps each kind through `L10n` in `en`/`de`/`fr`/`pl`
(`TunnelProfilesSheet.failureKey(_:)`/`failureLabel(_:)`), read by all
four surfaces (the profiles sheet, the autostart sheet, the Dock menu's
tooltip, the sidebar glyph's tooltip) that used to show the English
sentence verbatim. A guard pins that no label renders `String(describing:
)` and that every `TunnelFailureKind.Name` resolves a catalogue key.

`TunnelFailure.connectFailed(reason:)`'s three carrier refusals (a
session using a login set, a session using a jump host, a non-SSH
session) and the App's "connection no longer exists" case were not
representable as a kind without re-parsing prose, so they became a new
typed `public enum TunnelRefusal: Error`, thrown by `TunnelConnection
.connect` and `TunnelManager.liveRunner` in place of
`TunnelFailure.connectFailed`. `TunnelCarriers.refusal(for:) -> String?`
keeps its old signature and exact sentences, read from the refusal's own
kind, so `tunnels add` and the sidebar's existing refusal text are
unchanged.

Fix round 1 (`8c9289a5`) added three more kinds so the App would not lose
detail the log always had: `remotePortZeroRefused`,
`remoteBindRefused(needsGatewayPorts: Bool)` and
`remoteForwardUnanswered`. **This is what makes the "Limits, stated"
bullets on `0.0.0.0`/`GatewayPorts` and on a refused port `0` true again
for the App, not only for the log and the CLI**: a non-loopback remote
bind refusal now shows the GatewayPorts hint (translated,
`tunnel.failure.remoteBindRefused.gatewayPorts`) and a port-`0` refusal
names itself (`tunnel.failure.remotePortZeroRefused`), on all four
surfaces, exactly as those two bullets already promised for the log line
they were originally written against.

One opaque case, not in the port-forwarding plan's own scope but closed
in the same commit: a `KeychainError` from the forwarding's secret chain
used to fall to `(error as NSError).localizedDescription` — "The
operation couldn't be completed. (macSCPCore.KeychainError error 1.)".
It now maps to `.keychainUnreadable`, "the keychain could not be read",
translated like every other kind.

**Residual, its own BACKLOG row:** a local bind failure other than
port-in-use (e.g. `EADDRNOTAVAIL`, a permission error) still collapses to
a plain "could not start listening" sentence in the App; the log and CLI
keep the full errno/detail text through the mechanism below.

### The connection-failure counter in `.active` (Task 7, `b9ee7d22`, `bc639257`)

`TunnelState.active` gained two fields with defaults, so every existing
construction and comparison still compiles:

```swift
case active(connections: Int, failedConnections: Int = 0, lastFailure: TunnelFailureKind? = nil)
```

**What counts:** a `direct-tcpip`/`forwarded-tcpip` channel or SOCKS5
CONNECT that fails after the destination is known — a refused connect, a
channel-open failure, a pipe failure. **What does not count:** a SOCKS5
client that never completed its handshake (no destination was ever
named, so there is nothing to attribute the failure to) and, since fix
round 1, a SOCKS5 client that disconnects before it can read the success
reply (`LocalForwardListener.accepted`'s `catch where replying`) — that
is the client's own failure, not the forwarding's, by the maintainer's
ruling. A success (`TunnelConnectionObserver.opened`) resets both fields
to `0`/`nil`; entering `.active` from `.connecting`/`.reconnecting`
(including after a reconnect) also starts at `0`/`nil`. No new lifecycle
state — an all-failing forwarding is still `.active`, by the same
"Log + Zähler im Status" decision.

Each failure writes one `.debug` `tunnel` line, `tunnel <name> connection
failed port=<bound> <kind.sentence>` — no `reason=`, no client address,
no destination. The App shows "Active · %lld connections failed"
(stringsdict, four languages, `pl` one/few/many/other) once
`failedConnections > 0`, and a new `stateTooltip(_:)` carries the
translated last failure on all four state surfaces.

**Residuals, their own BACKLOG rows:** a stopped attempt's buffered
reports still publish intermediate `.active` states while they drain
(only the *next* attempt is protected, by an awaited reader in
`releaseCurrent()`); a stop race in `RemoteForward.swift` reports the
same "forward has been stopped" event as a connection failure in one of
its two occurrences and not the other; `SOCKS5Handshake.succeed`'s own
`removeHandler` failure is folded into, and so hidden by, the
client-disconnect exemption above; a forwarding failing every connection
still shows a green glyph and badge, by design.

### The SOCKS5 limits (Task 3, `86135e0a`, `db432037`)

`SOCKS5Listener` carries a 30 s handshake deadline
(`socks5HandshakeDeadline`) and a cap of 64 parked handshakes
(`socks5ParkedHandshakeLimit`), both named constants with their reasoning
in a comment (a SOCKS greeting plus CONNECT is a few dozen bytes; `ssh
-D` has neither limit, so these are this app's own; loopback bind by
default). A client that stalls mid-handshake is closed and its
`SOCKS5RequestBox` resolved with `SOCKS5HandshakeError.deadlineExpired`
once the deadline fires; a connection beyond the cap is refused at once
(socket closed, no box ever parked) with `tooManyParkedHandshakes`.
`SOCKS5RequestBox.value()` now carries the same `withTaskCancellationHandler`
`OpenPortBox` (`RemoteForward.swift`) already had. A refused or
timed-out handshake writes one `.debug` `tunnel` line naming only the
local port — never client data. Neither failure reaches the tunnel's
`onFailure`/the counter above: a client's own SOCKS5 failure is still not
a tunnel failure, unchanged from before this task.

### The SFTP-less connect (Task 8, `c479fd37`, `f0d9f4ff`, `feb0a55e`)

`CitadelFileSystem.connect` was factored into a shared
`connectAuthenticated(config:connectTimeout:knownHosts:onUnknownHostKey:
establish:)` that holds everything TOFU-relevant in one place — agent
handling, the dedicated event-loop group, `connectWithTOFURetries` (the
mismatch hard stop, the accept-retry path, the known-hosts upsert) and
`attemptConnect` (jump hop, both hops through the same registered
algorithms, authentication). `establish` runs inside `attemptConnect`
exactly where the SFTP open used to sit, so a failure inside it is still
mapped the same way as before.

A new internal `SSHForwardingConnection` (`Sources/macSCPCore/SSH/
SSHForwardingConnection.swift`) calls `connectAuthenticated` with a step
that never opens the SFTP subsystem, and now owns the forwarding-only
surface that used to live on `CitadelFileSystem`
(`openDirectTCPIP`, `withRemotePortForward`, the remote-bind failure
mapping). `TunnelConnection.connect` uses it; tabs still go through
`CitadelFileSystem.connect`, unchanged, and still open SFTP.

A new rig service, `sshd-nosftp` (`127.0.0.1:2236`, SFTP subsystem
disabled via a custom-cont-init hook that comments out the image's
`Subsystem sftp` line — a config-fragment override could not remove it,
because sshd keeps the FIRST `Subsystem sftp` directive it sees and the
image's own comes after any `Include`), measures the new path: a
forwarding dial connects and carries bytes with no SFTP request ever
sent; `CitadelFileSystem.connect` against the same server is refused SFTP
by the server (visible in its log).

**Residual, found while measuring, its own BACKLOG rows:** a tab dial
against a server without the SFTP subsystem does not fail, it HANGS —
`openSFTP` waits on the server's version reply with no timer of its own,
past the connect timeout, and Cancel leaks the connection rather than
ending it; and a dial that fails partway (not the success path, which
this task's fix round 1 already covers) can still release its
agent-auth event-loop group while Citadel's 10 s login timer is pending.

### The store refusal (Task 2, `f31212b3`)

`TunnelStore.upsert`/`delete(id:)`/`deleteAll(for:)` now go through a
private `writableFile()` that switches on the same `decode()`
`readProfiles()` already used, and throw a new
`TunnelStoreError.unreadable(path:)` on a present-but-undecodable
`tunnels.json` instead of silently treating it as empty and overwriting
it — the file is left byte-identical. The lenient readers (the sidebar
glyph, autostart) are unchanged: they still read an unreadable file as
empty, which is what makes the app usable while a `tunnels.json` is
being repaired by hand.

The App surfaces the throw through a new catalogue key
(`tunnel.store.unreadable`, four languages) on the profiles sheet's save
and delete paths. The CLI maps it to `CLIExitCode.connection` (13, the
same code an unreadable session store already returns) and a message
naming the file and "could not be read". `sessions rm` does **not**
block on a `deleteAll` refusal — a session nobody could delete until the
file is fixed by hand was judged worse than a stale row — it warns to
stderr naming the file, still removes the session, and exits 0.

**Residuals, closed the same day** — see "The store refusal's residuals
closed" below, from the technical-backlog plan's sibling, the next-build
plan.

### The store refusal's residuals closed (Task 2, `208c1f32`, `8bd29c25`, `5fc4f876`, `ece85285`, `cf5f2f20`, `c043c8f1`, `d1243789`)

The four residuals the subsection above left open, all closed the same
day by the next-build plan's Task 2 (ledger:
`.superpowers/sdd/2026-09-17-next-build/progress.md`).

`TunnelManager.save`/`remove` used to call `discardRunner` **before** the
store write; a refused write over an unreadable `tunnels.json` therefore
stopped a profile's running tunnel although nothing on disk had actually
changed. The write now comes first (`208c1f32`); only a write that
succeeded stops the runner.

Orphan rows — a session deleted while the store was unreadable — used to
resurface as stopped rows once the file was repaired, because the
session filter ran only in the activation reconcile. `8bd29c25` added it
there; `5fc4f876` found the same gap in `init` and `reload()` (behind
`save`, `remove`, `startAutoStart` and `reloadAutoStartProfiles`) and
replaced all of it with one private `listed(_:known:)`, used by every
read. Because `reload()` itself stops nothing, the reconcile now also
discards any runner it does not list, so an orphan's runner cannot
outlive its row; `ece85285` closed a further window where `remove(_:)`
kept a row listed while its `discardRunner` was parked, letting a menu
start in that gap pass `start()`'s guard for a row about to disappear.

`sessions rm`'s prompt and `--verbose` output used to say "0
forwardings" for a session whose count could not be read, rather than
saying the count is unknown. `cf5f2f20` reads the count through
`readProfiles()` instead of the lenient reader, reports an unreadable
count as unknown (`SessionRemovalWording.swift`), and the summary no
longer claims those forwardings were deleted. A same-day sibling fix,
outside this residual list but in the same commit sequence
(`d94f962d`), rewords the deletion QUESTION itself: it used to promise
"and an unknown number of forwardings" for a session whose forwarding
count could not be read, though the removal leaves those forwardings in
the file; it now asks about the session alone and says the forwardings
will stay in the forwarding list.

Exit code 13 was documented (`CLIExitCode.swift:22`) as a transport
failure only; `c043c8f1` names an unreadable forwarding list, and an
unreadable or unwritable session store, in the same doc bullet, with no
code change.

`TunnelRunner` gained a related, not-a-residual fix in the same task: a
report that reaches the runner once `stop()` has begun is now dropped
instead of applied as an intermediate `.active` state and log line
(`9a96e1c9`) — closing the "buffered connection reports" residual under
"The connection-failure counter in `.active`" above.

**Newly pinned by test only, no behaviour change** (`d1243789`):
`forgetEverything(for:)`'s "rows leave the mirror before any await"
ordering, previously asserted only after the call had returned; and
`sessions rm` over a `tunnels.json` that decodes but cannot be written,
which still aborts the removal (exit 13, session and file untouched) —
the behaviour the doc comment already stated, now with a case that
plants it.
