# Backlog: RSA-through-agent is rejected by Go-based SSH servers

**Created:** 2026-09-01, from the final whole-branch review of
`docs/superpowers/plans/2026-09-01-ssh-key-formats.md`. The review found
that both the plan and `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`
called this caveat "not measured," when it had in fact already been
measured and documented in the tree. This entry is the corrected record,
not a new measurement.

## What is measured

`Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift:92-115` (the doc
comment on `AgentAlgorithm.RSASha512`) documents a VERIFIED
incompatibility, checked directly against Go's `golang.org/x/crypto/ssh`:

- An RSA identity offered through macSCP's ssh-agent route signs as
  `rsa-sha2-512`. swift-nio-ssh's `.custom` key type derives BOTH the
  outer userauth algorithm name and the public-key blob's own embedded
  type tag from the same `NIOSSHPublicKeyProtocol.publicKeyPrefix`/
  `signaturePrefix` statics, so the blob ships tagged `rsa-sha2-512`
  rather than RFC 8332's `ssh-rsa`.
- OpenSSH's `sshd` accepts that blob — it matches `authorized_keys` by
  parsed key material, not by wire tag, and treats `rsa-sha2-*` as a
  valid (if normally sig-only) name for `KEY_RSA`. Proven live by the
  gated `agentAuthConnectsRSA` integration test against the Docker rig.
- `x/crypto/ssh`, however, parses the public-key blob's leading string
  strictly as a KEY FORMAT, not merely a signature algorithm, and does
  not recognize `rsa-sha2-512` there. Verified directly (`ParsePublicKey`
  on a blob tagged `rsa-sha2-512`) — it rejects with:

  ```
  ssh: signature algorithm "rsa-sha2-512" isn't a key format; key is
  malformed and should be re-encoded with type "ssh-rsa"
  ```

- Any server built on `x/crypto/ssh` — Gitea, Forgejo, Gogs,
  `gitlab-sshd`, SFTPGo, and others sharing the library — therefore
  refuses an RSA-backed agent identity from macSCP, even though the
  identical key works over OpenSSH `sshd`.
- ed25519 and ECDSA agent identities are **not** affected: for those
  algorithms the blob's embedded type tag and the signature/algorithm
  name are already the same string (e.g. `ssh-ed25519`), so there is no
  three-way divergence for swift-nio-ssh's `.custom` path to collapse.
  The incompatibility is specific to RSA's `rsa-sha2-*` vs. `ssh-rsa`
  split.

As of the final review of 2026-09-01, `core.connect.keyTypeNotLoadableRSANote`
(all four catalogs) carried this caveat in the message a user saw when
macSCP declined to load an RSA key from a file. **Since 2026-09-02 that
message is gone** — the loader loads RSA files (`fa67138`, Citadel fork
`0.12.1-noix.2`), and the note with it. The incompatibility itself is
NOT gone: an RSA file key now offers the same `rsa-sha2-512`-tagged blob
the agent path offers (upstream PR #135 writes the blob type from the
algorithm name, the same NIOSSH conflation), so the Go-based servers
verified above refuse RSA file logins exactly as they refuse RSA agent
logins; OpenSSH 10.3 accepts both (measured, see
`2026-08-31-backlog-ssh-key-formats.md`). The user sees the server's
plain "authentication failed" for it, with no caveat any more. The clean
fix is one NIOSSH fork change — a user-auth algorithm name beside
`keyPrefix` on `NIOSSHPrivateKeyProtocol`, the mirror of the
`hostKeyAlgorithmNames` that fixed the host-key side in 0.3.9 — and that
is the next fork item, not a message.

## Why it exists

The custom key's public blob is tagged `rsa-sha2-512` instead of
`ssh-rsa` — see "What is measured" above for the full mechanism.
`AgentBackedPrivateKey.swift`'s doc comment traces the exact call chain
in swift-nio-ssh (`UserAuthSignablePayload.init`,
`NIOSSHPublicKey.write`, `writeUserAuthRequestMessage`) that forces this
coupling for a `.custom` key.

## What is NOT measured

The comment at `AgentBackedPrivateKey.swift:92-115` calls the actual fix
"out of scope for macSCP itself" because it "requires upstream
swift-nio-ssh to let a `.custom` key's blob-embedded type tag diverge
from its signature/algorithm name." That framing predates a fact worth
re-checking: macSCP does not consume upstream `swift-nio-ssh` at all —
`Package.swift` pins `https://github.com/NoiXdev/swift-nio-ssh` at tag
`0.3.8`, a fork this project already controls (see
`docs/superpowers/specs/2026-08-20-backlog-dependencies.md` for how that
fork came to be pinned). A change on the fork's side to decouple the
blob tag from the signature name is therefore in reach in a way "wait
for upstream" is not.

That does not make the fix designed, scoped, or safe:

- **Not measured:** whether decoupling the two on the fork's `.custom`
  key path would produce a blob BOTH OpenSSH `sshd` and a Go-based
  server accept. It is a reasonable expectation — a blob tagged
  `ssh-rsa` with a `rsa-sha2-512` signature algorithm is exactly the
  RFC 8332 shape — but nobody has built the fork change and run it
  against either kind of server.
- **Not measured:** whether any other consumer of the fork's `.custom`
  key path (this project's own code, or something else the fork
  serves) currently relies on the blob tag and algorithm name being the
  same string, the way `AgentBackedPrivateKey.swift`'s doc comment
  describes swift-nio-ssh's write path assuming today.
- **Not designed:** what the fork's API change would look like, how it
  is tested, or how macSCP's `AgentAlgorithm.RSASha512` marker would
  change to use it. None of that is decided here.

This entry records the corrected premise and where the fix would live if
someone designs it. It does not design the fix.

## Fixed 2026-09-02 (night) — the blob is typed `ssh-rsa`, the name stays `rsa-sha2-512`

Plan `../plans/2026-09-02-rsa-blob-typing-rfc8332.md`; the fork record in
`2026-08-20-backlog-dependencies.md` ("the user-auth split").

**Measured first, on a real Go server.** The rig gained an SFTPGo service
(`drakkan/sftpgo:v2.6.6`, port 2240, admin API on 18091; `a6518dd`), and
the gated `GoServerRSAIntegrationTests` (`513e34e`) pinned today's
refusal for both paths: an RSA file key and an RSA agent identity are
both dropped with macSCP seeing
`RemoteFSError.connectionFailed(reason: "Disconnected()")` and SFTPGo
logging `ssh: unknown key algorithm: rsa-sha2-512` (`login_type:
"no_auth_tried"`). That corrects the sentence above: the user did NOT
see "authentication failed" — `x/crypto/ssh` cannot parse the blob and
disconnects before any auth request is judged. ed25519 against the same
server was green, so the rig itself was proved.

**Where the fix went, and why not where the plan first said.** The plan
assumed NIOSSH wrote `pkalg` and the blob from two identifiers; the
Citadel implementer measured one (`NIOSSHPublicKey.keyPrefix` feeds all
three: `pkalg`, the blob's type, the signed payload's copy) and stopped,
because a blob-only flip yields `pkalg = ssh-rsa`, which OpenSSH ≥ 8.8
refuses. So: swift-nio-ssh `0.3.10` adds `userAuthAlgorithmName` beside
`publicKeyPrefix` (the sibling of 0.3.9's `hostKeyAlgorithmNames`),
Citadel `0.12.1-noix.3` sets both members on its RSA-SHA2 types, and
macSCP's own agent-backed RSA type sets the same two. Wire read back
from a serialised request: `rsa-sha2-512 / ssh-rsa / rsa-sha2-512`.

**Measured after the fix (`002af4a`, `6740c2a`), against the same rig:**
SFTPGo accepts both — file key: `User "testuser" logged in with
"publickey: SHA256:kZQ/jj4ICRGi5Sa8H7MpuoPktDxQtb4QNyWIf23qyNc:macscp-itest"`;
agent identity: `…publickey: SHA256:8JyOqFoTRYERLdK9lW79VS8a1Z9HQ6J6xVTnaVxibRs:macscp-itest`.
OpenSSH kept accepting: the ten-cell file matrix on 2222, the agent
matrix, and the RSA host key on 2235 all green. Two probes stand in for
a server log that never names the algorithm: reverting the blob type
alone reds SFTPGo's agent row with the old `Disconnected()`; deleting
`userAuthAlgorithmName` reds BOTH servers (SFTPGo: `ssh: algorithm
"ssh-rsa" not accepted`). Registration: four types declare the `ssh-rsa`
blob prefix, exactly one is registered in macSCP's process
(`RSASHA2HostKey`; Citadel's registrations run only through an
`algorithms:` argument macSCP never passes) — that ordering is
load-bearing for host-key parsing; since `0d09d6b` an ungated test pins
that the registered claimant is the one with the modulus floor (a
floor-less claimant registered ahead of it turns the test red), and the
agent type's two identifiers are pinned ungated as well.

