# M23 — Data-Driven Session Lifecycle

**Status:** approved 2026-08-07. Successor to M22 (data-driven backend registration).

## Why

M22 made every backend declare its *fields* as data. Its closing review measured
what that left behind: **16 protocol branches in 5 files**, and behind the first
three of them six complete method bodies — `connectSSH/S3/WebDAV` and
`validateForEditSaveSSH/S3/WebDAV`. The honest summary from that review:

> The form, the login-set editor, the resolver, the CLI and the connect path are
> data-driven. The session lifecycle — connect, validate, save, fill, export — is
> not.

Adding a fourth protocol today still means editing five generic files. M23
finishes the job.

It also dissolves a defect at its root rather than at its symptom: S3 and WebDAV
sessions store the literal placeholder `"unused"` in `host` and `username`,
written by `validateForEditSaveS3` and `validateForEditSaveWebDAV` — two of the
sixteen branches. That placeholder already caused one data-loss bug (every
non-SSH session shared the import duplicate key `unused|22|unused`, so
"Replace" could overwrite an unrelated session and delete its Keychain entry).
That symptom is fixed; the cause is not.

## Decisions

Settled with the maintainer before any design work:

1. **Scope: all three areas** — session lifecycle, `StoredSessionConnectionConfig`,
   and export/import.
2. **Structure: one spec, three sequenced phases**, each with its own plan and its
   own green, shippable end state.
3. **Validation is declarative in the schema**, not a per-backend closure. A
   closure would relocate the six bodies; a declaration dissolves them.
4. **SSH's fields move into their own block**, symmetric with `s3` and `webdav`.
5. **The migration writes a new file** rather than changing the existing one in
   place.

## The foundation

### Two additions to `ConnectionField`

`isRequired` already exists (M22, Task 9, currently read only by the login-set
editor). Two more:

- **`format: FieldFormat?`** — today exactly one case, `.numeric`. The port is
  the only format rule in the entire existing validation code. Resist adding
  cases speculatively; a second case should arrive with a second real need.
- **`invalidMessageKey: String?`** — so "the port must be a number" does not
  flatten into a generic "this field is required". Without it the declarative
  validator would be a downgrade in message quality.

### One validator in Core

```
ConnectionFieldSchema.firstViolation(in: FieldValues, namespace: String)
    -> (messageKey: String, fieldID: String)?
```

It walks `visibleFields(in:namespace:)` — the fields that currently apply — and
returns the first violation. Nothing more is needed, because `visibleWhen`
already carries the conditions: SSH's password is required *and* only visible
under password auth, so the auth-kind branching that `connectSSH` does by hand
falls out for free.

### One write adapter on the descriptor

```
apply: @Sendable (FieldValues, inout StoredSession) -> Void
```

The counterpart to M22's read-only `sessionValues(_:)`. It replaces the three
`validateForEditSave*` bodies, each of which currently hand-assembles a whole
`StoredSession`.

**It must mutate in place, never reconstruct.** `StoredSession` carries group
assignment, login-set binding and per-protocol blocks that a rebuilding adapter
would silently drop. M22's SSH adapter already has a test that populates
`groupID`, `loginSetID` and a real `JumpSpec` *before* applying and asserts they
survive — that test's shape is the requirement here, for all three backends.

### What deliberately stays out of the schema

The jump-host validation and "a name is required when saving the session" are
**form rules, not backend fields**. They stay in `ConnectionViewModel` and stay
unchanged when a fourth backend arrives. Pulling them into the schema would mean
inventing schema vocabulary for concepts only one protocol has (jump) or that no
protocol has (the save-name checkbox).

## The format migration

### Target shape

```
{ id, name, groupID, loginSetID, kind,
  ssh:    { host, port, username, authKind, keyPath, jump },
  s3:     { … },
  webdav: { … } }
```

`authKind`, `keyPath` and `jump` move into the `ssh` block with the rest. All
three are SSH concepts that currently sit at the top level, meaningless, on every
S3 and WebDAV session.

### What this means for the Swift type, and what it costs

`StoredSession` gains `ssh: StoredSSHConfig?` alongside `s3` and `webdav`, and
**loses** the top-level `host`, `port`, `username`, `authKind`, `keyPath` and
`jump`. That is the point of the change, and it is also the expensive part:

- `StoredSession(name:host:port:username:)` is the initializer nearly every test
  in the suite uses to build a fixture. It goes away, and those call sites move
  to the block. This is mechanical churn across many test files — **expect it,
  budget for it, and do not let a plan pretend it is a handful of sites.**
  Count them before planning the phase.
- Every reader of `session.host` / `session.username` must be found and moved.
  The dangerous ones are the paths that currently *depend* on those fields being
  present for non-SSH sessions — `SessionImportPlanner.duplicateKey` is already
  kind-aware (fixed today) and the sidebar label already comes from
  `displaySummary`, but the sweep must be exhaustive rather than assumed.
- `SessionExportCodec` reads them too. Phase 3 owns that; Phase 1 must therefore
  keep export compiling and correct in the interim, even though the columns do
  not become schema-derived until later.

### A correction that shaped this design

The original plan was "a hard cut with a format version, so an older macSCP
refuses the file with a clear message instead of aborting cryptically."

**That is not achievable.** macSCP 1.0 is already shipped and knows nothing about
a `formatVersion` key. It reads the file, fails to find the required `host`, and
aborts with a decode error. A version number helps *future* readers, never past
ones.

### What is achievable

The new version writes **`sessions-v2.json`** and leaves `sessions.json` in
place, untouched. On first launch it reads the old file once and writes the new
one.

This buys three things:

- A downgrade **does not crash**. The older version finds its own file and opens
  it.
- The old file is a **backup from the migration moment**, if the rewrite goes
  wrong.
- There is never an instant where a half-written file is the only copy.

**The price, stated plainly:** after the migration the two files diverge. A
connection created in the new version is invisible to the old one, and an edit
made in the old version is lost on returning to the new. A downgrade goes from
"does not start" to "shows a stale state". This is a real trade — the maintainer
chose it knowingly.

**This belongs in the release notes**, because macSCP ships DMGs and has an
update checker, and reverting after a bad release is a thing people do.

## The three phases

### Phase 1 — Foundation and session lifecycle

Adds the two field properties, the Core validator and the write adapter. With
those, `connect()`, `validateForEditSave()` and `beginEditing()` collapse to one
body each; the two `ContentView` save/fill paths and `ConnectionFormView`'s
secret ternary go with them.

The format migration lands here too, because the write adapter is the place a
`StoredSession` comes into existence.

**End state:** a fourth protocol costs zero lines in those five files.

### Phase 2 — `StoredSessionConnectionConfig` onto the factory

Two ways to build a connection config from a stored session exist today, and the
M22 closing review proved they **already disagree**:

- `buildS3`/`buildWebDAV` throw `.secretRequired` on an empty secret;
  `makeConfig` accepts it.
- `buildSSH` requires a non-empty secret under password auth;
  `SSHFieldSchema.makeConfig` builds `.password("")`.

Harmless today only because the two run in different contexts. Two truths about
one thing, in a milestone whose thesis is "the factory is the one place". This
phase makes the factory the only way.

### Phase 3 — Export and import

`ExportedSession` derives its columns from the schema instead of listing them by
hand, and the import builds its session through the same write adapter.

The misleading conflict sheet goes with it: it says "Name Already Exists" when
the name does not collide at all — the wording that pushed users toward the
"Replace" that used to destroy an unrelated session.

## How we know it worked

Three kinds of test, the shape M22 proved out:

- **Completeness, per backend** — every field carries its rules; no field is
  declared and then unvalidated.
- **Round trip, per backend** — values survive the adapter and the file format.
- **A frozen legacy fixture** — a `sessions.json` in today's exact format that,
  after migration, yields every session unchanged, including jump host and group
  assignment. *This is the only test that proves nobody loses their connections,
  and the only one reasoning cannot replace.*

Plus one guard the M22 review specifically asked for: after Phase 2, a test
pinning that the two config-building paths are **equivalent**, so they cannot
drift apart again.

## Success criteria

1. Adding a fourth `ConnectionKind` requires no edit to `ConnectionViewModel`,
   `ContentView`, `SessionListViewModel`, `SessionImportPlanner` or
   `ConnectionFormView`.
2. The `"unused"` placeholders no longer exist anywhere.
3. A `sessions.json` written before M23 migrates with every field intact.
4. `StoredSessionConnectionConfig.build` and `descriptor.makeConfig` produce
   identical configs for the same input, enforced by a test.
5. Every existing test stays green, unedited, except where a test pins the old
   top-level field layout — those are relocated, never deleted, exactly as M22
   handled the credential-schema move.

## Known risks

- **The divergence window.** Between the migration and the eventual removal of
  the old file, two session stores exist. Nothing reads the old one after
  migration, but a user who downgrades and edits will lose that edit silently.
- **Phase 1 is the largest.** It touches the connect path for all three
  protocols. The M22 lesson applies: TOFU handling is security-critical, a
  host-key or certificate mismatch is a hard stop, and any change there needs a
  line-by-line comparison against the current behaviour, not a plausibility
  argument.
- **The jump host.** `makeConfig` deliberately drops it (one secret parameter
  cannot build a second login). Phase 1 must keep `ConnectionViewModel`
  attaching it after the factory call, and the existing pinning test must stay.
