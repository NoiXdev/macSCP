# Backlog: S3 rides the shared URL session

**Created:** 2026-08-29, as a production finding from diagnosing a flaky
test. **Measured**, not assumed — but the consequences in live operation are
**not** measured, and the difference is laid out below.

**Done 2026-08-29** (see "What came of it" at the end). The text below
stays in the state it was in when this entry was filed; the closing section
says which parts of that are now wrong.

## The counted finding

`URLSessionHTTPTransport.init` carries the default value `session:
URLSession = .shared`, and `S3FileSystem.connect` takes that default.
**S3 is the only path in the tree on the shared session** — recounted in
this pass:

| Path | Session |
|---|---|
| S3 | `URLSession.shared` |
| WebDAV | own, from `URLSessionConfiguration.ephemeral` |
| Update check | own, from `.ephemeral` |

`URLSession.shared` uses `URLCache.shared`: a **persistent on-disk cache**
shared by every process on the machine, living under `~/Library/Caches`.

## How it was found

Not by reading. A test answering the S3 redirect question failed
occasionally; the obvious explanation (tight timing under load) was wrong.
80 runs showed: **without load it failed more often**, and with
`URLCache.shared` cleared it stopped failing entirely. Proved across two
processes — a second `swift test` process with no listener of its own found
`cachedEntry=true status=308` and followed a Location that an earlier
process had left behind.

The full chain is in
`2026-08-08-testsuite-hang-investigation.md`.

## Why this is more than a test quirk

**Measured**: that an endpoint's 301 and 308 responses land on disk and get
served again **across processes**.

**Follows from that, unmeasured in live operation:**

1. **S3 responses sit in `~/Library/Caches`** — bucket listings, and
   depending on headers, object responses too. Unencrypted, outside any
   flow macSCP controls. The rest of this project puts secrets exclusively
   in the Keychain and never writes them to a JSON file; bucket contents
   are not a secret of the same class, but they are not nothing either.
2. **A permanent redirect (301/308) delivered once acts across restarts.**
   If an endpoint answers once with a 301 to a foreign origin, macSCP may
   subsequently follow that redirect from cache — without ever asking the
   real endpoint. This is the same class of question that
   `2026-08-29-backlog-s3-weiterleitungen.md` asks, only longer-lived.
3. **The session is shared.** Cookies, credential cache, and connection
   reuse of `URLSession.shared` apply to everything that uses it.

## What would need to be done

**The seam already exists and WebDAV already uses it:**
`URLSessionHTTPTransport(session:)`. S3 would get its own session from
`URLSessionConfiguration.ephemeral`, the way WebDAV has one.

To decide before implementing:

- **Is `ephemeral` enough, or should `URLSessionHTTPTransport`'s default
  value disappear entirely?** A default value that points at process-wide
  shared state is exactly the kind this project already removed from
  `SessionListViewModel.init` — dropping it compiled there, and whoever
  dropped it got the real call site. Here it is the same pattern.
- **What this means for the download path.** `sendStreaming` goes through
  `URLSession.bytes(for:)`; whether the same caching question applies
  there is **unmeasured** and belongs before the design.
- **Whether a dedicated session costs something** that today comes
  silently from the shared one — connection reuse across multiple
  requests is the candidate.

## What this is not

- **Not a confirmed leak.** That responses get cached is measured; that a
  user is harmed by it is not.
- **No change to WebDAV**, which already does it right.
- Not a rebuild of `HTTPTransport` as the seam — it is sufficient and used
  as it is.

---

## What came of it (2026-08-29)

Both decisions implemented as proposed:

1. **S3 builds its own session** from `URLSessionConfiguration.ephemeral`
   and releases it in `disconnect()` — like `WebDAVFileSystem`. Before,
   `disconnect()` was empty; a dial attempt that fails now closes the
   session too, instead of leaving it standing.
2. **`URLSessionHTTPTransport.init`'s default value is gone.** Four
   construction sites, each naming its session. The rule is now carried by
   the compiler, not by a guard that buys one spelling and lets another
   through.

### The three questions the entry posed before the design

**"Does a cached permanent redirect act across restarts?"** Yes,
remeasured across processes. Process A fetches a 308 to a second loopback
port through a disk-backed `URLCache`. Process B, with **no listener
anywhere**, requests the same URL: it fails with
`NSURLErrorCannotConnectToHost` at the **target** port. It never asked the
origin. That closes the chain: `URLSession.shared.configuration.urlCache`
*is* `URLCache.shared` (object identity checked), 20 MB of disk under
`~/Library/Caches`. `URLSessionConfiguration.ephemeral`, by contrast,
hands out a **fresh** cache instance per session with `diskCapacity == 0`
— not just no disk, but nothing shared between two connections of the same
process either.

**"What does that mean for the download path?" — the open measurement.**
`sendStreaming` over `URLSession.bytes(for:)` behaves **identically**: the
same cached 308 was replayed across processes, and a
`Cache-Control: max-age=3600` response with a body landed on disk and was
served to the second process from there, **body included**. The question
was "whether the same caching question applies there" — the answer is
yes, without qualification. Object contents a provider marks cacheable
thus sat unencrypted in `~/Library/Caches`.

**"Does a dedicated session cost something?"** Connection reuse does not:
it is a property of *one* session across multiple requests, and the
session now lives exactly as long as the `S3FileSystem` that built it —
i.e., across all `list`/`stat`/`readStream`/`write` calls of one
connection. What is lost is only what `URLSession.shared` shared **between
independent connections**: connection pool, cookie storage, and credential
cache. For S3 that is nothing that is needed — S3 signs every request
individually and sets no cookies — and shared state between two windows is
exactly what this project's window rule excludes.

### What remains open

The session carries **no delegate**. It *could* now carry one, which was
not possible under `URLSession.shared` at all — the redirect control from
`2026-08-28-backlog-s3-redirects.md` has thereby become reachable,
but not built. A separate task, as decided there.
