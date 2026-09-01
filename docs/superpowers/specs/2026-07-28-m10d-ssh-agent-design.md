# M10d — ssh-agent authentication (design)

Date: 2026-07-28 · Status: approved by the maintainer ("let's go")

## Goal

Authentication via the local ssh-agent as a THIRD auth kind everywhere
(form target + jump, login sets, stored sessions). The private key never
leaves the agent; macSCP speaks the agent protocol over `SSH_AUTH_SOCK`
itself.

**Maintainer decisions (2026-07-28):**

1. Scope: agent auth ONLY. Agent FORWARDING (including the "forward per
   host + global default" setting) is its own later milestone — the
   feasibility analysis showed that forwarding requires a maintained fork
   of swift-nio-ssh (the parser hard-throws on
   `auth-agent@openssh.com` channel opens; outbound channel requests are
   sealed off), whereas auth works without a fork via the official
   extension point.
2. No identity picker in M10d: behavior like OpenSSH — identities are
   offered in order. Pinning a preferred identity = backlog.

## Feasibility basis (verified against the vendored sources)

- `NIOSSHPrivateKeyProtocol` + `NIOSSHPrivateKey.init(custom:)` are the
  official custom-signer hook (swift-nio-ssh `CustomKeys.swift:23-89`,
  `NIOSSHPrivateKey.swift:50-52`); Citadel's `Insecure.RSA.PrivateKey`
  (`Citadel/Algorithms/RSA.swift:167-255`) is the production model.
- The blob to sign is exactly RFC 4252 §7
  (`UserAuthSignablePayload.swift:32-55`) — identical to the `data` field
  of `SSH_AGENTC_SIGN_REQUEST`. The custom key receives it raw/unhashed.
- No `NIOSSHAlgorithms` registration is needed (the registry is only
  consulted when PARSING foreign types; we only send).
- swift-nio (NIOPosix `ClientBootstrap` with
  `SocketAddress(unixDomainSocketPath:)`) is already transitively in the
  tree.

## 1. Agent client (Core, RISK)

- `SSHAgentCodec` (pure, testable): framing uint32 length + type byte;
  requests `SSH_AGENTC_REQUEST_IDENTITIES` (11) /
  `SSH_AGENTC_SIGN_REQUEST` (13); responses
  `SSH_AGENT_IDENTITIES_ANSWER` (12) / `SSH_AGENT_SIGN_RESPONSE` (14) /
  `SSH_AGENT_FAILURE` (5). Identities response: list of
  (pubkey blob, comment); type string and SHA256 fingerprint are derived
  from the blob (reuse the existing fingerprint helpers from M3c where
  they fit).
- `SSHAgentClient`: transport protocol (injectable; in production a
  NIO `ClientBootstrap` on the UDS path from `SSH_AUTH_SOCK`), API
  `listIdentities() async throws -> [AgentIdentity]` and
  `sign(publicKeyBlob:data:flags:) async throws -> Data`
  (raw signature response: `string` with algo + blob).
- RSA identities (blob type `ssh-rsa`): SIGN_REQUEST with
  `SSH_AGENT_RSA_SHA2_256` (2) or preferably `…_512` (4) flags —
  a named residual risk, covered by the gated live test.
- Typed errors: `AgentError.socketUnavailable`
  (`SSH_AUTH_SOCK` missing/connection fails), `.noIdentities`,
  `.refused` (FAILURE frame), `.protocolError(reason:)`.

## 2. NIOSSH binding + connect (Core, RISK)

- `AgentBackedPrivateKey: NIOSSHPrivateKeyProtocol` (one instance per
  agent identity; `signature(for:)` passes the blob through to
  `SSHAgentClient.sign`) + `AgentSignature: NIOSSHSignatureProtocol`
  and `AgentBackedPublicKey: NIOSSHPublicKeyProtocol`, which re-emit the
  blob supplied by the agent VERBATIM.
- `SSHConnectionConfig.AuthMethod.agent` (no payload). The connect path
  (CitadelFileSystem) builds an `SSHAuthenticationMethod` for it that
  offers the agent identities IN ORDER (OpenSSH behavior; NIOSSH's
  delegate is asked again on each failed attempt — the Citadel pattern
  `SSHAuthenticationMethod` with a consumable list). Bounded: each
  identity exactly once.
- Identities are listed ONCE at connect time (no re-listing between
  attempts); the jump hop and target hop may both use `.agent` (each
  with its own signatures, same agent).
- Error mapping: `.socketUnavailable`/`.noIdentities` ⇒ their own
  localized, HONEST messages (no generic "Auth failed");
  all identities rejected ⇒ `RemoteFSError.authenticationFailed`
  (at the jump hop: `jumpAuthenticationFailed` — the existing
  stage-1 classification applies unchanged). TOFU invariants
  untouched.

## 3. Model everywhere (Core)

- `StoredSession.AuthKind.agent` (raw "agent" — exactly the value that
  M10b's logins.json record store was built forward-compatible for).
  `keyPath` stays nil; keychain slots stay untouched for agent logins
  (slot hygiene: switching to `.agent` clears an old manual slot the
  same way a set change does).
- `JumpSpec.authKind` inherits `.agent` automatically (same enum).
- Login sets: `.agent` sets (no secret, no keyPath); editor third
  segment; AGENT badge in the sheet; `LoginResolver.resolve/resolveJump`
  return `ResolvedLogin` with `authKind: .agent`, `secret: nil`.
- Merge detection: agent groups = same username (no secret comparison;
  sessions with `.agent` participate WITHOUT keychain access).
- Deletion restore: `.agent` sets copy back only username/authKind
  (no secret transfer — a trivial special case of the existing
  machinery).
- Export/import: `authKind` "agent" travels along as a value (no
  password); import takes it over.

## 4. Known downgrade boundary (deliberately accepted)

`logins.json` is safe thanks to M10b (older versions skip over "agent"
records on read). `sessions.json` and export files are NOT: an older app
version fails to decode an "agent" session's enum (the file reads empty,
or import fails). Affects only downgrades AFTER using the feature;
documented as a boundary, no countermeasure in M10d.

### 4a. T2 review addenda (reconnect behavior + RSA boundary)

**Per-identity RECONNECT instead of repeated delegate calls (verified):**
Citadel's `SSHAuthenticationMethod.custom(_:)` consumes its delegate
EXACTLY ONCE per connection attempt (`implementations.removeFirst()` empties
the single `.custom(delegate)` entry permanently on the first call). If the
agent offers N identities, that means N SEPARATE
`SSHClient.connect()`/`jump(to:)` calls — each a FRESH
`SSHAuthenticationMethod.custom(...)` wrapper around the same
`AgentAuthDelegate` instance, whose internal cursor (`remaining`) advances
across the calls this way (see `CitadelFileSystem.connectHop`). From the
target server's point of view, each failed attempt appears as a SEPARATE
failed login — visible on the sysadmin side, e.g. in `auth.log`/
`journalctl`, as several `Failed publickey` entries instead of a single
login process offering several keys. The count is deliberately capped
(see M-3/I-3: cap at `min(identities.count, 6)`, MaxAuthTries parity), so
that an agent with many identities does not generate login spam against
the server.

**I-2 addendum: the cap of 6 is NOT true MaxAuthTries parity, and that has
a fail2ban consequence.** `MaxAuthTries` counts auth OFFERS within ONE
single connection (one TCP/SSH handshake, several keys offered in
sequence). The per-identity reconnect above instead produces up to 6
SEPARATE, individually failed logins — each with its own
TCP-connect/SSH-handshake/auth attempt, visible as 6 individual
`Failed publickey` entries instead of one process with 6 offers (more, on
top TOFU retries). fail2ban's stock jail for `sshd` defaults to
`maxretry = 5`. A user with ≥5 agent identities, all of which the target
server rejects (e.g. on the first connection attempt to a new host, or
when none of the offered keys is authorized there), can lock out their own
IP on a fail2ban-protected host — triggered by ONE connection attempt in
macSCP, not by repeated manual attempts. The cap stays at 6 (maintainer
decision still pending); this consequence is hereby deliberately
documented, not mitigated by countermeasures.

**Known RSA boundary (verified, not hypothetical):** An
`ssh-rsa` identity is offered via the agent with the blob tag
`rsa-sha2-512` (swift-nio-ssh couples algorithm name and blob tag
inseparably for `.custom` keys, see `AgentBackedPrivateKey.swift`,
`AgentAlgorithm.RSASha512` documentation). Against real OpenSSH `sshd`
this works (gated `agentAuthConnectsRSA` test, Docker rig). Against
servers based on Go's `golang.org/x/crypto/ssh` (Gitea, Forgejo,
Gogs, `gitlab-sshd`, SFTPGo, etc.) it fails — verified directly against
`x/crypto/ssh`, exact error message:

```
ssh: signature algorithm "rsa-sha2-512" isn't a key format; key is
malformed and should be re-encoded with type "ssh-rsa"
```

ed25519 and ECDSA identities are NOT affected (their blob tag and
signature name are already identical, no three-way coupling needed). The
actual fix would have to happen in swift-nio-ssh itself (decoupling blob
tag and algorithm/signature name for `.custom` keys) — outside macSCP's
scope; documented as a known boundary, not fixed in M10d.

## 5. App (form + sets editor)

- Auth segments for target AND jump: `Password | SSH Key | Agent`. Agent
  mode hides the password/key fields; validation requires only the
  username. `selectAuthChoice`/`selectJumpAuthChoice` clear secrets on
  switching as before.
- Set editor: third segment "Agent" (name + username suffice).
  LoginSetsSheet: AGENT badge (KEY/PASS pattern), short form
  `user · Agent`.
- Error messages: "No SSH agent reachable (SSH_AUTH_SOCK)."
  / "The SSH agent has no identities loaded." EN/DE, attached to the
  auth segment (jump variants mark the jump fields).
- Edit prefill: `.agent` ⇒ Agent segment, no secret fields.

## 6. Tests

- Codec, pure: framing round-trip, identities parse (several, empty),
  sign-request bytes (incl. RSA flags), FAILURE frame ⇒ `.refused`,
  garbage ⇒ `.protocolError`.
- Client with mock transport: listIdentities/sign sequence, dead socket ⇒
  `.socketUnavailable`.
- Auth order with mock: identities in sequence, success stops, all
  rejected ⇒ authenticationFailed; `.agent` on the jump ⇒
  `jumpAuthenticationFailed` classification.
- Model: AuthKind.agent decode/encode, set without a secret, resolver,
  merge grouping by username, restore, export/import round-trip.
- Gated (MACSCP_ITEST, rig): the test starts its OWN `ssh-agent` process
  (SSH_AUTH_SOCK from its output), `ssh-add` with a generated
  ed25519 key, the pubkey pushed into the rig via docker-exec (M3b
  pattern), connect with `.agent` ⇒ list("/"); an RSA variant for the
  sha2-flag negotiation; the agent process is killed in teardown. One
  test with a dead socket path ⇒ `.socketUnavailable` (can run ungated).
- App: visual smoke (T5) including the maintainer's real agent
  (1Password/ssh-agent).

## 7. Breakdown

T1 agent codec + client (RISK) → T2 NIOSSH key + AuthMethod.agent +
connect incl. jump + gated live tests (RISK) → T3 model/VM/sets/export →
T4 app (segments, editor, L10n) → T5 closing. NO release (standing
rule).

## 8. Deliberately NOT in M10d

- No agent forwarding (its own fork milestone, backlog), no per-host
  forwarding settings, no identity picker/pinning, no sessions.json
  downgrade safeguard, no FIDO/sk special path (sk identities work as
  long as the agent signs them normally).
