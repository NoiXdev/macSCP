# P3c — Wrap-up: terminal from the host context menu

Completed 2026-08-18. Three content commits plus two ledger docs:

```
267930c refactor(core): resolve a connection config without dialing it
1081142 refactor(core): keep the save-name rule out of the shared resolution
af2de15 feat(app): open a terminal straight from a host's context menu
4b3cb35 docs(app): record context-menu export everywhere as P3f
547dcef docs(app): record the retained password-hint config as P3g
```

## How the resolution is shared

`ConnectionViewModel.resolveConfigWithoutDialing() -> ConfigResolution`
(`Sources/macSCPCore/Presentation/ConnectionViewModel.swift`) contains
everything `connect()` does before the dial, and nothing else: the schema
check (`descriptor.firstViolation(requireSecrets: true)`), `validateJump`,
`descriptor.makeConfig` and `attachingJump(to:)`. `connect()` keeps only the
re-entrancy guard, the save-name check, `state = .connecting`, the dial
including the host-key decider, and the `lastConnectedConfig` recording; it
repeats no resolution step.

`ConfigResolution` is its own return type (`.resolved(ConnectionConfig)` /
`.failed(State)`), not an optional `ConnectionConfig?`: the failure case
carries the exact `State` that `connect()` would otherwise assign, so the
error mapping (message + field) stays in one place. The function
**publishes nothing** — a failure is returned, not written to `state`,
otherwise an externally triggered resolution would overwrite the
`.connecting` that a running `connect()` owns — and **retains nothing**:
the resolved plaintext secret belongs to the caller for the duration of
its own call, `lastConnectedConfig` continues to be written exclusively by
a successful `connect()`.

The **equivalence guard**
(`Tests/macSCPCoreTests/ConnectionConfigResolutionTests.swift`, 8 tests)
fills two identically configured view models — one dials, one only
resolves — and compares what one dialed against what the other resolved.
It goes red if `connect()` starts resolving anything itself again. It does
**not**, however, pin the behavior of the shared function itself:
`connect()` delegates to it, so a change there moves both sides of the
comparison at once — that is what the case-by-case assertions (hop
host/port, every error message including its field) stand next to it for,
not the guard.

## Why the save-name rule is not in the shared function

A form legitimately carries `shouldSaveSession == true` with an empty save
name while the user is still typing an ad-hoc "save & connect" — that is
not an error state of the configuration but a bookkeeping rule of the
form. The context-menu caller saves nothing and must not be rejected for a
rule that does not apply to it. The check therefore stays in `connect()`,
before the call to `resolveConfigWithoutDialing()`.

(Task 1 had initially implemented and justified this point the other way
round — the save-name check at first *inside* the shared function. The
review refuted that justification, the fix landed in `1081142`, proved by
mutation: pushing the rule back → guard goes red; a mutation inside the
shared function → the equivalence tests stay green, the case-by-case ones
catch it. The Task 1 report was subsequently corrected by the coordinator
for this; the code and this wrap-up follow the correction.)

## The two context-menu entries

Under "Connect" in the session row:

- **"Open Terminal"** (`ContentView.openTerminalFromSidebar`) — connects
  within macSCP like `connect()`/`connectFromSidebar` (target selection,
  re-entrancy, filling, error display — all unchanged), only with
  `paneVisibility: .terminalOnly` instead of the saved split. Nothing is
  persisted.
- **"Open in External Terminal"**
  (`ContentView.openExternalTerminalFromSidebar`) — fills a **throwaway
  `ConnectionViewModel`** (local, the connector throws), resolves it with
  `resolveConfigWithoutDialing()`, and hands it to the configured external
  terminal client. macSCP does not establish its own connection in the
  process; the throwaway object does not survive the call, so the resolved
  plaintext secret never gets a second home.

Visibility rule: `SessionRowTerminalMenuPlan.build(for:)`
(`Sources/MacSCPAppKit/SessionSidebar.swift`) — `.shown` when
`BackendDescriptor.capabilities.supportsShell` holds, otherwise `.hidden`.
Both entries are **hidden, not greyed out**, when a session has no shell:
a permanently dead entry on an S3 bucket explains nothing.

Filling the form (~240 lines: kind/values, login-set resolution, keychain,
managed-key passphrase, jump resolution) used to be inline in
`connect(in:stored:)` and was pulled out into
`ContentView.fillForm(_:from:) throws -> Bool` — both paths (sidebar
connect as well as external launch) call the same function. The verbatim
property of this extraction was checked **mechanically**, not by a test: a
`diff` of the extracted block against the previous inline code shows
exactly **seven** lines of difference, all `return` → `return false`, plus
the signature and a trailing `return true`. `ContentView` cannot be
instantiated from the tests (no rendering tool in the project), so a test
was structurally not possible here — the `diff` plus the green full suite
stand in for it.

## Deferred: P3g

From Task 2's overall review: `pendingPasswordHintRequest`
(`ContentView.swift`) can hold an `SSHConnectionConfig` with a plaintext
password for as long as the one-time password-hint alert is open. Both
alert buttons and every SwiftUI dismissal of the dialog set it to `nil` —
but `disconnect` and `clearRetainedSecrets` do not reach it. Pre-existing
since M11d; this phase widens the exposure because the external path is
now also reachable for a session that macSCP **never** connects to.
Exactly what the doc comment on `resolveConfigWithoutDialing` warns
against. Recorded as its own small phase P3g in the spec addendum
(`docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`) and in commit
`547dcef` — not a blocker, not part of this phase.

## GUI: not launched

The app was **not** launched during this phase. For the maintainer, to
verify by hand:

- Both entries appear on the context menu of a saved **SSH** session.
- **Neither** entry appears on an **S3** or **WebDAV** session.
- "Open Terminal" comes up without the file browser — the terminal only.
- "Open in External Terminal" shows the password hint the first time
  (with password auth), the same as the existing toolbar path.

## Measurement

```
swift test          → 2076 tests in 178 suites, alle grün
plutil -lint         → alle acht *.strings-Kataloge OK
```

Unchanged versus Task 2 (2076/178) — no test was added or lost between the
Task 2 wrap-up and this wrap-up.

## Build verification (`scripts/package-app`, started in the background)

```
lipo -archs dist/macSCP.app/Contents/MacOS/macSCP      → x86_64 arm64
lipo -archs dist/macSCP.app/Contents/MacOS/macscp-cli  → x86_64 arm64
Resources/*.bundle                                      → macSCP_MacSCPAppKit.bundle, macSCP_macSCPCore.bundle
Resources/*.lproj                                        → de, en, fr, pl (alle vier)
plutil -lint Info.plist                                  → OK
UTExportedTypeDeclarations                                → 3 (dev.noix.macscp.sessions, .logins, .snippets)
```

The app was **not** launched; `scripts/release` was not run.

## Brief error

This phase's brief contained no new error beyond what the ledger already
records (the fourteenth misnaming of `resolveConfigWithoutDialing()` in
Task 2's plan and brief, already corrected there). The Task 1 report
itself was left uncorrected after the fix `1081142` and contradicts
today's code on one point (the location of the save-name check) — the
coordinator addendum at the end of this report clarifies that; this
wrap-up follows the code throughout, not the uncorrected section.
