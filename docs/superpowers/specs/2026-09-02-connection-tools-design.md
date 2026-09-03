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
live connection; the error dialog's button opens the panel pre-filled from the failed attempt, with Run as the default button — it does not run by itself (decided 2026-09-02: diagnostics run only on the button; the earlier wording here said "runs it immediately" and was corrected 2026-09-03 after a guard review found it would have licensed exactly the automatic start the guard forbids).

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

### Verdicts — measured 2026-09-03, macOS 26.6.2, uid 501, unsigned `swift test` binary

Measured by `Tests/macSCPCoreTests/ICMPSpikeTests.swift`
(`MACSCP_NETSPIKE=1 swift test --filter ICMPSpikeTests`), three runs, all
three agreeing on every line below; the numbers are run 1 / 2 / 3.

- **(a) ICMP echo — yes, both families.** `socket(AF_INET, SOCK_DGRAM,
  IPPROTO_ICMP)` = fd 3 and `socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)`
  = fd 3, both without privileges, no `errno`. `sendto` = 25 of 25 bytes
  each. IPv4 echo reply (type 0, code 0) from `127.0.0.1` after 1.360 /
  1.375 / 0.215 ms; IPv6 echo reply (type 129, code 0) from `::1` after
  0.184 / 1.050 / 0.213 ms. **The identifier is NOT rewritten** on this
  version: sent 3006/3024/3072, delivered 3006/3024/3072, sequence 1 in
  every run — the design's assumption that macOS renumbers a DGRAM ICMP
  socket's echoes did not hold here, so a matcher may use the identifier
  but must not depend on it being the one it wrote. Two shapes an
  implementation has to handle: the IPv4 socket delivers **the IP header
  too** (45 bytes = 20 + 8 + 17 payload, `ip header included=true`, so the
  reader skips IHL×4), the IPv6 socket does not (25 bytes); and the IPv6
  socket **also receives its own outgoing echo request** (type 128, same
  identifier, from `::1`, 0.126–1.009 ms before the reply), so reading one
  datagram and calling it the reply is wrong — filter on type, or set
  `ICMP6_FILTER`.
- **(b) IPv4 time-exceeded — yes.** A UDP datagram to TEST-NET-1
  `192.0.2.1:33434` with `IP_TTL = 1` (`setsockopt` = 0, `connect` = 0
  sending nothing, `send` = 17 bytes) produced ICMP **type 11 code 0** on
  the unprivileged ICMP DGRAM socket after 3.326 / 4.000 / 3.513 ms,
  sourced from the LAN's first-hop router (an RFC 1918 address, kept out
  of this record deliberately — the repository is public and the exact
  address is site topology, not evidence), 73 bytes with the IP header,
  quoting 45 bytes of the original datagram. The UDP socket's own two
  exits, read after the 2 s window: `getsockopt(SO_ERROR)` = **65
  `EHOSTUNREACH`** and `recv(MSG_DONTWAIT)` = -1 `errno` 35 `EAGAIN`, in
  all three runs. So the UDP socket learns only *that* the probe died —
  `EHOSTUNREACH` does not distinguish time-exceeded from unreachable and
  carries no hop address; the ICMP socket is what identifies the hop.
  (`SO_RECVERR` does not exist on macOS, as expected.)
- **(c) IPv6 time-exceeded — no IPv6 route, unmeasured.** The route probe
  (`connect` of an unconnected UDP socket to `2001:db8::1`, which puts no
  packet on the wire) = -1, `errno` 65 `EHOSTUNREACH`, in all three runs;
  this machine has no global IPv6 address, only link-local. **Nothing was
  sent.** The IPv6 trace path is therefore untested, not refused — it must
  be measured again on a machine with a global IPv6 route before §2.5
  claims it works, and it may not be inferred from (a) or (b).

What is still unmeasured for all three: the **signed, notarized release
build**. The app is not sandboxed (`scripts/release:48`) and the hardened
runtime does not restrict sockets, so no difference is expected — but
expected is not measured, and this record says so.

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
