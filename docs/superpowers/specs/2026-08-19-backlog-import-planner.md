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
