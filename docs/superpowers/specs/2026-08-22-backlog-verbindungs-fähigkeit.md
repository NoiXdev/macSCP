> **Implemented on 2026-08-28** via
> `docs/superpowers/plans/2026-08-28-faehigkeitsgrenze-verbinden.md`
> (`04a6def`, `b62f8b5`, `637c82b`, `dba405a`).
>
> **What the compiler now holds:** deciders are types with a private
> initializer — `{ _ in true }` at a call site no longer compiles, so round 6
> is no longer expressible. `BackendDescriptor.connect` and the three backend
> `connect`s are module-internal; a direct dial from the App or the CLI fails
> with `'connect' is inaccessible due to 'internal' protection level`. Both
> planted from outside and the errors proved verbatim.
>
> **What it does not hold, and why a seventh scan would not change that:**
> `import Citadel` compiles in `Sources/MacSCPAppKit`, even though
> `Package.swift` declares the dependency only for Core — SwiftPM leaves
> transitive modules on the search path. A raw
> `SSHClient.connect(…, hostKeyValidator: .acceptAnything(), …)` reaches
> **no TOFU** there. This gap sits *below* the types; the scan and the
> import allowlist remain load-bearing for it and were therefore **not**
> deleted.
>
> Also open and named: `ConnectionViewModel.connect()` is public and
> bypasses the form paths; the App test target imports `@testable` and gets
> everything back; and planting `.asking { _ in true }` at the App's one
> certificate call site turns **nothing** red — reported rather than
> guarded, because a seventh scan over one call site does not carry the
> burden of proof.
>
> The lesson below stands unchanged and was confirmed three times during
> implementation: each of the four tasks refuted a premise of this plan.

# Backlog: The app should not be able to dial at all

**Created:** 2026-08-22, after four review rounds on one guard. An
architecture proposal, **not a design** — and a boundary that deserves to
be named honestly.

## What is meant to be secured

Rebuilding a connection after a connection loss must run through **the
same** connection path as a fresh build. TOFU as a hard stop, the keychain
rules, login-set resolution, and the passphrase prompt all hang on this. A
second path at this point is a second chance to forget a security rule.

## What was tried, and how far it carries

A source-code guard, turned around four times, round after round:

1. **Delegation checked** — anchored to one function. Bypassed: the
   scheduling reached the path at a different spot.
2. **Allowlist of call sites** — every dial and hand-off site must be
   named. Bypassed: the *detection* was still an enumeration —
   `.connect(` with a paren, a fixed root list, a start-of-line pattern.
3. **Detection turned around** — category patterns instead of names,
   roots derived from the filesystem *and* `Package.swift`,
   position-free patterns. Bypassed: a **symlinked directory** gets
   compiled but not walked.
4. **Symlinks closed.** And then the case remained that remains.

## The boundary

**A dial process in Core under a different name, called by the App, is not
textually recognizable.** `QuickOpenHelper.open(config)` names no
`connect`, no backend type, needs no new import. Core is excluded as a
root because that is **where** dialing belongs — an App call into an
arbitrarily named Core function looks like any other Core call.

Catching that would mean knowing which Core functions dial. That is the
same problem, one layer down.

## The proposal

Not to **watch** better, but to **withdraw** the capability: the App layer
cannot establish a connection except through a type it must hold and that
only the shared path issues. Then "around the path" is not a violation a
test would have to find — it is something that cannot be expressed at all.

To clarify before a design: where this type is created, who is allowed to
pass it on, and what it means for the CLI and for tests — both currently
need a way to connect that does not go through the App surface.

## Why this is here at all

Four rounds, four holes, each in the layer nobody had turned around yet.
The lesson worth the most out of this:

> **Mutation tests prove a guard's sensitivity, never its scope.**

A guard written after the implementation is cut to fit the lines just
written — and every mutation dreamed up for it comes from the same mental
model. What is missing is the question *where could the property even be
violated from*, and that question gets asked before writing, or not at
all.

Two further bypasses are known and documented in the guard itself: a
keypath write access and a `Mirror` access via field names. Both exotic,
both named rather than left unspoken.

---

## Addendum 2026-08-25: round 6, and what it says about priority

The closing review of the *failed build* plan beat the guard a sixth
time — and this time **not** at the boundary named above. It was the
*named, direct* form:

```swift
async let dialed = BackendDescriptor.descriptor(for: config.kind).connect(
    config, { _ in true }, { _ in true }, 30)
```

A raw backend dial with accept-everything deciders, in a new App file.
Compiles, full suite green. The controls run in the same pass — the same
line with `await`, and a `Task.detached` around it — were both red, so the
scan did in fact reach the file.

The reason: the discrimination asked for the **word** `await`, and
`async let` calls an `async` function without writing it. The suite
comment explicitly claimed the opposite ("every dial process in this
project is `async` and therefore cannot be called without `await`"),
which led a reader of the gap list to correctly conclude that this form
was covered.

Closed (the discrimination now knows both spellings), and the gap list
now says what it still does not see.

**What this means for this note.** As long as the boundary above was read
as "a scan cannot see a renamed Core function", it was academic. Round 6
shows that even the direct, named form escapes as soon as the spelling
avoids the pattern — and that the fix again consisted of **writing down
the spelling that was just found**.

> A scan over a language with several spellings per semantics loses this
> race permanently. Not because it is sloppy, but because it can only
> enumerate what someone has already thought of.

Six rounds, six spellings, each looking complete from inside the round
before it. That is the argument for the capability boundary — **to raise
its priority**, not to add a seventh pattern.
