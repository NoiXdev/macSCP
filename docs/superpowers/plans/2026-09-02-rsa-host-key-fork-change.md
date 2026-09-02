# RSA Host Keys: the Fork Change and the Wiring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A server offering only an RSA host key (`rsa-sha2-512`/`-256`)
connects, its key is verified, and the known-hosts store records
`ssh-rsa` — proved by the gated test on port 2235 flipping from its
measured failure to green for the right reason (the signature verified).

**Architecture:** The spike (`2026-09-02-rsa-host-key-spike.md`, verdict (b),
record in `2026-08-20-backlog-dependencies.md` "Measured 2026-09-02")
found that NIOSSH's single `publicKeyPrefix` must be both the offered
algorithm name and the blob type. The fork gains
`static var hostKeyAlgorithmNames: [String]` on `NIOSSHPublicKeyProtocol`
(default `[publicKeyPrefix]`), used ONLY where the negotiated name is
meant: the KEX offer and the post-KEX identity check. Blob lookup and the
`K_S` re-serialisation keep using the blob prefix. macSCP then registers
one pair — `RSASHA2512PublicKey` (blob prefix `ssh-rsa`,
`hostKeyAlgorithmNames = ["rsa-sha2-512"]`) and `RSASHA2512Signature`
(prefix `rsa-sha2-512`, PKCS#1 v1.5 over SHA-512 via `_CryptoExtras`) —
directly through `NIOSSHAlgorithms.register` (Citadel's `SSHAlgorithms`
path cannot be used from a `.v6` target without warnings, measured).
`rsa-sha2-256` is added only if a measured server needs it. `ssh-rsa`
(SHA-1) is never registered.

**Tech Stack:** fork `NoiXdev/swift-nio-ssh` (branch `citadel2`, tags
0.3.7/0.3.8 so far), `Package.swift` `exact:` bump, swift-crypto
`_CryptoExtras` (new direct product for macSCPCore), the spike's saved
types (`spike-untracked.patch` in the spike workspace — a starting point,
not a finished type: its verification was never exercised).

## Global Constraints

- English only in both repos; Conventional Commits; footer exactly
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **TOFU stays a hard stop.** The RSA key reaches `TOFUHostKeyValidator`
  through the same path as every other type; nothing accepts an
  unverified key.
- **No SHA-1 host-key signatures**, ever, on any path.
- **The verification must be PROVED to run**: a test that hands the
  signature type a tampered signature and sees it rejected, and a test
  that sees the real one accepted — the spike's log was empty, so "it
  connected" alone is not proof the signature was checked.
- **The exchange hash must be proved to match**: a successful KEX against
  port 2235 is that proof (a wrong `K_S` serialisation fails NEWKEYS/MAC
  immediately); state it in the test's doc comment.
- Fork tag `exact:`; the SwiftPM identity warning is not a compiler
  warning. Swift 6 language mode, warning budget 1 on a fresh scratch
  path — the spike measured that Citadel's `SSHAlgorithms` route costs two
  `Sendable` warnings, hence direct registration.
- The registry is process-global: register once, idempotently, before
  the first connect (NIOSSH dedupes by `ObjectIdentifier`).
- No key material committed; the rig from the main checkout only.

---

### Task 1: The fork — `hostKeyAlgorithmNames`

**Files (fork clone at the scratchpad `fork/swift-nio-ssh`, branch from `citadel2`):**
- Modify: `Sources/NIOSSH/Keys And Signatures/CustomKeys.swift`
  (`NIOSSHPublicKeyProtocol`: `static var hostKeyAlgorithmNames: [String] { get }` with a
  protocol-extension default `[publicKeyPrefix]`),
  `Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift:553-560`
  (offer: `customPublicKeyAlgorithms.flatMap { $0.hostKeyAlgorithmNames }`)
  and `:254-256` (identity check accepts any of the selected type's
  names), `Sources/NIOSSH/Keys And Signatures/NIOSSHPublicKey.swift:206-208`
  (`knownAlgorithms` likewise). Leave `:456` and `:400-402` alone.
- Test (fork): a test type with `publicKeyPrefix = "blob-x"` and
  `hostKeyAlgorithmNames = ["alg-x"]`; the client's KEX offer contains
  `alg-x` and not `blob-x`; the identity check accepts a `blob-x` blob
  when `alg-x` was negotiated; a type WITHOUT the override behaves
  exactly as before (offer == prefix).

- [ ] Red first; run the fork's own suite; commit
  `feat(kex): let a custom host-key type offer names other than its blob prefix`;
  tag `0.3.9`; push (`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, fallback
  `-o HostName=ssh.github.com -p 443`); fast-forward `citadel2`.

### Task 2: macSCP — the pair, registered, proved

**Files:**
- Modify: `Package.swift` (fork `exact: "0.3.9"`; `_CryptoExtras` product
  for macSCPCore)
- Create: `Sources/macSCPCore/SSH/RSASHA2HostKey.swift` — the two types,
  from the spike patch, with `hostKeyAlgorithmNames = ["rsa-sha2-512"]`,
  and `enum HostKeyAlgorithms { static func registerOnce() }` (a
  `static let` token so it runs once)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` — call
  `registerOnce()` before every `SSHClient.connect` (both sites, ~393 and
  ~443)
- Test: `Tests/macSCPCoreTests/RSASHA2HostKeyTests.swift` (ungated): a key
  generated with `ssh-keygen -t rsa`, its public blob parsed by the type;
  a signature made with `ssh-keygen -Y sign` (or OpenSSL) over known data
  verifies; one bit flipped fails; an `ssh-rsa`-prefixed (SHA-1)
  signature blob is rejected by prefix.
- Modify: `Tests/macSCPCoreTests/HostKeyTypeIntegrationTests.swift` — the
  RSA test flips: connect succeeds, `store.find(...)?.keyType == "ssh-rsa"`;
  add the tampered-RSA-key mismatch test (hard stop, decider never asked).

- [ ] Commits: `build(deps): swift-nio-ssh fork at 0.3.9; _CryptoExtras for Core`,
  `feat(ssh): verify rsa-sha2-512 host keys`, `test(ssh): the RSA host-key row turns green`.

### Task 3: Closeout

**Files:**
- Modify: `docs/BACKLOG.md` (RSA host keys → Done, route and proof),
  `docs/superpowers/specs/2026-08-20-backlog-dependencies.md` (fork tag
  0.3.9 in the fork record), `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`
  (the 2235 row of the measured table → green, dated).

- [ ] Commit — `docs(backlog): RSA host keys verified through the fork's 0.3.9`

## What is explicitly not in this plan

- No `rsa-sha2-256` unless measured necessary; no `ssh-rsa`.
- No file keys (separate plan, Citadel fork).
- No upstreaming of the fork change in this plan (worth a PR to
  apple/swift-nio-ssh afterwards; note it in the closeout).
