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
| [Host-key types in the rig](superpowers/plans/2026-09-02-host-key-types-rig.md) | **Done 2026-09-02.** One sshd per host-key type (ports 2231–2235), `ssh-keyscan` proof in the rig README, one gated test per type pinning the recorded key type, a mismatch hard stop on ECDSA. Measured: ed25519 and all three ECDSA curves green; **a server with only an RSA host key could not be connected to** that morning (`keyExchangeNegotiationFailure`, the client offered no RSA algorithm) — fixed the same evening, see the RSA host keys row below. File keys per type were already pinned; agent auth per type came with B-2. Record in the key-formats entry. |
| [RSA host keys](superpowers/plans/2026-09-02-rsa-host-key-fork-change.md) | **Done 2026-09-02.** Fork 0.3.9 gave `NIOSSHPublicKeyProtocol` a `hostKeyAlgorithmNames` beside its blob prefix; macSCP registers one pair (`ssh-rsa` blob, offered as `rsa-sha2-512`, PKCS#1 v1.5 over SHA-512 via `_CryptoExtras`) before every connect. The gated RSA row flipped green: port 2235 records `ssh-rsa`, fingerprint identical to `ssh-keyscan`'s; a tampered RSA key is a hard stop; a modulus below 1024 bits (OpenSSH's floor) is not a key. Verification proved by unit tests (valid / flipped byte / wrong digest) and four planted defects. Only `rsa-sha2-512` is offered; a server restricted to `rsa-sha2-256` still fails — add the second digest if one is measured. Upstream PR candidate: the fork change. |
| **B-1** | [Bug list](superpowers/specs/2026-08-20-bugs.md) | Connecting to a dead host blocks the app. Cause measured: Citadel's deadline is set to 30 s and was never passed through. **Fixed** — the deadline is passed through and the attempt is cancellable, and the open half was **measured 2026-08-28** (`ConnectMainActorLivenessTests`): the main thread does not block; it was an operator-facing bug. Still unmeasured: a real hanging nameserver (needs privileges the rig lacks). |
| **B-2** | [SSH key formats](superpowers/specs/2026-08-31-backlog-ssh-key-formats.md) | **Done 2026-09-02** (12 commits). The loader names the key type before parsing (Citadel\'s `SSHKeyDetection`); the message says what the key is and that RSA/ECDSA connect through the ssh-agent — with the **verified** Go-server RSA caveat named, which the entry had wrongly called unmeasured. Measured on the rig: P-384, P-521 and a passphrase-protected key through the agent. RSA from a file still cannot connect (Citadel signs SHA-1); the Go-server case is now fixable in the project\'s own swift-nio-ssh fork — see [RSA via agent vs Go servers](superpowers/specs/2026-09-01-backlog-rsa-agent-go-servers.md). **2026-09-02, later:** the agent path is a ten-cell matrix (five types × with/without passphrase), all green. |
| **B-3** | [Connecting to S3 without a bucket](superpowers/specs/2026-08-31-backlog-s3-without-bucket.md) | **Cheap half done 2026-09-02** (13 commits): a new S3 form starts with `us-east-1` — a named assumption, never written into a saved session (`BackendDescriptor.editBaseline` guards three paths) — and blank bucket/region get their own messages. The rest — a "start at the bucket list" toggle, `ListBuckets` checked on connect, a root mode, the rig extension — is **decided 2026-09-02** (visible toggle; presets only, no provider type) and next to plan: [bucket browser design](superpowers/specs/2026-09-02-s3-bucket-browser-design.md). |

## Security and testability

| Entry | Core |
|---|---|
| [Capability boundary instead of a guard](superpowers/specs/2026-08-22-backlog-connection-capability.md) | **Implemented 2026-08-28.** Deciders are types, the dialing happens module-internal — both proved from outside by planting compile errors. Open and named: `import Citadel` compiles in the app layer (SwiftPM search path), this gap sits below the types and keeps the scan plus the import allow-list alive. |
| [Tests reaching real stores](superpowers/specs/2026-08-22-backlog-test-isolation.md) | `ContentView` hard-wired the keychain and the session store. A test consequently wrote into the real keychain. A seam now exists; the entry holds the rule and the remaining cases. |
| [How far can the UI be tested?](superpowers/specs/2026-08-21-backlog-ui-test-coverage.md) | **Decided 2026-08-28: XCUITest struck for now** — pulling in a second build system while the first has not yet shipped just defers the problem. The trade-off (guard / ViewInspector / XCUITest) stays readable; a bug of this class reaching a user is what brings it back. |
| [Teardown against a frozen peer](superpowers/specs/2026-08-25-backlog-teardown-with-frozen-peer.md) | **Done 2026-08-29.** `disconnect()` never returned against a silent peer; specifically `sftp.close()` hung. Three of the four teardown stages are now bounded — the fourth (`cancelAll`) was measured and its deadline was reverted, because it caught nothing and cost the synchronous sweep. With an open shell: ≥31 s with no return before, 10.3 s and `.lost` after. The unbounded call is additionally **structurally excluded** (`BoundedSFTPSession`). |
| [Unbounded file closes](superpowers/specs/2026-08-28-backlog-unbounded-file-closes.md) | **Fixed 2026-09-02** (`55e6830`, review fixes `17abf12`). All eight counted `SFTPFile.close()` sites are structurally bounded: `BoundedSFTPSession.openFile` now hands out `BoundedSFTPFile`, whose only close is `closeBounded()` against the 5 s session bound, and Citadel's raw `SFTPFile` type is no longer nameable from `CitadelFileSystem.swift` (proved by a planted compile-error). Gated tests green, ~5.2–5.3 s against the red's ~10.5 s; the two arms that used to hang now cost up to that same 5 s where they previously never returned. Open: `write`'s success-path close AND `readStream`'s EOF close both now swallow a non-`ok` CLOSE status instead of throwing — parked for the maintainer, not decided here (a three-case `closeBounded()` outcome would cover both without touching `BoundedClose` or `BoundedSFTPSession`); the separate cancellation finding (a cancelled Task does not interrupt an in-flight SFTP read/write against a frozen peer) is unchanged and still undesigned. |
| [Two open questions from the closing review](superpowers/specs/2026-08-26-backlog-open-questions-review.md) | **S3 half measured and cleared 2026-08-28:** `Authorization` is not carried along across any redirect (10 cases, 2 origin forms, 5 status codes). **M3 fixed 2026-08-29** (`a07640c`): the dial's origin is bound to the attempt, not the tab — a refused connect cannot contribute one. Design: [2026-08-28-two-open-questions-design.md](superpowers/specs/2026-08-28-two-open-questions-design.md). |
| [S3 runs on the shared URL session](superpowers/specs/2026-08-29-backlog-s3-shares-the-url-session.md) | **Done 2026-08-29.** S3 now has its own `ephemeral` session and releases it in `disconnect()`; the `.shared` default in `URLSessionHTTPTransport.init` is gone, four call sites name their session. The open measurement is answered, and unfavorably so: `sendStreaming` caches **identically** — a `max-age` response was served to a second process, body and all, from disk. |
| [S3 follows redirects without control](superpowers/specs/2026-08-28-backlog-s3-redirects.md) | **Done 2026-08-29** (`9e96025`), only buildable once S3 had its own session. Same origin gets re-signed and followed — which at the same time fixes the functional bug that a legitimate redirect arrived unsigned; a foreign origin (scheme, host **and** port) is refused, and the message names both origins without the path. The wrong `Host` disappears through the re-signing. |

## Interface

| Entry | Core |
|---|---|
| [Sessions, tabs, sidebar](superpowers/specs/2026-08-20-backlog-sessions-tabs-sidebar.md) | **Fully done** (eleven of eleven, completed 2026-08-29). The pointer stays because the justifications and measured starting states in it still apply. |
| [Management sheets](superpowers/specs/2026-08-20-backlog-management-sheets.md) | **Fully done** (2026-08-29): items 1, 2, 3 and 5 implemented, item 4 dropped. The facet filter is one control for three sheets, chained with the search via a testable value; the values come from the rows, and with fewer than two values no picker appears. Found along the way: **all three** sheets carried the same silent lie — "unfiltered" meant "search field empty". The pointer stays because of the justifications, especially item 4. |
| [Fine polish on the tabs](superpowers/specs/2026-08-27-backlog-tab-polish.md) | **Done 2026-08-27/28**, re-verified 2026-08-29: the insertion marker highlights the target tab (`TabStripView.dropTarget`), and switching terminal ↔ files hangs off `TabMenuEntry.pane(_:_:)` in the tab menu, with `PaneToggleState` as the single source of truth. The pointer stays because the justifications in it apply. |
| [Snippet editor: usability](superpowers/specs/2026-08-21-backlog-snippet-editor-interaction.md) | **Done 2026-08-30.** Variables fold without remembered state; a variable with an error cannot be collapsed, which turns "collapse all" into "show me only the problems". Insertion, autocomplete on `{{`, and the hint for an undeclared `{{NAME}}` — as a **display**, not a send block. **Done 2026-09-02:** a `{{DB}}` for an environment variable gets its own sentence (declared, but as an environment variable — nothing is filled in; write it as `$NAME`), a display beside the first. **Left open:** the row's insert path appends at the end; a foreign `{{foo}}` is flagged, blocking nothing. |
| [Checksums for files](superpowers/specs/2026-08-27-backlog-file-hashes.md) | **Items 1 and 2 done 2026-08-31** (four tasks). Core did not get a generic `exec(String)`, but "compute this file's checksum": `ChecksumCommandLine` has a `fileprivate init` and two construction sites in the whole package. A result without **provenance** cannot be constructed — proved by planting the weaker construction and watching it pass with a green suite. A multipart ETag explicitly says it is **not** the file's checksum. **Item 3 decided 2026-09-02** (column empty until the user asks; computing is an action, never automatic per listing) and plannable, plus no progress within a file and no dedicated case for "this algorithm does not exist here". |
| [Snippet dry run](superpowers/specs/2026-08-20-backlog-snippet-dry-run.md) | **Done 2026-08-30** (four tasks). The dry run shows the resolved command, the send form, the rejection reason and the coloring — from **one** value that both entry points call (rejection on trigger, "Test" in the editor). The per-snippet marker exists in addition; it **cannot** be exported, because export got its own type before the field existed. The inserted value reaches no log, no export, and no error message — not even a test failure message. |

## New features

| Entry | Core |
|---|---|
| [FTP and SMB/AFP](superpowers/specs/2026-08-25-backlog-further-protocols.md) | Two very different halves under one word. macOS already speaks SMB/AFP — it would be about integration, and the usual TOFU guarantees have no counterpart there. FTP would first need a decision on library and variant, since bare FTP transmits credentials in plaintext. **Do not take on together.** **Decided 2026-09-02: both halves deferred.** |
| [Tools for inspecting a connection](superpowers/specs/2026-08-25-backlog-connection-tools.md) | Ping and trace per connection, even without a saved host. The open question is what both should mean here — a log of macSCP's own connection setup is probably more useful than a traceroute and needs no elevated privileges. **Decided 2026-09-02:** ping = TCP attempt AND ICMP echo; trace = own-setup log AND network trace; entry points tab, context menu, error dialog. Privilege halves behind a spike; needs a design first. |

## Tooling and maintenance

| Entry | Core |
|---|---|
| [CLI: completion, help, host list](superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md) | **Item 1 done 2026-09-02.** `macscp-cli sessions` lists sessions via `SessionCatalog`, filterable by `--group`/`--kind`/`--name`/`--tag` (`--name` is a case-insensitive substring, not a pattern), `--json` included; a source-scanning guard pins that the command touches no secret or connection API. **Open: item 2** (autocompletion — session names only vs. remote paths is still an open design question) **and item 3** (a root-command `discussion` explaining `name:/path`). **Item 2 decided 2026-09-02:** static scripts plus dynamic session names; plannable. |
| [Dependencies](superpowers/specs/2026-08-20-backlog-dependencies.md) | swift-nio-ssh comes in as a **foreign fork** via Citadel — the actual finding. Also: SwiftTerm hangs off a bare revision, swift-crypto is two major versions behind. |
| [Import planner](superpowers/specs/2026-08-19-backlog-import-planner.md) | **Done 2026-09-02.** A bag the backend's own schema cannot dial (half bag, jump-only twin) is rejected and counted, judged over the schema's defaults with a blank value read as absent, so a port-less entry still imports and an S3 export with an empty region still imports for repair. Left as is: the pre-M23 column-less S3/WebDAV entry, a documented store exception. |

---

## Done (pointers stay so the justifications stay findable)

| Entry | |
|---|---|
| [Swift 6 warnings](superpowers/specs/2026-08-19-backlog-swift6-warnings.md) | done 2026-08-26: all six targets on `.v6`, warning-free, CI gate proved red and green |
| [Keep-alive as two settings](superpowers/specs/2026-08-25-backlog-keepalive-two-settings.md) | done 2026-09-02: `keepAliveEnabled` + a sentinel-free 15…600 interval, read-side migration for old `0`-interval files, the probe loop keyed on the switch, and the sentinel-mapping enum (`KeepAliveControlPlan`) plus the view-local memory (`SSHSettingsSection.lastKnownKeepAliveInterval`) deleted rather than kept |
| [Snippet editor part 3: declared variables](superpowers/specs/2026-08-19-backlog-snippet-part-3.md) | implemented, ten review rounds |
| [M6a polish backlog](superpowers/specs/2026-07-26-m6a-polish-backlog-design.md) | milestone completed |
| [M11e backlog sweep](superpowers/specs/2026-07-29-m11e-backlog-sweep-design.md) | milestone completed |

---

## If you don't know where to start

Three candidates, for different reasons:

1. **Single click no longer connects** — one line, felt on every use, and the context menu already has the path.
2. **Known-hosts column sorting** — almost free, because the sheet is already a `Table`.
3. **The capability boundary** — the only entry that ends a recurring bug class instead of handling its next instance.
