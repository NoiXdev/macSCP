# M10c — Jump host (design)

Date: 2026-07-28 · Status: approved by the maintainer ("yes, that works"; mockup
frozen: `docs/design/assets/m10-mockups.html` section 2)

## Goal

Connections via an intermediate host (ProxyJump): an optional jump block in
the connection form with its own login choice (a login set from M10b OR
manual), its own TOFU flow for BOTH hops, saved sessions remember their
jump configuration. Deliberately ONE hop — chains are backlog.

**Maintainer decisions (2026-07-28):**

1. Export (M9a): the jump configuration is exported RESOLVED (login sets →
   plaintext values as in M10b; password only when the password option is
   enabled). Old app versions ignore the new fields.
2. One hop; merge detection stays target-only (jump logins do not
   participate in equality detection — backlog).

## 1. Connection setup (Core, RISK)

- Feasibility verified: the pinned Citadel version has
  `SSHClient.jump(to: SSHClientSettings)` — opens a direct-tcpip channel
  over the existing client and drives a full SSH session over it with its
  OWN auth and its OWN host-key validator
  (`.build/checkouts/Citadel/Sources/Citadel/Client.swift:197`).
- `SSHConnectionConfig.jump: Jump?` — `struct Jump: Equatable, Sendable`
  with `host/port/username/auth` (same validation rules as the target:
  host/username non-empty trimmed, port 1…65535; checked in the config
  init).
- `CitadelFileSystem.connect` in two stages: (1) a jump client via
  `SSHClient.connect` with a TOFU validator + box for the JUMP host, (2)
  `jumpClient.jump(to:)` with the target settings, TOFU validator + box
  for the TARGET, (3) `openSFTP()` on the target client.
- TOFU retry semantics: the previous "unknown → decider → upsert → exactly
  ONE retry" logic becomes a bounded loop with **at most two accept
  retries (one per hop)**. Every accept upserts the key; the same key
  never prompts twice. A mismatch stays the hard stop on EVERY hop (the
  decider is never asked); all existing TOFU invariants untouched.
- Lifecycle: `CitadelFileSystem` holds the jump client; `disconnect`
  closes the target client, THEN the jump client; every failure path in
  connect closes an already-open jump client (no leak). SFTP and terminal
  (withPTY) continue to multiplex unchanged over the TARGET client — the
  "one connection per tab" invariant stays.
- Error honesty: `HostKeyError` carries the host (prompt/mismatch show
  which hop). Auth failures at stage 1 are surfaced as a NEW case
  `RemoteFSError.jumpAuthenticationFailed` (additive; existing switches
  have default branches), so the form marks the JUMP fields instead of
  misleadingly marking the target password; the remaining stage-1 errors
  carry a jump context in the reason string
  (`connectionFailed(reason: "jump host: …")`).
- Gated integration test against the rig: container 1 (2222) as a jump to
  container 2 — target address as seen from the jump container (an
  internal compose service name; fallback host gateway). T1 verifies
  reachability empirically before the test is committed.

## 2. Model + persistence

- `StoredSession.jump: JumpSpec?` — a nested
  `struct JumpSpec: Codable, Equatable, Sendable` with `host: String`,
  `port: Int`, `username: String`, `authKind: StoredSession.AuthKind`,
  `keyPath: String?`, `loginSetID: UUID?`, `secretID: UUID`. Optional
  WITHOUT a custom decoder (the groupID/loginSetID pattern): legacy JSON
  reads nil.
- Keychain: manual jump secrets live under `secretID` (its own slot — the
  session slot belongs to the target); `secretID` is generated when the
  JumpSpec is created. Jump in set mode uses the set's slot (M10b).
- Deleting a session also deletes the jump slot. A session update that
  removes the jump or switches to set mode cleans up the orphaned
  `secretID` slot.
- **Deleting a login set (the M10b fallback) ALSO restores jump
  references**: sessions whose `jump.loginSetID` points at the set get
  username/authKind/keyPath copied into the JumpSpec and the set's secret
  into their `secretID` slot; counting/error tolerance as with the
  existing fallback (a keychain error counts, does not abort). The delete
  confirmation counts jump references too.
- Merge detection (LoginMergePlanner) stays target-only, unchanged.
- Resolution on connect: jump login analogous to `LoginResolver` (set →
  values + set secret; a missing referenced set ⇒ an honest message, no
  silent fallback — as with M10b for the target).

**Known limitation (final review M-5, KnownHosts):** the TARGET's known
key is managed exclusively via its own literal address (`host`/`port`) —
on the two-hop connect, `CitadelFileSystem` passes `config.host`/
`config.port` through unchanged to the target `TOFUHostKeyValidator`,
without folding the jump used into the key. Two different machines that
happen to be reachable under the same literal target address via
different bastions therefore share ONE KnownHosts entry. This is
deliberately fail-closed: a differing key still triggers the hard stop
(`HostKeyError.mismatch`, no decider call) instead of a silent pass-through
— the security property is preserved, only the error message currently
does not name the jump context ("via which bastion"). A jump-aware key
(e.g. `host@via-jump-host`) is backlog, not M10c scope.

## 3. Form (exactly mockup section 2)

- Toggle "Connect via an intermediate host (ProxyJump)", default OFF.
- Switched on: bastion host + port + the M10b three-way building blocks
  for the jump login (login-set picker OR manual with user +
  password/key). The bastion and the target may use different sets; "Save
  as a new login set" exists ONLY for the target (the jump offers
  set/manual — YAGNI).
- Validation: toggle on ⇒ jump host non-empty, port numeric, a login
  chosen (set) or user+password/key filled in (manual).
- Edit mode shows the remembered state (JumpSpec ⇒ toggle on + set
  preselection or manual prefill; password field "unchanged" prompt).
- On first contact, up to TWO TOFU prompts in sequence (bastion first,
  then target) via the existing prompt mechanism — the prompt shows the
  respective host.
- ConnectionViewModel fields (Core, plain stored properties):
  `jumpEnabled: Bool`, `jumpHost/jumpPort/jumpUsername/jumpPassword/
  jumpKeyPath: String`, `jumpAuthChoice`, `jumpLoginMode`,
  `jumpSelectedLoginSetID: UUID?`.

## 4. Export/import (M9a extension)

- `ExportedSession` gets OPTIONAL jump fields (host/port/user/authKind/
  keyPath + `jumpPassword` only with `includePasswords`); login sets are
  resolved on export (M10b pattern); a missing jump set exports the
  session with its own jump values, export never aborts. Missing jump
  secrets count in missingPasswordCount.
- The format stays v1 (additive optional fields): old app versions ignore
  them and import the session without a jump.
- Import creates fresh `secretID` slots for supplied jump passwords;
  keychain errors count as before.
- ssh-config ProxyJump import: backlog (mockup decision).

## 5. Tests

- Config: jump validation (empty host/user, port bounds), Equatable.
- JumpSpec: decode compatibility with old sessions.json (nil), roundtrip.
- TOFU two-stage-ness, mock-side: accept per hop (two retries), mismatch
  on hop 1 and hop 2 = hard stop, reject saves nothing.
- Secret lifecycle: save creates the `secretID` slot, session delete
  cleans it up, jump removal/set switch cleans it up, set-delete fallback
  copies values+secret into the JumpSpec.
- Resolver: jump-set resolution including a missing set (typed error).
- Export: resolved jump, password gating, import roundtrip with a fresh
  secretID; an old file without jump fields reads nil.
- Gated: jump integration test container 1 → container 2 (SFTP listing
  over the hop, byte-exact transfer optional).
- UI: visual smoke test (T4 checklist for the maintainer).

## 6. Breakdown

T1 config + two-stage connect + rig test (RISK) → T2 JumpSpec + VM
(save/edit/delete/fallback/resolver/export) → T3 App (form block, wiring,
edit, L10n) → T4 wrap-up. NO release (standing rule).

## 7. Deliberately NOT in M10c

- No jump chains (one hop), no ssh-config ProxyJump import, no merge
  detection for jump logins, no "save as a new set" in the jump block, no
  ssh-agent (M10d).
