# M11e — Backlog Sweep (Design)

Date: 2026-07-29 · Status: approved by the maintainer ("works for me")

## Goal

Clear the hardening and hygiene items collected from M10 and
document the two user-relevant limits, before someone trips
over them. No new feature.

**Ordering decision (maintainer 2026-07-29):** M11e first, then
M11a (intermediate host from a stored connection — as a REFERENCE to a
stored session), M11b (update check), M11c (recursive permissions),
M11d (external terminal).

## 1. README "Known limitations" (EN, before `## Install`)

Three items, factual and without stack terms in the intro
area (the section itself may be technical):

1. **ssh-agent + RSA:** RSA identities from the agent authenticate
   against OpenSSH servers; servers on a Go base (Gitea, Forgejo, SFTPGo,
   gitlab-sshd) reject them. ed25519/ECDSA are unaffected. The App
   currently shows this case as an ordinary auth error.
2. **Multiple agent identities:** are offered as SEPARATE login attempts
   (max. 6). On servers with fail2ban (default
   `maxretry = 5`), this can trigger an IP ban starting around five
   identities.
3. **Audit log location:** `~/Library/Application Support/macSCP/audit/`
   (one file per stored connection).

## 2. Hardening (Core)

- **Agent frame limit:** `SSHAgentClient` accepts only frames up to
  256 KiB (the OpenSSH maximum); larger declared lengths ⇒
  `AgentError.protocolError`, instead of buffering until the deadline.
- **Signature timeout:** the wait in `AgentBackedPrivateKey.signature`
  gets its own wall-clock limit (15s) and throws afterward
  `AgentError.protocolError("timeout")` — protects against the case where
  the promise is never fulfilled (e.g. a task on an already
  shut-down event loop).
- **Honest message for unusable identities:** when ALL
  agent identities are of an unsupported type, the connect no longer
  returns `noIdentities` ("agent has no identities
  loaded"), but its own case `AgentError.noUsableIdentities`
  with its own EN/DE message.
- **Cleanup:** the `authRejectionError` variable, redundant after the
  M10d fix, in the reconnect loop is removed (behavior identical).
- **Target-set asymmetry (M10c):** a login set at the TARGET pointing
  into thin air is silently ignored when connecting from the form,
  while the jump half correctly refuses. Align it: `resolveSelectedLoginSet`
  returns `Bool` like its jump counterpart, and submit aborts with the
  existing `loginSets.missingSet` message (no silent connect with
  stale fields, no persisting of a dead reference).

## 3. Audit log: jump context

`AuditRecorder.recordConnected` gets an optional jump host; the
`connected` event's detail names it (`via <jumphost>`) when connected via
an intermediate host. ONLY the host — no bastion username,
no credentials. Direct connections stay
byte-identical to today.

## 4. Test hygiene

- `SSH_AUTH_SOCK` race: `AgentAuthTests` and the gated
  agent integration tests both set the process environment; `.serialized`
  only works WITHIN one suite. Secure both via a shared
  serialization (shared suite membership or a global
  lock around the env mutation) — a latent CI flake.
- Gated jump/agent tests clean up their temporary KnownHosts directories
  (the file's `defer` pattern, four places — including the three
  pre-existing leaks).
- `transportErrorMapsToProtocolErrorDuringOperation` currently tests the
  mock-exhaustion path instead of the claimed transport-error
  mapping: either queue two responses or switch to a single do/catch.

## 5. Tests

A targeted test for every hardening item: frame over 256 KiB ⇒ protocolError;
signature timeout (mock transport that never responds) ⇒ protocolError;
all identities unusable ⇒ `noUsableIdentities`; target-set asymmetry
⇒ submit refused (VM level, as far as verifiable without an App target;
otherwise honestly noted in the report as App-layer wiring); audit detail
with and without a jump. Full suite + gated suites green.

## 6. Breakdown

T1 Core hardening + target-set asymmetry → T2 audit jump context +
test hygiene → T3 README + wrap-up (coordinator). NO release.

## 7. Deliberately NOT in M11e

Agent forwarding (its own fork milestone), identity picker/pinning,
`deinit` safety net (contradicts the architecture rule "the UI
owns lifecycles explicitly"), ECDSA-P384/P521 tests, the
unreproduced suite hang (stays a CI observation), cosmetic
duplicates (the `supportedKeyTypes` list, test-vector construction),
`ignoredMergeGroups` pruning, ssh-config ProxyJump import.
