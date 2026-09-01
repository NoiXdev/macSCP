# RSA from the file — anchor locally instead of forking — design

**As of:** 2026-08-31. Response to `2026-08-31-backlog-ssh-schluesselformate.md`
and to the maintainer's question of whether the missing protocol parts can
be anchored **locally in the project** and removed again later.

**The answer is yes** — for unencrypted keys, without a fork and without
hand-written cryptography. The boundary sits at a point that is measured and
named below.

---

## The measured starting state

| | from the **file** | via the **agent** |
|---|---|---|
| ed25519 | yes | yes |
| RSA | **no** — parses, does not authenticate | yes |
| ECDSA P-256/384/521 | **no** — no parser | yes, all three |

RSA does not fail **at parsing**: Citadel's file-based signer can only do
SHA-1 (`ssh-rsa`), and OpenSSH removed that from its defaults as of 8.8.
Isolated by running it — same key, same server, only the algorithm varies
(`ssh-rsa` rejected, `rsa-sha2-512` accepted).

## Why this works locally

**The plug-in point belongs to NIOSSH, not Citadel** — and macSCP already
serves it fully. `AgentBackedPrivateKey` satisfies
`NIOSSHPrivateKeyProtocol`, `AgentBackedPublicKey` the public counterpart,
`AgentSignature` the signature protocol, and **`RSASha512` is already
sitting** there on the wire with the right name.

A file-based twin differs in **exactly one** respect: it computes the
signature instead of asking for it.

**The computing comes from swift-crypto**, not by hand: `_CryptoExtras` is a
declared library product of the package macSCP already links against, and
`_RSA.Signing.PrivateKey.signature(for:padding:)` takes a `Digest`.

## The hurdle, and what it forces

**Citadel's parsed key is not reusable.**
`Insecure.RSA.PrivateKey.privateExponent` is `internal`, and
`signature(for:)` hard-wires SHA-1. macSCP has to **read the OpenSSH
container itself**.

**That is container parsing, not cryptography** — Base64 plus a documented
binary format, to get at the modulus and exponent. The computing stays with
swift-crypto. This distinction is why the project rule "no home-grown key
parser" is not violated here, and it deserves to be said out loud rather
than silently reinterpreted.

## The boundary: encrypted keys stay out

OpenSSH encrypts private keys with **bcrypt_pbkdf**. Measured: Citadel's
implementation is `internal`, and swift-crypto delivers PBKDF2 and Scrypt,
but **no bcrypt_pbkdf**. Anchoring this locally would mean hand-writing a
Blowfish-based key derivation.

**That will not be built.** Hand-written cryptography is not an option in
this project, and a design that smuggles it in through the back door would
be worse than no RSA support at all.

**No regression:** an encrypted RSA key fails today just the same. For it
there is a **measured** path — the ssh-agent, where a passphrase-protected
key mostly lives anyway. The message says so.

## The design

### Three parts, one of them the removal

**1. Read the container.** A pure value in Core that reads the components
out of an unencrypted OpenSSH RSA key. It **decrypts nothing**: if it hits
an encrypted key, it says so as its own result, not as an error — the
caller then points to the agent.

**2. Sign locally.** A type modeled on `AgentBackedPrivateKey`, which
satisfies the same NIOSSH protocols and computes the signature via
`_RSA.Signing`.

**Two decisions someone else will otherwise "improve":**

- **The padding is PKCS#1 v1.5**, not PSS. RFC 8332 mandates
  RSASSA-PKCS1-v1_5; swift-crypto names the choice
  `.insecurePKCS1v1_5`, and that name invites changing it. Switching to
  PSS produces signatures that **no** SSH server accepts. That belongs as a
  comment at the spot **and** in a test.
- **`rsa-sha2-512` first.** Whether `rsa-sha2-256` is additionally offered
  is something to **measure** while implementing — not assume: the offer
  goes through NIOSSH's mechanism, and whether two algorithms can be offered
  for the same key is unchecked.

**3. The removal, as a guard.** If Citadel's PR #135 lands, the local type
gets deleted and the loader points to `rsaSHA2()`. So that this stays a
deletion and not archaeology:

> A guard holds that the local signer has **exactly one** call site — behind
> `SSHPrivateKeyLoader`.

If it spreads, that shows up before the removal is due. And because that is
a **positive** check with a number, it cannot go stale in silence.

### What the user sees afterward

| Key | Result |
|---|---|
| ed25519, file | connects (as before) |
| **RSA unencrypted, file** | **connects** |
| RSA encrypted, file | message: use the ssh-agent |
| ECDSA, file | message: use the ssh-agent |
| everything in the agent | connects (measured) |

The message names the **detected type** — `SSHKeyType` from Citadel can do
that — instead of a parenthetical that reads like its own opposite.

**One caveat, explicitly unmeasured:** the agent's RSA blob is said to be
incompatible with Go servers (Gitea, Forgejo, SFTPGo). Read, not verified —
whoever writes the message either measures this or does not claim it.

## What no test in this project can see

Everything is checkable: the container reading against generated keys, the
signature against the rig, the padding, the refusal on an encrypted key, and
the single call site.

**Not checkable** is the behavior of third-party servers beyond the rig —
the rig is OpenSSH, and a Go server is not in it.

## What explicitly does not belong here

- **No bcrypt_pbkdf**, no hand-written cryptography, no decryption of
  private keys.
- **No fork** of Citadel and no second third-party source in
  `Package.resolved`.
- **No ECDSA file support** in this change. The same pattern would even be
  smaller there (`P256/384/521.Signing.PrivateKey(rawRepresentation:)`
  takes the raw bytes without a DER detour) — but the same encryption
  boundary applies, and one change at a time.
- **No change to TOFU** and none to the hard stop on a fingerprint
  conflict.

---

## Withdrawn (2026-08-31, the same day)

**The maintainer struck down the design at the point where it counts:**
roughly 90% of its users use passphrase-protected keys. A change that
excludes exactly those fixes almost nobody — and brings container parsing
into the project for it.

**Two further paths were then checked, both dead ends:**

- `Insecure.RSA.PrivateKey.privateExponent` is `internal`, with no public
  access. Citadel's parsed key does not hand over its material.
- `protocol OpenSSHPrivateKey` and `OpenSSH.PrivateKey<…>` are **also
  internal**. So macSCP cannot hang its own type off Citadel's decrypting
  parser either — the path that would have gotten decryption for free.

Which leaves: parse it yourself ⇒ decrypt it yourself ⇒ bcrypt_pbkdf by
hand. This design rejects that, and the rejection stands.

## What holds instead

**Citadel can already decrypt** — only the signing is SHA-1. If PR #135
lands, RSA from the file works **including passphrase**, without macSCP
ever reading a container. That is the path that solves everything, and it
costs nothing but waiting.

**Until then, the ssh-agent carries it.** A passphrase-protected key is
loaded once with `ssh-add` and afterward sits decrypted in the agent.

**Unmeasured, and therefore flagged here:** what was measured is the agent
path with **unencrypted** keys. That an encrypted one looks identical to the
client after `ssh-add` follows from how ssh-agent is built — it is an
**inference, not a measurement**. Before a user-facing message points to
this, exactly that needs to be measured after the fact: generate a key with
a passphrase, load it via `ssh-add`, connect.

## What remains of this document

The measurements. They are correct and expensive to obtain: the plug-in
point belongs to NIOSSH and macSCP already serves it; `_CryptoExtras` is a
declared product; the padding would have been PKCS#1 v1.5. If #135 never
lands and the fork does become necessary after all, the path is described
here.

**The design, as a recommendation, is withdrawn.**
