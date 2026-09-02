# Agent Keys: Every Type With and Without a Passphrase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The gated agent-authentication tests cover the matrix key type ×
passphrase — ed25519, RSA 2048, ECDSA P-256, P-384, P-521, each loaded
into the agent once unencrypted and once passphrase-protected — instead of
covering the passphrase only for ed25519.

**Architecture:** `CitadelFileSystemIntegrationTests` already has the
pieces: `makeInstalledKey(type:bits:passphrase:)` (line ~426) generates a
key with `ssh-keygen` and installs its public half in the rig,
`agentAuthConnectsWithPassphraseProtectedKey` (line ~2031) adds a
passphrase-protected key through `ssh-add` with `SSH_ASKPASS` pointing at
a helper that reads the passphrase from a 0600 file (never from an
argument or the environment), and the five per-type tests exist without a
passphrase. This plan turns the passphrase test into a parameterised one
over the five types and keeps the unencrypted five as they are — one
matrix, ten cells, each a green cell today or a measured red one.

**Tech Stack:** Swift Testing parameterised `@Test(arguments:)`,
`ssh-keygen`/`ssh-add`, the Docker rig (2222), gated by `MACSCP_ITEST=1`.

**Source:** the maintainer's question of 2026-09-02 ("are the keys also
tested with and without a passphrase?") and the measurement that
answered it: with-passphrase only for ed25519, on every path.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **On the agent path the passphrase never reaches an argument list, the
  environment, a log line or an `#expect`'s source text.** Keep the
  existing 0600-file + `SSH_ASKPASS` mechanism for `ssh-add`; keep the
  value in the existing named constant; compute any Bool before the
  expectation. (Key GENERATION is the exception the existing helper
  already makes: `makeInstalledKey` passes the test constant to
  `ssh-keygen -N` on argv — a local process, a non-secret value; this
  plan does not change that.)
- **No key material committed**; keys are generated at runtime into a
  temp dir and removed in `defer`; the agent is killed and its socket file
  removed as the existing tests do (`killAgent`).
- Gated tests only; the unit suite must not need Docker or an agent.
- A cell that fails is recorded as measured (exact error), not forced.
- Swift 6 language mode; warning budget 1 on a fresh scratch path.

---

### Task 1: The matrix

**Files:**
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift`
  (`agentAuthConnectsWithPassphraseProtectedKey` ~line 2031)

- [ ] **Step 1:** Turn the test into
  `@Test(arguments: [("ed25519", nil), ("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)]) func agentAuthConnectsWithPassphraseProtectedKey(type: String, bits: Int?)`,
  passing `type`/`bits` to `makeInstalledKey`, everything else unchanged.
  Rename nothing else; the five unencrypted tests stay.
- [ ] **Step 2:** Run `MACSCP_ITEST=1 swift test --filter agentAuthConnectsWithPassphraseProtectedKey`.
  Record the five outcomes in the report before touching anything. A red
  cell: copy `String(reflecting:)` of the error and the agent's stderr;
  pin it as its own test with the "expected once … turns red then"
  comment, as the host-key plan did.
- [ ] **Step 3:** Update the test's doc comment: what the matrix is, and
  that the agent — not macSCP — decrypts the key, which is exactly why
  the cell is measured and not assumed.
- [ ] **Step 4:** Full gated run once; then commit —
  `test(ssh): agent authentication with a passphrase, every key type`

### Task 2: The entry

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`
  (append "Measured 2026-09-0x — passphrase matrix"), `docs/BACKLOG.md`
  (B-2 row: one sentence)

- [ ] Commit — `docs(backlog): the agent passphrase matrix, measured`

## What is explicitly not in this plan

- No file-key passphrase cases beyond ed25519: the loader refuses the
  other types until they can be loaded at all (see
  `2026-09-02-file-keys-without-agent.md`).
- No FIDO2/security keys (`sk-ssh-ed25519`, `sk-ecdsa-sha2-nistp256`):
  unsupported and untested; a separate entry if wanted.
