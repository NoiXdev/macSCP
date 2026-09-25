# The answered decisions of 2026-09-24 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build what the maintainer decided in chat on 2026-09-24 — a managed key's passphrase editable in two separate ways, a diagnostics deadline that holds under load, failure reasons carried as a typed cause and rendered in four languages, and an S3 test server to replace the one whose images are gone — together with the open bugs and test gaps that sit in the same code.

**Architecture:** Nine tasks. Tasks 1-3 are the key and secret work (the passphrase UI, the unreadable-store fact reaching the jump hop, the CLI's second Keychain consent). Task 4 is the deadline. Tasks 5-6 are the typed failure cause: Core carries it, then the App renders it. Task 7 is the test server. Task 8 is a test-hygiene sweep of four recorded rows. Task 9 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first — each carries its own measurement — and re-verify every anchor with `grep -n`. The anchors below were taken at `94f1641d` and drift.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, **macOS 15.5 SDK**, three cores, zero-warning budget), Swift Testing, SwiftUI/AppKit, Docker rig (from the MAIN checkout).

## Global Constraints

- **The maintainer's answers of 2026-09-24 bind**: the passphrase gets TWO separate menu actions (correct the stored value; change the key file's own passphrase); a diagnostics deadline is a HARD limit that holds however loaded the machine is; failure reasons are rebuilt NOW as a typed cause carried into the App and translated; the S3 rig gets a replacement server rather than the old images from another registry.
- **User documentation ships with the feature** (CLAUDE.md, 2026-09-19). Every task that changes something a user sees also writes it into a worktree of `/Users/noidee/_dev/noix-docs` on branch `docs/macscp-next` (pushed, at `28e1739`), marked `*(next version)*`, with `npm run build` and `npm run check` green, committed there and **not pushed** unless the maintainer asks.
- **CI's SDK is older than this machine's** (macOS 15.5 vs macOS 27), measured the hard way on 2026-09-24: `ENOTCAPABLE` compiled here and not there. Anything new that names a platform constant, an API availability or an SDK symbol is a CI risk; prefer a derived value over a spelled one, and say in the report what you could not verify locally.
- No secret in any store, state, log, reason, report, row or test message; no real host names in tests; the rig from the MAIN checkout only. TOFU is a hard stop; no accept-anything path. **NO secret through the CLI** — no flag, no stdin, no keychain write, nothing printed; the CLI reads the app's keychain entry read-only as the last link of its chain.
- Swift Testing, red first (recorded); tests never block the cooperative pool; no wall-clock ceiling, and no fake that finishes on its own while a deadline races it; no `#require` on a non-optional; polling goes through `pollUntil` under the suite's own `.timeLimit`.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form), in `Sources/MacSCPAppKit/Resources/<locale>.lproj/Localizable.strings`; Core's own catalogue through `CoreL10n`; plurals through `Localizable.stringsdict`. The CLI's JSON: add keys, never rename.
- Source-scanning guards read through `Tests/MacSCPTestSupport/SourceCorpus.swift`; a negative check keeps a positive beside it. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`.
- Subagents work in the FOREGROUND only. Build and test with `swift test --build-system native` — the default build system fails here on SwiftTerm's Metal shader. A run that crashes or shows a `testStarted`/`testEnded` mismatch with no recorded issue wants `swift package clean` first; only the clean run counts (measured 2026-09-24, a stale witness table after a protocol change).
- Zero compiler warnings. Conventional Commits, English, one blank line before the footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` before Task 9.

---

### Task 1: A managed key's passphrase, in two separate actions

**Row:** "No UI to change a managed key's stored passphrase, so a typed jump passphrase is kept but never used" (maintainer's answer: both, as two separate actions).

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHKeysSheet.swift` (`SSHKeysSheet` `:24`, `actionMenuItems(for:)` `:342` with its five existing actions `:343-348`, `.contextMenu` `:299`; `RenameKeySheet` `:929` is the closest existing shape for a one-field sheet)
- Read: `Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift` (`resolve(keyPath:typed:store:secrets:)` `:39`, reads `secrets.password(for: key.id)` `:53`; `hasStoredPassphrase` `:88`), `Sources/macSCPCore/Sessions/SecretStore.swift` (`SecretStore` `:9`, `KeychainSecretStore` `:31`), `Sources/macSCPCore/SSH/SSHKeyConverter.swift` (`inPlaceCommandLine(forKeyAt:)` `:121` is the `ssh-keygen -p` this project already offers), `Sources/macSCPCore/SSH/SSHKeyGenerator.swift` and `KeyToolBound.swift` (how an `ssh-keygen` run is bounded and kept off the pool)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (the `keys.rename` family at `en:945-947` is the pattern)
- Test: `Tests/macSCPAppKitTests/` (the key-manager suites), `Tests/macSCPCoreTests/` (whatever Core gains)

- [x] **Action one — "Correct the stored passphrase".** The app's stored value is wrong or missing; the key file is untouched. The sheet takes one field, **verifies** the typed passphrase against the key file before saving it (`ssh-keygen -y -P … -f …` is what `KeyToolBound` already bounds), and refuses with a fixed message when it does not open the key. Saving writes only the Keychain item for `key.id`. A passphrase that does open the key must never be rejected, and a wrong one must never be stored.
- [x] **Action two — "Change the key file's passphrase".** Old and new (plus a confirmation), `ssh-keygen -p` on the key file, then the stored value follows in the same operation. State what happens if the file is re-encrypted and the Keychain write then fails — the honest answer is that the file's new passphrase is the truth and the app must say so rather than pretend. A key the app did not import (not under its own directory) is refused with a message naming why.
- [x] Both actions are reachable from the key's own context menu beside the existing five, both are disabled where they cannot apply (state when), and both run their tool off the cooperative pool through the existing bound runner. No secret reaches a log, a reason, a report, an error text, or an `#expect`'s source text; the sheets follow the async-reentrancy rules the key sheets already carry (capture inputs, disable fields, cancellable task).
- [x] Tests, red first: correcting with the right passphrase stores it; correcting with a wrong one refuses and stores nothing; changing the file's passphrase re-encrypts and the new value is stored; a Keychain failure after a successful re-encryption is reported as such; a key outside the app's directory is refused. Gated `MACSCP_KEYCHAIN=1` where a real keychain is needed, and say which cases are gated.
- [x] Whole suite, zero warnings; docs updated (the keys page: both actions and when each one is the right one). Commit `feat(keys): a managed key's passphrase can be corrected and changed`.

---

### Task 2: The unreadable-store fact reaches the jump hop

**Row:** "A managed-key store's unreadable-store message does not reach the jump hop".

**Files:**
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift` (`ResolvedLogin` `:52` with its four fields `:53-56`; `preferringManagedKeyPassphrase(_:keys:secrets:)` `:221` — **the row's `fallingBackToManagedKeyPassphrase` was renamed in `04e8c4d6`** — which drops `Resolution.unreadableStoreHidTheKey` by design, its doc at `:227-232`)
- Modify: the three jump fills — `Sources/macSCPCore/Presentation/SessionListViewModel.swift` `resolvedJumpLogin(for:)` `:1426` (uses it `:1429`), `resolvedJump(for:)` `:1445` (`:1450`), and `SessionListViewModel+Submit.swift` `fillJumpForm(_:from:)` `:86` (`:102`)
- Read/Modify: `Sources/macSCPCore/Diagnostics/DiagnosticJump.swift` (`DiagnosticJump` `:20`, `dialViaJump` `:361-448`, the `DialSupport.dialSecret(usesAgent:missing:_:)` call `:442-443` passing `DiagnosticReason.noJumpSecret`), `Sources/macSCPCore/Diagnostics/DiagnosticReason.swift` (`noJumpSecret` `:27`)
- Test: the jump and login-resolver suites in `Tests/macSCPCoreTests/`

- [x] Today the hop says "no secret" whether there is none or the managed-key store could not be read — two different problems with one sentence, and the user can only act on one of them. Carry the fact: `ResolvedLogin` gains a field for it (or an equivalent you argue for), the three fills copy it through, and the jump diagnosis distinguishes "no secret" from "the key store could not be read" with its own reason.
- [x] The tab's own fill writes no diagnostic line today; decide whether it should, state the decision, and keep it consistent with what the chain's link already logs.
- [x] Tests, red first: an unreadable store reaches the jump hop as its own reason, for each of the three fills; a genuinely absent secret still reads as `noJumpSecret`; no secret, path or store content appears in either message.
- [x] Whole suite, zero warnings; docs updated if the user-visible wording changes. Commit `fix(keys): an unreadable key store is named at the jump hop`.

---

### Task 3: An unattended run asks for consent once

**Row:** "An unattended CLI run may need a second Keychain consent".

**Files:**
- Read/Modify: `Sources/macSCPCore/Sessions/CLISecretSources.swift` (`secretSources(for:passwordCommand:keychainStore:keyStore:)` `:236`, the managed-key link appended `:277-282` — **the row's `:223` has drifted**), `Sources/macSCPCore/Sessions/SecretStore.swift` (`KeychainSecretStore` `:31`, addressed by `sessionID`; a managed key's item is addressed by `key.id`)
- Read: `Sources/MacSCPCLI/DiagnoseCommand.swift` (`jump(of:)` `:389` and its doc `:376-388`)
- Test: `Tests/macSCPCoreTests/CLISecretSourcesTests.swift` (chain order `:481`, the negative `:595`)

- [x] Two DIFFERENT keychain items are read in one run — the session's and the managed key's — so macOS can ask twice, and an unattended run stalls on the second ask. Measure first: which runs read both, in what order, and whether the second read is reachable when the first already answered. Write the measurement down before changing anything; if the second read is avoidable when the first succeeded, that is the fix.
- [x] Whatever the fix, the rule stands: no secret through the CLI, and the CLI reads the app's keychain entry read-only. Do not add a flag, a prompt, or a way to pass a secret in.
- [x] Tests, red first for whatever behaviour changes; if the honest outcome is "both reads are necessary", say so, record it, and change no code — a measurement is a legitimate deliverable here.
- [x] Whole suite plus the gated keychain suite; zero warnings; docs updated if what an unattended run needs changes. Commit `fix(cli): an unattended run asks for keychain consent once` (or `docs(cli): why an unattended run can be asked twice, measured`).

---

### Task 4: A diagnostics deadline that holds under load

**Row:** "CI starvation: the deadline, bcrypt and audit-append costs left open" — the `DispatchQueue.global()` deadline weakness half only (maintainer's answer: a hard limit, independent of load).

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/BlockingProbe.swift` (`BlockingProbe` `:19`, `run(label:timeout:_:)` `:23`, the timer at `:38`; `DetachedProbe` `:65`, its timer at `:100`)
- Read: `Sources/macSCPCore/Diagnostics/DiagnosticStep.swift:538` (the `Duration.seconds` bridge), and `BlockingProbe.swift:93-99`'s comment claiming the global queue "overcommits past the core count" — the row's measurement contradicts it
- Test: `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift` and the probe suites

- [x] The measurement in the row: ten CPU-bound tasks delayed a 0.3 s timer to 5.0 s, because the deadline is a `DispatchQueue.global()` timer and a saturated pool has no thread to fire it. The maintainer's ruling is a hard limit. Design it, state the design, and say what it costs: one dedicated timing thread for the process is the obvious shape (the same fix `4a4835b2` used for a test stub earlier), but weigh at least one alternative before choosing.
- [x] Correct the comment at `:93-99` in the same pass — it states as fact the thing the measurement disproves (CLAUDE.md, "Comments that describe other code").
- [x] Tests, red first, and this is the hard part: prove the deadline fires under saturation WITHOUT a wall-clock ceiling. A floor is allowed ("this did not return early"); an ordering is better ("the deadline's effect is observed before the work's"). The existing `MACSCP_SATURATION=1` gate (one test that parks the whole GCD global queue, run alone) is the precedent — read it and follow it rather than inventing a second saturation harness.
- [x] Whole suite plus the saturation gate run alone; zero warnings. Commit `fix(diagnostics): a step's deadline holds however loaded the machine is`.

---

### Task 5: Core carries the failure's cause, not only its sentence

> **Correction to this plan, 2026-09-25.** The first row named below, "A forwarding's
> failure reason is English on four localized surfaces", was **already closed before this
> plan started** — done 2026-09-17 in `ab4a2c4c` (technical-backlog plan, Task 6), which
> gave `TunnelState.failed`/`TunnelEvent.failed` a typed `TunnelFailureKind`. Verified
> independently by two agents with `git show`: Task 5's review, and Task 6, which
> re-measured the App half rather than assuming it (35 `TunnelFailureKind.Name` cases to
> 36 `tunnel.failure.*` keys in all four catalogues, and
> `TunnelActiveFailuresLabelTests.everyStateSurfaceReadsTheTooltip` already pinning all
> four surfaces). The plan's premise for that row was stale; the row is correct and was
> not re-closed. The live work of Tasks 5 and 6 was the other two rows.

**Rows:** "A forwarding's failure reason is English on four localized surfaces", "Transfer failure reasons are English inside a localized frame", "A forwarding's `.secretRequired` renders as a case index in the diagnostic log" (maintainer's answer: rebuild now).

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift` (`DialSupport` `:126`, `reason(for:)` `:228`, `classify(_:)` `:260` with arms for `HostKeyError` `:265`, `TunnelFailure` `:282`, `TunnelRefusal` `:312`, `KeychainError` `:326`, `SSHKeyError` `:333`, `AgentError` `:368`, `SFTPStartError` `:385`, `RemoteFSError` `:392`, `IOError` `:437`, `default` `:454` — and **no arm for `StoredSessionConnectionError`**)
- Modify: `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift` (`StoredSessionConnectionError` `:6`, cases `:12`, `:15`, `:19`, `:40`)
- Modify: `Sources/macSCPCore/Tunnels/TunnelFailureKind.swift`, `Sources/macSCPCore/Tunnels/TunnelRunner.swift` (the log line `:353`, `needsAPerson(_:)` `:509` with its `.secretRequired` check `:511`)
- Test: the tunnel, dial and transfer suites

- [x] The shape the row already states: `TunnelState.failed` (and the transfer queue's failure) carries a TYPED cause — the case and its data, a port number, a host, a refusal — not its rendering. Core keeps producing today's English sentence for the audited log from that value, so the log does not change; what is new is that the case identity survives for the App to translate. `classify(_:)` gains its missing `StoredSessionConnectionError` arm in the same pass, so `.secretRequired` stops rendering as a case index in the diagnostic log.
- [x] This is a Core model change and the largest task in the plan. Keep it to Core: the App's rendering is Task 6. Do not change any log text; a diff in the audited line is a regression here, and a test should say so.
- [x] Tests, red first: every typed cause survives to the boundary the App will read; the rendered English sentences are byte-identical to today's for every case (pin them); `.secretRequired` reaches the log as its own sentence rather than a case index; no secret in any cause's data.
- [x] Whole suite, zero warnings. Commit `feat(tunnels): a failure carries its cause, not only its sentence`.

---

### Task 6: The four catalogues render the cause

**Rows:** the same three as Task 5 — this task closes them.

**Files:**
- Modify: `Sources/MacSCPAppKit/TunnelProfilesSheet.swift` (`stateLabel`), `Sources/MacSCPAppKit/TunnelAutostartSheet.swift`, `Sources/MacSCPAppKit/TunnelDockPresence.swift`, `Sources/MacSCPAppKit/SessionSidebar.swift` — the four surfaces the row counted, three of them through `stateLabel`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`message(for:)`, which formats `core.transfer.failed %@` with a raw reason)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (+ `.stringsdict` if any case needs a plural)
- Test: the App's tunnel and queue suites, plus the localization checks

- [x] Map the typed cause through `L10n` into the four catalogues, German in du-form. Every case gets a sentence in all four languages; a case with data (a port, a host) interpolates it, and nothing that could be a secret is interpolated — state which fields are safe and why.
- [x] A cause with no catalogue entry must not fall back to a raw English sentence silently: decide what it does, state it, and give the localization check a positive that every case is covered, so a case added later is a loud red rather than an English leak.
- [x] Tests, red first: each of the four surfaces reads the localized text; the transfer queue's failure does too; the German catalogue addresses the user as du (`GermanAddressFormTests` already holds it); a missing entry is caught by the guard.
- [x] Whole suite, zero warnings; docs updated (any page quoting a failure sentence). Commit `feat(app): a failure's cause is read in the user's language`.

---

### Task 7: An S3 test server that exists

**Row:** "The S3 test rig cannot start: MinIO images are no longer on Docker Hub" (maintainer's answer: find a replacement and wire it in).

**Files:**
- Modify: `docker/test-server/compose.yml` (`minio` `:41-86`, image `:42`; `minio-init` `:87-113`, image `:88`; the port comment `:114`), `docker/test-server/minio/scoped-seed-policy.json` and whatever else the seed mounts
- Read: the S3 gated suites that depend on the rig
- Modify: `CLAUDE.md`'s rig paragraph and `docs/` where the rig is described

- [x] Measure before choosing. The rig needs what the S3 backend actually exercises: list, ranged GET, multipart upload and abort, `DeleteObjects`, presigned URLs, ETags, a scoped credential policy, and refusal behaviours the tests assert. Try at least two candidates, say which of those each one satisfies, and name the images with their exact tags. The maintainer asked for a replacement rather than the same images from another registry; if the measurement says nothing else satisfies the list, say so plainly with the evidence rather than quietly falling back.
- [x] Wire the winner in with a pinned tag, keep the ports and the seed's shape so the gated suites do not have to change; where a test must change, say why. The rig's own README/comments say what it is and why.
- [x] Prove it: `docker compose … up -d` from the MAIN checkout, then the S3 half of `MACSCP_ITEST=1 swift test --build-system native`, with the before/after counts. A suite that has not run against a real server since the images vanished may have drifted — report every failure it finds as a finding, not as noise.
- [x] Whole suite plus the gated S3 suite; zero warnings. Commit `test(s3): the rig runs against a server that still exists`.

---

### Task 8: Four recorded test gaps

**Rows:** "The `M10d/T2` ssh-agent tests in `CitadelFileSystemIntegrationTests` accept any unknown host key", "`deleteTree`'s cancellation path is pinned by no test", "Three test doubles drop a validator handed to them", "`DiagnosticsNoDescribingGuardTests.swift:113` cites a stale line number".

**Files:**
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (`M10d/T2` section `:1903-2257`; the ten `.asking { _ in true }` at `:1930`, `:1965`, `:2002`, `:2047`, `:2080`, `:2124`, `:2149`, `:2178`, `:2205`, `:2249`; the jump-hop cases `agentAuthOnJumpHop` `:2063` and `agentAuthOnJumpHopWrongKeyFailsJumpAuth` `:2098`; the seeding helpers `rigHostKeyEntries()` `:1606` and `rigKnownHosts(in:)` `:1639`, and the pattern to follow at `dialJumpPairConnection` `:1650` which dials `.refusing`)
- Modify: `Tests/macSCPCoreTests/S3FileSystemTests.swift` or a sibling (follow `Tests/macSCPCoreTests/HTTPTransferCancelTests.swift` `:22`, whose `aUserCancelReadsCancelled` `:26` is the existing shape)
- Modify: `Tests/macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift` (`ProbeTargetStatCounter` `:564`, forwards `supportsAppendResume` at `:582`; `DisconnectTimingProbe` `:649`, at `:668`), `Tests/macSCPCoreTests/EditSessionManagerTests.swift` (`GatedRemoteFileSystem` `:65`)
- Modify: `Tests/macSCPCoreTests/DiagnosticsNoDescribingGuardTests.swift:113`

- [x] The ten accepting deciders: seed through `rigKnownHosts(in:)` and dial `.refusing`, as the two-live-connections matrix does. Where a case's SUBJECT is the TOFU path itself (Task 8 of the previous plan kept exactly one such case for that reason — find it and follow the same judgement), keep a decider that answers only for keys the rig holds, and say which cases you treated which way and why.
- [x] `deleteTree`'s cancellation: one case pinning that a cancel during the batch delete reads as a cancellation and not as a transport failure. `Task.checkCancellation()` at `S3FileSystem.swift:858` and `HTTPCancellation.cancellation(in:)` at `HTTPTransport.swift:114` are the two paths; say which one your case exercises, and whether the other stays unpinned.
- [x] The three doubles: forward `entityTag(path:)`, `readStream(path:fromOffset:ifMatching:)` and `statWithEntityTag(path:)` the way each already forwards `supportsAppendResume`, and add the case that would have caught it — a validator handed to the wrapper reaches the inner file system.
- [x] The stale citation at `:113`: the clause it cites now sits at `DialProbes.swift:221`. Retake the number, and while you are there ask whether a citation that drifts every time the file moves should be a derived anchor instead.
- [x] Whole suite plus `MACSCP_ITEST=1` (the rig from the MAIN checkout; if Task 7 landed a new S3 server, run against it); zero warnings. Report the `M10d/T2` section's results specifically. Commit `test(ssh): the agent tests refuse an unknown host key` plus one more for the rest, or one commit per row — your call, stated.

---

### Task 9: Closeout

- [x] `docs/BACKLOG.md`: each row named above gets a **Done 2026-09-24** (or the day the work lands) sentence leading the row, with its commits; open remainders get their own rows; every decision taken FOR the maintainer inside these tasks is listed so it can be overturned; the sight checks join the grouped sight-check row. This plan's step boxes ticked. The docs worktree's commits are named in the report. Commit `docs(backlog): the answered decisions of 2026-09-24 are recorded`.

## Self-review

- Coverage: the maintainer's four answers → Tasks 1, 4, 5-6, 7; the open bugs beside them → Tasks 2-3; the recorded test gaps → Task 8; Task 9 closes.
- Placeholders: Task 2's carrier field, Task 3's outcome (a measurement is a legitimate deliverable), Task 4's timing design, Task 6's behaviour for an uncatalogued case, Task 7's chosen server and Task 8's commit split are decisions the implementer states and the closeout records.
- Type consistency: `SSHKeysSheet`, `RenameKeySheet`, `ManagedKeyPassphrase.resolve`, `SecretStore`/`KeychainSecretStore`, `SSHKeyConverter.inPlaceCommandLine`, `LoginResolver.preferringManagedKeyPassphrase`, `ResolvedLogin`, `DiagnosticJump`/`DiagnosticReason.noJumpSecret`, `CLISecretSources.secretSources`, `BlockingProbe`/`DetachedProbe`, `DialSupport.classify`, `StoredSessionConnectionError`, `TunnelRunner.needsAPerson`, `rigKnownHosts(in:)`/`rigHostKeyEntries()` and the three test doubles all exist at `94f1641d`, verified by `grep -n` on 2026-09-24.
- **Not in this plan**, deliberately: the thirteen "deferred minors" rows, sized on 2026-09-24 at 54 open items (13 trivial, 22 small, 23 real). They are their own sweep, and mixing them with a Core model change would bury both.
