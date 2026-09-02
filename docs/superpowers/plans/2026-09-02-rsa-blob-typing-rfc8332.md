# RSA User-Auth Blob Typing per RFC 8332 — Measurement and Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An RSA login — from a file or through the agent — sends the
user-auth request the way RFC 8332 §3 specifies: `pkalg = rsa-sha2-512`,
key blob typed `ssh-rsa`, signature typed `rsa-sha2-512`. Then the
Go-based servers that refuse today's `rsa-sha2-512`-typed blob
(Gitea/Forgejo, SFTPGo, gitlab-sshd — verified 2026-09-01 on the agent
path, inherited by file keys on 2026-09-02) accept it, proved against an
SFTPGo container in the rig, while OpenSSH keeps accepting it.

**Architecture (corrected 2026-09-02, night — the first version of this
paragraph was wrong and is kept below for the record):** NIOSSH writes
the user-auth request from ONE identifier. The `key` in
`.publicKey(.known(key:signature:))` is a `NIOSSHPublicKey`
(`SSHMessages.swift:151-154`), and its `keyPrefix` for a custom key is
the public key type's `publicKeyPrefix` (`NIOSSHPublicKey.swift:195-196`);
`SSHMessages.swift:1307` writes that as `pkalg`, `writeSSHHostKey` writes
it as the blob's type, and `UserAuthSignablePayload.swift:48` copies it
into the signed payload. `SHA2PrivateKey.keyPrefix` never reaches the
request. Measured by the Task 2 implementer with a serialised
`UserAuthRequestMessage` under `@testable import NIOSSH`: today
`pkalg/blob/sig = rsa-sha2-512/rsa-sha2-512/rsa-sha2-512`; with Citadel's
blob prefix flipped alone, `ssh-rsa/ssh-rsa/rsa-sha2-512` — which OpenSSH
≥ 8.8 REFUSES (`sshkey_check_sigtype` requires the signature type to equal
`pkalg`, and `ssh-rsa` is no longer an accepted `pkalg`). So the
one-liner in Citadel alone is a regression, and the fix belongs in the
NIOSSH fork, as the sibling of what 0.3.9 did for host keys: a
`userAuthAlgorithmName` (default `publicKeyPrefix`) on
`NIOSSHPublicKeyProtocol`, written as `pkalg` and into the signed
payload, while the blob keeps `publicKeyPrefix`. Then Citadel's RSA-SHA2
public key sets `publicKeyPrefix = "ssh-rsa"` and
`userAuthAlgorithmName = <algorithm name>`, and macSCP's agent-backed
RSA type does the same. Registration by prefix matters only on the read
path (host keys — `RSASHA2HostKey` is registered first; `PK_OK` — never
received because Citadel signs at offer time); the write path reads the
concrete instance. Side effect to record: the 256/512 wrappers and the
SHA-1 `Insecure.RSA.PublicKey` become `==` and hash alike, since
`BackingKey`'s equality is `publicKeyPrefix` + `rawRepresentation`.

*The withdrawn paragraph said:* "NIOSSH writes `pkalg` from the PRIVATE
key's `keyPrefix` (`SSHMessages.swift:1307`) and the blob … from the
PUBLIC key's `publicKeyPrefix` … so no NIOSSH change is needed." That was
read from a grep of the two writer lines without following the type of
`key`, and it sent the first Task 2 dispatch after a one-liner that would
have broken OpenSSH logins. The implementer stopped on the measurement.

**Tech Stack:** Citadel fork (`noix` branch → tag `0.12.1-noix.3`),
`Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift`, the rig (a new
`sftpgo` service — `drakkan/sftpgo`, arm64 image available, AGPL-3.0 as a
test-only container, not linked), gated tests.

**Source:** the final review of the file-keys branch (2026-09-02, I-1);
`2026-09-01-backlog-rsa-agent-go-servers.md`; the fork review's I-1 in
`.superpowers/sdd/2026-09-02-file-keys-without-agent/fork-review.md`
(copied into `2026-08-20-backlog-dependencies.md`).

## Global Constraints

- English only in both repos; Conventional Commits; footer exactly
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No SHA-1 anywhere on the path**: the signature stays `rsa-sha2-512`
  (or `-256`); `includeSHA1Fallback` stays `false`; the `ssh-rsa` string
  appears only as the BLOB type, never as `pkalg` or a signature type.
- **A measurement first, against both server families**, before any
  loader/agent code relies on it: OpenSSH (rig 2222) must keep accepting;
  SFTPGo must flip from refusal to acceptance — both pasted verbatim.
- The rig from the main checkout only; only `macscp-test-*` containers;
  SFTPGo's admin/user credentials are rig constants.
- Fork changes red first with the fork's own suite; `Package.resolved`
  restored before each fork commit (the `swift test` v1→v2 churn);
  `exact:` tag bump in `Package.swift`; the fork record extended.
- No key material committed; the passphrase rules as before.
- Swift 6; warning budget 1.

---

### Task 1: The rig — an SFTPGo service, and today's refusal measured

**Files:**
- Modify: `docker/test-server/compose.yml` (service `sftpgo`, image
  `drakkan/sftpgo:<pinned tag>`, SFTP on host port 2240, an admin and one
  user `testuser` with password `testpass` created via SFTPGo's REST API
  or its `SFTPGO_DEFAULT_ADMIN_*` env + a one-shot init container that
  posts the user with the test public keys — read SFTPGo's docs for the
  supported way; the user's authorized keys are added at test time
  through the API from the test, like `makeInstalledKey` does for sshd,
  or via a mounted `authorized_keys` if SFTPGo supports it)
- Modify: `docker/test-server/README.md` (the service, ports, how a test
  installs a key)
- Create: `Tests/macSCPCoreTests/GoServerRSAIntegrationTests.swift`
  (gated): ed25519 file key against 2240 → green (proves the rig); RSA
  file key against 2240 → the measured refusal today (copy the error and
  SFTPGo's log line), pinned with the "turns red when it works" comment;
  RSA agent identity against 2240 → the same.

- [ ] Prove the container from the main checkout; record the two refusals
  before touching anything; commit — `build(rig): an SFTPGo service, and the RSA blob refusal measured`.

### Task 2a: NIOSSH fork `0.3.10` — a user-auth algorithm name beside the blob prefix

**Files (fork clone at the scratchpad `fork/swift-nio-ssh`, branch `citadel2` at 0.3.9):**
- Modify: `Sources/NIOSSH/Keys And Signatures/CustomKeys.swift`
  (`NIOSSHPublicKeyProtocol`: `static var userAuthAlgorithmName: String { get }`,
  protocol-extension default `publicKeyPrefix`), `NIOSSHPublicKey.swift`
  (a `userAuthAlgorithmName` computed property beside `keyPrefix`: bundled
  types → their prefix; `.custom` → the type's member; `.certified` → as
  today), `SSHMessages.swift:1307` and `:1341` (`pkalg` and the `PK_OK`
  echo write `userAuthAlgorithmName`), `UserAuthSignablePayload.swift:48`
  (the signed copy likewise), and the two parse-side checks at
  `SSHMessages.swift:694`/`:768` (accept a blob whose type's
  `userAuthAlgorithmName` equals the received name — server role, kept
  consistent).
- Test (fork): a custom type with `publicKeyPrefix = "blob-x"` and
  `userAuthAlgorithmName = "alg-x"`: a serialised user-auth request reads
  `pkalg = alg-x`, blob type `blob-x`; the signable payload carries
  `alg-x`; a type without the override serialises exactly as before
  (byte-identical against a recorded fixture); bundled ed25519/ECDSA
  requests byte-identical.

- [ ] Red first; the fork's suite; tag `0.3.10`; push (`GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20"`, fallback `-o HostName=ssh.github.com -p 443`); fast-forward `citadel2`.

### Task 2: Citadel fork `0.12.1-noix.3` — the blob is `ssh-rsa`, `pkalg` stays the algorithm

**Files (fork clone `scratchpad/fork/Citadel`, branch `noix`):**
- Modify: `Package.swift` (the fork's `swift-nio-ssh` dependency →
  `https://github.com/NoiXdev/swift-nio-ssh.git` `exact: "0.3.10"`; this is
  what makes the new protocol member visible to Citadel),
  `Sources/Citadel/Algorithms/RSASHA2.swift:70-71`
  (`SHA2PublicKey.publicKeyPrefix` → `"ssh-rsa"`, plus
  `static var userAuthAlgorithmName: String { Variant.algorithmName }`; a
  doc comment citing RFC 8332 §3 and naming the three identifiers and the
  NIOSSH field that reads each)
- Test (fork): the preserved
  `.superpowers/sdd/2026-09-02-rsa-blob-typing-rfc8332/RSAUserAuthBlobTypingTests.swift`
  — red today, green exactly when the wire reads
  `rsa-sha2-512 / ssh-rsa / rsa-sha2-512`
- Test (fork): serialise a user-auth request through NIOSSH's writer (the
  test target has `SSHMessage.UserAuthRequestMessage` reachable via
  `@testable import NIOSSH`? — if not, assert on
  `SHA2PublicKey.publicKeyPrefix == "ssh-rsa"`, `SHA2PrivateKey.keyPrefix ==
  "rsa-sha2-512"`, `SHA2Signature.signaturePrefix == "rsa-sha2-512"` and
  on the bytes `NIOSSHPublicKey.write(to:)` produces for the key: first
  SSH string `ssh-rsa`)

- [ ] Red first; fork suite; tag `0.12.1-noix.3`; push; commit
  `fix(rsa): the user-auth key blob is typed ssh-rsa, as RFC 8332 says`.

### Task 3: macSCP — the agent-backed RSA type, the bump, the flip

**Files:**
- Modify: `Package.swift` (swift-nio-ssh `exact: "0.3.10"`, Citadel `exact: "0.12.1-noix.3"`),
  `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift` (the RSA public key
  type's `publicKeyPrefix` → `"ssh-rsa"` and `userAuthAlgorithmName = "rsa-sha2-512"`; the doc comment at ~92-115 that
  documents the Go-server refusal is rewritten to the fix and the
  measurement), `docs/superpowers/specs/2026-09-01-backlog-rsa-agent-go-servers.md`
  ("Fixed" section), the registration order note in `RSASHA2HostKey.swift`
  if the shared `ssh-rsa` prefix needs stating.
- Modify: `Tests/macSCPCoreTests/GoServerRSAIntegrationTests.swift` — both
  RSA rows flip to green; the OpenSSH ten-cell matrix stays green
  (`FileKeyTypeIntegrationTests`); the agent matrix stays green.

- [ ] Commits: `build(deps): Citadel fork at 0.12.1-noix.3`,
  `fix(ssh): RSA logins type the key blob ssh-rsa; Go-based servers accept them`.

### Task 4: Closeout

- [ ] `docs/BACKLOG.md` (B-2's "still open" sentence → done, with the two
  server families measured), `2026-08-31-backlog-ssh-key-formats.md`,
  `2026-08-20-backlog-dependencies.md` (tag `.3`), the Go-servers entry;
  commit `docs(backlog): RSA blob typing per RFC 8332, measured on OpenSSH and SFTPGo`.

## What is explicitly not in this plan

- (Withdrawn: "no NIOSSH fork change" — Task 2 measured otherwise; the
  NIOSSH change is Task 2a.) No change to the host-key path of 0.3.9.
- No `rsa-sha2-256` unless a server requires it.
