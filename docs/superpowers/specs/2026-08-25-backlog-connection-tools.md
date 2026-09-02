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

