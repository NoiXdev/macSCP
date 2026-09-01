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
