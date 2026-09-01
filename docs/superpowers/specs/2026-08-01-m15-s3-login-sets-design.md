# M15 — Complete S3 login sets (design/spec)

**Date:** 2026-08-01
**Status:** approved (brainstorm), ready for writing-plans
**Branch:** `develop`
**Predecessor:** M12 T6 (login set foundation: `kind`+`accessKeyID`, store,
export/import, `LoginResolveError.kindMismatch`), M14 (presigned URLs).

## Goal

An S3 login set (a reusable access key ID + secret) can be created, bound
to an S3 session/connection, and resolved correctly on connect —
symmetric to SSH login sets. This closes the three gaps M12 T6
deliberately left open (resolver, editor UI, form integration).

## Starting point (as-is)

- **Core foundation present:** `LoginSet.kind`(ssh/s3) + `accessKeyID`
  (`LoginSetStore.swift`), the store persists both, secret in Keychain
  under `set.id`, export/import carries `kind`+S3, `LoginResolveError.kindMismatch`
  exists.
- **Gap 1 (Core):** `LoginResolver.resolve(session:sets:secrets:)` only
  returns `ResolvedLogin` (username/authKind/keyPath/secret) — no `accessKeyID`.
  An S3 session bound to an S3 set gets **no** credentials on connect.
- **Gap 2 (App):** `LoginSetEditorView` (`LoginSetsSheet.swift`) is
  SSH-only (auth picker + username/keyPath/secret). No ssh/s3 switch,
  no S3 fields → **no S3 login set can be created**.
- **Gap 3 (App):** The `Login` switch (login set / manual) only sits in
  the SSH branch of `ConnectionFormView`. The S3 section is manual-entry
  only → **an S3 session cannot use a set**.
- **Persistence gap:** The S3 `save(...)` branch in
  `ContentView.swift` (~1893) passes **no** `loginSetID` → a
  set-bound S3 session could not even save the binding.

## Decisions (maintainer, 2026-08-01)

1. **Set contents:** An S3 login set carries **only access key ID +
   secret**. Region/endpoint/bucket stay on the session (the "where to").
   Mirrors SSH (login = credentials, session = address); the M12 store
   also only has `accessKeyID`.
2. **Resolver shape:** **Own `ResolvedS3Login` type** + own
   `resolveS3` method, rather than extending `ResolvedLogin`. The connect
   path already knows the `kind` (`switch kind`), so it calls the matching
   method directly. Scales cleanly to later backends (each connection
   type brings its own `Resolved…` type).
3. **Picker filter:** The set picker in the form shows **only kind-matching
   sets** (S3 session → S3 sets only). `kindMismatch` remains the hard
   safeguard behind it.
4. **Full SSH parity in the form:** S3 manual mode gets the same
   "save as new login set" path as SSH.

## Architecture

### Core

**New type** (parallel to `ResolvedLogin`, `LoginResolver.swift`):

```swift
/// S3 credentials, resolved from a login set (M15). Parallel to
/// `ResolvedLogin`; `secretAccessKey` is the set's Keychain entry
/// (under `set.id`), nil if none is stored.
public struct ResolvedS3Login: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String?

    public init(accessKeyID: String, secretAccessKey: String?) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}
```

**New resolver method** (`LoginResolver`), mirroring `resolve`:

```swift
public static func resolveS3(
    session: StoredSession, sets: [LoginSet], secrets: any SecretStore
) throws -> ResolvedS3Login?
```

Behavior:

| Case | Result |
|------|----------|
| `session.loginSetID == nil` | `nil` (manual S3 session, uses its own data) |
| bound, `set.kind == .s3` | `ResolvedS3Login(accessKeyID: set.accessKeyID ?? "", secretAccessKey: (try? secrets.password(for: set.id)) ?? nil)` |
| bound, `set.kind == .ssh` | throws `LoginResolveError.kindMismatch` |
| `loginSetID` points to no set | throws `LoginResolveError.missingSet` |

The existing `resolve` (SSH) stays **unchanged** and keeps throwing
`kindMismatch` when an SSH session binds an S3 set (symmetry).

**VM wrapper** (`SessionListViewModel`), thin like `resolvedLogin(for:)`:

```swift
public func resolvedS3Login(for session: StoredSession) throws -> ResolvedS3Login? {
    try LoginResolver.resolveS3(session: session, sets: loginSets, secrets: secrets)
}
```

### App

**A) `LoginSetEditorView` (`LoginSetsSheet.swift`):**

- New **kind switch** (segmented, at the top): `SSH` / `S3`. When
  editing, initialized to `existing.kind`.
- `kind == .ssh` → today's block unchanged (username + auth +
  secret/keyPath).
- `kind == .s3` → only **access key ID** (TextField) + **secret access
  key** (`SecureField`). No username/keyPath/authKind.
- Set name stays for both.
- `Save` builds an SSH or S3 `LoginSet` depending on `kind`
  (`LoginSet(kind: .s3, accessKeyID: …)`, username/authKind at their
  defaults) and calls the same `onSave(set, secret)`. The existing
  edit rule "empty secret = unchanged" applies to both.
- `isSaveDisabled` per kind: SSH as today; S3 requires a non-empty
  access key ID (secret required on new creation, optional on edit —
  same logic as the SSH secret).

**Badge/list** (`LoginSetsSheet.swift`, `authKindBadge`/`badgeStyle`,
row label): S3 sets get an **`S3` badge** (its own token pair like
`KEY`/`AGENT`/`PASS`). Row label for S3: `name — accessKeyID` instead
of `name — username`.

**B) `ConnectionFormView.swift` — S3 section:**

- The `Login` switch (login set / manual, segmented) moves into the
  S3 section (currently SSH branch only).
- **Set mode** → set picker `ForEach(sessionList.loginSets.filter { $0.kind == .s3 })`,
  row label `name — accessKeyID`, next to it a "Manage logins…" button.
- **Manual mode** → today's S3 fields + "Save as new login set" toggle
  (SSH parity).
- **region/endpoint/bucket** stay visible session fields in **both**
  modes.

**C) Fill paths (`ContentView.swift`):**

1. `fillForm(_:from:)` (~1601) gets an S3 branch: if the chosen set's
   `kind == .s3`, fill `form.s3AccessKeyID = set.accessKeyID ?? ""` and
   `form.s3SecretAccessKey` from the Keychain (synthetic `StoredSession`
   under `set.id`, like the SSH branch). `resolveSelectedLoginSet(in:)`
   then calls it the same way for S3 sessions.
2. Saved session connect (`stored.kind == .s3` block, ~2008): if
   `stored.loginSetID != nil`, resolve via `resolvedS3Login(for:)` and
   fill `s3AccessKeyID`/`s3SecretAccessKey` from it; region/endpoint/bucket
   continue from `stored.s3`. `kindMismatch`/`missingSet` land in the
   existing `loginSets.missingSet` error path (show the form instead of
   connecting). Set `form.loginMode`/`selectedLoginSetID` from
   `stored.loginSetID`.

**D) Close the persistence gap (`ContentView.swift`, S3 `save`, ~1893):**
Pass `loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID`
(currently the parameter is missing entirely). `maybeCreateNewLoginSet(from:)`
gets an S3 branch that creates a `LoginSet(kind: .s3, accessKeyID: …)` +
secret (Keychain).

## Security / invariants

- Secret exclusively in the Keychain, addressed via `set.id`; never in
  JSON, logs or URLs.
- `kindMismatch` remains a hard stop — **no** fallback to
  wrongly-typed credentials.
- No `if kind == .s3` special path in the signer/transport: resolution
  ends up in the existing `S3ConnectionConfig` construction
  (`connectS3`), which stays unchanged.
- No new external dependency.

## Tests

**Core unit (Swift Testing, TDD red→green):**

1. `resolveS3` happy path: set-bound S3 session → `accessKeyID` from set +
   secret from Keychain.
2. `resolveS3` manual (`loginSetID == nil`) → `nil`.
3. `resolveS3` `kindMismatch`: S3 session binds SSH set → throws.
4. `resolveS3` `missingSet`: dangling `loginSetID` → throws.
5. Regression guard: SSH session with SSH set still returns
   `ResolvedLogin` unchanged.
6. Symmetry guard: `resolve` (SSH) still throws `kindMismatch` for
   SSH session + S3 set.

**Gated MinIO (`MACSCP_ITEST=1`, from the main checkout):**

- Create an S3 login set → bind an S3 session to it → connect → list
  bucket succeeds. Proves that the set-resolved credentials actually
  authenticate against MinIO (not just against a fake).

**Runtime smoke (maintainer):** In the dev build, create an S3 set,
bind a session, connect — visual check.

## L10n

New user-visible strings (editor kind switch "SSH"/"S3", S3 field
labels if new, `S3` badge, picker placeholder if any) in EN/DE/FR/PL,
typographic quotes, FR/PL AI-generated (native review before release).
Existing S3 field labels (Access Key ID, Secret Access Key) are reused
where present.

## Not in M15

- Cross-backend transfer S3↔SSH (→ M16).
- "Open with" S3 CLI tool, connection diagnostics, SSH key manager,
  SSH terminal snippets (own later milestones).

## Files affected

- `Sources/macSCPCore/Sessions/LoginResolver.swift` — `ResolvedS3Login`,
  `resolveS3`.
- `Sources/macSCPCore/Presentation/SessionListViewModel.swift` —
  `resolvedS3Login(for:)`.
- `Sources/MacSCPApp/LoginSetsSheet.swift` — kind switch, S3 fields,
  S3 badge, S3 row label, kind-dependent save/disable.
- `Sources/MacSCPApp/ConnectionFormView.swift` — login switch +
  filtered picker + "save as new set" toggle in the S3 section.
- `Sources/MacSCPApp/ContentView.swift` — `fillForm` S3 branch,
  saved session connect S3 resolve, S3 `save` `loginSetID`,
  `maybeCreateNewLoginSet` S3 branch.
- `Tests/macSCPCoreTests/…` — `resolveS3` unit tests + gated MinIO.
- String catalogs (App + Core) EN/DE/FR/PL.
