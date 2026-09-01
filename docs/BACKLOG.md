# macSCP — Backlog

**Status:** 2026-08-29. An index over the entries under
`docs/superpowers/specs/`, so they do not have to be searched for one by
one. Every entry there is a **secured idea or a measured finding**, not a
design — the designs are created only when the work is taken on.

This file contains no content, only pointers. Whoever changes something
changes it in the entry and at most updates the line here to match.

---

## Bugs

| | Entry | Core |
|---|---|---|
| **B-1** | [Bug list](superpowers/specs/2026-08-20-bugs.md) | Connecting to a dead host blocks the app. Cause measured: Citadel's deadline is set to 30 s and was never passed through. **Partially fixed** — the deadline is now passed through and the connection attempt is cancellable; whether the main thread actually blocks remains open. |
| **B-2** | [SSH key formats](superpowers/specs/2026-08-31-backlog-ssh-schluesselformate.md) | From a bug report on v1.3.0, and it is **two** things. The message "SSH key format is not supported (currently: OpenSSH ed25519)" means "ed25519 is what's supported" and reads as "your ed25519 is not supported" — cheap to fix and simultaneously answers which case is present on the next report. Behind it: the loader can **only** do ed25519, RSA and ecdsa can be managed but not connected with. |
| **B-3** | [Connecting to S3 without a bucket](superpowers/specs/2026-08-31-backlog-s3-ohne-bucket.md) | From the same report: without a bucket and region, macSCP will not connect. Maintainer's suggestion: both empty → load buckets and show them as a starting point. **`ListBuckets` does not exist in the tree**, the region cannot stay empty (SigV4 signs with it), and a bucket level is a **second kind of directory** — different columns, different possible actions. The cheap part (region default + explanatory message) is separable from this. |

## Security and testability

| Entry | Core |
|---|---|
| [Capability boundary instead of a guard](superpowers/specs/2026-08-22-backlog-verbindungs-fähigkeit.md) | **Implemented 2026-08-28.** Deciders are types, the dialing happens module-internal — both proved from outside by planting compile errors. Open and named: `import Citadel` compiles in the app layer (SwiftPM search path), this gap sits below the types and keeps the scan plus the import allow-list alive. |
| [Tests reaching real stores](superpowers/specs/2026-08-22-backlog-testisolation.md) | `ContentView` hard-wired the keychain and the session store. A test consequently wrote into the real keychain. A seam now exists; the entry holds the rule and the remaining cases. |
| [How far can the UI be tested?](superpowers/specs/2026-08-21-backlog-ui-testabdeckung.md) | **Decided 2026-08-28: XCUITest struck for now** — pulling in a second build system while the first has not yet shipped just defers the problem. The trade-off (guard / ViewInspector / XCUITest) stays readable; a bug of this class reaching a user is what brings it back. |
| [Teardown against a frozen peer](superpowers/specs/2026-08-25-backlog-abbau-bei-eingefrorenem-peer.md) | **Done 2026-08-29.** `disconnect()` never returned against a silent peer; specifically `sftp.close()` hung. Three of the four teardown stages are now bounded — the fourth (`cancelAll`) was measured and its deadline was reverted, because it caught nothing and cost the synchronous sweep. With an open shell: ≥31 s with no return before, 10.3 s and `.lost` after. The unbounded call is additionally **structurally excluded** (`BoundedSFTPSession`). |
| [Unbounded file closes](superpowers/specs/2026-08-28-backlog-unbegrenzte-dateischluesse.md) | Side finding from two teardown measurements: **8** `SFTPFile.close()` sites, none bounded, several on a teardown path. **Not a confirmed bug** — the same shape as two calls that demonstrably hung, but the one path leading there is measured and returns. Measure first, only then bound it. |
| [Two open questions from the closing review](superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md) | **S3 half measured and cleared 2026-08-28:** `Authorization` is not carried along across any redirect (10 cases, 2 origin forms, 5 status codes). **M3** stays open — an as-yet-unselected session origin gets attributed to an ad-hoc failure; designed in [2026-08-28-zwei-offene-fragen-design.md](superpowers/specs/2026-08-28-zwei-offene-fragen-design.md). |
| [S3 runs on the shared URL session](superpowers/specs/2026-08-29-backlog-s3-teilt-die-url-session.md) | **Done 2026-08-29.** S3 now has its own `ephemeral` session and releases it in `disconnect()`; the `.shared` default in `URLSessionHTTPTransport.init` is gone, four call sites name their session. The open measurement is answered, and unfavorably so: `sendStreaming` caches **identically** — a `max-age` response was served to a second process, body and all, from disk. |
| [S3 follows redirects without control](superpowers/specs/2026-08-28-backlog-s3-weiterleitungen.md) | **Done 2026-08-29** (`9e96025`), only buildable once S3 had its own session. Same origin gets re-signed and followed — which at the same time fixes the functional bug that a legitimate redirect arrived unsigned; a foreign origin (scheme, host **and** port) is refused, and the message names both origins without the path. The wrong `Host` disappears through the re-signing. |

## Interface

| Entry | Core |
|---|---|
| [Sessions, tabs, sidebar](superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md) | **Fully done** (eleven of eleven, completed 2026-08-29). The pointer stays because the justifications and measured starting states in it still apply. |
| [Management sheets](superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md) | **Fully done** (2026-08-29): items 1, 2, 3 and 5 implemented, item 4 dropped. The facet filter is one control for three sheets, chained with the search via a testable value; the values come from the rows, and with fewer than two values no picker appears. Found along the way: **all three** sheets carried the same silent lie — "unfiltered" meant "search field empty". The pointer stays because of the justifications, especially item 4. |
| [Fine polish on the tabs](superpowers/specs/2026-08-27-backlog-reiter-feinschliff.md) | **Done 2026-08-27/28**, re-verified 2026-08-29: the insertion marker highlights the target tab (`TabStripView.dropTarget`), and switching terminal ↔ files hangs off `TabMenuEntry.pane(_:_:)` in the tab menu, with `PaneToggleState` as the single source of truth. The pointer stays because the justifications in it apply. |
| [Snippet editor: usability](superpowers/specs/2026-08-21-backlog-snippet-editor-bedienung.md) | **Done 2026-08-30.** Variables fold without remembered state; a variable with an error cannot be collapsed, which turns "collapse all" into "show me only the problems". Insertion, autocomplete on `{{`, and the hint for an undeclared `{{NAME}}` — as a **display**, not a send block. **Left open:** a `{{DB}}` for an environment variable is just as silent and is not reported — one click away from the fixed case, needs its own pass. |
| [Checksums for files](superpowers/specs/2026-08-27-backlog-datei-hashes.md) | **Items 1 and 2 done 2026-08-31** (four tasks). Core did not get a generic `exec(String)`, but "compute this file's checksum": `ChecksumCommandLine` has a `fileprivate init` and two construction sites in the whole package. A result without **provenance** cannot be constructed — proved by planting the weaker construction and watching it pass with a green suite. A multipart ETag explicitly says it is **not** the file's checksum. **Open: item 3** (table column), whose question 3 remains unanswered, plus no progress within a file and no dedicated case for "this algorithm does not exist here". |
| [Snippet dry run](superpowers/specs/2026-08-20-backlog-snippet-probelauf.md) | **Done 2026-08-30** (four tasks). The dry run shows the resolved command, the send form, the rejection reason and the coloring — from **one** value that both entry points call (rejection on trigger, "Test" in the editor). The per-snippet marker exists in addition; it **cannot** be exported, because export got its own type before the field existed. The inserted value reaches no log, no export, and no error message — not even a test failure message. |

## New features

| Entry | Core |
|---|---|
| [FTP and SMB/AFP](superpowers/specs/2026-08-25-backlog-weitere-protokolle.md) | Two very different halves under one word. macOS already speaks SMB/AFP — it would be about integration, and the usual TOFU guarantees have no counterpart there. FTP would first need a decision on library and variant, since bare FTP transmits credentials in plaintext. **Do not take on together.** |
| [Tools for inspecting a connection](superpowers/specs/2026-08-25-backlog-verbindungswerkzeuge.md) | Ping and trace per connection, even without a saved host. The open question is what both should mean here — a log of macSCP's own connection setup is probably more useful than a traceroute and needs no elevated privileges. |

## Tooling and maintenance

| Entry | Core |
|---|---|
| [CLI: completion, help, host list](superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md) | The host listing is entirely missing and is at the same time the data source for completion — hence first. Constraint: the listing must not touch the keychain. |
| [Dependencies](superpowers/specs/2026-08-20-backlog-abhaengigkeiten.md) | swift-nio-ssh comes in as a **foreign fork** via Citadel — the actual finding. Also: SwiftTerm hangs off a bare revision, swift-crypto is two major versions behind. |
| [Keep-alive as two settings](superpowers/specs/2026-08-25-backlog-keepalive-zwei-einstellungen.md) | One stored value carries "off" and "interval" at once; the interval does not survive a restart. Cause was a wrong default in the task spec, not the implementation. |
| [Import planner](superpowers/specs/2026-08-19-backlog-import-planer.md) | Half-filled field bags on import. Before taking this on, check how much of it the snippet branch has already handled. |

---

## Done (pointers stay so the justifications stay findable)

| Entry | |
|---|---|
| [Swift 6 warnings](superpowers/specs/2026-08-19-backlog-swift6-warnungen.md) | done 2026-08-26: all six targets on `.v6`, warning-free, CI gate proved red and green |
| [Snippet editor part 3: declared variables](superpowers/specs/2026-08-19-backlog-snippet-teil-3.md) | implemented, ten review rounds |
| [M6a polish backlog](superpowers/specs/2026-07-26-m6a-polish-backlog-design.md) | milestone completed |
| [M11e backlog sweep](superpowers/specs/2026-07-29-m11e-backlog-sweep-design.md) | milestone completed |

---

## If you don't know where to start

Three candidates, for different reasons:

1. **Single click no longer connects** — one line, felt on every use, and the context menu already has the path.
2. **Known-hosts column sorting** — almost free, because the sheet is already a `Table`.
3. **The capability boundary** — the only entry that ends a recurring bug class instead of handling its next instance.
