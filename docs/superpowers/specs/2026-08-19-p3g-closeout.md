# P3g — Completion

**Goal:** The password hint no longer holds a plaintext secret.
**Status:** done. Suite 2110 tests in 183 suites, green.

## What the measurement corrected in the spec

The spec assumed the start script contained a password — the doc comment
on `requestExternalTerminal(config:)` claimed exactly that. Both were
wrong. `SSHCommandBuilder` reads host, port, username, key *path*, and
jump target; it never passes a secret, `ssh` itself asks for it — which
is exactly what the hint text the app shows says too.

So the fix was not "one more cleanup path", but: never hold the secret
back in the first place. `redactingSecrets()` returns a copy without
plaintext payloads; the auth kind itself survives, because callers branch
on it. The state "hint open and password in view state" is now not
cleaned up, it is unrepresentable.

## What the full review found — and what came of it

The phase had fixed the **smaller** of the two instances.
`lastConnectedConfig` held the same plaintext password for **the whole
session** instead of the seconds of an open alert — and, on the toolbar
route, was the source of the configuration that flows into the hint.
Redacting the copy while the source kept the plaintext lowered the
exposure there by zero.

Reverified: `lastConnectedConfig` has exactly **one** consumer in
production, the external terminal launch. It never dials. So `connect()`
now stores it redacted. The phase's real gain therefore no longer sits
only on the P3c sidebar route.

Seven doc comments followed suit: three still claimed that the cleanup
on `disconnect` was the reason no plaintext password survives a
connection. The redaction at assignment is the stronger guarantee; that
is now stated too. `clearRetainedSecrets()` still clears
`lastConnectedConfig` — it is just no longer the barrier, but diligence
for host/user metadata.

## Resolved open points from the spec

- **Should the cleanup paths also capture it?** No — redaction at
  assignment makes them unnecessary, instead of creating a third path
  that every later change would have to maintain alongside.
- **Does the hint need to hold the configuration at all?** Yes, but
  redacted. Re-resolving after confirmation could fail and would bring a
  second error path for nothing.
- **Does a window that closes during the hint need its own path?** No.
  After redaction, the retained request only carries host/port/
  user/key path, and `@State` dies with the view. Deliberately left as
  is: the alert buttons start a detached `Task` that still opens the
  external terminal even if the window closes right after the click —
  that is the user's intent, not a leak.

## Checked and refuted

A background scan reported as its strongest finding that the jump secret
in `values` survives the disconnect, because `clearPassword()` only
clears top-level fields and `teardown` does not call
`clearJumpFields()`. The scan itself had marked this as unverified.
Reverified: `teardown` calls `exitEditMode()`, and that calls
`clearJumpFields()`. No finding.

## Open leads (unverified, worth their own phase)

From the same scan, each **not verified** — measure before implementing:

- A managed-key passphrase resolved from the keychain lands in the
  long-lived form (`ConnectionFormView`, `ContentView.fillForm`). On a
  **failed** connect, nobody clears it.
- Login-set secrets are pre-filled into the form before every submit; a
  rejected submit leaves them standing.
