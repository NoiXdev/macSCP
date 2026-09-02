# Backlog: import planner — half-filled field bags

**Created:** 2026-08-19, while cleaning up the throwaway reports under
`.superpowers/`. The point comes from the import-planner pass and was
tracked there explicitly as "deliberately not fixed". Re-measured
against the source before carrying it over: still holds.

## The open case

`SessionImportPlanner` lets a field bag through as soon as it's *not
empty* — not only once it's usable. A bag that, for instance, contains
only `SSHField.keyPath` gets through; `SSHFieldSchema.apply` then writes
the defaults `host: ""`, `port: 22`, `username: ""`.

Result: a record that's visible but not selectable. It survives
`dropsOnLoad`, because an `ssh` block exists.

**Not affected:** the orphan cases that the same pass fixed. The entry
is visible and deletable, and deleting cleans up the keychain slot along
with it — so not a data leak, just an annoyance when importing broken
files.

## Related case already noted in the code

The twin — an entry with `jumpHost` and `jumpUsername` but no SSH block,
which gets an empty `ssh` block through the jump attachment and thereby
also survives the drop — is commented in the planner itself as a known
remainder lying outside the scope of that earlier task. Whoever tackles
(a) should handle both in one pass: it's the same cause.

## Why not right away

Both forms only arise from a hand-edited export file, or one produced by
a third-party source. A proper fix checks the bag against the backend's
required-field schema instead of against `isEmpty` — that's more than
one line and belongs in its own pass with tests for both forms.

## Done 2026-09-02 (`0587a2c`, `ed9f1ce`)

Planned in `../plans/2026-09-02-import-planner-unusable-bags.md`.

One gate for both forms. Before an entry is planned, the loop builds the
same probe `wouldBeDroppedByStore` already built and asks a second
question of it: would the backend's own schema let this bag through?
`isUnusable` lays the entry's bag over
`BackendDescriptor.descriptor(for: kind).defaultValues` and runs
`firstViolation(in:requireSecrets: false)` — the check the connection
form's Save runs — so a bag holding only `SSHField.keyPath` fails on the
blank host. The jump-only twin fails the same way: the jump attachment
gives the probe an `ssh` block, which is exactly what makes the gate
apply to it (the gate declines to judge an entry that would get no
config block at all), and that block has a blank host. A rejected entry
is counted under `rejected`, by name, like the empty-bag case since M27.

**In the gate's view, a blank value is an absent one.** Only non-empty
bag values are laid over the defaults. That is what keeps an entry
without a `port` key — or with `"SSHField.port": ""` — importable at port
22, which the numeric check would otherwise read as unparsable; and it is
what keeps an S3 export with an empty `region` importable: the gate sees
the schema's `us-east-1` default and passes it, while `apply` still
writes the empty region into the session, so the shape
`BackendDescriptor.editBaseline` exists for — a session imported for
repair in the edit form — is not lost on re-import. The gate answers
"could this be dialed after the form's own defaults", not "is every
column filled".

`requireSecrets: false` because the secret travels in its own column and
its absence is a legal import. `SessionStore.dropsOnLoad` stays the only
judge for the empty-`.ssh`-bag-without-jump shape: `isUnusable` declines
to judge an entry for which no config block would be built at all
(`hasStoredConfiguration`), and the comments in the planner say so.

**Tests** (9 new in `SessionImportPlannerTests`, one extended): the half
bag, the jump-only twin, the port-less bag that still imports, a bag with
a blank port that still imports, an S3 bag without a bucket, an S3 bag
with a blank region that imports with the region kept empty, a WebDAV bag
without a base URL, a mixed file that rejects the unusable entries and
imports the rest, and the property that a rejected entry's password
reaches no planned session or report — the probe is built (it is the
same one the store's rule reads) and dropped on the floor. The existing
ghost-group test gained a schema-rejected sibling, so a group referenced
only by such an entry is not created either.

**Pre-existing, left as it is:** a column-less legacy `.s3`/`.webdav`
entry (empty bag, pre-M23 export) still imports with no config block —
the pinned tests `webdavFileSessionWithoutColumnsKeepsKindAndHasNoConfig`
and `preFixExportFileStillImports` keep that shape on purpose, and
`SessionStore` documents it as a known, explicitly handled exception.
This entry's two forms were SSH shapes; that one is a different entry if
anyone wants it.

