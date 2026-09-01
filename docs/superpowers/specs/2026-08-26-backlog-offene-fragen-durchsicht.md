# Backlog: two open questions from the closing review

**Logged:** 2026-08-26, as an addendum to the closing review of the plan
*gescheiterter Aufbau* (`re-review-final.md`). Both points had until then
lived only under `.superpowers/`, which `.gitignore:10` excludes — they
would have vanished with the working directory. **Not a design.** Both
points are explicitly marked as **reasoned, not measured**; that is not
carelessness here, but what a network trial or a concurrency test drive
would have cost for this finding, against the rule of this review not to
pick a real host.

## M3 — An as-yet-unselected saved session origin can be attributed to an ad-hoc failure

**Reasoned only, not carried out.**

`connect(in:stored:)` sets `tab.dialingStoredSessionID = stored.id`
**before** `await form.connect()`. If an ad-hoc dial of the form is
already running at that point, `ConnectionViewModel.connect()` rejects
the second call (`secondConnectWhileConnectingIsRejected`) — without
changing state, so the mirror never consumes the origin. If the
**ad-hoc** attempt then fails, `ConnectFailure` carries `stored.id`, and
the surface offers "Sitzung bearbeiten" for a session this attempt never
selected.

Reachable because the form's connect button does **not** take
`tab.isReconnecting` (only `connect(in:stored:)` does) and
`sidebarConnectTarget` returns the same tab as long as it is not
connected.

**Classification:** purely cosmetic — "Erneut versuchen" would then
select the saved session, which is presumably what the user just clicked.
No security problem, no data mix-up across a window boundary; just a
mislabeled surface for a narrow timing-window case.

**Cheap fix, if anyone takes this on:** have the mirror also clear the
origin when rejecting the second call, or set
`dialingStoredSessionID` only AFTER a confirmed exclusivity check instead
of before it.

## The S3 redirect question

**Open question without evidence, explicitly noted as such — not a
measured finding.**

S3 sets the `Authorization` header by hand and runs over
`URLSession.shared` **without** a delegate, i.e. without redirect control
in code (unlike WebDAV, which uses `WebDAVSessionDelegate` as the only
delegate class in the tree). Whether Foundation's `URLSession` carries
this hand-set `Authorization` header along on an automatic redirect
across a **different origin** cannot be decided without a real network
trial — and the closing review deliberately did not run one (constraint:
no real host).

The header does not carry the secret key, but it does carry the access
key ID and the signature. A carried-along signature to a foreign origin
is not a plaintext credential leak, but it is a request-forgery surface
that would depend on the response of a foreign, redirect-capable
endpoint.

**What this means for taking it on:** before any statement about the
security of this path, it needs either a controlled redirect test (a
local server issuing a 3xx to a second origin, run against `S3FileSystem`'s
real request) or reading up on Foundation's documented behavior for
`Authorization` headers across redirects (which can differ by macOS
version and status code). Until then this is an open question, not a
confirmed bug — and should be cited as such.


---

## Addendum 2026-08-28: the S3 question is measured and cleared

`Authorization` is **not** carried along across a redirect — ten cases,
two origin forms (port only; host and port), five status codes
(301/302/303/307/308), measured against the real signed request over
`URLSession.shared` on macOS 26.6.2 / Swift 6.3.3. The test lives in the
tree (`Tests/macSCPCoreTests/S3RedirectAuthorizationMeasurementTests.swift`)
and re-asks the question on every platform, because Foundation's behavior
here is undocumented and version-dependent.

What the measurement does **not** clear is in
`2026-08-28-backlog-s3-weiterleitungen.md`: the redirect is followed
instead of refused, the hand-set `Host` travels along and is wrong
afterward, and Foundation strips the header even for the same origin —
which would let a legitimate provider redirect arrive unsigned.
Maintainer decision from the same day: take it on as its own change.

**M3 stays open** and is designed in
`2026-08-28-zwei-offene-fragen-design.md`.
