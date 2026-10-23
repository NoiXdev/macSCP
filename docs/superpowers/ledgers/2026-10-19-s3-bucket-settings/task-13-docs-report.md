# Task 13, Step 1: user documentation report

Worktree: /Users/noidee/_dev/noix-docs-s3-bucket-settings, branch docs/macscp-s3-bucket-settings. Not pushed, not merged.

## Pages

Created (all under src/content/docs/macscp/guide/):
- s3-bucket-settings.md (order 12): Connection Actions menu, availability table, Create Bucket, empty account.
- s3-versioning.md (order 13): three states, one-way, suspension, Object Lock interaction.
- s3-cors.md (order 14): Fields/Text views, validation, clearing.
- s3-object-lock.md (order 15): bucket default, per-file retention, legal hold, Compliance danger aside.
- audit-log.md (order 16): opening a log, filters, the four new entries.

Extended: getting-started/first-connection.md (one sentence on the empty account), reference/security.md (link from "Audit logs").

## Verification

npm ci, then npm run build: "All internal links are valid", 165 pages built, no warnings. npm run check: 0 errors, 0 warnings, 0 hints.

## Labels quoted from the catalogue

Bucket created / Versioning changed / CORS rules changed / Object Lock changed (en.lproj keys audit.kind.*). Menu rows: Create Bucket…, Versioning…, CORS Rules…, Object Lock…. File actions: Retention…, Legal Hold…. The app calls the log "Audit Log…" (sidebar.auditLog), so the docs use "audit log", not "activity log".

## Not explained / deviations from the brief

See the handback message; same text.

## Update round: create-bucket read-back, empty screen, audit detail

Changed pages: guide/s3-bucket-settings.md (create outcomes, empty-account passage corrected), guide/audit-log.md (Bucket created detail), guide/s3-object-lock.md (Governance extend statement, link to the default-retention warning). Build: all internal links valid, 165 pages, no warnings. Check: 0 errors, 0 warnings, 0 hints.
Sentences quoted from en.lproj: s3.createBucket.error.settingsDidNotTake, settingsUnconfirmed, protectionNotChosen, defaultRetentionNotSetHere, existsIncompletely; browser.pane.noContainers.title/body.
Not documented by design: a store without Object Lock (clean plain create).
