# Port Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH port forwarding — local, remote and dynamic — as profiles
per session, started from the context menu, optionally at app start or
login, with the state in the sidebar and the Dock icon.

**Architecture:** Core owns the profile model, the store, the runtime
(`TunnelRunner` per running profile: its own SSH connection through
`CitadelFileSystem`, a listener or a remote registration, a byte pump
per accepted connection, reconnect with backoff) and the pure planners
(state machine, backoff, Dock badge, SOCKS5 decoder). The App owns
`TunnelManager` (app-wide, explicit lifecycle, stopped in the quit
chain), the context-menu block, the two overlays, the sidebar glyph,
the Dock badge and menu, and the login item. Measured at HEAD
94e7ff82: Citadel's `createDirectTCPIPChannel` and
`withRemotePortForward` are public on the pinned forks; no TCP
listener, `dockTile` or `SMAppService` exists in `Sources/` yet.

**Tech Stack:** Swift 6 strict, SwiftNIO (`ServerBootstrap`,
`ClientBootstrap`, `EmbeddedChannel` in tests), Citadel, SwiftUI +
AppKit, `ServiceManagement`, Swift Testing, the Docker rig.

**Spec:** `docs/superpowers/specs/2026-09-06-port-forwarding-design.md`.

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string`/`CoreL10n.string` in all four catalogs (German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- **No secret in `tunnels.json`, in a state, in a log line or in a failure reason.** Secrets reach a tunnel only through the existing `SecretSource`/`SecretResolver` path at connect time.
- **TOFU stays a hard stop**: a tunnel started from the context menu uses the window's host-key decider (it may prompt); autostart uses `.refusing` and reports `.needsConfirmation`; a mismatch is never overridden.
- **Tunnels are not tabs**: `TunnelManager` is the one app-wide owner; a tunnel's connection is its own; the lifecycle is explicit (start → connect → listen → stop → disconnect), `stopAll()` runs in the quit chain before the windows, no `deinit` cleanup. Nothing in Core knows about windows, menus or the Dock.
- Local listeners bind `127.0.0.1` by default; any other bind is shown as "reachable from your network".
- Red first; no `#require` on a non-optional; no wall-clock ceiling in tests (backoff and timeouts are the code under test, injected); tests never block the pool (NIO futures through `awaitCancellably`, waits through `pollUntil`, listeners on port 0); a negative source check has a positive beside it; comments in prose near anchors; a number in a comment is counted; the Docker rig only from this checkout; no real host.
- Do NOT launch the GUI; the dev build is the maintainer's sight check.

---

### Task 1: Model, store, state planner (Core)

**Files:**
- Create: `Sources/macSCPCore/Tunnels/TunnelProfile.swift` (`TunnelProfile`, `Kind`, `AutoStart`, `TunnelState` as in the spec; `Codable` with a versioned envelope like the session store's)
- Create: `Sources/macSCPCore/Tunnels/TunnelStore.swift` (`tunnels.json` in `SessionStore.defaultDirectory`, injectable directory; `profiles(for sessionID:)`, `upsert`, `delete(id:)`, `deleteAll(for sessionID:)`, `autoStart(_:) -> [TunnelProfile]`)
- Create: `Sources/macSCPCore/Tunnels/TunnelStatePlan.swift` (a pure state machine: `next(state:event:) -> TunnelState` for events `start, connected, listening, connectionAccepted, connectionClosed, connectionLost, retryDue(attempt), failed(reason), stop, needsConfirmation`; `BackoffPlan.delay(attempt:) -> Duration` — 2 s doubling, capped at 60 s)
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift` (deleting a session tells the tunnel store — find how deletion is done and add the one call, or a `SessionDeletionObserver` seam if the store must not know tunnels; say which)
- Test: `Tests/macSCPCoreTests/TunnelProfileTests.swift` (round trip of each kind; old-envelope decode), `TunnelStoreTests.swift` (temp dir; upsert/delete/autoStart filter; the JSON holds no key named like a secret — a scan of the written file's keys against `password|secret|token|key|passphrase`; deleting a session removes its profiles), `TunnelStatePlanTests.swift` (every transition in the spec's table; backoff 2,4,8,16,32,60,60)

- [x] **Step 1: Red first** — `cannot find 'TunnelProfile'`.
- [x] **Step 2: Implement**; `swift test --filter Tunnel` green; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(tunnels): profiles, their store, and the state machine`.

---

### Task 2: Local forward — the byte pump, the listener, the connection (Core, gated rig test)

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`func openDirectTCPIP(host: String, port: Int) async throws -> Channel` wrapping `client.createDirectTCPIPChannel(using:initialize:)` — the originator address is `127.0.0.1:0`; the client stays private)
- Create: `Sources/macSCPCore/Tunnels/BytePump.swift` (two `ChannelDuplexHandler`s glued in a pair: bytes read on one are written on the other; `channelWritabilityChanged` toggles `autoRead` on the peer (backpressure); `inputClosed`/half-close forwarded; either side closing closes both; a `TunnelConnectionObserver` seam for counts)
- Create: `Sources/macSCPCore/Tunnels/LocalForwardListener.swift` (`ServerBootstrap` on `bind:port` (port 0 allowed for tests; reports the bound port); per accepted channel: `directTCPIPFactory(host, port)` (a `@Sendable` closure, the real one calling `openDirectTCPIP`) → pump; `stop()` closes the server channel and every pair; errors mapped to `TunnelFailure` (`portInUse(port)`, `bindFailed(reason)`, `channelOpenFailed(reason)`))
- Create: `Sources/macSCPCore/Tunnels/TunnelConnection.swift` (builds the SSH connection for a stored session the way the CLI does — read `Sources/MacSCPCLI/SessionConnecting.swift` and `Sources/macSCPCore/CLI/` for the stored-session → `SSHConnectionConfig` path and the `SecretSource` protocol; takes a `HostKeyDecider`; returns the `CitadelFileSystem`)
- Test: `Tests/macSCPCoreTests/BytePumpTests.swift` (`EmbeddedChannel` pairs: bytes both ways, order, half-close, a closed peer closes the other, writability toggles the peer's `autoRead`), `LocalForwardListenerTests.swift` (port 0 on loopback with a FAKE factory that returns a loopback echo channel: connect, write, read back; `portInUse` when bound twice; `stop()` closes an accepted pair; every wait an `await`), gated `TunnelRigITests.swift` (`MACSCP_ITEST=1`: a local forward from port 0 to the rig's sshd `127.0.0.1:22` inside the container as seen by the server — i.e. `host: "127.0.0.1", port: 22` behind the tunnel; then a second `CitadelFileSystem.connect` to `127.0.0.1:<boundPort>` lists a directory through the tunnel — end to end)

- [x] **Step 1: Red first** — `cannot find 'LocalForwardListener'`; the pump tests.
- [x] **Step 2: Implement**; unit green; `MACSCP_ITEST=1 swift test --filter TunnelRig` green against the rig; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(tunnels): a local forward pumps bytes through a direct-tcpip channel`.

---

### Task 3: Dynamic forward — SOCKS5 (Core, gated)

**Files:**
- Create: `Sources/macSCPCore/Tunnels/SOCKS5Handshake.swift` (a `ByteToMessageDecoder` state machine: greeting (version 5, methods; reply `05 00` no-auth or `05 FF`), request (CONNECT only; ATYP IPv4/domain/IPv6; BIND/UDP → reply `07`), success reply `05 00 00 01 0.0.0.0:0` once the direct-tcpip channel opened, failure replies `01` general, `05` refused, `04` host unreachable mapped from `TunnelFailure`; after success the handler removes itself and the pump takes over)
- Create: `Sources/macSCPCore/Tunnels/SOCKS5Listener.swift` (the local listener with the handshake in front; the decoded destination fed to the same factory)
- Test: `SOCKS5HandshakeTests.swift` (byte fixtures for each frame; a wrong version → close; BIND → `07`; a domain name decoded exactly; the removal after success; counted: N fixtures), `SOCKS5ListenerTests.swift` (port 0 with the fake factory: a hand-written greeting + CONNECT → success reply → echo), gated: a SOCKS5 CONNECT to the rig's sshd through the tunnel followed by an SSH banner read (`SSH-2.0` prefix)

- [x] **Step 1: Red first**; **Step 2: Implement**; green + gated green; **Step 3: Commit** `feat(tunnels): a dynamic forward speaks SOCKS5`.

---

### Task 4: Remote forward (Core, gated)

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`func withRemotePortForward(bind: String, port: Int, onOpen: @Sendable (Int) -> Void, handleChannel: @Sendable (Channel) async -> Void) async throws` wrapping Citadel's; the server's bound port reported through `onOpen`)
- Create: `Sources/macSCPCore/Tunnels/RemoteForward.swift` (a long-lived `Task` inside the wrapper; each inbound channel: `ClientBootstrap` to `localHost:localPort` → pump; a connect failure closes the inbound channel and counts a `.failed` per connection, not for the tunnel; `stop()` cancels the task — Citadel sends `cancel-tcpip-forward` on cancellation, read `RemotePortForward+Client.swift:100-112`)
- Test: `RemoteForwardTests.swift` (with a fake `withRemotePortForward` seam: an inbound `EmbeddedChannel` is connected to a loopback listener the test owns; bytes both ways; a refused local connect closes the inbound side), gated: a remote forward `127.0.0.1:0` on the rig (the server picks the port, reported through `onOpen`), a loopback listener in the test as the local target; `docker exec macscp-test-ssh sh -c 'printf hi | nc 127.0.0.1 <port>'` (read the container name from `docker/test-server/compose.yml`) lands `hi` on the test's listener — through `SubprocessRunner`; skip with a reason if `nc` is absent in the image and use `bash -c 'exec 3<>/dev/tcp/127.0.0.1/<port>; printf hi >&3'` instead (say which worked)

- [x] **Step 1: Red first**; **Step 2: Implement**; green + gated green; **Step 3: Commit** `feat(tunnels): a remote forward brings the server's port to this Mac`.

---

### Task 5: `TunnelRunner`, reconnect, the log lines (Core)

**Files:**
- Create: `Sources/macSCPCore/Tunnels/TunnelRunner.swift` (an actor per profile: `start(decider:)`, `stop()`, `state` as an `AsyncStream<TunnelState>`; drives `TunnelStatePlan`; builds the connection (Task 2), then the kind's runtime (Tasks 2–4); on connection loss (`CitadelFileSystem`'s disconnect signal — read `ConnectionLiveness`/`onDisconnect`) with `reconnects` → `.reconnecting(attempt:)`, sleeps `BackoffPlan.delay(attempt:)` through an injected `sleep` seam, retries forever until `stop()`; `.needsConfirmation` when the decider is `.refusing` and the host key is unknown, or the secret source has nothing)
- Modify: `Sources/macSCPCore/Diagnostics/` call sites — `tunnel <name> start|active port=… |failed reason=… |reconnecting attempt=… |stop` at `.info`, category `tunnel` (add it to the secrecy guard's fixed list, count it); each accepted connection at `.debug` with destination and duration; reasons through `DialSupport.reason(for:)` (the `reason:` overload)
- Test: `TunnelRunnerTests.swift` (with a fake connection factory and fake runtimes: the state sequence for a clean start/stop; connection lost → reconnecting with the injected sleep called with 2, 4, 8; stop during backoff ends it; an unknown host key under `.refusing` → `.needsConfirmation`; no secret → `.needsConfirmation`; every wait an `await` on the stream), the secrecy guard's category list updated (positive beside negative)

- [x] **Step 1: Red first**; **Step 2: Implement**; green; **Step 3: Commit** `feat(tunnels): a runner drives a profile through its states, reconnecting with backoff`.

---

### Task 6: `TunnelManager`, the context menu, the profile overlay (App)

**Files:**
- Create: `Sources/MacSCPAppKit/TunnelManager.swift` (`@MainActor final class`, `shared` + `init(store:)` for tests; `profiles(for:)`, `state(of:)`, `start(_:decider:)`, `stop(_:)`, `startAll(for:)`, `stopAll(for:)`, `stopAll()`, `startAutoStart(_ when: AutoStart)`; `@Observable` state for the views; the per-profile runner from Task 5)
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift` (the session row's context menu gains the "Port forwarding" submenu for SSH sessions: profiles with checkmarks, Start all, Stop all, Manage profiles…; the decider handed in is the window's — read how the row's Connect obtains the host-key decider), `Sources/MacSCPAppKit/TunnelProfilesSheet.swift` (new: the table + form from the mockup; validation; Save → store; Start/Stop per row through the manager), the four App catalogs (`tunnel.*` keys; German du)
- Modify: the quit chain (`MacSCPApp.swift`'s deferred quit): `TunnelManager.shared.stopAll()` BEFORE the windows' closures, pinned in the delegate-order guard
- Test: `TunnelManagerTests.swift` (a store in a temp dir, fake runners: start/stop/startAll/stopAll; `startAutoStart(.appStart)` starts only `.appStart` profiles; `stopAll()` stops every running one), `TunnelMenuWiringGuardTests.swift` (the submenu only for SSH — positive + negative; every entry reads its key through `L10n.string(`; the manager is the only caller of the runner's start — positive; no `connect(` in the sheet — negative beside it), catalogue parity, `QuitSequenceTests` gains `.stopTunnels` before `.teardownWindows`

- [x] **Step 1: Red first**; **Step 2: Implement**; green; **Step 3: Commit** `feat(tunnels): profiles per session, started from the context menu, stopped at quit`.

---

### Task 7: Autostart overlay, login item, sidebar glyph, Dock badge and menu (App)

**Files:**
- Create: `Sources/MacSCPAppKit/TunnelAutostartSheet.swift` (Window menu "Forwardings at launch…" + a button in Settings › General: the two toggles and the table from the mockup), `Sources/MacSCPAppKit/LoginItem.swift` (`SMAppService.mainApp` register/unregister/status; the status shown as the system reports it; errors shown in the sheet)
- Modify: `MacSCPApp.swift` (`startAutoStart(.appStart)` after the what's-new decision; `.login` profiles start too when the app was launched as a login item — measure `NSAppleEventManager.shared().currentAppleEvent`'s `keyAEPropLaunchedAsLogInItem` or `ProcessInfo` — if the flag is readable and true only at login launch, ship "Start in the background" (the main window ordered out at such a launch); if not measurable, ship "Open at login" alone and say so in the sheet's footer and the backlog row)
- Modify: `SessionSidebar.swift` (`SessionRow`: the forwarding glyph with count/`!` and colour by the worst state, tooltip with the reason; no glyph without a profile; both densities), `MacSCPApp.swift`/`AppDelegate` (`applicationDockMenu(_:)` with the block; `NSApp.dockTile.badgeLabel` from a pure `DockBadgePlan.label(activeCount:failedCount:) -> String?` — count, `!` on any failure, nil when none active — updated on every state change), the menu-bar model's block when the setting is on, the four catalogs
- Test: `DockBadgePlanTests` (the three cases), `TunnelSidebarGlyphTests` (a pure `TunnelGlyphPlan.glyph(states:) -> (colour, text)?`: none → nil; all stopped → grey no count; one active → green "1"; any failed → red "!"), the sidebar guard (the row reads the plan; positive + negative), `LoginItemTests` (the status mapping from `SMAppService.Status` — pure; registration not exercised in tests), the Dock-menu guard (the block reads the manager; no `connect(` there), catalogue parity

- [x] **Step 1: Red first**; **Step 2: Implement**; green; **Step 3: Commit** `feat(tunnels): autostart at app start or login, and the state in the sidebar and the Dock`.

---

### Task 8: Closeout

- [x] `docs/BACKLOG.md` (a Done row: the eight commits, what shipped per task, the limits from the spec, the sight check — a local forward to a database, a dynamic forward with a browser's SOCKS setting, a remote forward, ⌘Q with a tunnel running, autostart across a relaunch and a login), `README.md` (one sentence, no tech-stack terms), `CLAUDE.md` ("Architecture invariants": the tunnel exception in one clause — tunnels are app-wide, not window-scoped, with an explicit lifecycle), the design's status line, the plan's checkboxes; commit `docs(backlog): port forwarding is in`.
