# The app must not be able to say "yes" to itself — Design

**Status:** 2026-08-28. Implements
`docs/superpowers/specs/2026-08-22-backlog-connection-capability.md`, the
entry the backlog itself lists as the most important one: after six
rounds, in each of which a new way of writing it beat a source-scanning
guard.

---

## What measuring moved

The entry describes the goal as "the App layer cannot establish a
connection except through a type that only the shared path emits". On
re-measuring, this turns out to be the **secondary** half.

**The danger is not the second dial path, it's the freely invented
decider.** TOFU is already secure: the hard stop on a fingerprint conflict
sits **in the backend**, not at the call site. What a bypass call actually
bypasses is the question to the user — it answers it itself:

```swift
async let dialed = BackendDescriptor.descriptor(for: kind).connect(
    config, { _ in true }, { _ in true }, 30)
```

That was round 6. It's possible because both deciders are **bare function
types**:

```swift
public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool
```

## The measured starting state

| | |
|---|---|
| Real callers of `descriptor(…).connect(` outside Core | **two**: `ContentView+Lifecycle` (App) and `SessionConnecting` (CLI) |
| Tests that dial through it | **none** — every hit in `Tests/` is probe material inside a guard |
| Core test files with `@testable import macSCPCore` | **170** — they keep access to internals |
| App test files | import `Foundation`/`Testing`; they read source, they don't dial |
| TOFU conflict | a hard stop **in the backend**, independent of the decider |

`internal` on the dial operation therefore locks out exactly the two
targets that need locking out, and costs the test suite nothing.

## The design

### 1. A decider is a type, not a closure

`HostKeyDecider` and the certificate decider become types with a
**non-public initializer** and public factories in Core:

| Factory | Meaning | User |
|---|---|---|
| `.asking(_:)` | **shows** the user the candidate and returns their answer | App |
| `.refusingUnknown` | rejects every unknown key, without asking | CLI without interaction |
| `.following(_:)` | the CLI's existing `HostKeyPolicy` | CLI |

That makes `{ _ in true }` at a call site **no longer a decider** — it
doesn't compile. Round 6 wouldn't have been caught, it wouldn't have been
expressible.

**The honest limit of this measure, stated here rather than in the fine
print:** `.asking` still takes something that answers. Anyone who writes
`.asking { _ in true }` has a yes-sayer again. The difference isn't
impossibility, it's **visibility**: the bypass now carries a name, sits at
a factory called "asking", and is thereby exactly the kind of thing a
guard can still watch — unlike an anonymous closure in an argument, which
could hide in six different spellings.

### 2. Dialing is not a capability of the App layer

`BackendDescriptor.connect` becomes **`internal`**. A single public entry
point in Core emits connections; the App and the CLI call it.

That is the capability boundary from the entry, in the literal sense:
"around the path" is no longer a violation a test would have to find, it's
something the compiler doesn't compile. And because Core tests import
`@testable`, they lose nothing.

**Why both and not just one:** without the decider type, the entry point
only pushes the problem one level up — it would still accept a closure.
Without the lockout, the raw dial operation would stay reachable, and with
it every future way of writing a path to it. Together they cover different
halves: the type prevents the **yes-sayer**, the lockout prevents the
**second path**.

### 3. The guard shrinks to what types can't express

What it checks today becomes redundant the moment it no longer compiles.
**Every check that duplicates a structural guarantee gets deleted**, not
kept "just in case" — a guard standing next to a guarantee makes the next
reader of the suite trust it more than it deserves.

What remains is what a type can't say:

- that the App attaches its `.asking` factory to the **real** prompt and
  not to a yes-sayer,
- that the certificate path does the same.

These remainders need to be explicitly named — along with what they
**cannot** see.

## What no test in this project can see

Everything decidable is testable, and the larger part becomes a compile
question.

**Not testable** is that the prompt actually appears in the running window
and the user is really asked. That was already the case before, and it
doesn't change.

---

## What is explicitly excluded

- **No change to TOFU itself.** The hard stop stays where it is.
- **No change to what the CLI decides** — it continues to reject unknown
  certificates and continues to follow its `HostKeyPolicy`.
- No new setting, no new behavior for the user. This work is invisible
  from outside; it changes what can be written.
