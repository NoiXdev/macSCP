# CLI sessions and tunnels — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `macscp-cli` creates, edits and deletes sessions and tunnel profiles, lists tunnel profiles, and runs one tunnel profile in the foreground; the CLI matrix drives every new verb on every backend; the app re-reads its stores when it becomes active.

**Architecture:** Two new subcommand groups in `Sources/MacSCPCLI` — `sessions` grows `add/edit/rm` beside its existing list, and `tunnels` is new with `list/add/edit/rm/start`. Every verb is a thin `AsyncParsableCommand` over Core: field validation, the OpenSSH forwarding-spec parser, the "which kinds carry a tunnel" rule and the name-conflict rule live in Core as pure functions so the app, the CLI and the tests read one truth. `tunnels start` reuses `TunnelRunner` and `TunnelConnection.connect` from Core in the CLI process. The matrix learns nested verbs and per-backend applicability from the binary and from Core, never from a list in the tests.

**Tech Stack:** Swift 6 strict, swift-argument-parser (already a dependency), Swift Testing, the Docker rig (`docker/test-server/compose.yml`), `SubprocessRunner`/`PTYSubprocess` from Tests/MacSCPTestSupport.

## Global Constraints

- Design: `docs/superpowers/specs/2026-09-06-cli-store-and-tunnels-design.md` (approved 2026-09-06). Maintainer decisions: scope tunnels AND sessions; NO secret through the CLI (no flag, no stdin, no keychain write, nothing printed); no `apply`; `tunnels start` is foreground in the CLI process.
- Swift 6 strict, `.swiftLanguageMode(.v6)`, macOS 15. Swift Testing, red first, the red recorded in the report.
- Tests never block the cooperative pool (no `syncShutdownGracefully()`, `futureResult.wait()`, `DispatchSemaphore.wait()`; every wait is an `await`); no wall-clock ceilings (floors and `.timeLimit` traits only); no `#require` on a non-optional; a secret never appears in argv, a store file, a state, a log line or a test failure message — the matrix's `secret` stays `private` with its single environment exit.
- Every user-facing CLI string is English (the CLI is not localized, as today); every App string through `L10n.string(_:_:)` in en/de/fr/pl (German du).
- Exit codes: 0 success; 64 usage/validation (ArgumentParser `validate()`); 10 secret; 11 host key unknown; 12 host key mismatch (hard stop, never confirmable); 13 connection failed; 14 remote error; 15 conflict. New verbs use only these.
- TOFU unchanged: `--accept-new` is the only way to accept an unknown key; a mismatch exits 12 with no flag that overrides it.
- Source-scanning guards: a negative check has a positive beside it; guards read `SwiftSource.blankingCommentsAndStrings` output; a guard derives a symbol rather than spelling it where it can. Comments that name callers or counts are counted in the same pass, in files outside the diff too. Scripted edits assert anchors and read back the insertion point. The report is written from the diff.
- Docker rig from the MAIN checkout only; gated suites behind `MACSCP_ITEST=1`; the rig's sshd has `AllowTcpForwarding yes`; remote forward port 0 is refused (fork limit, `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`).
- Zero warnings (CI `MAX_WARNINGS=0`). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI.
- `everySubcommandTheBinaryOffersIsDrivenByACase` and `everyConnectionKindHasAMatrixSuite` must stay green at every commit.

---

### Task 1: Core rules — forwarding spec, tunnel carriers, name conflicts

**Files:**
- Create: `Sources/macSCPCore/Tunnels/TunnelSpec.swift`
- Create: `Sources/macSCPCore/Tunnels/TunnelCarriers.swift`
- Create: `Sources/macSCPCore/Sessions/SessionNameRule.swift`
- Test: `Tests/macSCPCoreTests/TunnelSpecTests.swift`, `Tests/macSCPCoreTests/TunnelCarriersTests.swift`, `Tests/macSCPCoreTests/SessionNameRuleTests.swift`

**Interfaces:**
- Produces: `public enum TunnelSpec { public static func parse(local: String) throws -> TunnelProfile.Kind; parse(remote:); parse(dynamic:); public static func render(_ kind: TunnelProfile.Kind) -> String }` — OpenSSH notation `[bind:]port:host:hostport` / `[bind:]port`, bind default `127.0.0.1`, IPv6 in brackets (`[::1]:8080:db:5432`), errors `TunnelSpecError.{malformed(String), portOutOfRange(Int), remotePortZero}` each with an English `description` naming the offending text (never a secret — a spec carries none).
- Produces: `public enum TunnelCarriers { public static func carries(_ kind: ConnectionKind) -> Bool; public static func refusal(for session: StoredSession) -> String? }` — an EXHAUSTIVE switch over `ConnectionKind` (`.ssh` true, `.s3`/`.webdav` false; a fourth kind does not compile); `refusal` returns nil for a plain SSH session and a sentence for non-SSH ("session X is an S3 session; forwardings need SSH"), a login set ("session X belongs to a login set; forwardings dial with the session's own login") and a jump host ("session X uses a jump host; forwardings cannot dial through one") — the same three rules `TunnelConnection.connect` throws for.
- Produces: `public enum SessionNameRule { public static func conflict(_ name: String, among: [StoredSession], excluding: UUID? = nil) -> StoredSession? }` — case-insensitive, whitespace-trimmed; read how the app's `nameConflict` in `SessionListViewModel` decides today and make the app call this function (one truth), keeping its tests green.

- [ ] **Step 1: Failing tests.** `TunnelSpecTests`: table test over `[(input, expectedKind or error)]` for local/remote/dynamic incl. `8080:db:5432`, `0.0.0.0:8080:db:5432`, `[::1]:1080`, `70000:x:1` → portOutOfRange, `a:b` → malformed, remote `0:x:1` → remotePortZero; `render(parse(x)) == canonical(x)`. `TunnelCarriersTests`: `.ssh` carries, `.s3`/`.webdav` do not; `refusal` for the four session shapes. `SessionNameRuleTests`: `"Prod"` conflicts with `" prod "`, `excluding:` the session itself does not.
- [ ] **Step 2: Run** `swift test --filter "TunnelSpec|TunnelCarriers|SessionNameRule"` → FAIL (types undefined).
- [ ] **Step 3: Implement** the three files; move the app's conflict check onto `SessionNameRule.conflict` (search `nameConflict` in `Sources/` and the guard that names it in `Tests/` — update both).
- [ ] **Step 4: Run** the filter → PASS; full `swift test` green; zero warnings.
- [ ] **Step 5: Commit** `feat(core): forwarding specs, tunnel carriers and the session-name rule as one truth`.

---

### Task 2: `sessions add / edit / rm`

**Files:**
- Modify: `Sources/MacSCPCLI/SessionsCommand.swift` (becomes a group: `list` keeps today's behaviour AND stays the default subcommand so `macscp-cli sessions` still lists; `add`, `edit`, `rm` beside it)
- Create: `Sources/MacSCPCLI/SessionFieldOptions.swift` (the per-kind flag groups and their validation)
- Create: `Sources/MacSCPCLI/StoreEditing.swift` (`StoreEditing.sessionStore()` / `tunnelStore()` honouring `MACSCP_STORAGE_DIRECTORY`, and `deleteSession(named:)` that deletes the tunnel profiles first through `TunnelStore.deleteAll(for:)` then the session)
- Test: `Tests/macSCPCoreTests/CLISessionsEditingTests.swift` (ungated, through the built binary like `CLISessionsJSONRoundtripTests`)

**Interfaces:**
- Consumes: `SessionNameRule`, `StoredSession`, `StoredSSHConfig{host,port,username,authKind,keyPath,jump}`, `StoredS3Config{accessKeyID,region,endpoint,bucket,usePathStyle,startsAtBucketList}`, `StoredWebDAVConfig{baseURL,username,useNextcloudPath}`, `SessionStore.upsert/delete/upsertGroup/allGroups`, `GroupTree` (for `" / "` paths).
- Produces: flags exactly as the design's table: ssh `--host --user [--port 22] [--key <path> | --agent]`; s3 `--endpoint --bucket --access-key [--region us-east-1] [--path-style] [--bucket-list]`; webdav `--url --user [--nextcloud]`; common `--group "A / B"`, `--tag` (repeatable), `--pane files|files-and-terminal`; `edit` adds `--rename`, `--no-tag`; `rm` adds `--yes`. A flag for the wrong kind → exit 64 "`--bucket` applies to `--kind s3`". No `--password`, no `--passphrase`, no stdin read: a source guard forbids any `readLine`/`FileHandle.standardInput` in the two new files (negative) with the positive that `--yes` prompting on a TTY exists in `rm` (that one reads the TTY, not stdin — use the same TTY path `--accept-new`'s host-key prompt uses; find it in `SessionConnecting.swift`).
- `rm` on a TTY without `--yes` asks "Delete session X and N forwardings? [y/N]"; with `--non-interactive` and without `--yes` → exit 64; deletes profiles then the session; `--verbose` prints "keychain entry left in place".

- [ ] **Step 1: Failing tests** (through the binary against a temp store): add ssh with key → `sessions --json` shows it with `authKind == privateKey`; add s3 with `--region` → fields; add webdav; duplicate name → 64 and the message; `--bucket` with `--kind ssh` → 64 and the message; edit `--tag x` then `--no-tag x`; edit `--rename` to a taken name → 64; edit `--kind` → 64; rm `--non-interactive` without `--yes` → 64; rm `--yes` deletes the session AND a seeded tunnel profile for it (seed via `TunnelStore` in the temp dir); the store-edit guard (negative + positive).
- [ ] **Step 2: Run** `swift test --filter CLISessionsEditing` → FAIL.
- [ ] **Step 3: Implement.** Keep `sessions` (no verb) listing: ArgumentParser `defaultSubcommand: SessionsListCommand.self`.
- [ ] **Step 4: Run** the filter → PASS; `swift test --filter "CLIMatrix"` unit parts (`theConnectionFlagsAreAskedForPerCommand`, `everySubcommandTheBinaryOffersIsDrivenByACase`) still green — the matrix scan must still see `sessions` as ONE subcommand; if the drive-scan regex needs the verb, that is Task 6, so add a temporary drive line only if the scan goes red and say so in the report.
- [ ] **Step 5: Commit** `feat(cli): sessions add, edit and rm write the store, never a secret`.

---

### Task 3: `tunnels list / add / edit / rm`

**Files:**
- Create: `Sources/MacSCPCLI/TunnelsCommand.swift` (group with `list` default, `add`, `edit`, `rm`; `start` comes in Task 4)
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift` (register `TunnelsCommand`), `Sources/MacSCPCLI/OutputFormatter.swift` (`print(tunnels: [TunnelRow], asJSON:)`)
- Modify: `Sources/MacSCPCLI/SessionNameCompletion.swift` (reuse for `--session`)
- Test: `Tests/macSCPCoreTests/CLITunnelsEditingTests.swift`

**Interfaces:**
- Consumes: `TunnelSpec`, `TunnelCarriers.refusal(for:)`, `TunnelProfile{id,sessionID,name,kind,autoStart,reconnects}`, `TunnelStore`.
- Produces: `tunnels list [--session <name>] [--json]` columns `name session kind spec autostart reconnect` (spec via `TunnelSpec.render`); `tunnels add <name> --session <name> (--local|--remote|--dynamic) <spec> [--autostart off|app-start|login] [--reconnect]`; `tunnels edit <name> --session <name> [...] [--rename] [--reconnect|--no-reconnect]`; `tunnels rm <name> --session <name>`. Name uniqueness PER SESSION enforced by the CLI: `add` refuses a taken name (64); `edit/rm` refuse an ambiguous name the app created ("two forwardings named X on session Y — rename one in the app", 64). Exactly one of the three spec flags (64 otherwise). `TunnelCarriers.refusal` text verbatim on 64. Remote port 0 → 64 with `TunnelSpecError.remotePortZero`'s text.
- `TunnelRow: Codable` in Core (`Sources/macSCPCore/Tunnels/TunnelRow.swift`) so the app could reuse it; JSON keys `name, session, kind, spec, autostart, reconnect, id`.

- [ ] **Step 1: Failing tests** (binary, temp store seeded with an ssh session, an s3 session, a jump-host ssh session): add local/remote/dynamic → list shows canonical specs; add on the s3 session → 64 with the carriers text; add on the jump session → 64; two spec flags → 64; remote port 0 → 64; duplicate name → 64; edit kind local→dynamic; edit `--no-reconnect`; rm; `list --json` shape; ambiguous name (seed two same-named profiles via `TunnelStore`) → 64 for edit and rm.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.**
- [ ] **Step 4: Keep the matrix green in the same commit.** The binary now offers `tunnels`, so `everySubcommandTheBinaryOffersIsDrivenByACase` demands a driving case. Add to `Tests/macSCPCoreTests/CLIMatrixITests.swift` the one shared case `tunnelsAddIsAllowedExactlyWhereCoreSaysSo` (all three backend suites): `tunnels add` on the fixture's session succeeds iff `TunnelCarriers.carries(kind)`, otherwise exit 64 with `TunnelCarriers.refusal(for:)`'s text read from Core. It needs `CLIMatrix.runStore(_:)` (a run with the fixture's storage directory and NO secret variable in the environment) — add that helper here; Task 6 builds on it. Verify: `swift test --filter CLIMatrix` (ungated parts, incl. the drive scan) green; `MACSCP_ITEST=1 swift test --filter CLIMatrix` green on the rig from the MAIN checkout, rig torn down.
- [ ] **Step 5: Commit** `feat(cli): tunnels list, add, edit and rm over the app's profile store`.

---

### Task 4: `tunnels start` — a foreground tunnel in the CLI process

**Files:**
- Create: `Sources/MacSCPCLI/TunnelStartCommand.swift`
- Modify: `Sources/MacSCPCLI/TunnelsCommand.swift` (register `start`), `Sources/MacSCPCLI/SessionConnecting.swift` (expose the secret-source chain and the host-key decider builder the other commands use — read it first; `tunnels start` takes `GlobalOptions` because it dials)
- Test: `Tests/macSCPCoreTests/CLITunnelStartTests.swift` (ungated unit tests of the state-line renderer and the exit-code mapping over `TunnelState`), rig coverage in Task 6

**Interfaces:**
- Consumes: `TunnelRunner(profile:connect:…)` (read `Sources/macSCPCore/Tunnels/TunnelRunner.swift` for the exact init and seams; `start(decider:)` is async, `stop()` awaited, `states` is an `AsyncStream<TunnelState>`), `TunnelConnection.connect(session:secrets:knownHosts:decider:)`, `DialSupport.reason(for:)` for every printed reason, the CLI's existing secret-source chain (environment variable → `--password-command`; never the app's keychain path — the CLI stays as it is) and its host-key decider (`--accept-new` → accept unknown once and record; otherwise refuse; mismatch always refuses).
- Produces: `tunnels start <name> --session <name> [--accept-new] [--non-interactive] [--password-command] [--json] [--verbose]`; prints one line per state change (`connecting`, `active port=<bound>` for remote / `active` otherwise, `active connections=N` on change, `reconnecting attempt=N`, `stopped`); `--json`: `{"state":"active","connections":0,"port":2222}` shapes, one object per line; SIGINT/SIGTERM → `await runner.stop()` → exit 0 (install the signal handler with `DispatchSource.makeSignalSource` on a dedicated queue and hop to the async context through a continuation — never block); `failed(reason:)` → stderr reason, exit 13 (`connectFailed`/`bindFailed`/`portInUse` map to 13; a secret failure to 10); `needsConfirmation` → exit 11 with "host key unknown; rerun with --accept-new", mismatch → 12. A second positional name → 64. `TunnelStateLine.render(_:json:)` and `TunnelExit.code(for:)` are pure functions in the CLI target, table-tested.
- The runner's backoff sleeper is the real `Task.sleep`; `--verbose` prints the backoff delay before sleeping.

- [ ] **Step 1: Failing tests:** `TunnelStateLine.render` table over every `TunnelState` case, text and JSON; `TunnelExit.code(for:)` table; a source guard that `TunnelStartCommand` builds its decider through the same function `ls` uses (positive: the function name derived from `LsCommand`'s call; negative: no `HostKeyDecider(` literal construction in the new file).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4:** PASS; full suite green.
- [ ] **Step 5: Commit** `feat(cli): tunnels start holds a forwarding open in the foreground`.

---

### Task 5: The app re-reads both stores when it becomes active

**Files:**
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (or the AppDelegate — wherever `applicationDidFinishLaunching` lives): observe `NSApplication.didBecomeActiveNotification`, call `TunnelManager.shared.reload()` and every registered window's `SessionListViewModel.reload()` (find how windows are enumerated for the quit chain — `TabRegistry` / the window registration — and reuse it; do not add a second registry)
- Modify: `Sources/MacSCPAppKit/TunnelProfilesSheet.swift` help text: one sentence "a forwarding edited outside the app keeps running as it was until you stop and start it" (all four catalogs)
- Test: `Tests/MacSCPAppKitTests/StoreReloadOnActivationGuardTests.swift` (source guard: positive — the observer names `didBecomeActiveNotification` and both reload calls; negative — no other `store.all()` read is added on activation, beside the positive) and a `TunnelManagerTests` case: write a profile straight to the store, `reload()`, `allProfiles` shows it, a running runner for another profile is untouched (identity)

- [ ] **Step 1: Failing tests.** **Step 2: FAIL.** **Step 3: Implement.** **Step 4: PASS**, catalogue parity green.
- [ ] **Step 5: Commit** `feat(app): the stores are re-read when the app becomes active`.

---

### Task 6: Matrix coverage — nested verbs, per-backend applicability, the SSH end-to-end cases

**Files:**
- Modify: `Tests/macSCPCoreTests/Support/CLIMatrix.swift` — `drivenSubcommands(inFileAt:)` learns nested verbs (a drive of `["sessions", "add", …]` counts for `sessions`; the scan regex takes the FIRST string in the argument array, which it already does — verify and extend the doc); `carriesTunnels(_:)` and `runStore(_:)` exist since Task 3 (read them); add the positive that the store cases pass NO secret variable in the child's environment.
- Modify: `Tests/macSCPCoreTests/CLIMatrixITests.swift` — shared cases in `CLIMatrixCases`: `sessionsAddEditRmRoundTrip` (all backends: add a second session of the fixture's kind, edit its tag, `sessions --json` shows both, rm `--yes --non-interactive`, gone); `tunnelsEditListRm` (SSH only, guarded by `carriesTunnels`); `tunnelsStartIsRefusedWhereCoreSaysSo` (S3/WebDAV: exit 64). SSH-only end-to-end cases in `CLIMatrixSSHITests`: `startLocalForwardCarriesTheSshdBanner` (add `--local 0:127.0.0.1:2222`… — port 0 is allowed for a LOCAL bind, read `LocalForwardListener`; the CLI prints `active port=<bound>`; connect to it from the test and read `SSH-2.0`), `startDynamicForwardAnswersSOCKS5Connect` (hand-rolled greeting + CONNECT to 127.0.0.1:2222 through the bound port, expect `05 00` then the banner), `startRemoteForwardIsReachableInsideTheContainer` (`--remote 127.0.0.1:<free>:127.0.0.1:<local listener the test opens>`; `docker exec macscp-test-sshd sh -c 'printf hi | nc 127.0.0.1 <port>'` reaches the test's listener), `startEndsWithExitZeroOnSIGINT` (send SIGINT to the child after `active`, expect exit 0 and a `stopped` line), `startRefusesAnUnknownHostKey` (fresh known-hosts dir, no `--accept-new` → 11; with it → active), `startIsAHardStopOnAChangedHostKey` (seed a wrong key like `aChangedHostKeyIsAHardStop` does → 12, and `--accept-new` does not help). Every child is bounded by the suite's `.timeLimit`, never by an `elapsed <` assertion; every wait for a state line is a read on the child's stdout (the `onStderrChunk`/stdout seam of `SubprocessRunner` — read `SubprocessRunnerTests` for the latch shape).
- The per-backend suites (`CLIMatrixSSHITests`, `…S3…`, `…WebDAV…`) each gain the shared cases so `everySubcommandTheBinaryOffersIsDrivenByACase` goes green again with `tunnels` driven.

- [ ] **Step 1:** run `MACSCP_ITEST=1 swift test --filter CLIMatrix` on the rig from the MAIN checkout → the new cases FAIL (or the `everySubcommand…` red from Task 3 is the red) — record it.
- [ ] **Step 2: Implement** the support changes and cases. **Step 3:** `swift test --filter CLIMatrix` (ungated parts) green; `MACSCP_ITEST=1 swift test --filter CLIMatrix` green on all three backends; rig torn down.
- [ ] **Step 4: Mutation probes** (record each red/green): make `TunnelCarriers.carries(.s3)` return true → the S3 refusal case red; remove the SIGINT handler → the SIGINT case red (no `stopped` line / non-zero exit); make `--accept-new` also accept a mismatch → the hard-stop case red.
- [ ] **Step 5: Commit** `test(cli): the matrix drives sessions and tunnels on every backend, and a forwarding end to end over SSH`.

---

### Task 7: Closeout

- [ ] `README.md` "Command line" section: four example lines (`sessions add`, `tunnels add`, `tunnels start`, `tunnels list`), no tech-stack terms; `docs/BACKLOG.md` Done row (commits per task, counted; limits from the design's Limits section; the sight check: run `tunnels start` from a terminal while the app is open and confirm the app's menu shows the profile as stopped — the recorded limit — and that a `sessions add` appears in the sidebar after ⌘-Tab); the design's status line; the plan's checkboxes; `docs/superpowers/specs/2026-08-03-m20-cli-design.md` gets a dated addendum pointing at this design ("the store is written from the CLI since 2026-09-…"). Commit `docs(backlog): sessions and tunnels from the command line are in`.

## Self-review

- Spec coverage: every verb in the design's Commands section has a task (2, 3, 4); the app reload → Task 5; matrix → Task 6; limits → Task 7. `apply`, secrets, IPC, login sets/jump hosts from the CLI are excluded by the design and by the Global Constraints.
- Placeholders: none; every step names the test, the command and the expected outcome.
- Type consistency: `TunnelSpec.parse(local:/remote:/dynamic:)` and `render(_:)` (Task 1) are what Tasks 3, 4 and 6 call; `TunnelCarriers.carries(_:)`/`refusal(for:)` (Task 1) are read by Tasks 3, 4, 6; `TunnelRow` (Task 3) is what `tunnels list --json` and Task 6's assertions decode; `TunnelStateLine.render(_:json:)` and `TunnelExit.code(for:)` (Task 4) are what Task 6's SSH cases read.
