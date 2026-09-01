# Backlog: S3 follows redirects without control

**Logged:** 2026-08-28, from the measurement that answered the closing
review's S3 question. **The security question is answered and cleared**
— what stands here are the findings beside it.

**Maintainer decision (2026-08-28): take it on, as its own change.**
Not because of the signature.

## What was measured, and what came out of it

Measured with `S3FileSystem.connect` without an injected transport — i.e.
the real signed request over `URLSessionHTTPTransport()` and thus
`URLSession.shared`. Two origin forms, five status codes, ten cases.
macOS 26.6.2 (25G83), Swift 6.3.3, CFNetwork 3860.700.1.

**`Authorization` is not carried along. In none of the ten cases.**

This refutes the original concern — a signature reaching a foreign
origin. The test lives in the tree and re-asks the same question on every
platform the suite runs on; that is deliberate, because Foundation's
behavior here is undocumented and version-dependent.

## The three findings that remain

### 1. The redirect is followed, not refused

The foreign origin learns the bucket path, the list query, `x-amz-date`,
`x-amz-content-sha256` — and, via the carried-along `Host`, the
configured endpoint. No signature, no access key ID. But not nothing
either.

**This is the reason for the change.** It fixes nothing hypothetical:
the exposure is measured, just smaller than feared.

### 2. The hand-set `Host` travels along and is wrong afterward

S3 sets `Host` explicitly because it is part of the SigV4 signature.
After a jump to a different origin, the request still carries the old
value — measured: a request to `localhost:<p2>` with
`Host: 127.0.0.1:<p1>`.

Not a credential problem, but a misaddressed request under
virtual-hosted addressing. And it is the path through which finding 1
exposes the endpoint.

### 3. Foundation strips the header on **every** redirect

Even for the same origin and only a different path — measured in the
control arm.

This is not a security question but a **functionality question**: a
legitimate redirect from a provider would arrive unsigned and get
rejected. Nobody has seen such a case; it belongs here so the fix does
not overlook it.

## What a change would need to clarify

The seam already exists and is used as it is:
`URLSessionHTTPTransport(session:)`. WebDAV runs exactly this way, with
`URLSessionConfiguration.ephemeral` and `WebDAVSessionDelegate` as the
only delegate class in the tree. **`URLSession.shared` cannot carry a
delegate** — that is the entire reason no control sits in the S3 path.

Open, to be decided while designing:

- **Refuse, or follow with a re-signed request?** Refusing a redirect
  across a foreign origin is the stricter and simpler answer. Following
  it and signing anew for the new target additionally fixes finding 3 —
  and is considerably more work, because the signature binds the `Host`.
- **What "foreign" means.** Scheme, host and port, or only the host? The
  measurement shows that Foundation does not distinguish here at all;
  the project would have to define this itself.
- **Does the same apply to `sendStreaming`?** The download path goes
  through `URLSession.bytes(for:)` — the same session, a different
  Foundation entry point. **Not measured.** Measure before designing.

## What this is not

- **Not a leak fix.** There is none; the measurement says so explicitly.
- **No change to WebDAV's delegate**, and no shared redirect policy
  across both backends, before someone has designed one.
- No statement about real S3 providers. Foundation was measured against
  a controlled stub on loopback — that suffices for the question asked
  and for nothing beyond it.
