# Connection Tools: Universal Ping and Trace, Plus a Seam per Protocol — Design Proposal

**Status:** decided 2026-09-02 (night) — the maintainer answered the two
questions at the end: the diagnosis runs **only on the button**, never
automatically after a failed connect; "Copy report" offers **both**
plain text and Markdown, as two entries of one menu. Ready for the
spike (§5) and then a plan. Written from the decisions recorded in
`2026-08-25-backlog-connection-tools.md` (ping = TCP attempt AND ICMP
echo; trace = own-setup log AND network trace; entry points: the tab,
the context menu, the error dialog; the tools are an interface with a
per-protocol seam). Nothing here is implemented.

## The measured starting point

- The app records `AuditEvent`s (`connected`, `disconnected`, transfers,
  …) with a timestamp — but no connect TIMING: nothing today says how
  long name resolution, the TCP dial, the SSH handshake, authentication
  or the SFTP channel took. `CitadelFileSystem.connect` hands the whole
  dial to Citadel as one call with one `connectTimeout`; the stages are
  Citadel's and NIOSSH's, invisible from here.
- The failed-connect surface lives in `SessionTab` (`failedConnect…`)
  and `ContentView+Detail`; it shows the mapped error and a details
  text. No probe exists. `ProtocolCapabilities` has `transport` and
  `supportsRemoteChecksum`, no diagnostics list. `BackendDescriptor`
  contributes `fileActions` per backend — the seam's shape already
  exists for file actions.
- `Network.framework` is not imported anywhere; NIO is (through Citadel).
  Nothing in the tree opens a raw or ICMP socket.

## 1. One tool surface, three doors

`DiagnosticsSurface` is a value the three entry points show, not three
implementations: a section in the tab (below the failed-connect surface
when it is showing, or behind a toolbar item when connected), the
session's context menu ("Diagnose…"), and a button in the error dialog.
All three call one `ConnectionDiagnostics.run(for: config)` and render
the same `DiagnosticReport`.

## 2. The universal half

`ConnectionDiagnostics` (Core, `Diagnostics/`) knows every backend's
`host` and `port` from its config through one descriptor field
(`endpoint(of:) -> (host, port)`), and runs, in order, cancellable, each
step with a wall-clock duration and an outcome:

1. **Resolve** — `getaddrinfo` for the host; the addresses found (A/AAAA),
   the time it took, or the error. No privileges.
2. **TCP ping** — one connection attempt per resolved address on the
   target port with a bounded timeout; "accepted / refused / timed out"
   plus the round-trip time. No privileges. This is what "is anyone
   accepting connections there?" means, and it is the half that works
   everywhere.
3. **ICMP echo** — on macOS an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP`
   socket sends an echo request without root; three probes, the RTTs.
   **Unmeasured:** whether the App Sandbox / hardened-runtime build allows
   that socket, and IPv6 (`IPPROTO_ICMPV6`). This half ships only after
   the spike in §5 says how it behaves in the signed app; until then the
   row says "not available in this build" rather than pretending.
4. **Own-setup trace** — the timings the app CAN see: resolve, TCP,
   then the backend's dial as one step ("SSH handshake + auth + channel"
   for SSH, "first signed request" for S3, "OPTIONS" for WebDAV), each
   with its outcome. Finer SSH stages need a NIOSSH observer (a channel
   handler that timestamps KEXINIT/NEWKEYS/USERAUTH_SUCCESS — a fork-side
   addition, measured first, not assumed); the design leaves a slot for
   it and does not promise it.
5. **Network trace** — hop-by-hop needs TTL-limited probes AND receiving
   ICMP time-exceeded, which on macOS needs a raw socket or a privileged
   helper. **Unmeasured** whether the unprivileged ICMP socket delivers
   time-exceeded; the spike decides. Same rule as 3: absent until proved,
   never faked.

Every step is an `async` function with a deadline; the report is a list
of `DiagnosticStep { name, started, duration, outcome, detail }` plus the
app's build/version line, copyable as text for a bug report. No step
touches a credential: the universal half dials without authenticating.

## 3. The per-protocol seam

`BackendDescriptor` gains `diagnostics: [DiagnosticContribution]` beside
`fileActions`. A contribution is `(id, titleKey, run: (ConnectionConfig, SecretSource?) async -> DiagnosticStep)`.
It MAY authenticate (it is the protocol's own probe, with the session's
credentials, through the same resolver the connect uses — never a second
copy of a secret). Candidates, each its own task later:

- **SSH:** the negotiation as the client saw it — KEX algorithm, host-key
  type, cipher/MAC, which auth method succeeded (agent/file/password),
  and whether the server accepted `rsa-sha2` for the key offered. Reads
  what NIOSSH already knows after `connect`; the fork exposes it.
- **S3:** a signed probe — `HeadBucket` / `ListObjectsV2` with `MaxKeys=1`
  / `ListBuckets` — showing status, `x-amz-request-id`, and which of the
  three the key may do. This is the maintainer's "show the key's access
  level" note (2026-09-02, item 18) and its first home.
- **WebDAV:** `OPTIONS` (the `DAV:` class and `Allow` list) and a
  `PROPFIND` depth 0 on the root — what the server claims to be.

FTP/FTPS and SMB, when they come, add their own contribution and touch
nothing in §2. No code path in §2 branches on `ConnectionKind`.

## 4. What the user sees

A single sheet/panel: the universal steps as rows (name, outcome badge,
duration, one line of detail), then the protocol section, a "Run again"
and a "Copy report" button. Rows for halves that this build cannot do
say so in one sentence (§2.3/§2.5). The context-menu entry works for a
saved session without connecting; the tab's entry pre-fills from the
live connection; the error dialog's button runs it immediately.

## 5. The spike before the plan

One gated, throwaway measurement on this machine, then in the signed
app build: (a) can an unprivileged ICMP datagram socket send an echo
and receive the reply, under the sandbox/hardened runtime the release
uses; (b) does it deliver ICMP time-exceeded for TTL-limited UDP probes;
(c) IPv6 for both. Three outcomes, each written down, decide which rows
§2.3 and §2.5 get. The universal TCP/resolve/own-setup half and the seam
do not wait for the spike.

*Measured 2026-09-03, before the spike:* the app is not sandboxed —
`scripts/release:48` passes no entitlements to `codesign`; the only
entitlement either binary ever carried was a keychain access group. The
spike's sandbox question collapses to "what an unprivileged process gets
from macOS". Plan: `docs/superpowers/plans/2026-09-03-connection-tools-spike.md`.

## Order, if approved

1. Spike (§5).
2. Core: `DiagnosticReport`, `ConnectionDiagnostics` with resolve, TCP
   ping, own-setup trace; the descriptor's `endpoint(of:)` and
   `diagnostics: []`; tests against the rig (an unroutable address for
   the timeout path, the sshd for the accepted path).
3. The three doors and the panel; catalogs.
4. ICMP / network trace per the spike's verdict.
5. First seam contributions: S3 access probe (item 18), SSH negotiation
   (needs the fork's observer), WebDAV OPTIONS.

*Decided 2026-09-02:* (1) only on the button; (2) both, as a two-entry
copy menu (plain text and Markdown).
