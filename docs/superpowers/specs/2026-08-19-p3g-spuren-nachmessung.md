# P3g — the two unverified leads, re-measured (2026-08-19)

The P3g wrap-up left two hypotheses open, because at the time of the
review they were only plausible, not measured. Both are now re-measured.
One was wrong, one was real.

## Lead 1: password in the generated ssh command — wrong

The hypothesis was that `SSHCommandBuilder` might write a password into
the command. Measured: it doesn't, nowhere. The command fundamentally
contains no secret; `ssh` asks for it interactively itself. The lead led
somewhere anyway: `ConnectionViewModel.lastConnectedConfig` had been
holding the full config, including the password payload, past the
connect. Fixed with `redactingSecrets()` (the auth *case* is preserved,
because callers branch on it).

## Lead 2: passphrase duplicate on edit-save — real

The hypothesis was that the edit-save path might store a secret twice.
Measured: it does. When creating a session, `SessionSecretPolicy.valueToPersist`
decides that a managed key's passphrase does **not** additionally move
into the session slot. When editing, this question was never asked at
all — the passphrase ended up in a second slot, and a later change to
one copy left the other stale.

Fixed in `9847d8b`: `updateSession` asks the same question via a new
`usesStoredManagedPassphrase(session:keys:secrets:)` overload, which
reads the persisted `AuthKind` directly instead of going through the
main-actor-isolated presentation layer. The guard sits in the
ViewModel, not with the callers — same reasoning as with the jump-secret
invariant next to it: a future caller can't forget it.

Two new tests in `SessionSecretPolicyTests`: a managed key with a stored
passphrase gets no session slot; without a stored passphrase, it gets
one.

## Side finding: a test that was only green outside the suite

The delivery test from P5 Task 3 waited for the shell to open with a
fixed 80 ms sleep. Run alone, always green; in the full suite, red about
every third run. An explicit gate replaces the sleep (`66ea90e`); after
that, 6 full-suite runs and 6 isolated runs green. At the previous rate
that would be about a 9% chance — indicative, not proof. So the
expectation now additionally states whether the bytes reached the shell
at all: a future failure will say immediately which half is missing.

## Lesson

Both leads confirm the same rule as P3e/P3f/P3g already: **measure
first, then design.** Half of plausible hypotheses are wrong, and the
other half is rarely exactly what was hypothesized — lead 1 was wrong,
but uncovered a different, real leak.

Plus a new, more expensive lesson: **a test that only turns red in the
full suite is more dangerous than a test that's always red.** It had
already been committed and run green in CI before the flakiness was
noticed.
