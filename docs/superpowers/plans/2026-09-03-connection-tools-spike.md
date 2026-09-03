# Connection Tools — the ICMP Spike — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer §5 of `docs/superpowers/specs/2026-09-02-connection-tools-design.md`
with measurements, so the plan for the tools can say which rows ICMP
echo and the network trace get.

**Measured before writing this plan (2026-09-03):** the app is **not
sandboxed** — `scripts/release:48` passes no entitlements to `codesign`
and says so; the only entitlement ever carried was a keychain access
group. The design's "under the sandbox/hardened runtime" question
therefore reduces to: what does an unprivileged process get from macOS.
Hardened runtime does not restrict sockets.

**Architecture:** one gated test file, `Tests/macSCPCoreTests/ICMPSpikeTests.swift`,
`.enabled(if: MACSCP_NETSPIKE=1)`, that opens `socket(AF_INET, SOCK_DGRAM,
IPPROTO_ICMP)` (and `AF_INET6`/`IPPROTO_ICMPV6`) without privileges,
sends an echo request, and reads the reply with a bounded `poll`; a
second test sends a UDP datagram with `IP_TTL=1` toward `192.0.2.1`
(TEST-NET-1, unroutable — the packet dies at the LAN's first router,
which answers with ICMP time-exceeded, so nothing leaves the local
network) and reads whether the unprivileged ICMP socket delivers that
time-exceeded message. Every read is bounded (2 s) and non-blocking
from the pool's point of view: the socket work runs on a
`DispatchQueue` created for the test and is awaited through a
continuation, never `poll`ed on a cooperative thread (CLAUDE.md "Tests
never block the cooperative pool"). The tests print their verdicts; a
"no" is a green test with a printed outcome, not a red.

**Tech Stack:** Darwin sockets, Swift Testing.

## Global Constraints

- Loopback and the LAN's first hop only; no packet to a remote host.
- Gated; skipped by default; leaves no socket behind (`defer { close }`).
- The verdicts are written into the design's §5 with the date, the
  macOS version and the exact outcomes (`errno` values on failure).
- English; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; zero warnings; no push.

---

### Task 1: The three measurements

**Files:**
- Create: `Tests/macSCPCoreTests/ICMPSpikeTests.swift`
- Modify: `docs/superpowers/specs/2026-09-02-connection-tools-design.md` §5 (the verdicts)

- [ ] (a) IPv4 echo to `127.0.0.1` and IPv6 echo to `::1` through unprivileged
  ICMP datagram sockets: socket creation `errno`, send result, whether a
  reply arrives inside 2 s, the reply's identifier/sequence as delivered
  (macOS rewrites the identifier on DGRAM ICMP sockets — record what
  comes back).
- [ ] (b) `IP_TTL=1` UDP datagram to `192.0.2.1:33434`; does the ICMP
  DGRAM socket deliver the time-exceeded message inside 2 s, and does the
  UDP socket itself report an error (`SO_RECVERR` does not exist on
  macOS — record what `recvfrom`/`getsockopt(SO_ERROR)` say).
- [ ] (c) the same as (b) over IPv6 (`IPV6_UNICAST_HOPS=1` toward `2001:db8::1`),
  if the machine has a global IPv6 route; otherwise record "no IPv6 route,
  unmeasured".
- [ ] Write the three verdicts into the design's §5 as a dated block, one
  line per measurement, with the raw numbers. Commit
  `test(spike): unprivileged ICMP echo and time-exceeded, measured` — the
  test file stays in the tree, gated, as the record of how it was measured.

## What follows

The tools plan (`2026-09-03-connection-tools.md`, to be written after
this spike) takes §2.3 / §2.5 rows from the verdicts.
