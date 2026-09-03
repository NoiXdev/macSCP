# Backlog: tools for investigating a connection

**Created:** 2026-08-25, from a maintainer note. A solid idea, **not a
design**.

## The wish

Per-connection tools for investigating a dead line: **ping**, **trace**,
similar. And explicitly **also without a stored host** — with a field
for an IP or domain, so you can check something you haven't even set up
yet.

## Why this is a natural fit right now

The connection-state branch taught the app to **notice** a lost
connection and **show** it. What's missing is the user's next question:
*what's causing it?* Today the information ends at "no connection
possible" plus a technical message in the details dialog — what the app
knows, but not what the line is doing.

The error branch also measured that a timeout and a hanging name service
behave completely differently and today look the same. Exactly this
distinction is what such tools would make visible.

## To clarify before a design

**What does "ping" actually mean here?** A real ICMP echo needs elevated
privileges or a special socket type; a TCP connection attempt to the
target port doesn't need that and answers the practically more
interesting question — *is anyone accepting connections there?* That's
the first decision and it determines the whole scope.

**What does "trace" mean?** Tracing a path through the network is again
a privilege matter. A log of what **macSCP's own connection setup**
does — name resolved, TCP up, handshake, authentication, channel open,
with timings — would presumably be more useful and is fully within its
own control. It answers "what's it hanging on?" more precisely than a
traceroute, because it shows the layers this program actually goes
through.

**Where does this live?** A dedicated window, an area in the tab, or a
path from the error surface's details dialog. The last one would have
the advantage of landing where the question arises.

**And different per protocol?** For SSH the handshake is interesting,
for S3 and WebDAV more the HTTP response. If the tools differ, the same
rule applies as for the tab menu: **contributions through the
`BackendDescriptor`, no `switch` over the kind.**

## Two conditions that hold from the start

**No secret in the output.** A connection log is exactly the kind of
surface where a password ends up when nobody's looking — this branch
closed three such leaks, two of them in texts considered harmless
diagnostics. What the tool outputs needs to be built from the start so a
secret has no place there, rather than filtering it out afterward.

**And it stays a tool.** A field for an arbitrary address is a way to
open connections to arbitrary hosts. What it's allowed to do needs to be
narrowly scoped: check whether someone answers there — not log in, not
save anything, not pin anything. In particular, an attempt from this
field must **not write any trust decision**; exactly this mix-up was the
most serious finding of this branch.

## Decided 2026-09-02 — what ping and trace mean here, and where they live

The maintainer's answers to the three questions above:

- **Ping: both.** A TCP connection attempt to the target port with timing
  (no privileges, answers "is anyone accepting connections there?") AND
  an ICMP echo. The ICMP half needs a measurement before a design: macOS
  allows an unprivileged ICMP datagram socket
  (`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`) for echo requests, but
  the sandbox/entitlement situation for the App Store build and IPv6
  (`IPPROTO_ICMPV6`) must be measured, not assumed — a spike task.
- **Trace: both.** A log of macSCP's own connection setup (name resolved,
  TCP up, handshake, authentication, channel open, with timings — fully
  within its own control) AND a network trace. The network half is again
  a privilege question: receiving ICMP time-exceeded for UDP/TCP probes
  ordinarily needs a raw socket; whether the unprivileged ICMP socket
  delivers those on macOS is the same spike.
- **Where: in the tab, in the context menu, and from the error dialog.**
  Three entry points onto one tool surface, so the design must make the
  surface a value the three call, not three implementations.

Order: the own-setup log and the TCP ping first (no privilege question,
answers the maintainer's "what is it hanging on?"), then the ICMP/route
halves behind the spike's verdict. Needs brainstorming → design →
plan; not yet planned.

## Done 2026-09-03

Shipped, plan `docs/superpowers/plans/2026-09-03-connection-tools.md`,
commits `8997c955`, `ea9ea544`, `64854401`, `35e456da` (Task 1: resolve,
TCP ping, the dial, the report/runner seam); `1f525642`, `42a730e7`,
`ae0be51f` (Task 2: ICMP echo); `d4e2e8e9`, `1a4573a1`, `4456836d`
(Task 3: IPv4 network trace); `9d232320`, `01ee5218`, `bf3b3bd4`,
`287d4d2d`, `d6cec28b` (Task 4: the panel behind three doors); `5828610f`
(Task 5: S3 and WebDAV contributions); `a4c59a2b`, `b6e181f3` (the
orphan-issue and flake fix rounds). CI green at `35e456da` (run
33728368993), `ae0be51f` (33731482467), `d6cec28b` (33772501551, 3976
tests in 40.8 s, warning gate 1/1); red at `4456836d` (33741778350 — one
issue with no test verdict line: the job log loses lines under
interleaved output) and `b6e181f3` (33770684841 — tests green, warning
gate red: a redundant `#require` on Swift 6.1.2, fixed in Task 4's fix
round 4).

**What shipped:**

- **Resolve, TCP ping and the dial**, one report behind the descriptor
  seam (`ConnectionDiagnostics`, `HostResolver`, `TCPPing`,
  `DialProbes`) — SSH's dial is the full connect (Citadel exposes no
  transport-only handshake), S3's an unsigned `HEAD`, WebDAV's an
  unauthenticated `OPTIONS`.
- **ICMP echo**, matched on a payload marker plus an 8-byte per-socket
  nonce rather than sequence alone: measured that an unprivileged
  `SOCK_DGRAM`/`IPPROTO_ICMP` socket is not demultiplexed by the
  kernel — a plain `ping` run by another process on the same machine
  delivers its replies to this probe's socket too (`ping -c 3
  127.0.0.1` from a separate process landed three foreign datagrams on
  a socket that had sent nothing). Both IPv4 and IPv6 confirmed working
  unprivileged, per the spike's verdict (a).
- **The IPv4 network trace**, with its own 20 s budget separate from
  the runner's per-step deadline, and honest endings: a hop the budget
  cut short is marked as such rather than printed as a silent `*`, a
  kernel refusal after measured hops ends the walk `.failed` with the
  hops kept, and a hop limit reached with at least one answer is `.ok`
  with a marker rather than `.timedOut`.
- **The panel**, behind three doors (tab toolbar, session context menu,
  connect-error dialog) landing on one entry
  (`ContentView.showDiagnostics(for:)`), with rows appearing
  incrementally as each step finishes and a diagnosis bound to the tab
  that opened it — teardown of that tab stops the run and keeps the
  rows measured so far; a cancelled or in-progress report says so in
  its copied text.
- **S3 access level and WebDAV server claims**, as the seam's first two
  contributions: three signed S3 calls (`HeadBucket`, `ListObjectsV2`,
  `ListBuckets`) narrowest to widest, each reported with its status and
  request id; an authenticated `OPTIONS` plus a depth-0 `PROPFIND` for
  WebDAV, reporting the `DAV:`/`Allow:` claims and the root's resource
  type.

**What stays open:**

- **SSH's negotiation contribution** needs the swift-nio-ssh fork's own
  observer (KEX/host-key/cipher/auth-method timestamps); the descriptor
  ships `diagnostics: []` for SSH and says so.
- **IPv6 network trace is unmeasured** — the spike found no IPv6 route
  on the measuring machine (verdict (c)), and the trace refuses a
  non-IPv4 destination rather than guess.
- **The trace's 20 s budget is a judgement, not a measurement** — no
  real internet path has been traced with this build.
- **`traceHopUnreachable`** (a mid-path destination-unreachable with a
  code other than port-unreachable) has never gone red from a real
  network message, only from a hand-built value case — loopback only
  ever sends code 3.
- **The twelve cancellation sites** in `ConnectionDiagnostics.run()`
  are a convention (a required `Completion` argument stops one from
  inheriting `.complete` silently) rather than a structural guarantee;
  nothing stops a future site from spelling `report(.complete)`
  deliberately.
- **The panel's detail-renderer blind spot**: the guard that requires
  every printed detail to go through
  `DiagnosticsPresentation.detail(of:)` has a rewrite it cannot see
  (`let d = step.detail; Text(d)`); closing it wants a structural row
  type the panel cannot draw un-rendered, which is a design decision
  rather than a fix.

## Decided 2026-09-02 (night) — order, and the shape: universal tools plus a per-protocol seam

The maintainer set the order for what follows the fork work: the
checksum column, then CLI completion, then THIS entry — ahead of the
FTP/FTPS and SMB designs. And one more decision for the design: the
tools are an **interface**. Ping (TCP attempt + ICMP echo) and trace
(own-setup log + network trace) are universal — every backend gets them
from one implementation — and beside them the surface carries a
**per-protocol seam** for diagnostics only that protocol has, contributed
the way `BackendDescriptor` already contributes file actions: SSH could
offer the key-exchange and authentication negotiation as read from the
client (algorithms offered/chosen, the host-key type, which auth method
succeeded), S3 a signed probe request with the response status and
headers, WebDAV an `OPTIONS`/`PROPFIND` probe with the DAV class the
server claims. Which of those exist at first is the design's call; the
seam is the requirement, so a fourth backend (FTP, SMB) adds its own
without touching the universal half. No code path in the universal half
branches on `ConnectionKind`.

**Appended by the controller, 2026-09-03 (after the closeout commit):**
Task 5's fix round `4fc60452` — the S3 probe signs the file system's own
request shapes through one `S3RequestSigning.signedRequest` factory (the
probe can no longer pair a URL with a canonical path of its own; the
four builders are `private` again), the catalogue guard compares
`Sources/` against `en.lproj` as a set in both directions, and the
endpoint-with-userinfo-containing-`/` vector is pinned. Open item added
to `docs/BACKLOG.md`: `DialSupport.reason(for:)` renders `RemoteFSError`
by `String(describing:)` — the general route by which a
configuration-carrying error could reach any dial's row; this plan closed
the two paths its own rows added, not the route.
Round 2 of the same task, `64a5dc5a`: the presigned URL signs the same
pairing (`addressed(_:query:config:)`, read by both signers), pinned by
a test over both path styles; the doors guard's doc names the
key-lands-with-first-use constraint.

## Selective runs and the hop table, 2026-09-03

Maintainer feedback on the dev build: the panel can stay as it is, but
running the whole diagnosis for one question is wasteful, and the
trace's hop list is hard to read as one detail line. Plan
`docs/superpowers/plans/2026-09-03-diagnostics-selective-runs.md`,
commits `0176da62`, `5ea7f2ba`, `7a81a455`, `36edabd4`.

- **`0176da62`** — `DiagnosticScope` (`complete`, `ping`, `trace`,
  `dial`, `contributions`) as a parameter of
  `ConnectionDiagnostics.run(scope:onStep:)`, default `.complete`; a
  step outside the chosen scope produces no row at all. A scoped report
  names its scope in a `Scope:` line in both the plain-text and the
  Markdown renderer; a complete report renders unchanged.
- **`5ea7f2ba`** — `DiagnosticTable` on `DiagnosticStep`: the trace step
  carries one row per hop, measured and silent alike, with columns hop,
  address, RTT in ms, outcome. `plainText()` renders it as aligned
  columns, `markdown()` as a Markdown table. The column keys
  (`diagnostics.trace.column.hop/address/rtt/outcome`) landed in all
  four App catalogs in this commit.
- **`7a81a455`** — the panel gains a menu-style scope picker beside Run
  that only changes what the next press does; the trace row renders as
  a grid with localized headers and outcome words
  (`diagnostics.trace.outcome.*`), the detail line staying for rows
  without a table. The mid-run "Copy" snapshot carries the scope the
  in-flight walk started with, not whatever the menu shows at the
  moment of copying. Keys `diagnostics.scope` and
  `diagnostics.scope.*` in all four catalogs.

- **`36edabd4`** — the trace's four outcome words are looked up, not
  passed through: the `en` values are capitalized so a lookup differs
  from the word Core composed, four round-trip assertions pin each key,
  the grid asserts a rectangular table in debug builds, and two comment
  counts in `ConnectionDiagnostics.swift` were corrected.

Full suite green after each commit, 4049 tests in 345 suites after
`36edabd4`.
