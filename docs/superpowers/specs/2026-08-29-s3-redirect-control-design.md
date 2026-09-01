# Controlling S3 redirects — Design

**Status:** 2026-08-29. Implements
`docs/superpowers/specs/2026-08-28-backlog-s3-redirects.md`.

**This change was not buildable until today.** S3 ran on
`URLSession.shared`, and the shared session cannot carry a delegate. Since
`36a68fe` S3 has had its own session — that is what made control reachable
at all.

---

## The measured starting state

From the 2026-08-28 measurement, ten cases across two origin forms and five
status codes:

| | |
|---|---|
| `Authorization` across a redirect | **is not carried over**, in any case |
| other hand-set headers (`x-amz-date`, `x-amz-content-sha256`, `Host`) | do travel along |
| the redirect itself | is **followed**, not refused |
| same origin, only a different path | the header is **also** stripped |

From this come the three findings the backlog entry records: the foreign
origin learns the bucket path, the list request, the timestamp, and — via
the `Host` that travels along — the configured endpoint; the `Host` is
then wrong; and a **legitimate** redirect would arrive unsigned and fail.

The last point is a functionality question, not a security one — and it is
the reason "reject everything" would be the wrong answer.

## Maintainer decisions (2026-08-29)

### 1. Same origin: re-sign and follow. Foreign origin: reject.

For the same origin, the request is **re-signed for the new target** and
followed. This also fixes the functional bug: the redirect arrives signed
instead of bare.

A foreign origin is **rejected**, with a message that names where the
endpoint tried to send it. Disclosing its bucket path and endpoint is
exactly the request-forgery surface the entry names — and the user is
better off learning that their endpoint tried to send them elsewhere than
having it happen silently.

### 2. "Foreign" means scheme, host and port

The origin definition from RFC 6454, with no discretion. `https` → `http`
is therefore foreign, so is a port change.

Downgrading to plaintext is explicitly the case this covers: a redirect
that strips encryption is the one you least want to follow.

## The design

### A dedicated delegate, not a shared one

`WebDAVSessionDelegate` is already a `URLSessionTaskDelegate`, but answers
a different question (certificates). Merging the two would pull two
policies that share nothing but the protocol shape into one type.

S3 gets its own, small delegate that answers exactly one question.

### The decision is a pure value

Whether a redirect is followed, re-signed, or rejected depends only on two
URLs. That belongs in Core as a testable value — following the model of
`SessionNameCollision` and `SidebarOrdering` — not inside a delegate
method, where it would only be reachable via a real session.

The delegate calls the value and carries out what it says.

### Re-signing means: the same request, a new target

The new request is **built the same way as the first one**, targeting the
redirect destination: method, body and headers from the existing signing
path, not from the request Foundation proposes. The wrong `Host` therefore
falls away on its own — it is re-set for the new target and signed along
with everything else.

**Measured, and recorded here for that reason:** the S3 path has **no**
streamed body — every request body is either in memory or absent. A
request can therefore be replayed faithfully. If a streamed upload is
added later, this assumption is the first thing to re-check: a stream
cannot be read twice.

### Rejecting is an error with content

A rejected redirect ends in an error that states **where** it was going to
be sent. "Connection failed" would be the wrong economy here: the user
could not conclude from it that their endpoint is trying to redirect them,
and that is exactly the information that matters.

The text goes through all four catalogs; the German uses du.

### What happens with the variety of status codes

All redirect codes go through the same decision. 301/302/303 rewrite the
method to GET, 307/308 preserve it — that is Foundation's behavior and it
stays that way. For re-signing, what counts is the method of the request
actually made.

## What no test in this project can see

Everything decidable is testable: the origin rule, that a same-origin
redirect arrives signed, that a foreign one is rejected and the target
appears in the message, and that the `Host` after re-signing matches the
new target. The loopback rig for this already exists
(`S3RedirectAuthorizationMeasurementTests`, `LoopbackHTTPStub`).

**Not testable** is what a real S3 provider does. Measurement is Foundation
against a controlled stub — that suffices for these questions and for
nothing beyond them.

## What is explicitly excluded

- **No change to `WebDAVSessionDelegate`**, and no shared redirect policy
  across both backends.
- **No setting** to turn off the rejection. Anyone who wants to trust a
  redirected endpoint enters it as the endpoint.
- **No change to the signing path itself**, only a second call to it.
- No handling of `x-amz-bucket-region` region changes as a separate case —
  a provider that redirects that way does so within its own origin, or is
  rejected like any other.
