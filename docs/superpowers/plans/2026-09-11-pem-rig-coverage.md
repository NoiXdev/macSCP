# PEM keys on the rig and in the CLI matrix — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every PEM variant the reader opens logs in to the Docker rig through macSCP's own connect path — including the two the first plan measured only in unit tests (Ed25519 PKCS#8, openssl's encrypted legacy files) — the variants it refuses are proved refused and then converted-and-logged-in, and the CLI's own chain (`sessions add --key` → `ls`) is measured with a PEM key.

**Architecture:** Test-only. `Tests/macSCPCoreTests/Support/InstalledKey.swift` gains an `installAuthorizedKey(publicKeyLine:)` that the existing `makeInstalledKey` delegates to, so a key that `ssh-keygen` did not generate can be authorised on the rig. `FileKeyTypeIntegrationTests` gains cells for the externally produced and the hand-built PEM files; `CLIMatrixITests` gains one SSH-only case that saves a key session through the binary and lists through it. No source under `Sources/` changes.

**Tech Stack:** Swift Testing, `SubprocessRunner`, `PEMFixtures` (from the PEM plan), the Docker rig (`docker compose -f docker/test-server/compose.yml up -d` from the MAIN checkout), gated `MACSCP_ITEST=1`.

## Global Constraints

- Follows `docs/superpowers/specs/2026-09-10-pem-private-keys-design.md` (implemented 2026-09-10); this plan adds measurement, not behaviour. If a cell turns red because the reader or the converter is wrong, that is a finding for the maintainer, not something this plan fixes silently.
- Swift 6 strict, Swift Testing, red first (each new cell is run once against the rig BEFORE its fixture is authorised on the rig, or with the variant the loader refuses, and the recorded red names the error), no `#require` on a non-optional.
- Tests never block the cooperative pool: every wait an `await`; child processes only through `SubprocessRunner`; `SSHKeyConverter.copyAsOpenSSH` is `async` and is awaited. No wall-clock ceiling (`.timeLimit` traits only).
- No secret in any `#expect` source text or failure message: passphrases in named constants or generated per cell (`"itest-\(UUID())"` as the existing cells do) and never interpolated; key material reduced to a `Bool` before any expectation. No real host name; the rig is `127.0.0.1:2222`, `testuser`.
- No key material committed: every key is generated at runtime into a per-cell temporary directory the cell removes. The rig's `authorized_keys` grows across runs, which the rig accepts by design (the existing comment in `InstalledKey.swift` says so).
- Measured facts this plan relies on (2026-09-10/11, this machine): `ssh-keygen` 10.3p1 cannot read an Ed25519 PKCS#8 file (`ssh-keygen -y` → "invalid format"), so its public key line must be computed from the seed; LibreSSL 3.3.6 cannot produce an encrypted Ed25519 PKCS#8, so the encrypted Ed25519 cell wraps the PKCS#8 DER with the PBES2 builder `PEMPrivateKeyDecoderTests.pbes2SHA256PEM(pkcs8DER:passphrase:…)` (move it to `PEMFixtures` so both suites share it); `openssl rsa -aes256` / `-des3` and `openssl pkcs8 -topk8 -v2 des3` write what the design's table records.
- Comments naming counts (the cell counts in `FileKeyTypeIntegrationTests`'s MARK and `KeyShape` docs, the matrix's case count if one is stated) are recounted in the same pass. Scripted edits assert their anchor; the report is written from `git diff --numstat` and `grep -n`.
- Zero warnings (`swift build --build-tests`). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push. Do not launch the GUI.

---

### Task 1: The rig logs in with every readable PEM variant, and converts the unreadable ones

**Files:**
- Modify: `Tests/macSCPCoreTests/Support/InstalledKey.swift` (extract `installAuthorizedKey(publicKeyLine:)` from `makeInstalledKey`; `makeInstalledKey` calls it — body otherwise unchanged)
- Modify: `Tests/macSCPCoreTests/Support/PEMFixtures.swift` (add `ed25519PublicKeyLine(seed:comment:)` — `ssh-ed25519 <base64(sshString("ssh-ed25519") ‖ sshString(publicKey.rawRepresentation))> <comment>` with `Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey`; move `pbes2SHA256PEM` here as `pbes2PEM(pkcs8DER:passphrase:prf:cipherKeyLength:)` keeping the decoder test's call site working)
- Modify: `Tests/macSCPCoreTests/FileKeyTypeIntegrationTests.swift`
- Modify: `Tests/macSCPCoreTests/PEMPrivateKeyDecoderTests.swift` (only the call site of the moved builder)

**Interfaces:**
- Produces: `func installAuthorizedKey(publicKeyLine: String) async throws` (the `docker exec macscp-test-sshd sh -c "mkdir -p /config/.ssh && echo '<line>' >> /config/.ssh/authorized_keys && chmod … && chown …"` that `makeInstalledKey` runs today, verbatim); `PEMFixtures.ed25519PublicKeyLine(seed:comment:) -> String`; `PEMFixtures.pbes2PEM(...)`.
- Consumes: `PEMFixtures.ed25519PKCS8PEM(seed:)`, `PEMFixtures.openssl(_:)`, `PEMFixtures.sshString(_:)`, `SSHKeyConverter.copyAsOpenSSH(from:to:passphrase:)`, `CitadelFileSystem.connect(config:connectTimeout:knownHosts:onUnknownHostKey:)`, `connectWithRetry`, `SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC"))`.

- [ ] **Step 1: Failing cells** in `FileKeyTypeIntegrationTests` (same suite, same `MACSCP_ITEST` gate, same connect-and-list body as `fileKeyAuthenticatesThroughMacSCP`, factored into a private `expectLogin(keyPath:passphrase:)` helper used by every cell in the file — recount the "cells" MARK comment):
  1. `@Test("an Ed25519 PKCS#8 key authenticates", arguments: [false, true])` — seed from `Curve25519.Signing.PrivateKey().rawRepresentation`; plain: `ed25519PKCS8PEM(seed:)` written 0600; encrypted: `pbes2PEM(pkcs8DER: der(ofPEM: plain), passphrase:)`; `installAuthorizedKey(publicKeyLine: ed25519PublicKeyLine(seed:comment: "macscp-itest"))`; login + list.
  2. `@Test("openssl's encrypted legacy RSA file authenticates")` — `ssh-keygen -t rsa -b 2048 -m PEM` plain → `openssl rsa -in <plain> -aes256 -passout pass:<constant> -out <f>` → install the `.pub` line of the plain key → login with the passphrase + list.
  3. `@Test("openssl's named-curve SEC1 key authenticates")` — `openssl ecparam -name prime256v1 -genkey -noout -out <f>`; public line via `ssh-keygen -y -f` (measured to work on SEC1); install; login + list.
  4. `@Test("a DES-EDE3 key is refused by the dial and logs in once converted", arguments: ["legacy", "pbes2"])` — `openssl rsa -des3` / `openssl pkcs8 -topk8 -v2 des3` from a plain PKCS#1 key; install the plain key's `.pub`; FIRST the dial with the unconverted file: `#expect(throws:)` catching `SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC"))` out of `CitadelFileSystem.connect` (no `connectWithRetry` around a call expected to throw before the wire); THEN `try await SSHKeyConverter.copyAsOpenSSH(from:to: <dir>/converted, passphrase:)` → login with the converted copy + list.
- [ ] **Step 2: Run red.** `MACSCP_ITEST=1 swift test --filter FileKeyTypeIntegrationTests` with the rig up: cells 1-3 red BEFORE `installAuthorizedKey` exists (compile) and, once it compiles, red when the install call is commented out for one run (the rig refuses the key — record the error); cell 4's refusal half is green by construction and its conversion half red when `copyAsOpenSSH` is skipped (record). Record every first failing line.
- [ ] **Step 3: Implement** the two helpers and un-comment the installs.
- [ ] **Step 4: Run green** twice (`MACSCP_ITEST=1 … --filter FileKeyTypeIntegrationTests`), then the whole unit suite (`swift test`) green, `swift build --build-tests` zero warnings. Record the cell counts (existing 10 + PEM 6 + new: 2 + 1 + 1 + 2 = 6 → 22 cells plus Step 0).
- [ ] **Step 5: Commit** `test(ssh): every readable PEM variant logs in to the rig, and a DES-EDE3 key is refused then converted`.

---

### Task 2: The CLI matrix saves a key session with a PEM key and lists through it

**Files:**
- Modify: `Tests/macSCPCoreTests/CLIMatrixITests.swift` (a new `CLIMatrixCases.listsThroughAPEMKeySession(_:)` and one `@Test` in the SSH suite only)
- Modify: `Tests/macSCPCoreTests/Support/CLIMatrix.swift` only if a helper is needed (prefer none)

**Interfaces:**
- Consumes: `CLIMatrix.withRig(_:label:_:)`, `rig.runStore(_:)`, `rig.runWithoutASecret(_:)`, `CLIMatrix.hostKeyFlags(for:binary:)`, `CLIMatrix.listing(_:)`, `rig.remotePath(_:)`, `rig.seed(_:path:content:)`, `makeInstalledKey(type:bits:passphrase:extraKeygenArguments:)` from Task 1's file (unchanged signature).

- [ ] **Step 1: Failing case.** In the SSH matrix suite: `@Test func listsThroughAPEMKeySession()` → `CLIMatrixCases.listsThroughAPEMKeySession(.ssh)`: `makeInstalledKey(type: "rsa", bits: 2048, extraKeygenArguments: ["-m", "PEM"])` (unencrypted — the CLI takes no passphrase and reads the app's Keychain read-only, so an encrypted key cannot be exercised here; say so in the doc comment); seed one file through `fileSystem`; `sessions add <name> --kind ssh --host 127.0.0.1 --port 2222 --user testuser --key <keyPath>` through `rig.runStore` (status 0; the store JSON names the session with `authKind` private key — read it back with `sessions --json` and assert the key path is recorded and no secret field is present); then `ls` + `hostKeyFlags(for: "ls")` + `--json` on `<name>:<remoteRoot>` through `rig.runWithoutASecret` (no password variable: the key needs none) → status 0, the seeded file listed; `rig.leaksSecret(result) == false` computed first, as the sibling case does. Doc comment: what this proves that `FileKeyTypeIntegrationTests` does not (the binary's own store → dial chain with a PEM path).
- [ ] **Step 2: Run red** (`MACSCP_ITEST=1 swift test --filter CLIMatrixITests/listsThroughAPEMKeySession` or the suite filter the file uses): red once with the `--key` flag omitted (the dial has no login → record the exit code and the first stderr line without quoting a secret), then green with it. If the CLI refuses `--key` with a PEM path for any reason, that is a finding — record and stop, do not work around it.
- [ ] **Step 3: Run** the SSH matrix suite green; the `CLIMatrixCommands` suite (runs without the rig) green; whole unit suite green; zero warnings.
- [ ] **Step 4: Commit** `test(cli): the matrix saves a session with a PEM key and lists through it`.

---

### Task 3: Closeout

- [ ] `docs/superpowers/specs/2026-09-10-pem-private-keys-design.md`: a dated "Coverage addendum 2026-09-11" under Tests listing the new cells and the CLI case, the commits, and the two measured limits (Ed25519 PKCS#8 public line computed because `ssh-keygen -y` cannot read it; the CLI case is unencrypted only). `docs/BACKLOG.md`: the PEM Done row gains "(+ rig and CLI coverage 2026-09-11, commits …)". This plan's checkboxes. Commit `docs(backlog): PEM rig and CLI coverage recorded`.

## Self-review

- Coverage: the two gaps named to the maintainer on 2026-09-11 (Ed25519 PEM + openssl encrypted legacy on the rig; a PEM key through the CLI chain) → Task 1 cells 1-2 and Task 2; the named-curve SEC1 and DES-EDE3 convert-then-login cells are the same measurement extended to the remaining producers in the design's table.
- Placeholders: none — every command line, flag and assertion is spelled.
- Type consistency: `installAuthorizedKey(publicKeyLine:)`, `ed25519PublicKeyLine(seed:comment:)`, `pbes2PEM(pkcs8DER:passphrase:prf:cipherKeyLength:)`, `listsThroughAPEMKeySession(_:)` are the names used throughout.
