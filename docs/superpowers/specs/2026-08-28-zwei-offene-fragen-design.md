# Two open questions from the closing review — design

**Status:** 2026-08-28. Implementation of
`docs/superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md`.

The entry lists two items that have nothing to do with each other except
their origin. They are designed here together because they were noted
together — but they share no source code, and one half is **not yet
designable** today.

---

## The asymmetry first

**M3 is a design question.** The mechanism is read, the wrong state is
named, the fix is a matter of form.

**The S3 redirect question is not.** Whether there is anything to build at
all hinges on a measurement nobody has taken. A design ahead of that would
be a fix for a bug whose existence is unknown — and this project has already
seen, three times, the measurement overturn the design.

Hence: **M3 gets designed and implemented. S3 gets measured, and the design
for S3 follows afterward or not at all.**

---

## M3 — The origin belongs to the attempt, not the tab

### The measured starting state

`connect(in:stored:)` sets `tab.dialingStoredSessionID = stored.id`
**before** `await form.connect()` runs. The comment at this spot carefully
justifies the ordering — a `fillForm` rejection should not leave an origin
behind — and in doing so overlooks the other case.

`ConnectionViewModel.connect()` begins with:

```swift
guard state != .connecting else { return nil }
```

A rejected second call therefore returns **without changing state**. But
the mirror clears the origin only on a state change:

```swift
if newState != .connecting { tab.dialingStoredSessionID = nil }
```

No change, no clearing. The origin stays in place and gets attached to the
**ad-hoc** attempt that fails right after it. The surface then offers
"Edit session" for a session this attempt never selected.

This is reachable because the form's connect button does not take
`tab.isReconnecting`, and `sidebarConnectTarget` returns the same tab as
long as it is not connected.

**Classification, unchanged from the entry:** purely cosmetic. No security
issue, no data mix-up across a window boundary. Just a mislabeled surface
in a narrow time window.

### The decision (maintainer, 2026-08-28)

**Bind the origin to the attempt** instead of clearing it after the fact.

The entry named two cheaper routes — clear it on rejection too, or set it
only after a uniqueness check. Both work. Both add a **cleanup rule**, and a
missing cleanup rule is exactly what produced this bug. Placing a second one
next to it fixes this case and invites the next one.

`ConnectionViewModel` already carries `currentAttempt`, freshly assigned at
the top of every `connect()` and moved unconditionally by
`cancelConnecting()`. A rejected call returns **before** this assignment —
it never becomes an attempt. If the origin is assigned where the attempt is
created, a rejected call cannot contribute one. The wrong state is then not
cleaned up — it is unrepresentable.

### The form

`connect()` takes the origin and writes it **after** the guard, together
with the assignment of the attempt:

```swift
public func connect(origin: UUID? = nil) async -> (any RemoteFileSystem)? {
    guard state != .connecting else { return nil }
    …
    let myAttempt = UUID()
    currentAttempt = myAttempt
    attemptOrigin = origin
```

The error surface then reads the origin **of the attempt that failed**,
instead of a tab property that can outlive it.

**`tab.dialingStoredSessionID` is thereby dropped entirely.** That is the
actual gain: the property that could hold a stale value stops existing.

### The default value, and why it sits differently here than in Task 1

`origin: UUID? = nil` carries a default value, and the same week removed
three default values from `SessionListViewModel.init` because omitting one
silently read a real user file.

**The difference is what omission means.** There, the default value pointed
at a real location, and a test that omitted it wrote into the maintainer's
own storage. Here, `nil` means **ad-hoc** — the true and only correct value
for a call that does not select a stored session. There is nothing real
that an omission could reach.

Counted in this pass: **two** production call sites of `form.connect()`
(the connect button in `ConnectionFormView` and the stored path in
`ContentView`) and **64** call sites under `Tests/`. A required argument
would change 64 test sites to express, at two production sites, something
that at 64 sites already reads `nil` anyway.

**The counterargument, so it is not left unsaid:** a default value makes it
possible to **forget** the origin at the stored call site, after which a
stored connection attempt behaves like an ad-hoc one. That is a visible
degradation, not a silent one — the surface would then fail to offer "Edit
session" where it should — and it is the direction a bug is supposed to
fall in.

### What no test in this project can see

Everything decidable is checkable: that a rejected second call leaves no
origin behind, and that a failed attempt carries its own. The time-window
case itself can be produced from the test, because both paths sit on the
main actor.

**Not checkable** is that the surface, in the live window, shows the
correct label. As before.

---

## The S3 redirect question — measure first

### What stands without a measurement

S3 sets the `Authorization` header by hand and runs over
`URLSessionHTTPTransport()`, whose default is `URLSession.shared`.
**`URLSession.shared` cannot have a delegate** — so there is no redirect
control on the S3 path, not because it was left out, but because this
session cannot accept one.

WebDAV already does it differently: its own `URLSession` built from
`URLSessionConfiguration.ephemeral` with `WebDAVSessionDelegate`, passed to
`URLSessionHTTPTransport(session:)`.

**The seam for a fix therefore already exists.** That is the reason nothing
needs to be designed here before it is measured: if the measurement comes
back bad, the fix is the pattern already running next door.

The header does not carry the secret key, but it does carry the access key
ID and the signature. A signature carried along to a foreign origin is not
a plaintext credential leak, but it is a request-forgery surface.

### The measurement setup

Loopback, no real host — the closing review's requirement still stands.
`Tests/macSCPCoreTests/LoopbackHTTPStub.swift` supplies the scaffolding,
including `seenRequests` and `waitForRequests(atLeast:within:)`.

Two origins arise on loopback in two ways, and **both need measuring**,
because they can come out differently:

| Case | first origin | second origin | differs in |
|---|---|---|---|
| A | `127.0.0.1:<p1>` | `127.0.0.1:<p2>` | port |
| B | `127.0.0.1:<p1>` | `localhost:<p2>` | hostname **and** port |

An implementation that strips only on a hostname change passes case A and
fails case B. Measuring only one would amount to making a claim about both.

What gets fired is the **real** request from `S3FileSystem` over the
default transport — that is the subject of the question. What gets observed
is whether the request at the second origin carries an `Authorization`
header.

**The positive check alongside it is mandatory, not optional.** "No
`Authorization` at the second origin" is a negative statement, and a
negative statement about a request that never arrived is vacuously true.
The measurement must therefore first prove that the redirect actually
happened and that the second origin saw a request at all — otherwise it is
measuring a broken stub and reporting safety. This exact trap already let a
security assurance stand silently once this week.

### What the measurement decides

- **Header is not carried along:** the question is closed, together with
  the measured macOS version. "Not carried along on 26.x" is not the same
  as "is not carried along" — Foundation's behavior depends on version and
  status code, and the entry says so itself. Whether a delegate follows
  anyway is then a decision made with data instead of without.
- **Header is carried along:** S3 gets its own session with a delegate,
  modeled on WebDAV. The design for that follows then — with the
  measurement as evidence, and the question of whether the redirect to a
  foreign origin is rejected outright or only the header is stripped.

### What no test in this project can see

What a **real** S3 provider does on a redirect. What gets measured is
Foundation's behavior against a controlled stub, not the behavior of AWS,
MinIO, or Ceph. That is enough for the question as posed — it is about
`URLSession`, not the counterpart — and it is enough for nothing beyond
that.

---

## What is explicitly out of scope

- **No change to `ConnectionViewModel`'s rejection of the second call.**
  `guard state != .connecting` stays, along with its test.
- **No change to WebDAV's delegate**, and no generalizing of redirect rules
  across both backends before it is measured.
- **No rework of the HTTP transport.** The seam
  `URLSessionHTTPTransport(session:)` is sufficient and is used as is.
- No blocking, no new setting, no visible change for the user arising from
  M3 — other than the correct label.
