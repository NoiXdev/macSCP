# Failed connection setup: its own surface instead of falling back to the form

**Status:** Design, approved by the maintainer 2026-08-25 (visual check on
the built bundle).

## The finding

A **teardown** has shown an error view in the tab since the connection-state
branch. A **failed setup** does not: `ConnectionSurfacePlan` only maps the
state, and a failed attempt leaves `liveness == nil`, which maps to `.form`.
The tab therefore falls back to the form, as if nothing had happened.

Maintainer's own words: *„wenn dann gleich verbinden wieder kommt ist man
eher verwirrt."* ("if Connect just comes right back up, it's more
confusing than anything") One wanted to connect, it didn't work, and
instead of an answer the input mask is there again.

**That was my own decision from Task 6**, justified on the grounds that the
error text had "always" lived in the form. The justification is correct and
still doesn't carry the weight: it explains where the text sits, not why
the surface should switch.

## The surface

Its own message, not the same one as for a teardown — "Connection lost"
would be wrong, none ever existed. Proposal: **"Could not connect"**, plus
a general sentence with no technical detail.

Four actions:

| Action | Effect | Visible |
|---|---|---|
| **Retry** | the same connection path as a fresh setup | only for a saved session (see addendum) |
| **Edit** | the form, pre-filled with the values | always |
| **Edit Session** | the session editor, a persistent change | only for a saved session |
| **Close** | close the tab | always |

Plus a **details dialog** with the full technical message — maintainer's
decision: the general message on the surface, everything exact in a dialog
for debugging.

### Addendum, 2026-08-25 (maintainer): two sentences instead of one

The design above says "a general sentence with no technical detail", the
same one for both cases. That is **deliberately softened** here, with the
maintainer's agreement, for a reason that only showed up during
implementation.

Two changes are linked:

1. **"Retry" drops out for a one-off attempt.** An ad-hoc, typed-in setup
   has no saved session to dial, and this branch deliberately has **no
   second dial point** that could dial it anyway: the values live in the
   form, and its own Connect button is the one place an ad-hoc setup
   happens. The first implementation offered the button anyway and routed
   it back to the pre-filled form — so no dialing, no "Connecting…", exactly
   the behavior the maintainer originally complained about, under a button
   that promises the opposite. A button that cannot act is worse than a
   button that does not exist.
2. **The sentence underneath therefore becomes case-dependent.** If "Edit"
   remains the only way forward, the surface also has to say why Edit is
   the path to retrying — otherwise one looks for a button that isn't
   there. For a saved session the general line stays unchanged: "Retry"
   sits right next to it and explains itself.

Concretely two catalog keys, selected by the **same** fact that already
decides between the two buttons:

| Case | Key | German |
|---|---|---|
| saved session | `connection.failed.body` | „macSCP konnte den Host nicht erreichen." |
| ad hoc | `connection.failed.body.adHoc` | „macSCP konnte den Host nicht erreichen. Bearbeite die Verbindung, um die Angaben zu prüfen und erneut zu verbinden." |

**What is explicitly NOT softened here:** the surface still carries
exclusively fixed catalog keys. What is softened is only *which* of two
fixed keys applies — never the text itself. The check that catches an
interpolated hostname
(`ConnectFailurePlanTests.everyReachableMessageComesFromTheFixedCatalogKeySet`)
covers both arms and was demonstrably red when the second key was added,
until the key was entered.

Why both edit paths exist: a one-off typing attempt ("is it the port?")
should not change the saved session; a real mistake in the session should
be permanently correctable. Those are two different intents, and a surface
that offers only one forces the wrong one.

## Requirement for the details dialog

The dialog shows the message from the layer underneath. It may contain what
the user themselves entered or saved — host, port, username — and
**never a secret**: no password, no passphrase, no key material, not even
inside a library's embedded error text.

This is not a formality: the project rule "no secret in a log, export,
error message, or test failure text" applies here for the first time to a
surface that shows a **raw** error text. Every earlier surface on this
branch was structurally safe because it carried only fixed keys. This one
is not — it needs a verified sanitization step.

## What stays unchanged

- **Retry** runs through **the same** connection path as a fresh setup.
  TOFU remains a hard stop, the Keychain rules remain. The branch's guard
  already covers this and must be extended to cover the new call site.
- The teardown case (`.lost`) and its texts stay as they are. This surface
  comes alongside it, not in its place.
- An open host-key prompt continues to override every surface.

## Boundary

A setup that fails on a **question** only a human can answer (a changed
host key, a missing passphrase) already has its own path and is not
touched by this. This surface is for what `lastFailureKind == .other`
means: timeout, name resolution, rejected.

## Testability

Which actions appear for which state, and which message applies, belongs
in a testable value alongside `LostConnectionPlan` — the surface itself
only renders. The sanitization of the details text must be checked against
real error values, not invented ones.
