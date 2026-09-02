# Backlog: SSH key formats, and a message that says its own opposite

**Created:** 2026-08-31, from an external bug report (v1.3.0).
One thing was reported; on closer inspection there are **two** things.

## The report

> "it looks it doesn't support the SSH key in ed25519 format"

What was shown:

> SSH key format is not supported (currently: OpenSSH ed25519).

## Finding 1 — the message reads as its own opposite

**Measured:** `SSHPrivateKeyLoader.authentication` attempts
**exclusively** `Curve25519.Signing.PrivateKey(sshEd25519:)`. So ed25519 is
the **only** type that connects — the loader's comment says so too, and
`ManagedKey.canConnect` is true only for ed25519.

The message therefore means "currently supported: OpenSSH ed25519". The
tester read it as "your ed25519 is not supported" — and that reading is
the more obvious one, because the sentence starts with "is not supported"
and the parenthetical reads like a description *of the key that was
presented*.

**This is the cheapest and probably most effective part of this entry.**
A sentence that says what the key is and what is needed, instead of
putting both into one parenthetical. Four catalogs.

## Finding 2 — RSA and ECDSA do not connect at all

`ManagedKey` can **manage** RSA and ECDSA keys, but cannot connect with
them. That was a deliberate YAGNI decision from M3b and stands as such in
the source.

**What no longer holds up about that today:** RSA is still the normal case
on older servers, and that is exactly what the tester tripped over. A
program that lets a key be imported and then cannot use it has put the
decision in the wrong place.

**To clarify before anyone tackles this:**

1. **Which of the two cases was it for the tester?** The report does not
   say, and the message does not distinguish them — an RSA key and an
   ed25519 key that failed to read for a different reason (PEM wrapping, a
   passphrase error that maps onto `unsupportedFormat`) produce **the same
   sentence**. Fixing finding 1 therefore also answers this question for
   the next report.
2. **Can Citadel even do RSA?** Check before any design, rather than
   assume it. The loader uses Citadel's parser; what it can do decides the
   scope.
3. **ssh-agent as a way out.** `AgentBackedPrivateKey` already knows
   `ssh-ed25519`, `ecdsa-sha2-nistp256/384` and the RSA-SHA2 identifiers.
   Someone with their key in the agent may therefore already be able to
   connect today — that belongs measured, because if so, it is the answer
   that needs no new parser.

## What this is not

- **No change to TOFU** or to the hard stop on a fingerprint conflict.
- **No custom key parser.** What Citadel cannot read, macSCP does not
  read.

---

## Measured 2026-08-31 — and finding 2 looks different afterward

Five throwaway keys, a dedicated `ssh-agent` on a scratch socket, run
against the rig.

| | from a **file** | via the **agent** |
|---|---|---|
| ed25519 | **yes** | yes |
| RSA | **no** — parses, does not authenticate | **yes** |
| ECDSA P-256/384/521 | **no** — no parser | **yes, all three** |

### Why RSA from a file fails

Not at parsing. The key is read and the login then fails:

```
rsa/openssh/file: PARSED
rsa/openssh/file: AUTH FAILED: allAuthenticationOptionsFailed
```

Isolated by running — the same key, the same server, only the signature
algorithm varying:

```
-o PubkeyAcceptedAlgorithms=ssh-rsa       → Permission denied
-o PubkeyAcceptedAlgorithms=rsa-sha2-512  → RSA_SHA2_OK
```

**Citadel's file-based RSA signer can only do SHA-1** (`ssh-rsa`), and
OpenSSH removed that from its defaults as of 8.8. The agent path bypasses
the signer and signs `rsa-sha2-512` — which is why RSA works there.

**This refutes "RSA is just wiring."** That claim came from reading the
dependency and was asserted twice before it was measured.

### What the agent path already could do

`agentAuthConnectsECDSA` has existed since `387dd9b` — ECDSA over the
agent was **never** unmeasured, only P-384 and P-521 had no coverage. Both
connect.

### Further findings

- **PEM RSA** (`-----BEGIN RSA PRIVATE KEY-----`) already fails at the
  parser (`invalidOpenSSHBoundary`), so **differently** from OpenSSH RSA.
  Users have both forms on disk, and they fail differently.
- An **encrypted** RSA key parses fine via `decryptionKey:`; without a
  passphrase it produces `missingDecryptionKey`, which the existing error
  mapper already handles.
- **Side finding, not a security issue:** the gated suite leaves agent
  sockets behind in `~/.ssh/agent/` — `spawnAgent` terminates the process
  but does not clean up the entry. Two leftovers found, from 08-21 and
  08-28.
- `AgentPrivateKeyFactory` carries the same five types as **two**
  literals (`supportedKeyTypes` and the `switch`). Identical today,
  counted — a rename can silently pull them apart.

## Upstream (checked 2026-08-31)

Both gaps are known at Citadel, both have code, **neither is merged**:

| PR | Content | Status |
|---|---|---|
| **#135** | `rsa-sha2-256`/`-512` in a new `RSASHA2.swift`, plus `rsaSHA2()` on `SSHAuthenticationMethod` | open, **no review**, last activity 2026-07-26 |
| **#131** | the same, narrower (SHA-256 only) | open since June |
| **#136** | OpenSSH parsing for ECDSA P-256/384/521 | open |

#135's rationale matches our finding word for word: OpenSSH 8.8 removed
`ssh-rsa` from its defaults.

**The trade-off riding on this:** `swift-nio-ssh` already comes in via
`Wellz26/swift-nio-ssh` — a stranger's fork, and the open finding of the
dependency entry. A second outside source on top of that extends the same
chain. Waiting for #135 to land costs nothing but time; forking costs the
chain.

## What follows from this for the message

It must **not** point at "RSA from a file" — that does not work. It should
name the detected type (`SSHKeyType` can do this) and, for RSA and ECDSA,
point at the **ssh-agent**, the only measured path.

**With one named caveat:** the RSA agent blob is reportedly incompatible
with Go servers (Gitea, Forgejo, SFTPGo, `gitlab-sshd`). **Not measured**
— read. Whoever writes the message should either measure that or not
claim it.

---

## Done 2026-09-01

Seven commits, `15e5042`..`d6efff7` (`git log --oneline 7fa32b0..HEAD`):

- `15e5042` feat(ssh): name a key's type before trying to load it
- `8f66d41` feat(ssh): say what a key is and what works instead
- `19cf094` refactor(ssh): one table for the agent key types
- `c103886` test(ssh): measure the agent route for every curve and for a passphrase-protected key
- `43f8ed8` fix(ssh): make the ASKPASS helper's cleanup exception-safe and its passphrase shell-safe
- `0d72b84` fix(ssh): close the write-then-chmod window in the ASKPASS helper
- `d6efff7` test(ssh): remove the agent socket the gated suite creates

### Task 1 — the loader names the type before parsing

`SSHPrivateKeyLoader` now calls Citadel's public
`SSHKeyDetection.detectPrivateKeyType(from:)` before attempting the
ed25519 parse. A correction to this entry's own "What follows" section
above: that section wrote "`SSHKeyType` can do this" as if `SSHKeyType`
were the detecting call. It is not — `SSHKeyDetection` is the API that
detects, and `SSHKeyType` is what it *returns*.

Two new `SSHKeyError` cases: `typeNotLoadable(algorithm: String)` and
`pemNotSupported`. A PEM-boundary check runs first and throws
`pemNotSupported` for any header other than
`-----BEGIN OPENSSH PRIVATE KEY-----`. An encrypted RSA key is named
(`typeNotLoadable(algorithm: "RSA")`) before a passphrase is requested —
covered by a dedicated test ("an encrypted RSA key is named without a
passphrase").

### Task 2 — the message says what the key is and what works

Three catalog strings (`core.connect.keyTypeNotLoadable %@`,
`core.connect.keyPEMNotSupported`, and a reworded
`core.connect.keyUnsupportedFormat`) added/changed in all four
`Localizable.strings` catalogs (`en`, `de`, `fr`, `pl`).

The PEM-conversion hint was measured before it shipped:
`ssh-keygen -t rsa -b 2048 -m PEM` writes
`-----BEGIN RSA PRIVATE KEY-----`; `ssh-keygen -p -N '' -P <pass> -f <key>`
rewrites that same file to `-----BEGIN OPENSSH PRIVATE KEY-----`. The
Go-server RSA-agent-blob caveat is in none of the four new strings —
checked by rereading each one against that constraint. It remains
unmeasured; see below.

### Task 3 — one table instead of two literals

`AgentPrivateKeyFactory`'s `Set<String>` (`supportedKeyTypes`) plus its
parallel `switch` collapsed into one
`factories: [String: @Sendable (...) -> NIOSSHPrivateKey]` dictionary.

The mutation that motivated the change: removing `"ssh-rsa"` from
`supportedKeyTypes` alone, leaving the switch's own `"ssh-rsa"` case in
place, left `AgentAuthTests` and `ConnectFailureSecrecyTests` fully
green — 24 of 24 tests passed. No existing test called
`supports(keyType:)` and `privateKey(for:client:)` on the same key type
and compared the two answers, so the drift went uncaught. That is the
finding the new `AgentPrivateKeyFactoryTests` now guards against, in
both directions plus an unrecognized-type case.

### Task 4 — measured on the rig

`MACSCP_ITEST=1 swift test` against the Docker SSH rig. All three cases
connected; no failure was found in any of them:

- ECDSA P-384 — connected (`agentAuthConnectsECDSAP384`)
- ECDSA P-521 — connected (`agentAuthConnectsECDSAP521`)
- A passphrase-protected ed25519 key, added to the agent via `ssh-add`
  under `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE=force` / `DISPLAY=:0`
  (measured on macOS 15, this machine) — connected
  (`agentAuthConnectsWithPassphraseProtectedKey`)

Two review findings against the plan's own ASKPASS helper sample were
fixed in two rounds:

1. **Cleanup was not exception-safe** (`43f8ed8`) — the helper script,
   which held the plaintext passphrase, was removed only after
   `ssh-add` returned normally; a throw in between left it on disk.
   Fixed with a `defer` registered before any throwing call in the
   function.
2. **The passphrase was interpolated unescaped into a single-quoted
   shell literal** (`43f8ed8`, closed further in `0d72b84`) — fixed by
   removing the shell interpolation entirely: the secret now goes into
   its own file, created directly at `0600` via
   `FileManager.createFile(atPath:contents:attributes:)` in one step
   (no separate chmod, so no window at looser permissions), and the
   `0700` helper script just `cat`s that file.

### Task 5 — measured: why sockets were left behind

Probed directly against `~/.ssh/agent/` (directory confirmed empty
first): a hard `kill -KILL` on a live `ssh-agent` leaves its socket file
behind (process confirmed dead; socket still present — count 1 before
removal). A plain TERM delivered to a still-live agent already removes
its own socket — the gated suite's own run measured 0 → 0, both before
and after the fix. This confirms the 21.08./28.08. leftovers this entry
flagged came from runs where TERM never reached a live agent (the test
process died first, or the agent was killed hard) — not from
`ssh-agent` failing to act on a TERM it received.

`killAgent` now removes the socket file itself
(`try? FileManager.default.removeItem(atPath: agent.socketPath)`) —
never the shared `~/.ssh/agent/` directory, which belongs to every
agent on the machine. Probe result: 1 → 0 after the removal line runs;
the directory itself stayed intact and empty throughout.

### Correction, 2026-09-01 — the Go-server caveat WAS measured

This section used to say the Go-server RSA-agent-blob caveat was "not
measured" and "not claimed anywhere." Both halves were wrong, and the
plan this entry fed (`docs/superpowers/plans/2026-09-01-ssh-key-formats.md`)
inherited the same wrong premise into its own Global Constraints.

The caveat is not a rumor read secondhand — it is a VERIFIED finding,
already sitting in the tree before this entry's "Done" section was
written: `AgentBackedPrivateKey.swift:92-115` documents it, checked
directly against Go's `golang.org/x/crypto/ssh` (`ParsePublicKey` on a
blob tagged `rsa-sha2-512`, which that library rejects with "signature
algorithm \"rsa-sha2-512\" isn't a key format"). It follows from how
swift-nio-ssh's `.custom` key type couples the blob's embedded type tag
to the signature/algorithm name (`AgentAlgorithm.RSASha512`'s doc comment
walks the exact call chain) — a fact about wire encoding, not a claim
about any particular server's behavior read from a forum post. Any
server built on that library — Gitea, Forgejo, Gogs, `gitlab-sshd`,
SFTPGo — therefore rejects an RSA identity offered through macSCP's
agent route, while OpenSSH `sshd` accepts the identical key (proven live
by the gated `agentAuthConnectsRSA` test). ed25519 and ECDSA identities
are not affected, because their blob tag and signature/algorithm name are
already the same string.

The final whole-branch review for the `2026-09-01-ssh-key-formats` plan
caught the gap this left: `core.connect.keyTypeNotLoadable %@` sent every
non-ed25519 key to the agent unqualified, including RSA, with no mention
of a route that a large share of that key's likely destinations will
reject outright. The message now carries a fourth catalog key,
`core.connect.keyTypeNotLoadableRSANote`, appended only when the named
algorithm is RSA (`ConnectionViewModel`'s `typeNotLoadable` arm compares
against `SSHKeyType.rsa.description`, not a string literal). See
`docs/superpowers/specs/2026-09-01-backlog-rsa-agent-go-servers.md` for
what is and is not measured about a fix.

## Measured 2026-09-02 — host-key types, one rig service per type

Planned in `../plans/2026-09-02-host-key-types-rig.md`; rig in
`docker/test-server/compose.yml` (`2f1f735`), tests in
`Tests/macSCPCoreTests/HostKeyTypeIntegrationTests.swift` (`b5af04e`).

Until today every TOFU test negotiated ed25519: the stock rig offers
three host-key types at once and the client prefers that one. The rig
now has one sshd per type, each restricted with `HostKeyAlgorithms` in
its own include, proved with `ssh-keyscan` (one type per port, pasted in
`docker/test-server/README.md`), and a gated test per port pins the key
type the known-hosts store records:

| port | server offers | outcome |
|---|---|---|
| 2231 | `ssh-ed25519` | green — recorded `ssh-ed25519` |
| 2232 | `ecdsa-sha2-nistp256` | green — recorded `ecdsa-sha2-nistp256` |
| 2233 | `ecdsa-sha2-nistp384` | green — recorded `ecdsa-sha2-nistp384` |
| 2234 | `ecdsa-sha2-nistp521` | green — recorded `ecdsa-sha2-nistp521` |
| 2235 | `rsa-sha2-512,rsa-sha2-256` (key type `ssh-rsa`) | **red** — `RemoteFSError.connectionFailed(reason: "NIOSSHError.keyExchangeNegotiationFailure")`, before any key reaches the validator; the store records nothing |

The RSA row is what the maintainer's question was about. NIOSSH's client
offers `ssh-ed25519, ecdsa-sha2-nistp384, ecdsa-sha2-nistp256,
ecdsa-sha2-nistp521` and nothing else
(`SSHKeyExchangeStateMachine.bundledServerHostKeyAlgorithms`). Citadel
registers only what a caller passes in `SSHAlgorithms.publicKeyAlgorihtms`
(its `Client.swift`, through `NIOSSHAlgorithms.register(publicKey:signature:)`),
and macSCP passes no `SSHAlgorithms` at all, so nothing is registered —
and the one RSA type Citadel ships is `ssh-rsa` over SHA-1, which the
server on port 2235 does not offer. (An earlier draft of this paragraph
gave a grep for an assignment to `customPublicKeyAlgorithms` as the
evidence; that is a computed getter nothing assigns, so the grep could
never have matched — corrected 2026-09-02 in the final review.) So a server
with only an RSA host key cannot be connected to at all — not a TOFU
question, a key-exchange one. The test pins the observed failure and
carries the comment that flips it the day the fork can negotiate RSA.
That is a new backlog row, opened with this measurement.

A mismatch test on `ecdsa-sha2-nistp256` (tampered key seeded, hard stop,
decider never asked) proves the hard stop is not an ed25519-only
property.

**File keys per type** were already pinned before this plan:
`SSHPrivateKeyLoaderTests` names RSA, ECDSA P-256/384/521 and an
encrypted RSA key as `typeNotLoadable`, so the plan's Task 3 needed no
change. Agent authentication per type was covered by B-2.

## Measured 2026-09-02 — the agent passphrase matrix

Planned in `../plans/2026-09-02-agent-key-passphrase-matrix.md`
(`9a8ad65`). `agentAuthConnectsWithPassphraseProtectedKey` is now
parameterised over the five key types; the five unencrypted per-type
tests are unchanged, so the agent path is a ten-cell matrix:

| type | without passphrase | with passphrase |
|---|---|---|
| ed25519 | green (existing) | green |
| RSA 2048 | green (existing) | green |
| ECDSA P-256 | green (existing) | green |
| ECDSA P-384 | green (existing) | green |
| ECDSA P-521 | green (existing) | green |

No cell was red, so nothing was pinned as a measured failure: `ssh-add`
decrypts every type the same way, and the passphrase reaches `ssh-add`
through the same 0600 file and `SSH_ASKPASS` helper as before — not an
argument, the environment, a log line or an expectation's source text on
that path. One exit stays open by design: `makeInstalledKey` hands the
same passphrase to `ssh-keygen -N` on its argument list when it GENERATES
the key (`CitadelFileSystemIntegrationTests.swift:436`), a local process
on the test machine, visible in `ps` for the moment it runs. It is a test
constant, not a secret; the rule protects real passphrases on the agent
path, and that is the path measured here. The point
of the matrix is that this was an assumption until today; it is now a
measurement that reruns with every gated pass.

File keys with a passphrase are still ed25519-only here, because the
loader still refuses the other types — see
`../plans/2026-09-02-file-keys-without-agent.md`.

