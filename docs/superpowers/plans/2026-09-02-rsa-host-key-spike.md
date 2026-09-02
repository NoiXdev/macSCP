# RSA Host Keys: a Spike Before a Plan — Measurement Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decide, by measurement against the rig's RSA-only server (port
2235, offers `rsa-sha2-512,rsa-sha2-256`), whether macSCP can verify an
RSA host key by registering an algorithm through Citadel's
`SSHAlgorithms.publicKeyAlgorihtms` — without touching the NIOSSH fork —
or whether the fork has to change. The spike ends in a written verdict
and, if the no-fork route works, in the gated test on port 2235 turning
green for the right reason.

**Architecture:** Two measurements, each a throwaway branch of the gated
test until it either passes or fails for a reason we can name. (1) Register
Citadel's existing `Insecure.RSA.PublicKey`/`Signature` pair (prefix
`ssh-rsa`, SHA-1): expected to STILL fail negotiation, because the server
does not offer `ssh-rsa` — this measures that the registration path works
at all (the client's KEX offer must now contain `ssh-rsa`; read it from
the failure or a packet capture, do not infer). (2) Write an
`rsa-sha2-512` pair: a `NIOSSHPublicKeyProtocol` with
`publicKeyPrefix = "rsa-sha2-512"` that parses the SAME blob layout as
`ssh-rsa` (two mpints, e then n) and a `NIOSSHSignatureProtocol` with
`signaturePrefix = "rsa-sha2-512"` verifying PKCS#1 v1.5 over SHA-512 via
swift-crypto's `_CryptoExtras` (`_RSA.Signing.PublicKey`,
`.insecurePKCS1v1_5`). The open question this answers: does NIOSSH hand
the server's host-key blob (typed `ssh-rsa` on the wire) to the type it
selected by negotiated NAME (`rsa-sha2-512`), or does it look the blob's
own prefix up (`NIOSSHPublicKey.swift:456`)? If the latter, a type whose
prefix is `rsa-sha2-512` never sees the blob and the wrinkle is a fork
change (a separate host-key-algorithm name beside the blob prefix).

**Tech Stack:** Citadel `SSHAlgorithms` (`Client.swift`), NIOSSH
`NIOSSHAlgorithms.register(publicKey:signature:)` (public, fork tag 0.3.8),
swift-crypto `_CryptoExtras`, the rig's port 2235, Swift Testing gated by
`MACSCP_ITEST=1`.

**Source:** `docs/BACKLOG.md` row "RSA host keys", the measurement of
2026-09-02 in `2026-08-31-backlog-ssh-key-formats.md`, and the
maintainer's decision the same day to take the fork/key work next.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **TOFU stays a hard stop.** Whatever verifies the RSA signature feeds the
  existing `TOFUHostKeyValidator`; no path accepts a key it did not verify.
- **A spike measures; it does not ship half.** Measurement code lives in
  the gated test file or a clearly named scratch type; if route (2) works,
  the production wiring is a task of its own in this plan (Task 3), with
  the same review gate as any feature.
- **No SHA-1 in production.** Route (1) is a probe of the registration
  path only; `ssh-rsa` (SHA-1) is never registered on the app's connect
  path.
- `_CryptoExtras` is a product macSCP does not yet depend on directly —
  add it to `Package.swift` for macSCPCore only if Task 3 happens; the
  spike may import it from the test target first.
- Swift 6 language mode; warning budget 1 on a fresh scratch path.
- **Every failure reason is copied, not paraphrased**, into the report:
  `String(reflecting:)` of the thrown error, and where NIOSSH's error has
  no detail, the client's KEX offer list captured by a `tcpdump`/`ssh -vvv`-
  equivalent or by a debug hook in the test — name which.

---

### Task 1: Route (1) — does registration reach the KEX offer?

**Files:**
- Modify: `Tests/macSCPCoreTests/HostKeyTypeIntegrationTests.swift` (a new
  test beside `rsaHostKeyIsRejectedForWantOfANegotiableAlgorithm`, marked
  as the spike's probe)
- Read: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (how
  `SSHClient.connect` is called; whether `algorithms:` is passed), Citadel
  `Client.swift` (`SSHAlgorithms`, `publicKeyAlgorihtms`, `register()`).

- [ ] **Step 1:** Find how macSCP calls Citadel's connect and whether an
  `SSHAlgorithms` value can be passed from a test without changing
  Sources. If not, the probe calls `Citadel.SSHClient.connect` directly
  with `algorithms: SSHAlgorithms(publicKeyAlgorihtms: .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)]))`
  against `127.0.0.1:2235`, `testuser`/`testpass`, and a host-key
  validator that records what it was asked and accepts nothing.
- [ ] **Step 2:** Run it. Record: the error (`String(reflecting:)`), and
  whether the client's offer now contains `ssh-rsa` (NIOSSH prints nothing;
  capture with `sudo tcpdump -i lo0 -A port 2235` is NOT available
  without a password — instead, read `SSHKeyExchangeStateMachine.swift:555-560`
  and assert in the test that `NIOSSHAlgorithms`' registry now lists the
  type, if NIOSSH exposes it; otherwise the server-side log:
  `docker logs macscp-test-sshd-hostkey-rsa` shows "no matching host key
  type found. Their offer: …" with the client's list — THAT is the
  measurement).
- [ ] **Step 3:** Write the finding into the report and the ledger. Do not
  commit the probe yet; keep it in the working tree for Task 2.

### Task 2: Route (2) — an `rsa-sha2-512` pair

**Files:**
- Create: `Tests/macSCPCoreTests/Support/RSASHA2HostKeySpike.swift`
  (`RSASHA2PublicKey: NIOSSHPublicKeyProtocol`, `RSASHA2Signature: NIOSSHSignatureProtocol`)
- Modify: the probe test from Task 1

- [ ] **Step 1:** Implement the two types. The public-key blob is
  `string "ssh-rsa", mpint e, mpint n` — reuse Citadel's `Insecure.RSA.PublicKey.read(from:)`
  for the parse if it is public, else a 30-line reader. Signature blob is
  `string "rsa-sha2-512", string sig`. Verify with
  `_RSA.Signing.PublicKey(n:e:)` (check the initialiser
  `_CryptoExtras` offers — `init(n:e:)` exists on recent versions; if
  not, build DER) and `.isValidSignature(_:for:padding: .insecurePKCS1v1_5)`
  over the SHA-512 digest of the exchange hash NIOSSH hands in.
- [ ] **Step 2:** Register the pair, connect to 2235 with a recording
  validator. Three outcomes, each a verdict: (a) the validator is asked
  with an RSA key and the signature verifies → the no-fork route works;
  (b) negotiation succeeds but the blob parse fails because NIOSSH looked
  up the blob's own `ssh-rsa` prefix → fork change needed (name it: a
  host-key-algorithm name distinct from the blob prefix on
  `NIOSSHPublicKeyProtocol`); (c) something else → copy it.
- [ ] **Step 3:** Copy the outcome and the server log line into the
  report. Commit the spike file and probe ONLY if (a); otherwise commit
  nothing from Tasks 1-2 and go to Task 4.

### Task 3: Only on (a) — production wiring

**Files:**
- Modify: `Package.swift` (`_CryptoExtras` product for macSCPCore),
  `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (pass `SSHAlgorithms`
  with the pair on every connect; the jump hop too), move the two types
  to `Sources/macSCPCore/SSH/RSASHA2HostKey.swift` with doc comments
  that say why `ssh-rsa`/SHA-1 is not registered.
- Modify: `Tests/macSCPCoreTests/HostKeyTypeIntegrationTests.swift` — the
  RSA test flips: recorded `keyType == "ssh-rsa"` on port 2235, and a
  tampered-RSA-key mismatch test (hard stop, decider never asked).
- Modify: `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`,
  `docs/BACKLOG.md` (RSA host keys → Done, with the measured route).

- [ ] Commits: `feat(ssh): verify rsa-sha2-512 host keys`, then `docs(backlog): RSA host keys verified without a fork change`.

### Task 4: Only on (b)/(c) — the fork entry

**Files:**
- Modify: `docs/BACKLOG.md` (RSA host keys row: the measured reason and
  the named fork change), `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`
  (the fork record: what the change would be, in the same "fork distance"
  terms that entry already uses)

- [ ] Commit: `docs(backlog): RSA host keys need <the named change> in the fork`

## What is explicitly not in this plan

- No RSA or ECDSA FILE keys for authentication — that is Citadel's
  signer (SHA-1) and a Citadel fork, its own entry.
- No `ssh-rsa` (SHA-1) host keys in production, ever.
- No change to the NIOSSH fork inside this plan; the plan ends in a
  verdict about whether one is needed.
