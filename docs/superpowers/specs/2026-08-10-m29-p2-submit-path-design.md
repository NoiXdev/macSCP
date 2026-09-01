# M29-P2 — The submit path moves into Core (design)

**Status:** 2026-08-10. Predecessor: `2026-08-09-m29-p1-closeout.md`.

## Why this phase exists

M28's whole-branch review found a **Critical**: a WebDAV or S3 password
could reach an SSH bastion host. The guard that closed it sits in
`ContentView.resolveSelectedJumpLoginSet` — a `private func` on a SwiftUI
view. **No test holds it.** In M29-P1 it was experimentally removed
entirely; the full suite stayed green.

P1 built the foundation (library split, second test target, localization
under `swift test`). **P2 pulls the decision out of the view**, to where
the existing suite can reach it.

## What the submit path does today

`ConnectionFormView` calls `resolveLoginSetForSubmit()` at three buttons.
The implementation in `ContentView` calls three functions and ANDs their
results:

```swift
let targetResolved = resolveSelectedLoginSet(in: tab)
let jumpResolved = resolveSelectedJumpLoginSet(in: tab)
let jumpSessionResolved = resolveSelectedJumpSession(in: tab)
return targetResolved && jumpResolved && jumpSessionResolved
```

**That all three run is deliberate** — every rejection is meant to show its
own message, not just the first one. Today that is secured solely by three
`let` lines standing before the `&&`.

Each of the three mixes three jobs: a mode guard, a check, and filling in
the form together with a localized message.

### The security property lives in the line order

`resolveSelectedJumpLoginSet` checks `JumpLoginSetEligibility.isEligible`
**before** `fillJumpForm` runs — and `fillJumpForm` reads the set's
keychain slot. Swap the two lines and M28's Critical is back: the
mismatched set's secret ends up in the form, a later mode switch writes it
into the session's own jump slot, and the connect carries it to the
bastion.

**This ordering is the milestone's actual guarantee, and to this day
nothing holds it in place.**

### Asymmetry between target and jump

The **target** fill path is already a one-liner into Core
(`form.applyResolvedCredentials(sessionListViewModel.credentials(of: set))`);
only the decision sits in the view. The **jump** fill path is entirely on
the app side and reads the keychain itself via a synthetic `StoredSession`.
That is exactly where the Critical sat.

## The design

Core gets **one** new type in `Sources/macSCPCore/Presentation/`. It
answers one question: *may this submit run, and with which values?* It
returns **cases, not text** — the same split as `LoginResolveError`, and
the one the project rule requires for Core messages.

### Three resolutions plus one coordinator

| Function | Job |
|---|---|
| `resolveTargetLoginSet` | resolve the target set; **new: `kind` guard** |
| `resolveJumpLoginSet` | resolve the jump set; **guard before the fill** |
| `resolveJumpSession` | resolve the referenced session (four error cases) |
| `prepareForSubmit` | calls all three, **never short-circuits**, collects **every** rejection |

The coordinator is not incidental. A short-circuiting coordinator hides
the second and third message — a behavior nobody checks today and that
can be written as a test. The rejections come back in **fixed order**
(target, jump set, jump session), so the app can display them
deterministically and the test can compare them as a list.

**Who fills.** Filling stays in Core, not in the App: `ConnectionViewModel`
is a Core type, and the guard-before-fill order is only pinned down when
both steps sit in the same checkable call. After this, the App's submit
path reads and writes **no** credential field at all.

### The rejection cases

Every case carries its own field to highlight. `ConnectionViewModel.
Field` is already `public` in Core, so the mapping belongs there — and
becomes checkable that way, instead of being scattered across four catch
branches as it is today.

| Case | Field | Message key (App) |
|---|---|---|
| `targetSetMissing` | – | `loginSets.missingSet` |
| **`targetSetKindMismatch`** (new) | – | **`form.loginSet.kindMismatch`** (new) |
| `jumpSetMissing` | `.jumpHost` | `loginSets.missingSet` |
| `jumpSetNotSSH` | `.jumpHost` | `form.jump.set.notSSH` |
| `jumpSessionMissing` | `.jumpSession` | `form.jump.session.missing` |
| `jumpChainNotSupported` | `.jumpSession` | `form.jump.session.chainNotSupported` |
| `jumpSessionNotSSH` | `.jumpSession` | `form.jump.session.notSSH` |
| `jumpSessionLoginUnresolvable` | `.jumpSession` | `loginSets.missingSet` |

The last case is a `catch`-all today ("a dangling login set on the
referenced session, or something else"). It keeps its message but gets a
name — an unnamed catch-all case is not checkable.

### What stays in the App

Three lines: translate the cases to text, call
`showFailure(message:field:)`, return `refusals.isEmpty`. No guard, no
ordering, no keychain read.

### The new target guard

`resolveSelectedLoginSet` today does **not** ask whether the chosen set
matches the session's protocol. This is consequence-free only by a
namespace coincidence: `applyResolvedCredentials` stores the values under
the respective backend's prefix, and an `.ssh` form never reads
`webdav.password`. **Safe by accident, not by construction** — and the
accident holds only as long as no backend uses another backend's field
names.

The guard asks the same question the jump side already asks, just for the
target: `set.kind == session kind`. This is the **only intended behavior
change** of this phase.

## What P2 makes checkable for the first time

The test that cannot exist today:

> A jump is bound to a WebDAV set. `prepareForSubmit` rejects with
> `jumpSetNotSSH` — **and** `form.jumpPassword` is unchanged. The secret
> was never read into the form.

The second assertion is the real one: it pins down the guard-before-fill
ordering. Swapping the two lines turns this test red — with the
credential visibly in the wrong place, not just with a differing flag.

Also: that the coordinator never short-circuits (two simultaneous errors
yield two rejections), and the case-to-field mapping.

## What is explicitly **not** part of this

- **Gutting the rest of `ContentView`** (3540 lines, 65 functions) and
  **splitting it into sub-views** — that is P3.
- **UI testing.** Neither XCUITest nor ViewInspector enter the project.
  Whether the button actually calls the Core function stays unverified;
  the residual risk shrinks because the App side collapses into three
  lines.
- **The stale slot** of a set-bound session. Its own pass.
- **The editor friction** when editing a login set.

## Risks

- **Behavioral equality.** Seven of the eight cases must deliver message
  **and** field exactly as today. A swapped mapping would be a silent
  regression: the user would get the wrong field highlighted.
- **The jump fill moves into Core along with it.** It reads the keychain
  via a synthetic `StoredSession` with the set's ID. This construction has
  to move along without a second reading of it appearing.
- **The new target guard can reject existing configurations** that work
  silently today — namely, a session bound to a mismatched set. That is
  intentional: it only appears to work, because the values are written
  into the void. The user now gets an explanation instead of an
  inexplicable login failure.
- **An eighth case that is not one today.** The `catch`-all gets a name;
  if more than the known case flows in there, the new name no longer hides
  that — it names it.

## Success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | The jump guard runs **before** any keychain read | Test: mismatched set bound ⇒ rejection **and** `jumpPassword` unchanged |
| 2 | Mutation turns criterion 1 red | Guard moved after the fill ⇒ red output quoted verbatim in the report, with the credential in the wrong place |
| 3 | The coordinator never short-circuits | Test with two simultaneous errors ⇒ two rejections |
| 4 | Each of the eight cases is individually reachable | one test per row of the case table |
| 5 | Case-to-field mapping is correct | test across all eight cases |
| 6 | Seven cases deliver message and field **as today** | comparison against today's code, case by case in the report |
| 7 | The new target `kind` guard fires | test per protocol pairing |
| 8 | The App side is three lines with no guard | review; no `isEligible`, no `kind`, no keychain read left in `ContentView`'s submit path |
| 9 | No secret value in message, log, or test failure text | review |
| 10 | The new key is present in all four App catalogues | existing guard test, `plutil -lint` |
| 11 | Suite stays green, count rises by the new tests | test output |

## For the release notes

**One sentence.** If a stored login chosen for a connection belongs to a
different protocol, macSCP now says so instead of silently discarding the
values.

## Open, deliberately not part of P2

- P3: gutting and view splitting.
- That the submit button calls the Core function is not pinnable (see
  above).
- No test covers the path by which the shipped app finds its resource
  bundle (finding from P1).
- The stale slot, the editor friction, the app-wide audit area.
- The release backlog: 399 commits ahead of `origin/main`.
