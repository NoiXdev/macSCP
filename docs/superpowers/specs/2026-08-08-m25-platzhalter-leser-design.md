# M25 — The last placeholder readers (Design)

**As of:** 2026-08-08. Predecessor: M24 (`2026-08-08-m24-abschluss.md`), whose
overall review named this milestone as the opening move.

## Goal

`StoredSession.host`/`port`/`username`/`authKind` return the SSH fallback
values `""`/`22`/`""`/`.password` for an `.s3` or `.webdav` session — the
placeholder M23 wanted to get rid of, in new spelling. M24 found, via a
compiler probe, five **unguarded** readers in `SessionListViewModel`
and deliberately left the accessors in place, because the spec had made
no promise there.

M25 clears out those five and **then checks** whether the four accessors
can be deleted. It is checked, not promised: both outcomes are a
valid result.

## The three changes

### 1. `delete` — hoist, don't restructure

`SessionListViewModel.delete(_:)` computes `bastionUsername`,
`bastionAuthKind`, `bastionKeyPath` and fetches `bastionSecret` from the keychain
(lines 248–257). **All four values are used exclusively inside the
loop over `affected`** — and `affected` has been empty for every
non-SSH session since M24 (`session.kind == .ssh ? sessionsUsingAsJump(...) : []`).

So this is not a protocol problem but wasted work. The computation
moves into an `if !affected.isEmpty`.

The side effect is the real win: deleting an S3 session no longer
fetches its **secret access key** from the keychain just to discard it.
A read of a secret that nobody needs is one too many — even when the
value flows nowhere.

Three of the five readers (lines 249, 250, 255) disappear as a result. The two
remaining (262, 263) already sit inside the loop and are guarded.

### 2. A new question on `BackendDescriptor`

Two places ask the same thing in SSH vocabulary:

| Site | today | meaning |
|---|---|---|
| `updateSession` | `updated.authKind == .agent` | "needs no login, clean up the old slot" |
| `exportPayload` | `authKind != .agent` | "has a secret that can be exported" |

The same incantation appears a third time in
`StoredSessionConnectionConfig.build` — there already schema-driven, but
spelled out. So, one member:

```swift
/// The secret field this stored session currently shows, or nil when it
/// needs none (M25) — the schema's answer to "does this login carry a
/// secret at all", asked without `StoredSession.authKind`.
public func visibleSecretField(for session: StoredSession) -> ConnectionField?
```

Body: `credentialSchema.visibleSecretField(in: sessionValues(session),
namespace: fieldNamespace)`. Three call sites, one rule.

**It does not guard itself.** `hasStoredConfiguration` stays the callers'
concern: `StoredSessionConnectionConfig.build` already checks beforehand
today and keeps doing so, `updateSession` and `exportPayload` have their
own guards. A member that sometimes guards and sometimes doesn't would be
worse than three callers that ask their own question.

**Equivalence, checked case by case:**

| Session | today | with the schema |
|---|---|---|
| SSH `.agent` | `authKind == .agent` → clean up | no secret field visible → `nil` → clean up |
| SSH `.password`/`.privateKey` | do not clean up | field visible → do not clean up |
| S3 / WebDAV | `authKind` fakes `.password` → do not clean up | field visible → do not clean up |
| SSH without a block (`ssh == nil`) | `authKind` falls back to `.password` → do not clean up | `values(from:)` reads through the same fallbacks → field visible → do not clean up |

The last row is why the member uses `sessionValues` and not, say, the
empty bag: for `.ssh`, `SSHFieldSchema.values(from:)` reads through the
accessors into a **filled** bag, for `.s3`/`.webdav` a missing block
returns an empty one. That is documented behavior
(`BackendDescriptor.sessionValues`) and, in both cases, the same result
as today.

### 3. `exportPayload` — only the fallback branch

There, the line reads `let authKind = resolved?.authKind ?? session.authKind`.
**The agent property of a set-bound session comes from the set, not from the
session.** Replacing that wholesale with a schema question against the
session values would change behavior: a session on an agent set would
suddenly look for a secret and, when none is there, be counted in the
user-visible "N passwords missing".

So only the fallback onto the session is replaced:

```swift
let needsSecret = resolved.map { $0.authKind != .agent }
    ?? (descriptor.visibleSecretField(for: session) != nil)
```

The `.agent` comparison on `ResolvedLogin` **stays**, and is not a
regression to old habits: `resolvedSSHLogin` has been deliberately
SSH-shaped since M22/T9 (the jump path and export format speak exactly
these four columns). A `StoredSession` accessor it is not.

**The local binding `authKind` disappears entirely** — verified, not
assumed: within `exportPayload` it is read at exactly one place, namely
this guard. The function's two other `authKind` occurrences are
`resolved.authKind.rawValue` for the field storage (which reads the
resolved login directly) and the jump's own `authKind`.

The line's two other kind conditions — `session.kind != .s3` and
`session.kind != .webdav || session.webdav != nil` — **stay untouched**
(maintainer decision, 2026-08-08). They are format logic, not
protocol dispatch: the export format has separate secret columns, and
M23/P3 explicitly restored both guards after a finding.

## The probe

After the three changes: `@available(*, deprecated, message: "…")` on the
four accessors, `swift build`, judge each hit individually.

- **Only `SSHFieldSchema.values(from:)` and guarded sites remain** →
  delete the accessors, run the full suite again, result in the
  closing report.
- **Something unguarded remains** → the accessors stay, and every
  remaining unguarded reader is named **by file and line**.

The probe is a compiler run, not a `grep`: M24 showed that grepping for
`.host`/`.port` returns 241 hits, the large majority of which are URLs
and unrelated types.

## Success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | Deleting a non-SSH session no longer touches the keychain | test with a read-hostile `SecretStore` (pattern: `agentSetResolvesWithoutKeychainRead`) |
| 2 | Deleting an SSH bastion restores unchanged | the existing `delete` tests stay green, unmodified |
| 3 | `updateSession` cleans up for ssh-agent and does not for S3/WebDAV | one test each, both directions |
| 4 | A session on an **agent login set** still exports no password and is not counted as missing | test — this is the spot where a blanket switch-over would have changed behavior |
| 5 | `visibleSecretField(for:)` has three call sites; the spelled-out copy in `StoredSessionConnectionConfig` is gone | grep |
| 6 | The probe has run and its result is in the closing report | both outcomes admissible, unguarded readers named |
| 7 | No other behavior change; test count ≥ 1587 | full suite, gated suites, four catalogs `plutil`-clean |

## Test notes

- Sessions via the fixtures (`sshSession`, `s3Session`, `webdavSession`),
  never `StoredSession` directly.
- For criterion 1 and for every "does not read" claim: a `SecretStore`
  whose `password(for:)` fails the test. The pattern is at the end of
  `LoginMergePlannerTests.swift`.
- Criterion 2 is the regression clamp: if the existing `delete` tests
  have to be touched, the relocation shifted behavior —
  that is a finding and must be reported, not written away.

## For the release notes

**Nothing.** M25 is a purely internal restructuring with no user-visible
effect. Should the probe bring a behavior change to light, it belongs
here, added after the fact.

## Open, deliberately not part of M25

- Unifying the export format's secret columns (`password` /
  `s3SecretAccessKey` / `jumpPassword` → one column, the schema says which).
  That would complete M23/P3, but is a **format change** with
  `.macscp` version 3, migration, and the end of exchange with v2 files.
  Its own milestone, its own spec.
- Moving the blockless guards (`session.s3 != nil`, `session.webdav != nil`)
  onto `hasStoredConfiguration`.
- The deferred M24 minors (`ssh.managedKeyID` test, comparator tiebreaker,
  two misleading comments, the German quote in a doc comment,
  `actions/checkout@v4` → `@v5`).
- The 0% CPU test suite hang (its own file:
  `2026-08-08-testsuite-haenger-untersuchung.md`).
