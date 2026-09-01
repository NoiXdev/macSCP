# Connection state: detection, display, recovery

**Status:** design, accepted by the maintainer 2026-08-21.

Combines three backlog entries because they share **one** state model:
A1 (error view in the tab with "Reconnect", state symbol on the tab) and A2
(keep-alive) from `2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`, plus
B-1 (freezing on a dead host) from `2026-08-20-bugs.md`.

Built separately, these would end up as three paths trying to say the same
thing: "connecting", "connected", "lost".

## What has already been measured

Checked against the source, not assumed:

- **Neither Citadel nor NIOSSH knows keep-alive.** NIOSSH's only public
  send API for global requests is `sendTCPForwardingRequest`; a custom
  `keepalive@openssh.com` cannot be sent through it.
- **Citadel's `session` is `internal`.** Neither the channel nor the
  `NIOSSHHandler` is reachable from outside. A keep-alive at the SSH level
  is therefore ruled out.
- **`SSHClient.isConnected`** (reads `channel.isActive`) and
  **`onDisconnect(perform:)`** are public and usable for detection.
- **`SSHClient.connect(host:port:…)` has a parameter
  `connectTimeout: TimeAmount = .seconds(30)`**, which `CitadelFileSystem`
  does not pass at **either** call site — jump hop and target. B-1's long
  wait is therefore an unset default, not a restructuring.
- **`RemoteFileSystem.stat(path:)`** is the cheapest round trip in the
  protocol and therefore the probe.

## 1. State model

One value per session, in Core:

| State | Dot | Meaning |
|---|---|---|
| `connecting` | yellow | setup in progress, cancelable |
| `connected` | green | last proof succeeded |
| `degraded` | yellow | one probe failed, a second attempt is running |
| `lost` | red | given up, session torn down |

The state belongs to the session at the **window scope**, never to an
app-wide singleton — existing architecture invariant.

`degraded` is not decoration: without it, a single lost probe would have to
go straight to red, and a single dropped packet would look like a
disconnect.

## 2. Detection

A timer per session, interval from settings.

On each tick:

1. **If the queue has work, it is skipped.** Traffic in flight proves the
   connection better than any probe, and an extra request during a transfer
   is pure interference.
2. Otherwise `stat` on the **home path determined at connect time**
   (`homeDirectoryPath()` runs during setup anyway) — no extra round trip
   just to find the path first.
3. Success → `connected`.
4. Failure or its own deadline expired → `degraded`, **one** immediate
   second attempt. If that also fails → `lost`.

The decision logic (skip / send / retry / give up) is a pure function over
(queue busy, last result, failed attempts) and belongs tested as its own
type, separate from the timer.

## 3. Recovery

`lost` shows the error view in the tab: what happened, and **"Reconnect"**.

The rebuild runs through the **same** connection path as a fresh setup.
That is the load-bearing decision of this section: TOFU remains a hard
stop, the keychain rules stay unchanged, and no second path exists where a
security rule could be forgotten.

Configurable behavior:

- **`offerOnly` (default)** — nothing happens without a click.
- **`onceThenAsk`** — one automatic attempt, then the error view.
- **`automatic`** — repeated attempts, first after 5s, then doubling the
  interval each time up to a maximum of 60s, with no give-up limit.
  Cancelable at any time; a cancel leads to the error view.

Even with `automatic`: an attempt that runs into TOFU or a passphrase ends
in the error view and is not retried in the background.

## 4. Connection setup (B-1)

Setup becomes a **cancelable task** and uses the same tab area:
"Connecting …" with cancel, while the rest of the app stays usable.

For this, `connectTimeout` is passed at both call sites, with a shorter
default than the inherited 30 seconds.

**Deliberately without a precondition:** whether the main thread actually
blocks today, or whether it's just a dead modal surface that looks like it,
is **not measured** (the app is not launched in this working mode). The
chosen form fixes both cases, so the question doesn't need to be answered
beforehand. If implementation reveals that it really does block, that is
its own finding and should be reported.

Noted in passing, not part of this scope: `AgentBackedPrivateKey` waits
blockingly with `semaphore.wait(timeout:)` in an otherwise asynchronous
path.

## 5. Transfers

On `lost`:

- The **running** transfer fails with the reason "Connection lost."
- The **waiting** ones stay in the list and are flagged — nothing is
  silently discarded.
- **No automatic resumption.** A half-written file on the other side is a
  conflict case that needs the existing conflict rules, not a silent
  decision.

Teardown goes through the existing sequence — `cancelAll` → terminal
`shutdown` → `disconnect` —, not around it. The queue invariants (FIFO,
exactly-once continuations, no orphaned shells) apply unchanged.

## 6. Settings

Three values in `SettingsStore`:

| Value | Default | Note |
|---|---|---|
| Reconnect behavior | `offerOnly` | the three cases from section 3 |
| Heartbeat interval | 60s | 0 turns the probe off |
| Connection setup deadline | 10s | NIO's own default; Citadel overrides it to 30. Applies to the **TCP setup of every hop** the deadline reaches — see the caveat below |

**Correction, measured 2026-08-21:** an earlier version of this spec
claimed the deadline applies "to each hop individually, including the jump
host." That is not true. Only the **first** hop goes through
`SSHClient.connect`, which accepts the deadline. The second runs through
Citadel's `jump(to:)`, which does not read `connectTimeout` at all — there
a hard-wired `loginTimeout` of 10 seconds limits it instead, and we cannot
reach that. A chain with a jump host is therefore only half configurable.
That belongs in the backlog, not in this scope.

The **probe's** deadline is deliberately **not** a setting: it must be
shorter than the interval, otherwise probes overtake each other. It is
derived from the interval — half the interval duration, capped at 10s on
the upper end — and this derivation belongs tested. At interval 0 no probe
runs, so the deadline is then moot.

## 7. Localization

All new strings in `en`, `de`, `fr`, and `pl`; a guard test enforces equal
key sets. Affected: the error view, the cancel button, the three settings
along with their explanation, the reason "Connection lost" on the transfer,
and the short-help texts for the three dot colors.

## 8. Testability

- **Unit:** state machine, probe rule, derivation of the probe deadline,
  fallback intervals under `automatic`. Pure logic, normal tests.
- **Docker rig (`MACSCP_ITEST=1`):** a real disconnect can be produced
  (stopping the container) and `lost` proven; likewise that the probe
  succeeds against a live counterpart and stays quiet while the queue is
  busy.
- **Visual check by the maintainer:** the dot on the tab in all three
  colors, the error view, the cancel button during setup. No test in this
  project renders SwiftUI.

## 9. Explicitly out of scope

- **No keep-alive at the socket level** (`SO_KEEPALIVE`). It was
  considered: no log noise, but macOS by default leaves such a socket idle
  for two hours, fine-tuning it only works through raw socket options, and
  a live TCP socket proves nothing about SSH or SFTP on top of it — and it
  would in practice be untested.
- **No resuming of interrupted transfers.**
- **No change to TOFU, the keychain, or the connection path itself.**

## 10. Text question for implementation

Whether the error view shows the technical reason or only an
understandable summary is decided when the texts are written. What is
fixed is the requirement: it may contain **no** secret and no value typed
by the user — the same rule that applies to logs, exports, and error
messages throughout the project.
