# File Keys Without the Agent: RSA and ECDSA Through a Citadel Fork — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An RSA or ECDSA (P-256/384/521) private key FILE — encrypted or
not — authenticates a macSCP connection directly, the way an ed25519 file
does today, with no agent in between. The gated suite proves it per type,
with and without a passphrase, against the rig.

**Architecture:** Measured 2026-09-02 (Citadel 0.12.1 at `ae8562f`):

- **RSA files parse today** — `Insecure.RSA.PrivateKey(sshRsa:decryptionKey:)`
  (`SSHCert.swift:108`) reads the OpenSSH container including bcrypt
  decryption. What fails is the SIGNATURE: `Insecure.RSA.PrivateKey
  .signature(for:)` hashes with `Insecure.SHA1` (`Algorithms/RSA.swift`,
  the `ssh-rsa` algorithm), which OpenSSH ≥ 8.8 no longer accepts. The key
  material is `internal` (`privateExponent`, BoringSSL `BIGNUM` pointers),
  so an `rsa-sha2-512` signer cannot be written outside Citadel without
  re-parsing the container — the fix belongs INSIDE Citadel.
- **ECDSA files do not parse at all** — `OpenSSH.PrivateKey`'s key-type
  enum has `sshRSA` and `sshED25519` only (`OpenSSHKey.swift:288-289`).
  NIOSSH itself carries native P-256/P-384/P-521 private keys, so once the
  container is parsed into a `P256.Signing.PrivateKey` (etc.), the
  connection side needs nothing new. The container parser and the bcrypt
  decryption are Citadel's and not public — again the fix belongs inside
  Citadel.

So this is the second fork, `NoiXdev/Citadel`, made and wired exactly like
`NoiXdev/swift-nio-ssh` (same-identity override in `Package.swift`, `exact:`
tag, fork record in `2026-08-20-backlog-dependencies.md`). Upstream has
Citadel PR #135 for RSA-SHA2 signatures; Task 1 measures its distance from
0.12.1 before anything is cherry-picked. The loader in macSCP then stops
refusing the three types and hands them to the connection; the agent
path is untouched.

**Tech Stack:** Citadel fork (Swift, BoringSSL via swift-crypto's
`CCryptoBoringSSL`), NIOSSH `NIOSSHPrivateKey.init(p256Key:)`/`p384Key`/
`p521Key` and `.custom(NIOSSHPrivateKeyProtocol)`, `SSHPrivateKeyLoader`,
gated tests with `makeInstalledKey(type:bits:passphrase:)` against the rig.

**Source:** the maintainer's decision of 2026-09-02 ("also make sure we
get support without the agent — that is what the fork is for"), the
key-formats spec `2026-08-31-backlog-ssh-key-formats.md` (which named
Citadel PR #135 or a fork as the fix), and the host-key spike
`2026-09-02-rsa-host-key-spike.md`, whose verdict on the NIOSSH prefix
question is an input to Task 3's RSA signature type name.

## Global Constraints

- English only in every artifact; Conventional Commits; footer exactly
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` — in BOTH repos.
- **No SHA-1 signatures leave the app.** The fork's `ssh-rsa` (SHA-1)
  signer is not what macSCP registers; macSCP registers `rsa-sha2-512`
  (and `rsa-sha2-256` if a measured server needs it) only.
- **No key material committed**, anywhere. Test keys are generated at
  runtime with `ssh-keygen`; the fork's own tests likewise.
- **On the connect path the passphrase never reaches an argument, the
  environment, a log or an expectation's source text** (the existing
  loader rules; test key generation via `ssh-keygen -N` on argv is the
  known, non-secret exception the helpers already make).
- **`includeSHA1Fallback` is `false` on every macSCP call**, and a test
  pins it: PR #135's `rsaSHA2(username:privateKey:includeSHA1Fallback:)`
  defaults it to `true` upstream, and nio-ssh signs at offer time, so a
  fallback offer is a real SHA-1 signature on the wire. The fork flips
  the default to `false` (Task 2); macSCP still passes it explicitly.
- **The fork carries every upstream security patch first**, like the
  NIOSSH fork did: Task 1 lists upstream commits since 0.12.1 and
  classifies them before feature work.
- Fork tags are `exact:` in `Package.swift`; the identity-conflict warning
  is a SwiftPM manifest warning, not a compiler warning, and does not
  count against the budget (CI counts `file:line:col: warning:` only).
- `ManagedKey.KeyType.isConnectable` (the key manager's "can be a file
  login" gate) changes only in Task 5, after the connection proves each
  type, so the UI never offers a type the transport cannot use.
- TOFU untouched. Swift 6 language mode. Warning budget 1.

---

### Task 1: Fork Citadel, measure the distance to PR #135 and the patch list

**Files:**
- Create (fork repo): `https://github.com/NoiXdev/Citadel`, default branch
  from tag `0.12.1`
- Modify: `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`
  (fork record: what was forked, from which commit, why)

- [ ] **Step 1:** `gh repo fork orlandos-nl/Citadel --org NoiXdev --clone=false`
  (or `gh repo create NoiXdev/Citadel --public` + push mirror if the org
  forbids forks — read the error, do not guess). Clone into the scratch
  directory, not into macSCP.
- [ ] **Step 2:** `git log --oneline 0.12.1..origin/main` — classify every
  commit: security / correctness / feature / noise, in a table in the
  report. Fetch PR #135 (`gh pr view 135 --repo orlandos-nl/Citadel --json title,state,mergedAt,files`;
  `gh pr diff 135`): what it changes, whether it merged, and whether it
  applies onto 0.12.1 cleanly (`git cherry-pick -n`, then `git diff --stat`,
  then abort — measure, do not keep).
- [ ] **Step 3:** Decide, with the numbers: cherry-pick PR #135 vs. write the
  `rsa-sha2-512` signer ourselves (an `NIOSSHSignatureProtocol` with
  prefix `rsa-sha2-512` and a `signature(for:)` hashing SHA-512 — about
  the same 40 lines as the SHA-1 one, using the same BoringSSL calls with
  `NID_sha512`). Write the ruling in the report; the controller confirms
  before Task 2.
- [ ] **Step 4:** Commit the fork record — `docs(backlog): the Citadel fork, measured`

### Task 2: The fork — RSA-SHA2 signing

**Files (fork) — reconciled 2026-09-02 with the Task 1 measurement:**
- Cherry-pick (`-x`) upstream PR #135's two commits, minus the
  `Package.resolved` hunk: `Sources/Citadel/RSASHA2.swift` (new, +166: the
  `rsa-sha2-256`/`rsa-sha2-512` signer, SHA-512/256 into `RSA_sign` under
  `NID_sha512`/`NID_sha256`), `Sources/Citadel/SSHAuthenticationMethod.swift`
  (+39: `rsaSHA2(username:privateKey:includeSHA1Fallback:)`),
  `Tests/CitadelTests/RSASHA2Tests.swift` (+109). `RSA.swift` is untouched;
  the SHA-1 `ssh-rsa` path stays as it was.
- Modify (our own commit): the default of `includeSHA1Fallback` → `false`,
  with a test that the default offer list carries no `ssh-rsa` entry.

- [ ] Both commits red/green against the fork's own suite; tag
  `0.12.1-noix.1`; push with `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`.
  The one PR claim not reproduced by Task 1 — that OpenSSH accepts a
  userauth key blob typed by the algorithm name rather than `ssh-rsa`,
  since nio-ssh writes both from one `publicKeyPrefix`
  (`SSHMessages.swift:688/759` in the 0.3.9 fork still compare them
  strictly) — is Task 4's FIRST measurement against the rig, before any
  loader change.

### Task 3: The fork — ECDSA private keys from the OpenSSH container

**Files (fork):**
- Modify: `Sources/Citadel/OpenSSHKey.swift` (key types
  `ecdsa-sha2-nistp256/384/521`; the private section is
  `string curve, string Q, mpint d` after the two `checkint`s, then the
  comment and padding — read the ed25519 arm and mirror it),
  `Sources/Citadel/SSHCert.swift` (public `P256.Signing.PrivateKey
  .init(sshEcdsa:decryptionKey:)` and the P-384/P-521 twins)
- Test (fork): parse keys generated at test time with `ssh-keygen -t ecdsa -b {256,384,521}`,
  encrypted and not; the public key derived from the parsed `d` equals
  `Q` from the container (that equality is the parser's proof).

- [ ] Red first; tag `0.12.1-noix.2`; `feat(openssh): ECDSA private keys, encrypted or not`.

### Task 4: macSCP — the loader loads all four types, the gated suite proves it

**Files:**
- Modify: `Package.swift` (Citadel → `https://github.com/NoiXdev/Citadel.git`,
  `exact: "0.12.1-noix.2"`, with the same explanatory comment shape as the
  NIOSSH override), `Sources/macSCPCore/SSH/SSHPrivateKeyLoader.swift`
  (RSA → the `rsaSHA2(username:privateKey:includeSHA1Fallback: false)`
  authentication method from Task 2, and the loader keeps its
  `passphraseRequired`/`wrongPassphrase` mapping; ECDSA →
  `NIOSSHPrivateKey(p256Key:)` etc.; `typeNotLoadable` remains for what is
  still not loadable, e.g. DSA), `ConnectionViewModel` (the RSA note
  appended to `keyTypeNotLoadable` goes away or shrinks — read it)
- Modify: `Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift` (the
  `typeNotLoadable` expectations for RSA/ECDSA flip into "loads"; keep
  the encrypted-RSA-named-first test's intent: an encrypted RSA key
  without a passphrase now throws `passphraseRequired`)
- Create: `Tests/macSCPCoreTests/FileKeyTypeIntegrationTests.swift` (gated):
  `@Test(arguments:)` over `[("ed25519", nil), ("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)] × [nil, passphrase]`
  — ten cells — using `makeInstalledKey` (move it to
  `Support/` if it is private) and `SSHConnectionConfig(auth: .privateKey(path:passphrase:))`
  (read the real case name), connecting to 2222. Every cell is recorded
  before anything is fixed; a red cell is pinned with its error.

- [ ] Commits: `build(deps): Citadel from the NoiXdev fork at 0.12.1-noix.2`,
  `feat(ssh): RSA and ECDSA private key files authenticate directly`,
  `test(ssh): every file key type, with and without a passphrase`.

### Task 5: The key manager offers what the transport can use

**Files:**
- Modify: `Sources/macSCPCore/SSH/ManagedKey.swift` (`KeyType.isConnectable`
  — read its doc comment and the tests that pin it), the catalogs if a
  string says "only ed25519" (grep the four `Localizable.strings` for
  `ed25519`), the guard tests that scan them.

- [ ] Commit — `feat(keys): RSA and ECDSA managed keys can be file logins`

### Task 6: Closeout

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`
  ("Done" section with the ten-cell table), `docs/BACKLOG.md` (B-2's
  row; the RSA host-key row is NOT this entry), the fork record.

- [ ] Commit — `docs(backlog): file keys of every type, with and without a passphrase`

## What is explicitly not in this plan

- No RSA host-key verification — that is the spike
  `2026-09-02-rsa-host-key-spike.md` and its outcome.
- No PEM (`-----BEGIN RSA PRIVATE KEY-----`) or PuTTY `.ppk` containers;
  `pemNotSupported` stays.
- No DSA. No FIDO2 `sk-*` keys.
- No change to the agent path, which already covers every type.
