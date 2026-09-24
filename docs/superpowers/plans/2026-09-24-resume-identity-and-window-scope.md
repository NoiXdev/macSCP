# Resume identity, a refused redirect, and two window-scoped reads — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close seven recorded, decision-free backlog rows: a resumed download that cannot tell the object changed under it, an S3 batch delete that hides a refused redirect, a bind failure that logs a bare errno, a command-line message that names three of four places it looked, a terminal type read from the wrong window, a launch-time window frame that can land on the main display, and two older jump test sections that accept any unknown host key.

**Architecture:** Eight tasks. Tasks 1-2 are the resume-identity change (Core protocol and the two HTTP backends first, then the queue that carries the validator across a retry). Tasks 3-5 are three small, independently reviewable corrections. Tasks 6-7 are the two window-scoped reads in the App. Task 8 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first and re-verify every anchor below with `grep -n` — the line numbers in this plan were taken at `4a4835b2` and drift.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, three cores, zero-warning budget), Swift Testing, SwiftUI/AppKit, the Docker rig (from the MAIN checkout).

## Global Constraints

- **User documentation ships with the feature** (CLAUDE.md, 2026-09-19). A task that changes something a user sees also writes it into a docs worktree of `/Users/noidee/_dev/noix-docs` on branch `docs/macscp-next` (the branch exists locally and on `origin`; the previous worktree's directory is gone — create a new one under this session's scratchpad with `git worktree add`), marked `*(next version)*`, with `npm run build` and `npm run check` green, committed there and **not pushed**. No tech-stack terms on those pages.
- TOFU is a hard stop; no accept-anything path. No secret in any store, state, log, reason, report or test message; no real host names in tests; the rig from the MAIN checkout only, and never `minio`.
- Swift Testing, red first (recorded); tests never block the cooperative pool; no wall-clock ceiling, and no fake that finishes on its own while a deadline races it; no `#require` on a non-optional; polling goes through `pollUntil` under the suite's own `.timeLimit`.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); plurals through `Localizable.stringsdict`. Core-layer user-facing text through `CoreL10n`. Settings keys go through `SettingsStore`. The CLI's JSON: add keys, never rename.
- Source-scanning guards read through `Tests/MacSCPTestSupport/SourceCorpus.swift`; a negative check keeps a positive beside it. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`.
- Subagents work in the FOREGROUND only. If the first build fails on a stale Metal toolchain path, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings. Conventional Commits, English, one blank line before the footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` before Task 8.

---

### Task 1: A resumed download can tell the object apart — Core and the two HTTP backends

**Row:** "A resumed download does not check that the object is still the same".

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (protocol at `:20`, requirement list `:21-100`, default extension from `:105`)
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (`readStream` `:436`, `listedEntry(at:)`/`eTag` used at `:1517-1530`)
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift` (`readStream` `:281-297`, `Self.dropping(_:from:)` `:300-318`)
- Modify: `Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift` (`didEndElement` switch `:131-159`, `Entry`/`PendingPropstat` `:74-98`)
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`, `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` (or the existing WebDAV unit suite), `Tests/macSCPCoreTests/WebDAVPropfindParserTests.swift`

**Interfaces produced (Task 2 consumes these exact names):**
- `RemoteFileSystem.entityTag(path:) async throws -> String?` — a validator for the object as it is now, or `nil` when the backend has none. Default extension returns `nil`.
- `RemoteFileSystem.readStream(path:fromOffset:ifMatching:) async throws -> AsyncThrowingStream<Data, Error>` — default extension ignores `ifMatching` and calls `readStream(path:fromOffset:)`.
- `RemoteFSError` reason constant for a validator mismatch (see below).

- [ ] Read the row, then re-find every anchor with `grep -n`. Both new members are **protocol requirements with default implementations in the extension**, so none of the 45 existing conformers changes and none needs recompiling attention. Watch the one trap: a conformer that overrides only one of the two `readStream` spellings must not end up calling itself — S3 and WebDAV override BOTH (the two-argument one delegating to the three-argument one with `nil`), everything else overrides only the two-argument one and takes the extension's three-argument default. State in a comment why that is not a cycle.
- [ ] `entityTag(path:)`: S3 answers from the listing entry's `eTag` (the same `listedEntry(at:)` read `remoteChecksum(forFileAt:algorithm:)` uses at `:1517-1527`) — the raw text with its quotes, not a parsed checksum, because it goes back out as a header. WebDAV answers from a new `getetag` property on the PROPFIND parser's entry, which the parser does not read today (verified: zero occurrences of `getetag` in `WebDAVPropfindParser.swift`). A backend with no validator returns `nil`, and that is not an error.
- [ ] `readStream(path:fromOffset:ifMatching:)`: when `ifMatching` is non-`nil` **and** `offset > 0`, the request carries `If-Match: <tag>`; S3 sets it after `buildSignedRequest` returns, beside the existing `Range` header (same reasoning as `Range`: not part of the signed set — say so in a comment). A `412` response is not a transport failure and not a `.protocolError` about HTTP status: it is the one thing this task exists to report, and it reads as a named constant beside `S3FileSystem.rangeIgnoredReason` (e.g. `sourceChangedReason`), worded so a user understands the file changed on the server and nothing was appended. WebDAV maps `412` the same way through its own constant. An `If-Match` is never sent on a fresh (offset 0) read — there is nothing to protect.
- [ ] Tests, red first, with the existing HTTP stub (never a real host): S3 — a resumed read with a tag sends `If-Match` exactly once with the listed tag; a 412 throws the named reason and no partial body is returned; a resumed read with `nil` sends no `If-Match`; a fresh read with a tag sends none either; the existing `answersTheRange` refusal still fires. WebDAV — the same four cases, plus the parser: `getetag` is read, a response without it yields `nil`, and a weak validator (`W/"…"`) is carried through as it arrived. No credential or endpoint text in any expectation (named constant, `Bool` computed first).
- [ ] Whole suite, zero warnings. Commit `feat(transfers): a resumed download can be tied to the object it started on`.

---

### Task 2: The retry carries the validator the first attempt saw

**Row:** the same row as Task 1 — this task closes it.

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (`copyFile` `:111-118`, resume block `:136-159`)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`Item` `:83`, its stored properties `:132-182`, `retryInterrupted` `:716-736`)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces consumed:** Task 1's `entityTag(path:)` and `readStream(path:fromOffset:ifMatching:)`.

- [ ] `copyFile` gains one parameter, defaulted so every existing call site keeps compiling: an expected source validator (`String?`, default `nil`). When it is set and the computed `resumeOffset > 0`, the read goes through the three-argument `readStream`; otherwise the call is what it is today. `copyFile` must also make the validator of the attempt it is starting available to its caller — decide how (an `onProgress`-style callback, a returned value, or an `inout` box), state the choice and why in the commit body, and keep it to one mechanism.
- [ ] The queue: an item that ends `.interrupted` remembers the validator its attempt started with, and `retryInterrupted(source:destination:)` hands it back as the expected validator of the re-enqueued job. An item whose source had no validator (`nil` — SFTP, local) behaves exactly as today. A validator mismatch fails that item with the Task 1 reason and leaves the partial file untouched, like the range refusal beside it; the queue does not silently restart from zero.
- [ ] Tests, red first, with fakes: a fake source that answers a different validator on the second attempt fails the retry with the named reason and writes nothing further to the destination (assert the destination's bytes are unchanged, snapshotted BEFORE the retry — CLAUDE.md, "Tests that watch a defect heal"); the same fake answering the same validator resumes and completes; a source answering `nil` resumes as today; a fresh (non-resumed) transfer never asks for a validator. Bound by the suite's `.timeLimit`, no elapsed-time ceiling.
- [ ] Whole suite plus `MACSCP_ITEST=1` for the transfer suites; zero warnings; docs updated in the docs worktree (the transfers page: what happens when a file changes on the server mid-download, marked `*(next version)*`). Commit `fix(transfers): a retry refuses to resume into a file that changed`.

---

### Task 3: A batch delete reports a refused redirect as one

**Row:** "S3's batch delete bypasses the channel's refused-redirect reporting".

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (`deleteTree` from `:767`, the batch send at `:799` — the row's `:761` is at `2bc3fa90` and has drifted)
- Modify (doc only, if the wording no longer holds): `Sources/macSCPCore/S3/S3HTTPChannel.swift` (`perform` `:95`, its doc `:64-78` names this exception)
- Test: `Tests/macSCPCoreTests/S3RedirectControlTests.swift` (or the redirect suite the row's I-4 names)

- [ ] Route the batch `DeleteObjects` through `perform` — `S3FileSystem.perform(_:)` at `:877` is the pass-through the uploader already uses — instead of calling `channel.transport.send` itself. The two arms `deleteTree` maps by hand (`HTTPCancellation`, `connectionFailure(_:)`) are exactly what `perform` does, so the hand-mapping goes; what is gained is the `refusedRedirect()` ask.
- [ ] `S3HTTPChannel.perform`'s doc comment states the batch delete as the one exception. Once it is not one, the sentence is wrong — correct it in the same commit (CLAUDE.md, "Comments that describe other code"), and re-count any other place that names an exception.
- [ ] Test, red first: a refused redirect during a batch delete is reported as the refusal, not as "S3 request failed with HTTP status" and a 3xx. Keep the existing cancellation and transport-failure cases green.
- [ ] Whole suite, zero warnings. Commit `fix(s3): a batch delete reports a refused redirect as one`.

---

### Task 4: A bind failure names the errno it hit

**Row:** "A forwarding's local-bind failure other than EADDRINUSE/EADDRNOTAVAIL/EACCES still logs a bare errno number, not its name".

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift` (`DialSupport` `:124`, `reason(for:)` `:228`, the private `classify(_:)` switch below it)
- Read: `Sources/macSCPCore/Tunnels/LocalForwardListener.swift` (`bindFailure` `:413-426`, the three named errnos `:420-422`), `Sources/macSCPCore/Tunnels/TunnelFailureKind.swift` (`bindFailed` `:86`, its sentence `:244`), `Sources/macSCPCore/Tunnels/RemoteForward.swift:378`
- Test: `Tests/macSCPCoreTests/LocalForwardListenerTests.swift` (the three named cases at `:86`, `:102`, `:127-129`), `Tests/macSCPCoreTests/TunnelFailureKindTests.swift`

- [ ] The gap is the fall-through: any errno besides the three named ones reaches `.bindFailed(reason: DialSupport.reason(for: error))`, and `classify` reduces a NIO `IOError` to `localizedDescription` — "…IOError error 1." Render an `IOError` with its errno's name (`strerror`/`String(cString:)` for the text, plus the symbolic name where the platform gives one) in `classify`, so the sentence says which refusal it was. English by construction, like every other `reason:` — this is the audited log line, not UI text.
- [ ] Keep the three named errnos exactly as they are: they map to their own typed cases before this fall-through is reached, and their sentences are already specific. Do not move that mapping.
- [ ] Tests, red first: an `IOError` carrying an errno outside the three reads its name in the reason; the three named errnos still produce their own sentences unchanged; a non-`IOError` error is still reduced to `localizedDescription` and never `String(describing:)`. No real host, no secret.
- [ ] Whole suite, zero warnings. Commit `fix(tunnels): a bind failure names the errno it hit`.

---

### Task 5: The command-line tool names every place it looked

**Row:** "The CLI's 'secret required' message names three places it looked, not four".

**Files:**
- Modify: `Sources/macSCPCore/CLI/CLIErrorMapping.swift:256-257` (the message; note it lives under `Sources/macSCPCore/CLI`, not `Sources/MacSCPCLI`)
- Read: `Sources/macSCPCore/Sessions/CLISecretSources.swift` (`secretSources(for:passwordCommand:keychainStore:keyStore:)` `:184`; links: `PasswordCommandSecretSource` `:8`/`:199`, `EnvironmentSecretSource` `:115`/`:202`, `KeychainSecretSource` `:140`/`:212`, `ManagedKeyPassphraseSecretSource` `:219-224`)
- Test: `Tests/macSCPCoreTests/CLITunnelStartTests.swift:404`

- [ ] The chain's last link — the managed key's saved passphrase — is missing from the sentence. Two of the four links are conditional (`--password-command` only when given; the managed-key passphrase only for an SSH private-key session with a non-empty key path), so decide and state: does the message list the chain as configured for THIS invocation, or all four always? Prefer naming what was actually consulted if the mapping has that information at hand; if it does not, say so in the commit body and list all four. Whichever is chosen, the message must not name a place that was not searched.
- [ ] No secret and no path that could carry one reaches the message; it stays a fixed sentence per case.
- [ ] Tests, red first: the message names the managed key's passphrase; the existing assertion at `CLITunnelStartTests.swift:404` is updated rather than duplicated; if the message is per-invocation, one case per shape.
- [ ] Whole suite, zero warnings; docs updated in the docs worktree (the command-line page's error list). Commit `fix(cli): the secret-required message names every place the tool looked`.

---

### Task 6: A tab's terminal type follows the tab, not the window it was born in

**Row:** "The terminal type of a tab reads its first window's session list".

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift:1841-1857` (the `let sessionList = sessionListViewModel` capture inside the terminal closure)
- Modify: `Sources/MacSCPAppKit/TabRegistry.swift` (`sessionListsByWindow` `:99`, `registerSessionList(_:for:)` `:439`, `unregisterSessionList(for:)` `:448`, `allSessionLists()` `:468`, `windowHolding(_:)` `:165`)
- Read: `Sources/macSCPCore/Settings/TerminalType.swift` (`resolved(sessionOverride:global:)` `:31`, `sessionOverride(of:in:)` `:41`)
- Test: `Tests/macSCPAppKitTests/TerminalTypeWiringGuardTests.swift`, `Tests/macSCPAppKitTests/TabRegistryTests.swift`

- [ ] The closure captures one window's `SessionListViewModel` by value and keeps reading it for the tab's whole life. Resolve through the tab's CURRENT window instead: `TabRegistry.shared.windowHolding(tab.id)` plus a new per-window accessor over `sessionListsByWindow` (there is none today — only the bulk `allSessionLists()`). State what happens when the lookup finds nothing (a tab mid-move, or a window already gone): fall back to the global setting, never to a dead list. Nothing in Core learns about windows.
- [ ] The registry's mirror holds weak references; a window that closed must not resurrect one. Read `WeakSessionList`'s existing semantics before adding the accessor and keep them.
- [ ] Tests, red first: a tab registered to window B resolves an override stored in B's list, not A's; a tab whose window is no longer registered resolves the global setting; the existing wiring guard still passes and gains a positive check for the new accessor (CLAUDE.md, "Guards that name what they watch"). Pure where possible — the resolution is already a pure function of a list and a setting.
- [ ] Whole suite, zero warnings; docs updated if the user-visible rule changes (the terminal page states the per-session override's scope). Commit `fix(terminal): a tab's terminal type follows the tab between windows`.

---

### Task 7: The launch-time frame stays on its own display

**Row:** "The launch-time window autosave can land on `NSScreen.main`".

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift:283` (the bare `applyFrameAutosave(to: $0)` in `windowChrome(_:)`'s `WindowAccessor` `onResolve`)
- Read/Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (`applyFrameAutosave(to:)` `:1032`, the already-fixed `growToBrowserSize()` `:2156-2170`), `Sources/MacSCPAppKit/MainWindowSizePlan.swift` (`frameToRestore(beforeResume:afterResume:)` `:142`)
- Test: `Tests/macSCPAppKitTests/MainWindowSizePlanTests.swift`

- [ ] `7cb822bd` measured the AppKit fact — setting the autosave name applies the stored frame relative to `NSScreen.main` — and guarded the resume path with `frameToRestore(beforeResume:afterResume:)`. The first resolve at launch calls `applyFrameAutosave(to:)` bare, so the same jump can happen on every launch. Decide what "its own display" means for a window that has just been created and has no earlier frame of its own, and state it: the stored frame's own screen is the honest answer, not the window's pre-autosave placeholder frame. If `MainWindowSizePlan` needs a second pure function for that case, add one there — the App's own call site stays a thin wiring line, because that is what is testable.
- [ ] Do not change `growToBrowserSize()`'s behaviour; this task adds the launch-time guard beside it and leaves the resume path as measured.
- [ ] Tests, red first, in `MainWindowSizePlanTests` (pure): a stored frame whose screen is not the main display is restored onto its own screen; a stored frame already on the main display is untouched; no stored frame at all leaves the window where AppKit put it. The `ContentView+Detail.swift:283` call site itself needs a real `NSWindow` and stays uncovered — say so in the report rather than faking it.
- [ ] Whole suite, zero warnings. Commit `fix(window): the launch-time frame is restored on its own display`.

---

### Task 8: The older jump tests refuse an unknown host key, and the closeout

**Row:** "The older jump tests in `CitadelFileSystemIntegrationTests` accept any unknown host key" (test-only), plus this plan's closeout.

**Files:**
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (`M10c/T1` `:1276-1409`, `M11a/T4` `:1813-1860`)
- Modify: `docs/BACKLOG.md`, this plan file

- [ ] Re-count the accepting deciders with `grep -n '\.asking' ` over the two sections before changing anything — the row's own count (5 accepting: `:1300`, `:1313`, `:1332`, `:1384`, `:1854`) was taken 2026-09-18 and the file has moved since. The two mismatch tests' deciders (`:1355`, `:1397`) record an issue if consulted and accept nothing — leave them exactly as they are.
- [ ] Replace the accepting deciders in those two sections with `HostKeyDecider.refusing`, the way Task 2 of the jump plan's two-live-connections matrix already does — seeding the known-hosts store for the hops the test needs, so the dial succeeds because the key is known and not because anything was accepted. The `M10d/T2` ssh-agent section below is NOT in this task's scope; leave its 10 deciders and record the count in the closeout so the row can be reopened for it.
- [ ] Run `MACSCP_ITEST=1 swift test` against the rig started from the MAIN checkout (`docker compose -f docker/test-server/compose.yml up -d`; never `minio`) and report the two sections' results specifically, not only the suite total.
- [ ] `docs/BACKLOG.md`: each row named in Tasks 1-8 gets a **Done 2026-09-24** (or the day the work lands) sentence leading the row, with its commits; open remainders get their own rows — including the decisions stated for the maintainer in Tasks 2, 5, 6 and 7, so they can be overturned, and the ssh-agent section's remaining deciders. The sight checks join the grouped sight-check row. This plan's step boxes ticked. The docs worktree's commits are named in the report. Commit `docs(backlog): the resume-identity and window-scope work of 2026-09-24 is recorded`.

## Self-review

- Coverage: seven rows → Tasks 1-8 (the resume row spans Tasks 1-2; Task 8 carries the jump-test row and the closeout).
- Placeholders: Task 2's mechanism for reporting the attempt's validator, Task 5's per-invocation-or-all-four wording, Task 6's fallback when no window is found and Task 7's definition of "its own display" are decisions the implementer states in the commit body and the closeout records — each has a stated default to fall back on.
- Type consistency: `RemoteFileSystem`, `RemoteFileItem`, `S3FileSystem`, `WebDAVFileSystem`, `WebDAVPropfindParser`, `TransferEngine.copyFile`, `TransferQueueViewModel.Item`/`retryInterrupted`, `S3HTTPChannel.perform`, `DialSupport.reason(for:)`, `TunnelFailure.bindFailed`, `CLISecretSources`, `TerminalType.resolved(sessionOverride:global:)`, `TabRegistry`, `MainWindowSizePlan.frameToRestore(beforeResume:afterResume:)` and `HostKeyDecider.refusing` all exist at `4a4835b2`, verified by `grep -n` on 2026-09-24.
