# RSA User-Auth Blob Typing per RFC 8332 — Measurement and Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An RSA login — from a file or through the agent — sends the
user-auth request the way RFC 8332 §3 specifies: `pkalg = rsa-sha2-512`,
key blob typed `ssh-rsa`, signature typed `rsa-sha2-512`. Then the
Go-based servers that refuse today's `rsa-sha2-512`-typed blob
(Gitea/Forgejo, SFTPGo, gitlab-sshd — verified 2026-09-01 on the agent
path, inherited by file keys on 2026-09-02) accept it, proved against an
SFTPGo container in the rig, while OpenSSH keeps accepting it.

**Architecture:** Measured 2026-09-02 in the fork checkouts: NIOSSH writes
`pkalg` from the PRIVATE key's `keyPrefix` (`SSHMessages.swift:1307`) and
the blob through `writeSSHHostKey(key)`, i.e. from the PUBLIC key's
`publicKeyPrefix` (`NIOSSHPublicKey.swift:425/449`). The two are already
separate identifiers on the wire path — no NIOSSH change is needed for
the client to write RFC-shaped bytes. What is wrong is the public-key
types: Citadel's `RSASHA2.SHA2PublicKey.publicKeyPrefix` returns the
algorithm name (`RSASHA2.swift:71`) and macSCP's own agent-backed RSA
public key type does the same. The fix is one line in each: the public
key's blob prefix becomes `ssh-rsa`; `keyPrefix` (pkalg) and
`signaturePrefix` stay the algorithm name. Registration by prefix: two
public-key types would now share `ssh-rsa` with Citadel's SHA-1
`Insecure.RSA.PublicKey`; NIOSSH's blob lookup takes the first
registered type (`NIOSSHPublicKey.swift:481`). That matters only where
the CLIENT parses an RSA blob — the host-key path (already handled by
`RSASHA2HostKey`, registered first, `ssh-rsa` blob) and `PK_OK`, which a
signed-at-offer request never receives. Task 1 measures exactly that
instead of assuming it. The strict server-side checks at
`SSHMessages.swift:694/768` are NIOSSH's server role and do not run in
macSCP.

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

### Task 2: Citadel fork `0.12.1-noix.3` — the blob is `ssh-rsa`

**Files (fork clone `scratchpad/fork/Citadel`, branch `noix`):**
- Modify: `Sources/Citadel/Algorithms/RSASHA2.swift:70-71`
  (`SHA2PublicKey.publicKeyPrefix` → `"ssh-rsa"`; a doc comment citing
  RFC 8332 §3 and naming the three identifiers)
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
- Modify: `Package.swift` (`exact: "0.12.1-noix.3"`),
  `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift` (the RSA public key
  type's `publicKeyPrefix` → `"ssh-rsa"`; the doc comment at ~92-115 that
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

- No NIOSSH fork change (measured unnecessary for the client's write
  path; if Task 1/2 measure otherwise, this plan stops and says so).
- No `rsa-sha2-256` unless a server requires it.
