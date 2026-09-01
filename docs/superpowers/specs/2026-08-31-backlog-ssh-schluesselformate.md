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
